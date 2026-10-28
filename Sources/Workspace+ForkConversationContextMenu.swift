import Bonsplit
import CmuxCore
import CmuxSettings
import CmuxSurfaceCatalogModel
import Foundation

extension Workspace {
    @discardableResult
    func forkAgentConversationFromContextMenu(
        fromPanelId panelId: UUID,
        destination: AgentConversationForkDestination
    ) async -> Bool {
        guard beginForkAgentConversationAction(panelId: panelId) else {
            return false
        }
        defer {
            endForkAgentConversationAction(panelId: panelId)
        }

        var selection = forkAgentConversationContextMenuOpenSelection(
            forPanelId: panelId
        )
        guard var snapshot = selection.snapshot,
              var ownership = surfaceOwnershipTarget(for: panelId),
              var anchorTabId = surfaceIdFromPanelId(ownership.containerPanelID),
              var paneId = paneId(forPanelId: ownership.containerPanelID) else {
            return false
        }
        guard let refreshedOwnership = surfaceOwnershipTarget(for: panelId),
              let refreshedAnchorTabId = surfaceIdFromPanelId(
                  refreshedOwnership.containerPanelID
              ),
              let refreshedPaneId = self.paneId(
                  forPanelId: refreshedOwnership.containerPanelID
              ),
              !isRemoteTerminalContext(refreshedOwnership.surfaceID) else {
            return false
        }
        ownership = refreshedOwnership
        anchorTabId = refreshedAnchorTabId
        paneId = refreshedPaneId
        if AgentForkSupport.requiresForkValidationExecutableIdentity(
            snapshot: snapshot
        ) {
            let selectedSnapshotFingerprint = ContentView.commandPaletteForkSnapshotFingerprint(
                snapshot
            )
            let selectedValidationIdentity = AgentForkSupport.forkValidationIdentity(
                snapshot: snapshot
            )
            guard let cachedExecutableFingerprint = SharedLiveAgentIndex.shared.forkSupportProbeExecutableFingerprint(
                workspaceId: id,
                panelId: panelId,
                fallbackSnapshot: snapshot
            ) else {
                return false
            }
            let currentExecutableFingerprint = await SharedLiveAgentIndex.shared.forkValidationExecutableFingerprint(
                snapshot: snapshot
            )
            let refreshedSelection = forkAgentConversationContextMenuOpenSelection(
                forPanelId: panelId
            )
            guard refreshedSelection.availability.isAvailable,
                  let refreshedSnapshot = refreshedSelection.snapshot,
                  ContentView.commandPaletteForkSnapshotFingerprint(
                    refreshedSnapshot
                  ) == selectedSnapshotFingerprint,
                  AgentForkSupport.forkValidationIdentity(
                    snapshot: refreshedSnapshot
                  ) == selectedValidationIdentity,
                  let refreshedOwnership = surfaceOwnershipTarget(for: panelId),
                  !isRemoteTerminalContext(refreshedOwnership.surfaceID),
                  let refreshedAnchorTabId = surfaceIdFromPanelId(
                    refreshedOwnership.containerPanelID
                  ),
                  let refreshedPaneId = self.paneId(
                    forPanelId: refreshedOwnership.containerPanelID
                  ) else {
                return false
            }
            selection = refreshedSelection
            snapshot = refreshedSnapshot
            ownership = refreshedOwnership
            anchorTabId = refreshedAnchorTabId
            paneId = refreshedPaneId
            guard currentExecutableFingerprint == cachedExecutableFingerprint,
                  SharedLiveAgentIndex.shared.forkSupportProbeAccepted(
                    workspaceId: id,
                    panelId: panelId,
                    fallbackSnapshot: selection.validationFallbackSnapshot
                  ) else {
                return false
            }
        }

        return forkAgentConversation(
            mutationPanelId: ownership.containerPanelID,
            snapshot: snapshot,
            destination: destination,
            anchorTabId: anchorTabId,
            paneId: paneId
        )
    }

    private func forkAgentConversation(
        mutationPanelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        destination: AgentConversationForkDestination,
        anchorTabId: TabID,
        paneId: PaneID
    ) -> Bool {

        if let direction = destination.splitDirection {
            return forkAgentConversation(
                fromPanelId: mutationPanelId,
                snapshot: snapshot,
                direction: direction
            ) != nil
        }

        switch destination {
        case .newTab:
            return forkAgentConversationToNewTab(
                fromPanelId: mutationPanelId,
                snapshot: snapshot,
                anchorTabId: anchorTabId,
                paneId: paneId
            ) != nil
        case .newWorkspace:
            return forkAgentConversationToNewWorkspace(
                fromPanelId: mutationPanelId,
                snapshot: snapshot
            )
        case .right, .left, .top, .bottom:
            return false
        }
    }

    private static func normalizedForkWorkingDirectory(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func forkAgentConversationToNewWorkspace(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        guard let owningTabManager,
              let launch = forkAgentWorkspaceLaunch(
                  fromPanelId: panelId,
                  snapshot: snapshot
              ) else {
            return false
        }

        guard let forkWorkspace = owningTabManager.addWorkspaceIfActive(
            workingDirectory: launch.terminalWorkingDirectory,
            initialTerminalCommand: launch.initialTerminalCommand,
            initialTerminalInput: launch.initialTerminalInput,
            initialTerminalStartupRestoreAgent: launch.startupRestoreAgent,
            initialTerminalEnvironment: launch.initialTerminalEnvironment,
            inheritWorkingDirectory: launch.terminalWorkingDirectory != nil,
            autoWelcomeIfNeeded: false
        ) else {
            return false
        }
        if let remoteConfiguration = launch.remoteConfiguration {
        }
        if let workingDirectory = launch.workingDirectory,
           launch.terminalWorkingDirectory == nil,
           let forkPanelId = forkWorkspace.focusedPanelId {
            forkWorkspace.updatePanelDirectory(panelId: forkPanelId, directory: workingDirectory)
        }
        return true
    }
}
