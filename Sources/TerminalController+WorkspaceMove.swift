import Foundation

extension TerminalController {
    private func mobileWorkspaceMoveGroupID(params: [String: Any]) -> UUID? {
        guard v2HasNonNullParam(params, "group_id"),
              let rawGroupID = v2RawString(params, "group_id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawGroupID.isEmpty else {
            return nil
        }
        return v2UUID(params, "group_id")
    }

    private func mobileWorkspaceMoveHasInvalidGroupID(params: [String: Any]) -> Bool {
        guard v2HasNonNullParam(params, "group_id") else {
            return false
        }
        guard let rawGroupID = v2RawString(params, "group_id")?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return true
        }
        guard !rawGroupID.isEmpty else {
            return false
        }
        return v2UUID(params, "group_id") == nil
    }

    private func mobileWorkspaceMoveTopLevelTargetIndex(
        workspaceID: UUID,
        _ beforeWorkspaceID: UUID?,
        targetIndex: Int?,
        topLevelIds: [UUID],
        tabManager: TabManager
    ) -> Int {
        guard let targetIndex else {
            let insertionPosition = mobileWorkspaceMoveTopLevelBeforeID(
                beforeWorkspaceID,
                tabManager: tabManager
            ).flatMap { topLevelIds.firstIndex(of: $0) } ?? topLevelIds.count
            guard let sourceIndex = topLevelIds.firstIndex(of: workspaceID) else {
                return insertionPosition
            }
            let clampedInsertion = max(0, min(insertionPosition, topLevelIds.count))
            let adjustedIndex = clampedInsertion > sourceIndex ? clampedInsertion - 1 : clampedInsertion
            return max(0, min(adjustedIndex, max(0, topLevelIds.count - 1)))
        }
        return targetIndex
    }

    private func mobileWorkspaceMoveTopLevelBeforeID(
        _ beforeWorkspaceID: UUID?,
        tabManager: TabManager
    ) -> UUID? {
        guard let beforeWorkspaceID,
              let beforeWorkspace = tabManager.tabs.first(where: { $0.id == beforeWorkspaceID }) else {
            return beforeWorkspaceID
        }
        guard let groupID = beforeWorkspace.groupId,
              let group = tabManager.workspaceGroups.first(where: { $0.id == groupID }) else {
            return beforeWorkspaceID
        }
        return group.liveAnchorWorkspaceId ?? beforeWorkspaceID
    }
}
