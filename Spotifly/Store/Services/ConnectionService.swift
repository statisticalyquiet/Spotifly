//
//  ConnectionService.swift
//  Spotifly
//
//  Service to sync librespot connection state with AppStore.
//

import Combine
import Foundation

@MainActor
@Observable
final class ConnectionService {
    private let store: AppStore
    private var connectionStateSubscription: AnyCancellable?

    init(store: AppStore) {
        self.store = store
        setupConnectionStateSubscription()
        refreshConnectionState()
    }

    /// Subscribe to connection state updates from SpotifyPlayer
    private func setupConnectionStateSubscription() {
        connectionStateSubscription = SpotifyPlayer.connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.store.setConnectionState(state)
            }
    }

    /// Manually refresh connection state from SpotifyPlayer
    func refreshConnectionState() {
        let state = SpotifyPlayer.getConnectionState()
        store.setConnectionState(state)
    }
}
