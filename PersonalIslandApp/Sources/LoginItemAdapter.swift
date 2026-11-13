/*
 * Personal Island — login item adapter.
 * Written for this personal project; no upstream file copied.
 */

import ServiceManagement

/// Uses macOS's own login-item service for this app (listed under System
/// Settings › General › Login Items). Nothing is installed elsewhere; turning
/// it off removes the item.
@MainActor
enum LoginItemAdapter {
    static func environment() -> LoginItemController.Environment {
        LoginItemController.Environment(
            state: {
                switch SMAppService.mainApp.status {
                case .enabled: .on
                case .requiresApproval: .needsApproval
                case .notRegistered: .off
                case .notFound: .unavailable
                @unknown default: .unavailable
                }
            },
            register: { try SMAppService.mainApp.register() },
            unregister: { try SMAppService.mainApp.unregister() }
        )
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
