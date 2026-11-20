// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import Combine
import UIKit

enum CameraAccessState: Equatable {
    case notDetermined, requesting, authorized, denied, unavailable
}

/// A platform-neutral view of `AVAuthorizationStatus` (restricted is treated as denied).
enum CameraAuthorizationStatus: Equatable {
    case notDetermined, authorized, denied
}

/// The effect boundary for camera access; tests inject fakes so no camera or TCC surface is touched.
struct CameraAuthorizationClient {
    var status: () -> CameraAuthorizationStatus
    var hasCamera: () -> Bool
    var requestAccess: () async -> Bool
    var openSettings: () -> Void

    static let live = CameraAuthorizationClient(
        status: {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .authorized
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        },
        hasCamera: { AVCaptureDevice.default(for: .video) != nil },
        requestAccess: { await AVCaptureDevice.requestAccess(for: .video) },
        openSettings: {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
}

/// Drives the pair screen's camera state: resolves authorization, requests it at most once,
/// re-reads it when the app returns to the foreground, and falls back to `.unavailable` when
/// capture setup fails.
@MainActor
final class CameraAccessModel: ObservableObject {
    @Published private(set) var state: CameraAccessState = .notDetermined
    private let client: CameraAuthorizationClient
    private var hasRequested = false

    init(client: CameraAuthorizationClient = .live) {
        self.client = client
    }

    /// Resolves the current state, prompting once if the user has not yet decided.
    func start() async {
        guard state != .requesting else { return }
        if client.status() == .notDetermined, !hasRequested {
            hasRequested = true
            state = .requesting
            _ = await client.requestAccess()
        }
        resolve()
    }

    /// Re-reads authorization (scene returned to `.active`) without ever re-prompting.
    func refresh() {
        guard state != .requesting, state != .unavailable else { return }
        resolve()
    }

    /// The scanner could not set up capture on an authorized device.
    func scannerFailed() {
        state = .unavailable
    }

    /// Only ever called from an explicit user tap.
    func openSettings() {
        client.openSettings()
    }

    private func resolve() {
        switch client.status() {
        case .authorized: state = client.hasCamera() ? .authorized : .unavailable
        case .denied: state = .denied
        // Still undetermined after our one-time request: treat as denied (no endless spinner).
        case .notDetermined: state = hasRequested ? .denied : .notDetermined
        }
    }
}
