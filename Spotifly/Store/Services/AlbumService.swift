//
//  AlbumService.swift
//  Spotifly
//
//  Service for album-related operations.
//  Handles API calls and updates AppStore on success.
//

import Foundation

@MainActor
@Observable
final class AlbumService {
    private let store: AppStore
    private var loadingAlbumTrackIds: Set<String> = []
    private var userAlbumsTask: Task<Void, Error>?

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - User Albums

    /// Load user's saved albums
    func loadUserAlbums(accessToken: String, forceRefresh: Bool = false) async throws {
        // Skip if already loaded and not forcing refresh (but only if we actually have data)
        if store.albumsPagination.isLoaded, !forceRefresh, !store.albumsPagination.hasMore, !store.userAlbumIds.isEmpty {
            return
        }

        // Handle force refresh
        if forceRefresh {
            userAlbumsTask?.cancel()
            userAlbumsTask = nil
            store.albumsPagination.reset()
        }

        // If already loading, await existing task
        if let existingTask = userAlbumsTask {
            _ = try? await existingTask.value
            return
        }

        // Create and store the loading task
        let offset = forceRefresh ? 0 : (store.albumsPagination.nextOffset ?? 0)
        store.albumsPagination.isLoading = true
        userAlbumsTask = Task {
            defer {
                self.userAlbumsTask = nil
                self.store.albumsPagination.isLoading = false
            }

            let response = try await SpotifyAPI.fetchUserAlbums(
                accessToken: accessToken,
                limit: 20,
                offset: offset,
            )

            // Convert to unified Album entities
            let albums = response.albums.map { Album(from: $0) }

            // Upsert albums into store
            self.store.upsertAlbums(albums)

            // Update user album IDs
            let albumIds = albums.map(\.id)
            if forceRefresh {
                self.store.setUserAlbumIds(albumIds)
            } else {
                self.store.appendUserAlbumIds(albumIds)
            }

            // Update pagination state
            self.store.albumsPagination.isLoaded = true
            self.store.albumsPagination.hasMore = response.hasMore
            self.store.albumsPagination.nextOffset = response.nextOffset
            self.store.albumsPagination.total = response.total
        }

        try await userAlbumsTask!.value
    }

    /// Load more albums (pagination)
    func loadMoreAlbums(accessToken: String) async throws {
        guard store.albumsPagination.hasMore, userAlbumsTask == nil else {
            return
        }
        try await loadUserAlbums(accessToken: accessToken)
    }

    // MARK: - Album Details

    /// Fetch album details and tracks
    func fetchAlbumDetails(albumId: String, accessToken: String) async throws -> Album {
        // Fetch details and tracks in parallel
        async let detailsTask = SpotifyAPI.fetchAlbumDetails(
            accessToken: accessToken,
            albumId: albumId,
        )
        async let tracksTask = SpotifyAPI.fetchAlbumTracks(
            accessToken: accessToken,
            albumId: albumId,
        )

        let (details, albumTracks) = try await (detailsTask, tracksTask)

        // Convert tracks to unified entities with album context
        let tracks = albumTracks.map { albumTrack in
            Track(
                from: albumTrack,
                albumId: details.id,
                albumName: details.name,
                imageURL: details.imageURL,
            )
        }
        store.upsertTracks(tracks)

        // Calculate total duration
        let totalDurationMs = tracks.reduce(0) { $0 + $1.durationMs }

        // Create album with track IDs
        let album = Album(
            from: details,
            trackIds: tracks.map(\.id),
            totalDurationMs: totalDurationMs,
        )

        store.upsertAlbum(album)
        return album
    }

    /// Get tracks for an album (from store or fetch)
    func getAlbumTracks(albumId: String, accessToken: String) async throws -> [Track] {
        // Check if tracks are already loaded
        if let album = store.albums[albumId], album.tracksLoaded {
            return album.trackIds.compactMap { store.tracks[$0] }
        }

        // Prevent concurrent fetches for the same album
        guard !loadingAlbumTrackIds.contains(albumId) else {
            // Wait for the other request to complete by polling
            while loadingAlbumTrackIds.contains(albumId) {
                try await Task.sleep(for: .milliseconds(50))
            }
            // Now return from store (should be loaded)
            if let album = store.albums[albumId] {
                return album.trackIds.compactMap { store.tracks[$0] }
            }
            return []
        }

        loadingAlbumTrackIds.insert(albumId)
        defer { loadingAlbumTrackIds.remove(albumId) }

        // Fetch album details (which includes tracks)
        let album = try await fetchAlbumDetails(albumId: albumId, accessToken: accessToken)
        return album.trackIds.compactMap { store.tracks[$0] }
    }

    /// Get album from store or fetch if needed
    func getAlbum(albumId: String, accessToken: String) async throws -> Album {
        if let album = store.albums[albumId] {
            return album
        }
        return try await fetchAlbumDetails(albumId: albumId, accessToken: accessToken)
    }

    // MARK: - Remove Album from Library

    /// Remove an album from the user's library
    func removeAlbumFromLibrary(albumId: String, accessToken: String) async throws {
        try await SpotifyAPI.removeUserAlbum(
            accessToken: accessToken,
            albumId: albumId,
        )

        // Update store on success
        store.removeAlbumFromUserLibrary(albumId)
    }
}
