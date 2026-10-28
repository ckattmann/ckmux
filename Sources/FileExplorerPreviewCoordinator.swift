import AppKit
import Bonsplit

/// Both sidebar entrypoints capture the displayed provider before suspending.
@MainActor
struct FileExplorerPreviewCoordinator {
    let store: FileExplorerStore

    func open(path: String, workspace: Workspace, pane: PaneID, isCurrent: @escaping @MainActor () -> Bool) {
        guard store.workspaceRootIdentity == workspace.id, let provider = store.provider,
              provider.isAvailable else { return }
        let context = store.resourceContextID
        if provider is LocalFileExplorerProvider {
            _ = workspace.openFileSurfaces(inPane: pane, filePaths: [path], focus: true,
                                          reuseExisting: true, duplicateWhenFocused: true)
            return
        }
        Task { [weak workspace, store] in
            guard let workspace else { return }
            do {
                guard isCurrent(), store.resourceContextID == context else { return }
                return
            } catch {
                guard isCurrent(), store.resourceContextID == context else { return }
                Self.present(error, window: AppDelegate.shared?.mainWindowContainingWorkspace(workspace.id))
            }
        }
    }

    private static func present(_ error: Error, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "fileExplorer.preview.failedTitle", defaultValue: "Unable to open remote file")
        alert.informativeText = (error as? FileExplorerError)?.localizedDescription
            ?? String(localized: "fileExplorer.preview.genericFailure", defaultValue: "The remote file could not be downloaded. Reconnect and try again.")
        alert.addButton(withTitle: String(localized: "fileExplorer.preview.ok", defaultValue: "OK"))
        _ = alert.runCmuxModal(presentingWindow: window)
    }
}
