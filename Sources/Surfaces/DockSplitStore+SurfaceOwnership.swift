import Bonsplit
import CmuxSurfaceCatalogModel
import Foundation

extension DockSplitStore {

    func surfaceDropRejection(
        _ transfer: PaneDragTransfer,
        source: PaneTransferSourceResolver.Source
    ) -> SurfaceTransferRejection? {
        switch source {
        case .vaultSession, .filePreview, .rightSidebarTool:
            return nil
        case .surfaceResources(let group):
            return SurfaceCatalog.shared.ownershipRejection(for: group.resources, policy: ownershipPolicy)
        case .surface:
            guard transfer.isFromCurrentProcess else { return ownershipPolicy.rejection(for: nil) }
            // A Dock surface split or reordered within this Dock stays on its machine.
            if surfaceIdToPanelId[TabID(uuid: transfer.tabId)] != nil { return nil }
            guard let app = AppDelegate.shared else { return ownershipPolicy.rejection(for: nil) }
            return app.ownershipRejection(forBonsplitTab: transfer.tabId, policy: ownershipPolicy)
        case .workspaceMerge:
            // The Dock declines a merged workspace quietly (no reason to show).
            return nil
        }
    }

    func acceptsDetachedSurface(_ transfer: Workspace.DetachedSurfaceTransfer) -> Bool {
        if transfer.origin == .dock(workspaceId) { return true }
        return surfaceOwnershipPolicy.rejection(for: transfer.surfaceMachine
            ?? SurfaceCatalog.shared.machineOwningPanel(transfer.panelId)
            ?? transfer.panel.transferredSurfaceMachine, kind: AppDelegate.shared?.surfaceResourceKind(for: transfer.panel)) == nil
    }

    func acceptsRestoredDisplay(_ snapshot: SessionPanelSnapshot) -> Bool {
        return true
    }

}

/// Whether a terminal's shell runs on another machine, wherever the terminal
/// is hosted: a workspace's split tree or a Dock. Predicted echo only runs for
/// these terminals.
@MainActor
enum TerminalRemoteMachineClassification {
}

extension DockSplitStore {
}
