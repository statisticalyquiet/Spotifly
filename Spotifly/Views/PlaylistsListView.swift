//
//  PlaylistsListView.swift
//  Spotifly
//
//  Displays user's playlists using normalized store
//

import SwiftUI

struct PlaylistsListView: View {
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(PlaylistService.self) private var playlistService
    @Bindable var playbackViewModel: PlaybackViewModel

    /// Selection uses playlist ID, looked up from store
    @Binding var selectedPlaylistId: String?

    @State private var errorMessage: String?

    var body: some View {
        Group {
            if store.playlistsPagination.isLoading, store.userPlaylists.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("loading.playlists")
                        .foregroundStyle(.secondary)
                }
            } else if let error = errorMessage, store.userPlaylists.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("error.load_playlists")
                        .font(.headline)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("action.try_again") {
                        Task {
                            await loadPlaylists(forceRefresh: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if store.userPlaylists.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("empty.no_playlists")
                        .font(.headline)
                    Text("empty.no_playlists.description")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.userPlaylists.enumerated()), id: \.element.id) { index, playlist in
                            VStack(spacing: 0) {
                                PlaylistRow(
                                    playlist: playlist,
                                    playbackViewModel: playbackViewModel,
                                    isSelected: selectedPlaylistId == playlist.id,
                                    onSelect: {
                                        selectedPlaylistId = playlist.id
                                    },
                                )

                                if index < store.userPlaylists.count - 1 {
                                    Divider()
                                        .padding(.leading, 56)
                                }
                            }
                        }

                        // Load more indicator
                        if store.playlistsPagination.hasMore {
                            ProgressView()
                                .padding()
                                .onAppear {
                                    Task {
                                        await loadMorePlaylists()
                                    }
                                }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await loadPlaylists(forceRefresh: true)
                }
            }
        }
        .task {
            if store.userPlaylists.isEmpty, !store.playlistsPagination.isLoading {
                await loadPlaylists()
            }
            // Set initial selection after loading or if already loaded
            if selectedPlaylistId == nil, let first = store.userPlaylists.first {
                selectedPlaylistId = first.id
            }
        }
        .onChange(of: store.userPlaylists) { _, playlists in
            if selectedPlaylistId == nil, let first = playlists.first {
                selectedPlaylistId = first.id
            }
        }
    }

    private func loadPlaylists(forceRefresh: Bool = false) async {
        errorMessage = nil
        do {
            let token = await session.validAccessToken()
            try await playlistService.loadUserPlaylists(
                accessToken: token,
                forceRefresh: forceRefresh,
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMorePlaylists() async {
        do {
            let token = await session.validAccessToken()
            try await playlistService.loadMorePlaylists(accessToken: token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    @Bindable var playbackViewModel: PlaybackViewModel
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(SpotifySession.self) private var session
    @Environment(\.displayScale) private var displayScale
    @State private var isHovering = false

    private let imageSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 10) {
            // Playlist image
            if let url = playlist.images.url(for: imageSize, scale: displayScale) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        playlistPlaceholder
                    case let .success(image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: imageSize, height: imageSize)
                            .cornerRadius(4)
                    case .failure:
                        playlistPlaceholder
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                playlistPlaceholder
            }

            // Playlist name
            Text(playlist.name)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer()

            // Play button (on hover)
            if isHovering {
                Button {
                    Task {
                        let token = await session.validAccessToken()
                        await playbackViewModel.play(uriOrUrl: playlist.uri, accessToken: token)
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .disabled(playbackViewModel.isLoading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            onSelect()
        }
    }

    private var playlistPlaceholder: some View {
        Image(systemName: "music.note.list")
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .frame(width: imageSize, height: imageSize)
            .background(Color.gray.opacity(0.15))
            .cornerRadius(4)
    }
}
