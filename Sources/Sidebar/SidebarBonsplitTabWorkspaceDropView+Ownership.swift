import AppKit
import CmuxFoundation

extension SidebarBonsplitTabWorkspaceDropView {
    /// SwiftUI and NSTableView sidebars share this same native destination.
    func updateOwnershipFeedback(action: SidebarDropPlanner.WorkspaceDropAction?, pasteboard: NSPasteboard) {
        guard case .existingWorkspace(let workspaceID) = action,
              let app = AppDelegate.shared,
              let workspace = app.workspaceFor(tabId: workspaceID) else {
            ownershipFeedback.clear()
            return
        }
        let resolver = PaneTransferSourceResolver()
        if let transfer = resolver.transfer(from: pasteboard), let source = resolver.source(for: transfer) {
        }
    }
}
