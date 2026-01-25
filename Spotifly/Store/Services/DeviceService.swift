//
//  DeviceService.swift
//  Spotifly
//
//  Service for Spotify Connect device operations.
//  Handles API calls and updates AppStore on success.
//

import Foundation

@MainActor
@Observable
final class DeviceService {
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Device Loading

    /// Load available Spotify Connect devices
    func loadDevices(accessToken: String) async {
        // Deduplicate concurrent requests - just skip if already loading
        guard !store.devicesIsLoading else { return }

        store.devicesIsLoading = true
        store.devicesErrorMessage = nil

        do {
            let response = try await SpotifyAPI.fetchAvailableDevices(accessToken: accessToken)
            store.upsertDevices(response.devices)
            // activeDeviceId is now computed from devices, no need to set it
        } catch is CancellationError {
            // Task was cancelled (e.g., view dismissed) - don't show error
        } catch let error as SpotifyAPIError {
            store.devicesErrorMessage = error.localizedDescription
        } catch {
            store.devicesErrorMessage = String(localized: "speakers.error.failed_to_load")
        }

        store.devicesIsLoading = false
    }

    // MARK: - Playback Transfer

    /// Transfer playback to a specific device
    /// Uses native Spotify Connect protocol for seamless handoff.
    /// Returns true if transfer succeeded (caller should activate Connect mode)
    func transferPlayback(to device: Device, accessToken: String) async -> Bool {
        // Optimistically mark the target device as active for immediate UI feedback
        store.setActiveDevice(device.id)

        // Check if target is our local device
        let isLocalDevice = device.id == store.connection?.deviceId

        do {
            if isLocalDevice {
                // Transfer TO local - use Spirc's native transfer
                try SpotifyPlayer.transferToLocal()
            } else {
                // Transfer FROM local to remote device
                try SpotifyPlayer.transferPlayback(to: device.id)
            }

            // Schedule a delayed refresh to confirm the state
            // (Web API returns stale data immediately after transfer)
            Task {
                try? await Task.sleep(for: .milliseconds(750))
                await loadDevices(accessToken: accessToken)
            }

            return true
        } catch {
            // Revert optimistic update on failure by refreshing from API
            await loadDevices(accessToken: accessToken)
            store.devicesErrorMessage = String(localized: "speakers.error.failed_to_transfer")
            return false
        }
    }

    // MARK: - Helpers

    /// Get appropriate icon name for device type
    func deviceIcon(for type: String) -> String {
        switch type.lowercased() {
        case "computer":
            "desktopcomputer"
        case "smartphone":
            "iphone"
        case "speaker":
            "hifispeaker"
        case "tv":
            "tv"
        case "avr", "stb":
            "appletv"
        case "automobile":
            "car"
        default:
            "speaker.wave.2"
        }
    }
}
