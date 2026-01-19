//
//  QueueListView.swift
//  Spotifly
//
//  Displays current playback queue (real-time updates via Spirc/Mercury)
//

import SwiftUI

extension Notification.Name {
    static let scrollToCurrentTrack = Notification.Name("scrollToCurrentTrack")

    // Toolbar menu actions
    static let showAlbumRemoveConfirmation = Notification.Name("showAlbumRemoveConfirmation")
    static let showArtistUnfollowConfirmation = Notification.Name("showArtistUnfollowConfirmation")
    static let showPlaylistEditDetails = Notification.Name("showPlaylistEditDetails")
    static let showPlaylistDeleteConfirmation = Notification.Name("showPlaylistDeleteConfirmation")
    static let showPlaylistUnfollowConfirmation = Notification.Name("showPlaylistUnfollowConfirmation")
}

struct QueueListView: View {
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(QueueService.self) private var queueService
    @Bindable var playbackViewModel: PlaybackViewModel

    @State private var scrollProxy: ScrollViewProxy?

    /// Queue item with track and provider info
    private struct QueueDisplayItem {
        let track: Track
        let provider: TrackProvider
    }

    /// Flattened queue with provider info: previous + current + next
    private var allQueueItems: [QueueDisplayItem] {
        var items: [QueueDisplayItem] = []

        // Previous tracks
        for entry in store.queue.previousTracks {
            if let track = store.tracks[entry.trackId] {
                items.append(QueueDisplayItem(track: track, provider: entry.provider))
            }
        }

        // Current track
        if let entry = store.queue.currentTrack, let track = store.tracks[entry.trackId] {
            items.append(QueueDisplayItem(track: track, provider: entry.provider))
        }

        // Next tracks
        for entry in store.queue.nextTracks {
            if let track = store.tracks[entry.trackId] {
                items.append(QueueDisplayItem(track: track, provider: entry.provider))
            }
        }

        return items
    }

    /// Currently playing index (position after previous tracks)
    private var currentIndex: Int {
        store.currentIndex
    }

    /// Total song count for header
    private var totalSongCount: Int {
        store.queueLength
    }

    /// Unplayed song count for header (next tracks only)
    private var unplayedSongCount: Int {
        store.nextTrackEntities.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Fixed header
            queueHeader

            Divider()

            // Scrollable content
            if let error = store.queue.errorMessage {
                errorView(error)
            } else if allQueueItems.isEmpty {
                emptyView
            } else {
                normalModeContent
            }
        }
        .task {
            // Load favorites for queue items (queue itself auto-updates via Spirc subscription)
            let token = await session.validAccessToken()
            await queueService.loadFavorites(accessToken: token)
        }
        .onChange(of: store.queue.currentTrack?.trackId) { _, _ in
            // When queue updates, refresh favorites for new items
            Task {
                let token = await session.validAccessToken()
                await queueService.loadFavorites(accessToken: token)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrollToCurrentTrack)) { _ in
            scrollToCurrentTrack()
        }
    }

    // MARK: - Header

    private var queueHeader: some View {
        HStack(spacing: 12) {
            // Song count
            VStack(alignment: .leading, spacing: 2) {
                Text("queue.title")
                    .font(.headline)
                if totalSongCount > 0 {
                    Text("queue.song_count \(totalSongCount) \(unplayedSongCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: - Normal Mode Content

    private var normalModeContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(allQueueItems.enumerated()), id: \.offset) { index, item in
                        TrackRow(
                            track: item.track,
                            index: index,
                            currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                            currentIndex: currentIndex,
                            provider: item.provider,
                            playbackViewModel: playbackViewModel,
                            doubleTapBehavior: .playTrack,
                            currentSection: .queue,
                        )
                        .id(index)

                        if index < allQueueItems.count - 1 {
                            Divider()
                                .padding(.leading, 78)
                        }
                    }
                }
            }
            .contentMargins(.bottom, 100)
            .onAppear { scrollProxy = proxy }
        }
    }

    // MARK: - Error and Empty States

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("error.load_queue")
                .font(.headline)
            Text(error)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("empty.queue_empty")
                .font(.headline)
            Text("empty.queue_empty.description")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxHeight: .infinity)
    }

    // MARK: - Navigation

    private func scrollToCurrentTrack() {
        guard currentIndex < allQueueItems.count else { return }
        withAnimation {
            scrollProxy?.scrollTo(currentIndex, anchor: .center)
        }
    }
}
