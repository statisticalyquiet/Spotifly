//
//  QueueService.swift
//  Spotifly
//
//  Service for queue-related operations.
//  Queue structure (track URIs) is received from Spirc via Mercury protocol.
//  Track metadata is fetched from Spotify Web API and cached in the store.
//

import Combine
import Foundation

@MainActor
@Observable
final class QueueService {
    private let store: AppStore
    private let tokenProvider: () async -> String
    private var queueSubscription: AnyCancellable?
    private var setQueueSubscription: AnyCancellable?
    private var metadataFetchTask: Task<Void, Never>?
    private var pendingTrackIds: Set<String> = []
    private var debounceTask: Task<Void, Never>?

    init(store: AppStore, tokenProvider: @escaping () async -> String) {
        self.store = store
        self.tokenProvider = tokenProvider
        setupQueueSubscription()
        setupSetQueueSubscription()
    }

    // MARK: - Queue Subscriptions

    /// Subscribe to queue updates from Spirc (via Mercury protocol)
    /// This fires after round-trip to Spotify servers
    private func setupQueueSubscription() {
        queueSubscription = SpotifyPlayer.queue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] queueState in
                self?.handleQueueUpdate(queueState)
            }
    }

    /// Subscribe to set queue events from Spirc
    /// This fires immediately when the queue is set/modified (e.g., from mobile app)
    private func setupSetQueueSubscription() {
        setQueueSubscription = SpotifyPlayer.setQueue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleSetQueue(notification)
            }
    }

    /// Handle set queue notification (fires immediately when queue is set or context is loaded)
    private func handleSetQueue(_ notification: SetQueueNotification) {
        let contextInfo = notification.contextUri.isEmpty ? "" : " context=\(notification.contextUri),"
        debugLog("QueueService", "Set queue:\(contextInfo) prev=\(notification.prevTracks.count), current=\(notification.currentTrack != nil ? 1 : 0), next=\(notification.nextTracks.count)")

        // Convert to QueueEntries
        func toQueueEntry(_ trackInfo: SetQueueTrackInfo) -> QueueEntry? {
            guard let trackId = SpotifyAPI.parseTrackURI(trackInfo.uri) else { return nil }
            return QueueEntry(trackId: trackId, provider: TrackProvider(from: trackInfo.provider))
        }

        // Current track
        let currentEntry: QueueEntry? = notification.currentTrack.flatMap { toQueueEntry($0) }

        // Next tracks
        let nextEntries: [QueueEntry] = notification.nextTracks.compactMap { toQueueEntry($0) }

        // Previous tracks
        let prevEntries: [QueueEntry] = notification.prevTracks.compactMap { toQueueEntry($0) }

        store.setQueue(previous: prevEntries, current: currentEntry, next: nextEntries)

        // Fetch track metadata for IDs not already in store
        let allIds = prevEntries.map(\.trackId) + (currentEntry.map { [$0.trackId] } ?? []) + nextEntries.map(\.trackId)
        fetchTrackMetadata(for: allIds)
    }

    /// Handle queue update from Spirc callback (Mercury protocol)
    private func handleQueueUpdate(_ queueState: QueueState?) {
        guard let state = queueState else {
            store.setQueue(previous: [], current: nil, next: [])
            return
        }

        // Convert QueueItem to QueueEntry (extract track ID and provider)
        func toQueueEntry(_ item: QueueItem) -> QueueEntry? {
            guard let trackId = SpotifyAPI.parseTrackURI(item.uri) else { return nil }
            return QueueEntry(trackId: trackId, provider: TrackProvider(from: item.provider))
        }

        let currentEntry: QueueEntry? = state.currentTrack.flatMap { toQueueEntry($0) }
        let nextEntries = state.nextTracks.compactMap { toQueueEntry($0) }
        // previousTracks is nil when from Web API (which doesn't provide history)
        let previousEntries = state.previousTracks?.compactMap { toQueueEntry($0) }

        if let prevCount = previousEntries?.count {
            debugLog("QueueService", "Queue updated from Mercury: prev=\(prevCount), current=\(currentEntry != nil ? 1 : 0), next=\(nextEntries.count)")
        } else {
            debugLog("QueueService", "Queue updated from Web API: current=\(currentEntry != nil ? 1 : 0), next=\(nextEntries.count) (preserving previous)")
        }

        store.setQueue(previous: previousEntries, current: currentEntry, next: nextEntries)

        // Fetch track metadata for IDs not already in store
        let allIds = (previousEntries ?? []).map(\.trackId) + (currentEntry.map { [$0.trackId] } ?? []) + nextEntries.map(\.trackId)
        fetchTrackMetadata(for: allIds)
    }

    // MARK: - Metadata Fetching

    /// Fetch track metadata from Web API for tracks not already in the store
    /// Uses debouncing to avoid cancelling requests during rapid queue updates
    private func fetchTrackMetadata(for trackIds: [String]) {
        // Deduplicate IDs (queue can have duplicates)
        var seenIds = Set<String>()
        let uniqueTrackIds = trackIds.filter { seenIds.insert($0).inserted }

        guard !uniqueTrackIds.isEmpty else { return }

        // Filter to only tracks not already in the store
        let trackIdsToFetch = uniqueTrackIds.filter { store.tracks[$0] == nil }

        guard !trackIdsToFetch.isEmpty else {
            debugLog("QueueService", "All \(uniqueTrackIds.count) unique tracks already cached in store")
            // Update queue items from cached data
            updateNowPlayingMetadata()
            return
        }

        // Accumulate track IDs and debounce the fetch
        pendingTrackIds.formUnion(trackIdsToFetch)

        // Cancel previous debounce timer (not the fetch itself)
        debounceTask?.cancel()

        debounceTask = Task { [weak self] in
            // Wait for rapid updates to settle
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }

            await self?.executeFetch()
        }
    }

    /// Execute the actual fetch for accumulated track IDs
    private func executeFetch() async {
        let trackIdsToFetch = Array(pendingTrackIds)
        pendingTrackIds.removeAll()

        guard !trackIdsToFetch.isEmpty else { return }

        // Don't cancel ongoing fetch - let it complete and just add more
        // Wait for any in-progress fetch to complete first
        if let existingTask = metadataFetchTask {
            _ = await existingTask.value
        }

        // Re-filter in case some were fetched by previous task
        let stillNeeded = trackIdsToFetch.filter { store.tracks[$0] == nil }
        guard !stillNeeded.isEmpty else {
            updateNowPlayingMetadata()
            return
        }

        debugLog("QueueService", "Fetching \(stillNeeded.count) tracks from Web API")

        metadataFetchTask = Task { [weak self, tokenProvider] in
            guard let self else { return }

            do {
                let accessToken = await tokenProvider()
                debugLog("QueueService", "Using token: \(String(accessToken.prefix(20)))...")
                let trackData = try await SpotifyAPI.fetchTracks(accessToken: accessToken, trackIds: stillNeeded)

                guard !Task.isCancelled else { return }

                // Convert APITrack to Track and store in the global store
                var tracksToStore: [Track] = []
                for (trackId, apiTrack) in trackData {
                    let track = Track(
                        id: trackId,
                        name: apiTrack.name,
                        uri: apiTrack.uri,
                        durationMs: apiTrack.durationMs,
                        trackNumber: apiTrack.trackNumber,
                        externalUrl: apiTrack.externalUrl,
                        albumId: apiTrack.albumId,
                        artistId: apiTrack.artistId,
                        artistName: apiTrack.artistName,
                        albumName: apiTrack.albumName,
                        imageURL: apiTrack.imageURL,
                    )
                    tracksToStore.append(track)
                }

                // Store tracks in the global cache
                store.upsertTracks(tracksToStore)

                debugLog("QueueService", "Cached \(tracksToStore.count) tracks in store")

                // Update queue items from store
                updateNowPlayingMetadata()

            } catch {
                debugLog("QueueService", "Failed to fetch track metadata: \(error)")
            }
        }

        _ = await metadataFetchTask?.value
    }

    /// Update Now Playing info from current track in AppStore
    private func updateNowPlayingMetadata() {
        // Trigger Now Playing update - it reads from store.currentTrackEntity
        PlaybackViewModel.shared.updateNowPlayingInfo()

        let prevCount = store.previousTrackEntities.count
        let nextCount = store.nextTrackEntities.count
        let total = prevCount + (store.currentTrackEntity != nil ? 1 : 0) + nextCount
        debugLog("QueueService", "Queue tracks resolved: \(total) with metadata (prev=\(prevCount), next=\(nextCount))")
    }

    // MARK: - Favorites Loading

    /// Batch check favorite status for all queue tracks and store in AppStore
    func loadFavorites(accessToken: String) async {
        // Collect all queue track IDs
        var allIds = store.queue.previousTracks.map(\.trackId)
        if let currentId = store.queue.currentTrack?.trackId {
            allIds.append(currentId)
        }
        allIds.append(contentsOf: store.queue.nextTracks.map(\.trackId))

        // Deduplicate IDs (queue can have duplicates)
        var seenIds = Set<String>()
        let trackIds = allIds.filter { seenIds.insert($0).inserted }

        guard !trackIds.isEmpty else { return }

        do {
            let statuses = try await SpotifyAPI.checkSavedTracks(
                accessToken: accessToken,
                trackIds: trackIds,
            )
            store.updateFavoriteStatuses(statuses)
        } catch {
            // Silently fail - favorites just won't show
        }
    }
}
