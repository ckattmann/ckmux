import AppKit
import CmuxSettings
import Foundation

/// Runtime enforcement for MDM managed policies (`DisableEmbeddedBrowser`,
/// `DisableRemoteControl`, `DisableCloud`, and `DisableRemoteConnections`):
/// installs the transition observer and tears down live resources when a
/// policy activates mid-session.
extension AppDelegate {
    /// Installs the managed-policy transition observer once at startup.
    func installManagedPolicyEnforcement() {
        guard managedPolicyEnforcementObserver == nil else { return }
        managedPolicyEnforcementObserver = ManagedPolicyEnforcementObserver(
            socketControlPolicy: {
                CmuxSettingsFileStore.socketControlPolicyResolution()
            },
            enforceBrowserPolicy: {
            },
            enforceBrowserURLAllowlistPolicy: {
            },
            enforceRemoteControlPolicy: {
                // syncToSettings() tears the mobile host down under the
                // policy (including live connections) and re-arms it when
                // the policy lifts.
            },
            enforceIncomingAccessPolicy: {
            },
            enforceCloudPolicy: {
            },
            enforceRemoteConnectionsPolicy: {
            },
            enforceComputerUsePolicy: {
            },
            enforceSocketControlPolicy: { [weak self] in
                self?.reconcileSocketListenerConfiguration(source: "managed_policy")
            }
        )
    }

    /// `DisableAutoUpdate`: a manual "Check for Updates…" explains the managed
    /// state instead of silently doing nothing. Returns true when the check
    /// may proceed.
    func managedAutoUpdateAllowsCheck() -> Bool {
        guard ManagedDevicePolicy().isEnforced(.disableAutoUpdate) else { return true }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "managedPolicy.autoUpdate.disabled",
            defaultValue: "Software updates are managed by your organization."
        )
        alert.informativeText = String(
            localized: "managedPolicy.autoUpdate.disabledDetail",
            defaultValue: "cmux does not check for or install updates on this Mac. Your organization deploys new versions."
        )
        alert.alertStyle = .informational
        alert.runModal()
        return false
    }

    private func allTabManagersForManagedPolicyEnforcement() -> [TabManager] {
        var managers: [TabManager] = []
        for context in mainWindowContexts.values {
            managers.append(context.tabManager)
        }
        if let tabManager, !managers.contains(where: { $0 === tabManager }) {
            managers.append(tabManager)
        }
        return managers
    }
}

extension AppDelegate {
    func commandPaletteCloudCapabilityAllows(commandId: String, preferredWindow: NSWindow? = nil, tabManager: TabManager? = nil) -> Bool { true }
}
