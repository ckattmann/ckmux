import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation
import GhosttyKit

/// Local-only control-plane pane and surface resolution. The upstream version
/// also projected remote tmux mirrors; this build has no remote terminals.
@MainActor
extension TerminalController {
    func controlTabManager(surfaceID: UUID) -> TabManager? {
        AppDelegate.shared?.locateSurface(surfaceId: surfaceID)?.tabManager
            ?? locateDockSurface(surfaceID)?.tabManager
    }

    func controlTabManager(paneID: UUID) -> TabManager? {
        v2LocatePane(paneID)?.tabManager
            ?? locateDockPane(paneID)?.tabManager
    }

    func controlSurfaceReorder(
        surfaceID: UUID,
        inputs: ControlSurfaceReorderInputs,
        requestedFocus: Bool
    ) -> ControlSurfaceReorderResolution {
        let focus = v2FocusAllowed(requested: requestedFocus)
        guard let tabManager = controlTabManager(surfaceID: surfaceID),
              let ws = tabManager.tabs.first(where: {
                  $0.controlReorderContainerPanelID(for: surfaceID) != nil
              }),
              let sourcePanelID = ws.controlReorderContainerPanelID(for: surfaceID),
              let sourcePane = ws.paneId(forPanelId: sourcePanelID),
              let windowID = v2ResolveWindowId(tabManager: tabManager) else {
            return .surfaceNotFound(surfaceID)
        }

        let targetIndex: Int
        if let index = inputs.index {
            guard let currentIndex = ws.indexInPane(forPanelId: sourcePanelID) else { return .reorderFailed }
            targetIndex = index > currentIndex ? index + 1 : index
        } else if let beforeSurfaceID = inputs.beforeSurfaceID {
            guard let anchorPanelID = ws.controlReorderContainerPanelID(for: beforeSurfaceID),
                  let anchorPane = ws.paneId(forPanelId: anchorPanelID),
                  anchorPane == sourcePane,
                  let anchorIndex = ws.indexInPane(forPanelId: anchorPanelID) else {
                return .anchorNotInSamePane
            }
            targetIndex = anchorIndex
        } else if let afterSurfaceID = inputs.afterSurfaceID {
            guard let anchorPanelID = ws.controlReorderContainerPanelID(for: afterSurfaceID),
                  let anchorPane = ws.paneId(forPanelId: anchorPanelID),
                  anchorPane == sourcePane,
                  let anchorIndex = ws.indexInPane(forPanelId: anchorPanelID) else {
                return .anchorNotInSamePane
            }
            targetIndex = anchorIndex + 1
        } else {
            return .reorderFailed
        }

        guard ws.reorderSurface(panelId: sourcePanelID, toIndex: targetIndex, focus: focus) else {
            return .reorderFailed
        }
        return .reordered(
            windowID: windowID,
            workspaceID: ws.id,
            paneID: sourcePane.id,
            surfaceID: surfaceID
        )
    }

    func controlPaneList(
        workspace: Workspace,
        tabManager: TabManager
    ) -> ControlPaneListSnapshot {
        let snapshot = workspace.bonsplitController.layoutSnapshot()
        return ControlPaneListSnapshot(
            workspaceID: workspace.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            panes: controlPaneSummaries(workspace: workspace, snapshot: snapshot),
            containerWidth: snapshot.containerFrame.width,
            containerHeight: snapshot.containerFrame.height
        )
    }

    func controlPaneSummaries(
        workspace: Workspace,
        snapshot: LayoutSnapshot
    ) -> [ControlPaneSummary] {
        let focusedPaneId = workspace.bonsplitController.focusedPaneId
        let geometryByPaneId = Dictionary(
            snapshot.panes.map { ($0.paneId, $0.frame) },
            uniquingKeysWith: { first, _ in first }
        )
        return workspace.bonsplitController.allPaneIds.compactMap { paneID -> ControlPaneSummary? in
            let tabs = workspace.bonsplitController.tabs(inPane: paneID)
            let panelIDs = tabs.compactMap { workspace.panelIdFromSurfaceId($0.id) }
            let selectedPanelID = workspace.bonsplitController
                .selectedTab(inPane: paneID)
                .flatMap { workspace.panelIdFromSurfaceId($0.id) }
            let frame = geometryByPaneId[paneID.id.uuidString].map {
                ControlPanePixelFrame(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }
            guard !panelIDs.isEmpty else { return nil }
            return ControlPaneSummary(
                paneID: paneID.id,
                isFocused: paneID == focusedPaneId && selectedPanelID != nil,
                surfaceIDs: panelIDs,
                selectedSurfaceID: selectedPanelID,
                pixelFrame: frame,
                gridSize: selectedPanelID
                    .flatMap { workspace.terminalPanel(for: $0) }
                    .flatMap { controlGridSize(panel: $0) }
            )
        }
    }

    private func controlGridSize(panel: TerminalPanel) -> ControlPaneGridSize? {
        guard panel.surface.hasLiveSurface, let surface = panel.surface.surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0 else { return nil }
        let cellPoints = panel.surface.cellSizePoints()
        return ControlPaneGridSize(
            columns: Int(size.columns),
            rows: Int(size.rows),
            cellWidthPx: Int(size.cell_width_px),
            cellHeightPx: Int(size.cell_height_px),
            cellWidthPoints: cellPoints.map { Double($0.width) },
            cellHeightPoints: cellPoints.map { Double($0.height) }
        )
    }

    func controlPaneSurfaces(
        workspace: Workspace,
        paneID requestedPaneID: UUID?,
        tabManager: TabManager
    ) -> ControlPaneSurfacesSnapshot? {
        let paneID: PaneID?
        if let requestedPaneID {
            paneID = workspace.bonsplitController.allPaneIds.first(where: {
                $0.id == requestedPaneID
            })
        } else {
            paneID = workspace.bonsplitController.focusedPaneId
        }
        guard let paneID else { return nil }
        let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneID)
        let surfaces = workspace.bonsplitController.tabs(inPane: paneID).compactMap {
            tab -> ControlPaneSurfaceSummary? in
            guard let panelID = workspace.panelIdFromSurfaceId(tab.id) else {
                return nil
            }
            let panel = workspace.panels[panelID]
            return ControlPaneSurfaceSummary(
                surfaceID: panelID,
                title: tab.title,
                typeRawValue: panel?.panelType.rawValue,
                isSelected: tab.id == selectedTab?.id
            )
        }
        guard !surfaces.isEmpty else { return nil }
        return ControlPaneSurfacesSnapshot(
            workspaceID: workspace.id,
            paneID: paneID.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            surfaces: surfaces
        )
    }

    func controlPaneFocus(
        workspace: Workspace,
        paneID requestedPaneID: UUID,
        tabManager: TabManager
    ) -> ControlPaneFocusResolution {
        guard let paneID = workspace.bonsplitController.allPaneIds.first(where: {
            $0.id == requestedPaneID
        }) else {
            return .paneNotFound(requestedPaneID)
        }
        if let windowID = v2ResolveWindowId(tabManager: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowID)
            setActiveTabManager(tabManager)
        }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
        workspace.bonsplitController.focusPane(paneID)
        return .focused(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: workspace.id,
            paneID: paneID.id
        )
    }

    func controlSurfaceSummaries(workspace: Workspace) -> [ControlSurfaceSummary] {
        var paneByPanelID: [UUID: UUID] = [:]
        var indexInPaneByPanelID: [UUID: Int] = [:]
        var selectedInPaneByPanelID: [UUID: Bool] = [:]
        for paneID in workspace.bonsplitController.allPaneIds {
            let tabs = workspace.bonsplitController.tabs(inPane: paneID)
            let selected = workspace.bonsplitController.selectedTab(inPane: paneID)
            for (index, tab) in tabs.enumerated() {
                guard let panelID = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                paneByPanelID[panelID] = paneID.id
                indexInPaneByPanelID[panelID] = index
                selectedInPaneByPanelID[panelID] = tab.id == selected?.id
            }
        }

        return orderedPanels(in: workspace).map { panel -> ControlSurfaceSummary in
            let terminalPanel = panel as? TerminalPanel
            return ControlSurfaceSummary(
                surfaceID: panel.id,
                typeRawValue: panel.panelType.rawValue,
                title: workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                isFocused: panel.id == workspace.focusedPanelId,
                paneID: paneByPanelID[panel.id],
                indexInPane: indexInPaneByPanelID[panel.id],
                selectedInPane: selectedInPaneByPanelID[panel.id],
                developerToolsVisible: nil,
                requestedWorkingDirectory: terminalPanel.flatMap {
                    v2NonEmptyString($0.requestedWorkingDirectory)
                },
                initialCommand: terminalPanel.flatMap {
                    v2NonEmptyString($0.surface.debugInitialCommand())
                },
                tmuxStartCommand: terminalPanel.flatMap {
                    v2NonEmptyString($0.surface.debugTmuxStartCommand())
                },
                isTerminal: terminalPanel != nil,
                resumeBinding: terminalPanel != nil
                    ? controlResumeBinding(from: workspace.surfaceResumeBinding(panelId: panel.id))
                    : nil,
                renderHealthRawValue: terminalPanel?.surface.renderHealth.rawValue
            )
        }
    }

    func controlSurfacePanels(workspace: Workspace) -> [any Panel] {
        orderedPanels(in: workspace)
    }
}

extension TerminalController {
    func remoteRelayDockTargetIsCurrent(routing: ControlRoutingSelectors, dock: DockSplitStore, surfaceID: UUID) -> Bool { true }
    func remoteRelayTargetIsCurrent(routing: ControlRoutingSelectors, workspace: Workspace, surfaceID: UUID) -> Bool { true }
}

extension TerminalController {
    nonisolated func socketWorkerCurrentWorkResponse(id: Any?, params: [String: Any]) -> String {
        v2Error(id: id, code: "unsupported", message: "current.list is unavailable in this build")
    }
}
