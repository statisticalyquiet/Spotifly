//
//  TrackLookupViewModel.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

@MainActor
@Observable
final class TrackLookupViewModel {
    var spotifyURI: String = ""
    var isLoading = false
    var track: Track?
    var errorMessage: String?

    func clearInput() {
        spotifyURI = ""
        track = nil
        errorMessage = nil
    }

    func lookupTrack(accessToken: String) {
        guard !spotifyURI.isEmpty else {
            errorMessage = "Please enter a Spotify URI or URL"
            return
        }

        // Try to parse as track URI for metadata lookup
        if let trackId = SpotifyAPI.parseTrackURI(spotifyURI) {
            isLoading = true
            errorMessage = nil
            track = nil

            Task {
                do {
                    let apiTrack = try await SpotifyAPI.fetchTrack(trackId: trackId, accessToken: accessToken)
                    self.track = Track(from: apiTrack)
                    self.isLoading = false
                } catch {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        } else {
            // For non-track URIs (album/playlist/artist), we won't fetch metadata
            // but we'll allow playback
            track = nil
        }
    }
}
