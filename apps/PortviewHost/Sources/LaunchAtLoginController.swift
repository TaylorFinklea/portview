// SPDX-License-Identifier: Apache-2.0
import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Sendable, Equatable {
    case enabled
    /// Registered, but the user must approve it in System Settings > Login Items.
    case requiresApproval
    case disabled
}

/// Seam over the login-item registration. The OS is the single source of truth; nothing is cached
/// in `UserDefaults`. Tests use a fake and never register a real login item.
protocol LaunchAtLoginControlling: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func setEnabled(_ enabled: Bool) throws
}

/// Production adapter over `SMAppService.mainApp`.
final class SMAppServiceLaunchAtLogin: LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
