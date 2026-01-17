//
//  PlaybackViewModel.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import Combine
import QuartzCore
import SwiftUI

import MediaPlayer

// MARK: - Drift Correction Timer

/// Helper class for periodic drift correction (not UI updates)
/// Uses a plain Thread with isCancelled check to avoid Swift concurrency issues
private final class DriftCorrectionTimer {
    private var thread: Thread?
    static let checkNotification = Notification.Name("DriftCorrectionCheck")

    func start() {
        let notificationName = DriftCorrectionTimer.checkNotification
        let thread = Thread {
            while !Thread.current.isCancelled {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: notificationName, object: nil)
                }
                // Check drift every second (not 100ms - UI uses TimelineView now)
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
        thread.name = "com.spotifly.drift-correction"
        thread.qualityOfService = .utility
        thread.start()
        self.thread = thread
    }

    func stop() {
        thread?.cancel()
        thread = nil
    }
}

// MARK: - Playback View Model

@MainActor
@Observable
final class PlaybackViewModel {
    /// Shared singleton instance - ensures only one timer runs
    static let shared = PlaybackViewModel()

    var isPlaying = false
    var isLoading = false
    var currentTrackUri: String?
    var errorMessage: String?

    /// Returns the URI of the currently playing track (alias for currentTrackUri)
    var currentlyPlayingURI: String? {
        currentTrackUri
    }

    // Playback state from Mercury (duration/position for progress bar)
    var trackDurationMs: UInt32 = 0
    var currentPositionMs: UInt32 = 0

    // Current track metadata for Now Playing info (set by QueueService)
    private(set) var currentTrackName: String?
    private(set) var currentArtistName: String?
    private(set) var currentAlbumArtURL: String?

    // Volume (0.0 - 1.0)
    var volume: Double = 0.5 {
        didSet {
            // Skip applying to Spirc if this change came from a remote volume callback
            guard !isSettingVolumeLocally else { return }
            // Debounce volume changes to avoid flooding Spirc with requests
            debounceVolumeChange()
            saveVolume()
        }
    }

    // Favorite status of currently playing track
    var isCurrentTrackFavorited = false

    private var isInitialized = false
    private var lastAlbumArtURL: String?
    private var playbackStateSubscription: AnyCancellable?
    private var volumeSubscription: AnyCancellable?
    private var sessionDisconnectedSubscription: AnyCancellable?
    private var sessionConnectedSubscription: AnyCancellable?
    private var loadingSubscription: AnyCancellable?
    /// Flag to prevent feedback loop when we set volume locally
    private var isSettingVolumeLocally = false
    /// Debounce task for volume changes
    private var volumeDebounceTask: Task<Void, Never>?
    /// Token provider for reinitialization after session disconnect
    private var tokenProvider: (@Sendable () async -> String)?

    /// State to restore after seamless reconnection
    private var pendingResumeTrackUri: String?
    private var pendingResumePositionMs: UInt32 = 0
    private var pendingResumeWasPlaying: Bool = false

    /// Timestamp when session was disconnected (for logging elapsed time on reconnect)
    private var disconnectedAt: Date?

    /// Reconnection state for exponential backoff
    private var reconnectAttempt: Int = 0
    private var reconnectTask: Task<Void, Never>?
    private let maxReconnectAttempts = 10

    private init() {
        setupPlaybackStateSubscription()
        setupVolumeSubscription()
        setupSessionDisconnectedSubscription()
        setupSessionConnectedSubscription()
        setupLoadingSubscription()
        setupRemoteCommandCenter()

        // Load saved volume (but don't apply it yet - mixer isn't initialized)
        let savedVolume = UserDefaults.standard.double(forKey: "playbackVolume")
        if savedVolume > 0 {
            volume = savedVolume
        }
        // Volume will be applied when playback starts

        // Set initial Now Playing info to claim media controls
        var initialInfo: [String: Any] = [:]
        initialInfo[MPMediaItemPropertyTitle] = "Spotifly"
        initialInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = initialInfo

        // Start position update timer
        startPositionTimer()
    }

    /// Sets the token provider for automatic reinitialization after session disconnect.
    func setTokenProvider(_ provider: @escaping @Sendable () async -> String) {
        tokenProvider = provider
    }

    func initializeIfNeeded(accessToken: String) async {
        guard !isInitialized else { return }

        isLoading = true
        do {
            try await SpotifyPlayer.initialize(accessToken: accessToken)
            isInitialized = true

            // Wait for Spirc to be ready (poll with timeout)
            var spircReady = false
            for _ in 0 ..< 50 { // 5 seconds max
                if SpotifyPlayer.isSpircReady {
                    spircReady = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }

            // Note: We don't auto-transfer on init anymore.
            // When the user plays something, spirc.load() automatically makes this device active.
            // transferToLocal() is only used for explicit "Transfer playback here" action.
            _ = spircReady // Acknowledge we waited for Spirc to be ready
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func play(uriOrUrl: String, accessToken: String) async {
        // Initialize if needed
        if !isInitialized {
            await initializeIfNeeded(accessToken: accessToken)
        }

        guard isInitialized else {
            errorMessage = "Player not initialized"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try await SpotifyPlayer.play(uriOrUrl: uriOrUrl)
            handlePlaybackStarted(trackId: uriOrUrl)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func playTrack(trackId: String, accessToken: String) async {
        await play(uriOrUrl: "spotify:track:\(trackId)", accessToken: accessToken)
    }

    func playTracks(_ trackUris: [String], accessToken: String) async {
        // Initialize if needed
        if !isInitialized {
            await initializeIfNeeded(accessToken: accessToken)
        }

        guard isInitialized else {
            errorMessage = "Player not initialized"
            return
        }

        guard !trackUris.isEmpty else {
            errorMessage = "No tracks to play"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try await SpotifyPlayer.playTracks(trackUris)
            handlePlaybackStarted(trackId: trackUris[0])
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func addToQueue(trackUri: String, accessToken: String) async {
        // Initialize if needed
        if !isInitialized {
            await initializeIfNeeded(accessToken: accessToken)
        }

        guard isInitialized else {
            errorMessage = "Player not initialized"
            return
        }

        errorMessage = nil

        do {
            // Use Spirc to add to queue directly via librespot
            try SpotifyPlayer.addToQueue(trackUri: trackUri)
            // Queue update will come via Mercury callback
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Playback State Helpers

    /// Common setup after playback has started
    private func handlePlaybackStarted(trackId: String) {
        currentTrackUri = trackId
        isPlaying = true
        // Apply volume after playback starts (mixer is now initialized)
        SpotifyPlayer.setVolume(volume)
        updateNowPlayingInfo(forcePositionUpdate: true)
        syncPositionAnchor()
        // Note: favorite status is checked by NowPlayingBarView's .task(id:) when currentTrackUri changes
    }

    func togglePlayPause(trackId: String, accessToken: String) async {
        if isPlaying, currentTrackUri == trackId {
            // Pause current track
            SpotifyPlayer.pause()
            isPlaying = false
        } else if !isPlaying, currentTrackUri == trackId {
            // Resume current track
            SpotifyPlayer.resume()
            isPlaying = true
        } else {
            // Play new track
            await playTrack(trackId: trackId, accessToken: accessToken)
        }
    }

    func stop() {
        SpotifyPlayer.stop()
        isPlaying = false
        currentTrackUri = nil
    }

    func updatePlayingState() {
        isPlaying = SpotifyPlayer.isPlaying
    }

    /// Updates current track metadata for Now Playing info center.
    /// Called by QueueService when the current track changes.
    func setCurrentTrackMetadata(name: String?, artist: String?, artURL: String?) {
        currentTrackName = name
        currentArtistName = artist
        currentAlbumArtURL = artURL
        updateNowPlayingInfo()
    }

    // MARK: - Playback Control (via Spirc)

    // All playback control uses local Spirc - state updates come back via Mercury callback

    func next() {
        do {
            try SpotifyPlayer.next()
            // State update will come from Mercury callback
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func previous() {
        do {
            try SpotifyPlayer.previous()
            // State update will come from Mercury callback
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func seek(to positionMs: UInt32) {
        do {
            try SpotifyPlayer.seek(positionMs: positionMs)
            // Update anchor for smooth interpolation from new position
            positionAnchorMs = positionMs
            positionAnchorTime = CACurrentMediaTime()
            currentPositionMs = positionMs
            updateNowPlayingInfo(forcePositionUpdate: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pause() {
        SpotifyPlayer.pause()
        // State update will come from Mercury callback
    }

    func resume() {
        SpotifyPlayer.resume()
        // State update will come from Mercury callback
    }

    /// Always returns true - Web API handles next track availability
    var hasNext: Bool { true }

    /// Always returns true - Web API handles previous track availability
    var hasPrevious: Bool { true }

    // MARK: - Media Keys & Now Playing

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Remove any existing handlers to prevent duplicates
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        // Enable commands
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        // Play command
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.isPlaying {
                    SpotifyPlayer.resume()
                    self.isPlaying = true
                    self.updateNowPlayingInfo(forcePositionUpdate: true)
                }
            }
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying {
                    SpotifyPlayer.pause()
                    self.isPlaying = false
                    self.updateNowPlayingInfo(forcePositionUpdate: true)
                }
            }
            return .success
        }

        // Toggle play/pause command
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying {
                    SpotifyPlayer.pause()
                    self.isPlaying = false
                } else {
                    SpotifyPlayer.resume()
                    self.isPlaying = true
                }
                self.updateNowPlayingInfo(forcePositionUpdate: true)
            }
            return .success
        }

        // Next track command
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            next()
            return .success
        }

        // Previous track command
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            previous()
            return .success
        }

        // Seek command
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                guard let seekEvent = event as? MPChangePlaybackPositionCommandEvent else { return }
                let positionMs = UInt32(seekEvent.positionTime * 1000)
                self.seek(to: positionMs)
            }
            return .success
        }
    }

    /// Updates the system's Now Playing info (Control Center, Lock Screen).
    /// - Parameter forcePositionUpdate: When true, updates elapsed time. When false (default),
    ///   skips elapsed time to prevent seek bar flicker. Pass true for: new track, seek, play/pause.
    func updateNowPlayingInfo(forcePositionUpdate: Bool = false) {
        // Don't update Now Playing with invalid data - causes --:-- display
        guard trackDurationMs > 0 else { return }

        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

        if let trackName = currentTrackName {
            nowPlayingInfo[MPMediaItemPropertyTitle] = trackName
        }

        if let artistName = currentArtistName {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artistName
        }

        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = Double(trackDurationMs) / 1000.0

        // Only update elapsed time when explicitly requested to prevent seek bar flicker.
        // The system smoothly interpolates position based on playback rate, so setting
        // elapsed time unnecessarily resets that interpolation and causes a visible jump.
        if forcePositionUpdate {
            let validPosition = min(currentPositionMs, trackDurationMs)
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(validPosition) / 1000.0
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        // Update Now Playing (preserves existing artwork)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo

        // Album art - only download if URL changed
        if let artURL = currentAlbumArtURL, artURL != lastAlbumArtURL, !artURL.isEmpty, let url = URL(string: artURL) {
            lastAlbumArtURL = artURL

            // Download album art asynchronously
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    guard let image = NSImage(data: data) else { return }

                    // Update Now Playing on main actor
                    await MainActor.run {
                        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                        // Mark closure as @Sendable to fix crash - MPNowPlayingInfoCenter executes
                        // the closure on an internal dispatch queue, not on MainActor
                        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in
                            image
                        }
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                    }
                } catch {
                    // Ignore album art download failures
                }
            }
        }
    }

    // MARK: - Playback State Subscription

    /// Subscribe to playback state updates from Mercury/Spirc
    /// This allows external control (e.g., pause from phone) to be reflected in the app
    private func setupPlaybackStateSubscription() {
        playbackStateSubscription = SpotifyPlayer.playbackState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handlePlaybackStateUpdate(state)
            }
    }

    /// Subscribe to remote volume changes from Spirc
    /// This allows volume changes from other devices to update the local slider
    private func setupVolumeSubscription() {
        volumeSubscription = SpotifyPlayer.volumeChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volumeU16 in
                guard let self else { return }
                // Convert from 0-65535 to 0.0-1.0
                let normalizedVolume = Double(volumeU16) / 65535.0
                #if DEBUG
                    print("[PlaybackViewModel] Remote volume change: \(volumeU16) -> \(normalizedVolume)")
                #endif
                // Set flag to prevent feedback loop
                isSettingVolumeLocally = true
                volume = normalizedVolume
                isSettingVolumeLocally = false
                saveVolume()
            }
    }

    /// Reconnection delays: 0s, 2s, 5s, 10s, 30s, 30s...
    /// First attempt is immediate to recover within audio buffer (~5s)
    private func reconnectDelay(attempt: Int) -> TimeInterval {
        switch attempt {
        case 0: 0 // Immediate - try to beat the buffer
        case 1: 2 // Quick retry
        case 2: 5 // Still within reasonable gap
        case 3: 10 // Network might be recovering
        default: 30 // Back off for persistent issues
        }
    }

    /// Subscribe to session disconnection events from Spirc
    /// Automatically reinitializes the player with a fresh token when the channel closes
    private func setupSessionDisconnectedSubscription() {
        sessionDisconnectedSubscription = SpotifyPlayer.sessionDisconnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }

                // Capture current playback state for seamless resumption
                let wasPlaying = isPlaying
                let trackUri = currentTrackUri
                let positionMs = currentPositionMs

                // Record disconnect timestamp for elapsed time logging
                disconnectedAt = Date()

                #if DEBUG
                    print("[PlaybackViewModel] Session disconnected at \(Date()) - capturing state: uri=\(trackUri ?? "nil"), pos=\(positionMs)ms, playing=\(wasPlaying)")
                #endif

                // Store state for resumption after reconnect
                if wasPlaying, let uri = trackUri, !uri.isEmpty {
                    pendingResumeTrackUri = uri
                    pendingResumePositionMs = positionMs
                    pendingResumeWasPlaying = true

                    // Use soft cleanup to preserve Player for uninterrupted audio
                    // This only clears Session/Spirc, keeping audio pipeline alive
                    #if DEBUG
                        print("[PlaybackViewModel] Using soft cleanup to preserve audio during reconnect")
                    #endif
                    SpotifyPlayer.softCleanup()
                }

                // Mark as not initialized so next action reinitializes
                isInitialized = false
                // Don't set isPlaying = false yet - keep UI showing playing state during reconnect

                // Cancel any existing reconnect task
                reconnectTask?.cancel()

                // Start exponential backoff reconnection loop
                guard let tokenProvider else { return }

                reconnectTask = Task { @MainActor [weak self] in
                    guard let self else { return }

                    while reconnectAttempt < maxReconnectAttempts {
                        // Check for cancellation
                        if Task.isCancelled { break }

                        let delay = reconnectDelay(attempt: reconnectAttempt)
                        #if DEBUG
                            print("[PlaybackViewModel] Reconnect attempt \(reconnectAttempt + 1)/\(maxReconnectAttempts), delay: \(delay)s")
                        #endif

                        // Wait for delay (if any)
                        if delay > 0 {
                            try? await Task.sleep(for: .seconds(delay))
                        }

                        // Check for cancellation again
                        if Task.isCancelled { break }

                        // Attempt reconnection
                        let token = await tokenProvider()
                        await initializeIfNeeded(accessToken: token)

                        // If initialized, we're done - SessionConnected callback will handle the rest
                        if isInitialized {
                            #if DEBUG
                                print("[PlaybackViewModel] Reconnection successful on attempt \(reconnectAttempt + 1)")
                            #endif
                            break
                        }

                        reconnectAttempt += 1
                    }

                    // If we exhausted attempts, give up and update UI
                    if reconnectAttempt >= maxReconnectAttempts {
                        #if DEBUG
                            print("[PlaybackViewModel] Reconnection failed after \(maxReconnectAttempts) attempts")
                        #endif
                        isPlaying = false
                        pendingResumeWasPlaying = false
                    }
                }
            }
    }

    /// Subscribe to session connection events from Spirc
    /// Resumes playback if we have pending state from a disconnect
    private func setupSessionConnectedSubscription() {
        sessionConnectedSubscription = SpotifyPlayer.sessionConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }

                // Reset reconnect state on successful connection
                reconnectAttempt = 0
                reconnectTask?.cancel()
                reconnectTask = nil

                // Check if we have pending playback to resume
                guard pendingResumeWasPlaying,
                      let trackUri = pendingResumeTrackUri,
                      !trackUri.isEmpty
                else {
                    return
                }

                let positionMs = pendingResumePositionMs

                #if DEBUG
                    let elapsed = disconnectedAt.map { Date().timeIntervalSince($0) } ?? 0
                    print("[PlaybackViewModel] Session reconnected after \(String(format: "%.1f", elapsed))s - pending resume: uri=\(trackUri), pos=\(positionMs)ms")
                #endif

                // Clear URI/position but KEEP pendingResumeWasPlaying flag
                // The Rust layer calls transfer(None) which loads the track at correct position
                // BUT the cluster state has is_paused=true (set by old Spirc shutdown)
                // We'll resume in the Loading callback when the track starts loading
                pendingResumeTrackUri = nil
                pendingResumePositionMs = 0
                // NOTE: Don't clear pendingResumeWasPlaying - Loading handler will use it

                #if DEBUG
                    print("[PlaybackViewModel] Session reconnected - awaiting Loading callback to resume")
                #endif
            }
    }

    /// Subscribe to loading notifications from Spirc
    /// This fires early (~180ms) when a track starts loading, before metadata is fetched
    /// Allows faster Now Playing updates when playing from remote devices
    private func setupLoadingSubscription() {
        loadingSubscription = SpotifyPlayer.loading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                #if DEBUG
                    print("[PlaybackViewModel] Loading notification: \(notification.trackUri) at \(notification.positionMs)ms")
                #endif

                // Update current track URI immediately for faster Now Playing updates
                if !notification.trackUri.isEmpty, notification.trackUri != currentTrackUri {
                    currentTrackUri = notification.trackUri
                    // Mark as playing since we're loading a new track
                    isPlaying = true
                }

                // Resume playback after reconnect if we were playing before disconnect
                // The transfer(None) loads the track at correct position but paused
                // (because old Spirc set is_paused=true during shutdown)
                if pendingResumeWasPlaying {
                    pendingResumeWasPlaying = false
                    #if DEBUG
                        print("[PlaybackViewModel] Resuming playback after reconnect (was playing before disconnect)")
                    #endif
                    SpotifyPlayer.resume()
                }
            }
    }

    /// Handle playback state update from Spirc callback
    private func handlePlaybackStateUpdate(_ state: PlaybackState?) {
        guard let state else { return }

        #if DEBUG
            print("[PlaybackViewModel] Playback state update: playing=\(state.isPlaying), paused=\(state.isPaused), uri=\(state.trackUri)")
        #endif

        // Update playing state
        // is_playing = true means actively playing audio
        // is_paused = true means paused (not playing but has a track loaded)
        let wasPlaying = isPlaying
        isPlaying = state.isPlaying && !state.isPaused

        // Update track if changed
        if !state.trackUri.isEmpty, state.trackUri != currentTrackUri {
            currentTrackUri = state.trackUri
            // Note: Track metadata (name, artist, etc.) will be updated from queue
        }

        // Update duration
        if state.durationMs > 0 {
            trackDurationMs = UInt32(state.durationMs)
        }

        // Sync position anchor on state changes
        if state.positionMs >= 0 {
            let posMs = UInt32(state.positionMs)
            positionAnchorMs = posMs
            positionAnchorTime = CACurrentMediaTime()
            currentPositionMs = posMs
        }

        // Update Now Playing info if state changed
        if wasPlaying != isPlaying {
            updateNowPlayingInfo()
        }
    }

    // MARK: - Position Tracking

    // Anchor-based position tracking using CACurrentMediaTime for precision
    // UI reads interpolatedPositionMs (computed), not currentPositionMs directly
    private var positionAnchorMs: UInt32 = 0
    private var positionAnchorTime: Double = CACurrentMediaTime()
    private var lastRustPosition: UInt32 = 0
    private var driftCorrectionTimer: DriftCorrectionTimer?
    private var driftObserver: NSObjectProtocol?

    /// Computed position using anchor interpolation - UI should bind to this
    /// Called by TimelineView on every frame for smooth updates
    var interpolatedPositionMs: UInt32 {
        guard isPlaying else { return currentPositionMs }
        let elapsed = CACurrentMediaTime() - positionAnchorTime
        let elapsedMs = UInt32(max(0, min(elapsed * 1000, Double(UInt32.max - 1))))
        let interpolated = positionAnchorMs.addingReportingOverflow(elapsedMs).partialValue
        return min(interpolated, trackDurationMs)
    }

    private func startPositionTimer() {
        let timer = DriftCorrectionTimer()

        // Observe drift correction notifications
        driftObserver = NotificationCenter.default.addObserver(
            forName: DriftCorrectionTimer.checkNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkDriftAndSync()
            }
        }

        timer.start()
        driftCorrectionTimer = timer
    }

    /// Sync position anchor with Rust - call after seek, play, resume, track change
    private func syncPositionAnchor() {
        let rustPosition = SpotifyPlayer.positionMs
        positionAnchorMs = rustPosition
        positionAnchorTime = CACurrentMediaTime()
        lastRustPosition = rustPosition
        currentPositionMs = rustPosition
    }

    /// Called every second to check for drift and sync state
    private func checkDriftAndSync() {
        var didCorrectDrift = false

        // Sync playing state with Rust
        let rustIsPlaying = SpotifyPlayer.isPlaying
        if rustIsPlaying != isPlaying {
            isPlaying = rustIsPlaying
            syncPositionAnchor()
            didCorrectDrift = true
        }

        // Update currentPositionMs for non-TimelineView consumers
        currentPositionMs = interpolatedPositionMs

        // Check for significant drift from Rust position
        let rustPosition = SpotifyPlayer.positionMs
        if rustPosition != lastRustPosition {
            let drift = abs(Int32(rustPosition) - Int32(interpolatedPositionMs))
            if drift > 500 {
                // More than 500ms drift - resync anchor
                positionAnchorMs = rustPosition
                positionAnchorTime = CACurrentMediaTime()
                currentPositionMs = min(rustPosition, trackDurationMs)
                didCorrectDrift = true
            }
            lastRustPosition = rustPosition
        }

        updateNowPlayingInfo(forcePositionUpdate: didCorrectDrift)
    }

    // MARK: - Favorite Management

    func checkCurrentTrackFavoriteStatus(accessToken: String) async {
        guard let uri = currentTrackUri, let trackId = SpotifyAPI.parseTrackURI(uri) else {
            isCurrentTrackFavorited = false
            return
        }

        do {
            isCurrentTrackFavorited = try await SpotifyAPI.checkSavedTrack(
                accessToken: accessToken,
                trackId: trackId,
            )
        } catch {
            #if DEBUG
                print("Error checking favorite status: \(error)")
            #endif
            isCurrentTrackFavorited = false
        }
    }

    func toggleCurrentTrackFavorite(accessToken: String) async {
        guard let uri = currentTrackUri, let trackId = SpotifyAPI.parseTrackURI(uri) else {
            return
        }

        do {
            if isCurrentTrackFavorited {
                try await SpotifyAPI.removeSavedTrack(accessToken: accessToken, trackId: trackId)
                isCurrentTrackFavorited = false
            } else {
                try await SpotifyAPI.saveTrack(accessToken: accessToken, trackId: trackId)
                isCurrentTrackFavorited = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Volume Persistence

    private func saveVolume() {
        UserDefaults.standard.set(volume, forKey: "playbackVolume")
    }

    /// Debounce volume changes to avoid flooding Spirc with rapid requests
    private func debounceVolumeChange() {
        // Cancel any pending volume update
        volumeDebounceTask?.cancel()

        // Capture current volume value
        let newVolume = volume

        // Schedule debounced update (50ms delay)
        volumeDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))

            // Check if task was cancelled
            guard !Task.isCancelled else { return }

            // Only apply volume if player is initialized (mixer is ready)
            if isInitialized {
                SpotifyPlayer.setVolume(newVolume)
            }
        }
    }
}
