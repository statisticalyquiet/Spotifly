//
//  SpotifyAPI+Player.swift
//  Spotifly
//
//  Playback and Spotify Connect API calls.
//

import Foundation
import os

extension SpotifyAPI {
    // MARK: - Devices

    /// Fetches available Spotify Connect devices
    static func fetchAvailableDevices(accessToken: String) async throws -> DevicesResponse {
        let urlString = "\(baseURL)/me/player/devices"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            do {
                let decoded = try JSONDecoder().decode(DevicesCodable.self, from: data)
                let devices = decoded.devices.compactMap { $0.toDevice() }
                return DevicesResponse(devices: devices)
            } catch {
                throw SpotifyAPIError.invalidResponse
            }
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Queue

    /// Response from GET /me/player/queue
    struct QueueResponse: Decodable {
        let currentlyPlaying: TrackCodable?
        let queue: [TrackCodable]

        enum CodingKeys: String, CodingKey {
            case currentlyPlaying = "currently_playing"
            case queue
        }
    }

    /// Fetches the current playback queue from Spotify Web API.
    /// Returns the currently playing track and upcoming queue.
    /// - Parameter accessToken: The access token for authentication
    /// - Returns: QueueResponse containing current track and queue
    static func fetchQueue(accessToken: String) async throws -> QueueResponse {
        let urlString = "\(baseURL)/me/player/queue"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return try JSONDecoder().decode(QueueResponse.self, from: data)
        case 204:
            // No content - nothing playing
            return QueueResponse(currentlyPlaying: nil, queue: [])
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }
}
