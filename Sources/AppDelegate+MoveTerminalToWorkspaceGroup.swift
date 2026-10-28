import Foundation

@MainActor
extension AppDelegate {
    private struct TerminalGroupMovePlan {
        let sourceWorkspace: Workspace
        let detachesSurface: Bool
    }

    func canMoveTerminal(panelId: UUID, toWorkspaceGroup groupId: UUID?, in tabManager: TabManager) -> Bool {
        terminalGroupMovePlan(panelId: panelId, toWorkspaceGroup: groupId, in: tabManager) != nil
    }

    /// Detaches the terminal into its own workspace when it shares one, then files that workspace under `groupId` (nil ungroups it).
    @discardableResult
    func moveTerminal(panelId: UUID, toWorkspaceGroup groupId: UUID?, in tabManager: TabManager) -> Bool {
        guard let plan = terminalGroupMovePlan(panelId: panelId, toWorkspaceGroup: groupId, in: tabManager) else {
            return false
        }
        let targetWorkspaceId: UUID
        if plan.detachesSurface {
            guard let result = moveSurfaceToNewWorkspace(
                panelId: panelId,
                destinationManager: tabManager,
                focus: false,
                focusWindow: false
            ) else {
                return false
            }
            targetWorkspaceId = result.destinationWorkspaceId
        } else {
            targetWorkspaceId = plan.sourceWorkspace.id
        }

        if let groupId {
            tabManager.addWorkspaceToGroup(workspaceId: targetWorkspaceId, groupId: groupId)
        } else if tabManager.tabs.first(where: { $0.id == targetWorkspaceId })?.groupId != nil {
            tabManager.removeWorkspaceFromGroup(workspaceId: targetWorkspaceId)
        }
        return true
    }

    private func terminalGroupMovePlan(
        panelId: UUID,
        toWorkspaceGroup groupId: UUID?,
        in tabManager: TabManager
    ) -> TerminalGroupMovePlan? {
        guard let source = tabManager.tabs.first(where: { $0.panels[panelId] is TerminalPanel }) else {
            return nil
        }
        if let groupId, !tabManager.workspaceGroups.contains(where: { $0.id == groupId }) {
            return nil
        }
        let anchoredGroupId = tabManager.workspaceGroups.first { $0.liveAnchorWorkspaceId == source.id }?.id
        let currentGroupId = anchoredGroupId ?? source.groupId
        let sharesWorkspace = source.panels.count > 1
        let mustDetach = anchoredGroupId != nil || source.isChiefHome
        if !sharesWorkspace && currentGroupId == groupId {
            return nil
        }
        if sharesWorkspace || mustDetach {
            guard canMoveSurfaceToNewWorkspace(panelId: panelId) else { return nil }
            return TerminalGroupMovePlan(sourceWorkspace: source, detachesSurface: true)
        }
        return TerminalGroupMovePlan(sourceWorkspace: source, detachesSurface: false)
    }
}
