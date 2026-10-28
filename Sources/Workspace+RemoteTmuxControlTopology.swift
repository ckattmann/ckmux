import Bonsplit
import CmuxWorkspaces
import Foundation

/// Local-only control-plane surface resolution. The upstream version also
/// projected remote tmux mirrors; this build has no remote terminals.
@MainActor
extension Workspace {
    typealias ControlSurfaceProjection = (
        surfaceID: UUID,
        paneID: UUID?,
        panel: any Panel
    )

    func isRemoteTmuxControlContainer(_ panelID: UUID) -> Bool { false }

    func controlTabTarget(for surfaceID: UUID) -> (panelID: UUID, paneID: UUID?)? {
        guard panels[surfaceID] != nil else { return nil }
        return (surfaceID, paneId(forPanelId: surfaceID)?.id)
    }

    func canResolveTerminalPathsAgainstLocalFilesystem(surfaceID: UUID) -> Bool {
        if panels[surfaceID] != nil { return true }
        if DockSplitStore.liveStores.first(where: {
            $0.panelID(forTerminalLinkSourceID: surfaceID) != nil
        }) != nil {
            return true
        }
        return false
    }

    func isRemoteTerminalContext(_ surfaceOrPanelID: UUID) -> Bool { false }

    func terminalRunsOnAnotherMachine(_ surfaceOrPanelID: UUID) -> Bool { false }

    func controlReorderContainerPanelID(for surfaceID: UUID) -> UUID? {
        panels[surfaceID] == nil ? nil : surfaceID
    }

    func controlSurfaceTarget(for surfaceID: UUID) -> ControlSurfaceProjection? {
        if let panel = panels[surfaceID] {
            return (surfaceID, paneId(forPanelId: surfaceID)?.id, panel)
        }
        guard let dock = _dockSplit,
              let panel = dock.panels[surfaceID] else {
            return nil
        }
        return (surfaceID, dock.paneId(forPanelId: surfaceID)?.id, panel)
    }

    func controlTerminalTarget(for surfaceID: UUID) -> (surfaceID: UUID, panel: TerminalPanel)? {
        guard let target = controlSurfaceTarget(for: surfaceID),
              let panel = target.panel as? TerminalPanel else { return nil }
        return (target.surfaceID, panel)
    }

    func controlTerminalPanel(for surfaceID: UUID) -> TerminalPanel? {
        controlTerminalTarget(for: surfaceID)?.panel
    }

    func terminalPanels(projectedFromPanelID panelID: UUID) -> [TerminalPanel] {
        (panels[panelID] as? TerminalPanel).map { [$0] } ?? []
    }

    func terminalInputTarget(
        forPanelID panelID: UUID
    ) -> (surfaceID: UUID, panel: TerminalPanel)? {
        let projection: ControlSurfaceProjection?
        if panels[panelID] != nil {
            projection = controlSurfaceProjection(forContainerPanelID: panelID)
        } else {
            projection = controlSurfaceTarget(for: panelID)
        }
        guard let projection,
              let panel = projection.panel as? TerminalPanel else {
            return nil
        }
        return (projection.surfaceID, panel)
    }

    func surfaceOwnershipTarget(
        for surfaceOrPanelID: UUID
    ) -> WorkspaceSurfaceOwnershipTarget? {
        if let panel = panels[surfaceOrPanelID] {
            guard surfaceIdFromPanelId(surfaceOrPanelID) != nil else { return nil }
            return WorkspaceSurfaceOwnershipTarget(
                surfaceID: surfaceOrPanelID,
                containerPanelID: surfaceOrPanelID,
                panel: panel
            )
        }
        guard let panelID = panelIdFromSurfaceId(TabID(uuid: surfaceOrPanelID)),
              let panel = panels[panelID] else { return nil }
        return WorkspaceSurfaceOwnershipTarget(
            surfaceID: panelID,
            containerPanelID: panelID,
            panel: panel
        )
    }

    func controlSurfaceProjection(
        forContainerPanelID containerPanelID: UUID
    ) -> ControlSurfaceProjection? {
        guard let panel = panels[containerPanelID] else { return nil }
        return (containerPanelID, paneId(forPanelId: containerPanelID)?.id, panel)
    }

    func focusedTerminalInputTarget() -> (surfaceID: UUID, panel: TerminalPanel)? {
        guard let focusedPanelId else { return nil }
        return terminalInputTarget(forPanelID: focusedPanelId)
    }

    func isFocusedTerminalInputSurface(_ surfaceID: UUID) -> Bool {
        focusedTerminalInputTarget()?.surfaceID == surfaceID
    }

    func controlDefaultTerminalTarget(
        paneID requestedPaneID: UUID?
    ) -> (surfaceID: UUID, panel: TerminalPanel)? {
        if let requestedPaneID {
            if let paneID = bonsplitController.allPaneIds.first(where: { $0.id == requestedPaneID }),
               let tab = bonsplitController.selectedTab(inPane: paneID),
               let panelID = panelIdFromSurfaceId(tab.id),
               let panel = terminalPanel(for: panelID) {
                return (panelID, panel)
            }
            return nil
        }
        return focusedTerminalInputTarget()
    }

    func controlRequestedSurfaceTarget(
        explicitSurfaceID: UUID?,
        routedPaneID: UUID?
    ) -> (requestedSurfaceID: UUID, target: ControlSurfaceProjection?)? {
        if let explicitSurfaceID {
            return (explicitSurfaceID, controlSurfaceTarget(for: explicitSurfaceID))
        }
        if let routedPaneID {
            guard let paneID = bonsplitController.allPaneIds.first(where: {
                $0.id == routedPaneID
            }),
            let selectedTab = bonsplitController.selectedTab(inPane: paneID),
            let panelID = panelIdFromSurfaceId(selectedTab.id) else {
                return nil
            }
            return (panelID, controlSurfaceTarget(for: panelID))
        }
        guard let focusedPanelId else { return nil }
        return (focusedPanelId, controlSurfaceProjection(forContainerPanelID: focusedPanelId))
    }
}
