import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation
import GhosttyKit

extension TerminalController {
    /// Socket error text extracted because `TerminalController.swift` sits at
    /// its file-length budget.
    nonisolated static var terminalSurfaceUnavailableSocketError: String {
        "ERROR: \(terminalSurfaceUnavailableMessage)"
    }
}

/// The surface-domain witnesses are the byte-faithful bodies of the former
/// `v2Surface*` / `v2DebugTerminals` dispatchers, minus the per-read `v2MainSync`
/// hop: the coordinator already runs on the main actor inside the socket-command
/// policy scope, so each hop would re-apply the identical thread-local
/// focus-allowance stack — a no-op.
///
/// App-coupled resolution (`resolveTabManager(routing:)`, `v2ResolveWindowId`, the
/// Bonsplit layout, surface creation/move, the Ghostty reads, the resume approval
/// flow, the `debug.terminals` table) stays here; the seam exposes only Sendable
/// snapshots, resolution enums, and one bridged ``JSONValue`` (`debug.terminals`).
/// Every blocking `NSAlert` and `String(localized:)` resolves here, in the app
/// bundle, so translations survive.
extension TerminalController: ControlSurfaceContext {
    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        resolveTabManager(routing: routing) != nil
    }

    /// The routing twin of the legacy `v2ResolveWorkspace(params:tabManager:)`.
    /// `internal` (not `private`) so the surface witnesses in the sibling
    /// `+ControlSurfaceContext2`/`3` files share it.
    func resolveSurfaceWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        if let owner = routing.remoteRelayOwnerWorkspaceID {
            guard let workspace = tabManager.tabs.first(where: { $0.id == owner }) else {
                return nil
            }
            return workspace
        }
        if let wsId = routing.workspaceID {
            guard !AppDelegate.isWindowDockRoutingId(wsId) else { return nil }
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = routing.surfaceID {
            if let workspace = tabManager.tabs.first(where: { $0.panels[surfaceId] != nil }) {
                return workspace
            }
            guard windowDockContainingPanel(surfaceId) == nil else { return nil }
            return nil
        }
        if let paneId = routing.paneID {
            if let located = v2LocatePane(paneId) {
                guard located.tabManager === tabManager else { return nil }
                return located.workspace
            }
            guard windowDockContainingPane(paneId) == nil else { return nil }
            if let located = locateDockPane(paneId), located.tabManager === tabManager {
                return located.workspace
            }
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }

    /// Converts an app resume-binding snapshot (after `applyingStoredApproval`) into
    /// the seam value type, byte-faithful to `v2SurfaceResumeBindingPayload`.
    /// `internal` (not `private`) so the resume witnesses in the sibling
    /// `+ControlSurfaceContext3` file share it.
    func controlResumeBinding(
        from binding: SurfaceResumeBindingSnapshot?
    ) -> ControlSurfaceResumeBinding? {
        guard let binding else { return nil }
        let effective: SurfaceResumeBindingSnapshot
        switch SurfaceResumeApprovalStore.applyingStoredApprovalLookup(to: binding) {
        case .pendingSigningSecret:
            effective = SurfaceResumeApprovalStore.bindingWithoutStoredApproval(to: binding)
        case let .resolved(binding):
            effective = binding
        }
        return ControlSurfaceResumeBinding(
            name: effective.name,
            kind: effective.kind,
            command: effective.command,
            cwd: effective.cwd,
            checkpointID: effective.checkpointId,
            source: effective.source,
            environment: effective.environment,
            launchCommand: effective.launchCommand.map {
                controlAgentLaunchCommand(
                    $0,
                    replaySafeEnvironmentFor: effective.kind
                )
            },
            permissionMode: effective.permissionMode,
            autoResume: effective.allowsAutomaticResume,
            approvalPolicyRawValue: effective.approvalPolicy?.rawValue,
            approvalRecordID: effective.approvalRecordId,
            executionLocationRawValue: effective.launchFlavor.executionLocationRawValue,
            remoteWorkspaceID: nil,
            remoteSurfaceID: nil,
            remotePTYSessionID: nil,
            updatedAt: effective.updatedAt,
            resumeEvidenceProvenance: effective.resumeEvidenceProvenance
        )
    }

    // MARK: - list

    func controlSurfaceList(routing: ControlRoutingSelectors) -> ControlSurfaceListSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            return controlDockSurfaceList(dock: dock, tabManager: tabManager)
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }

        let summaries = controlSurfaceSummaries(workspace: ws)
        return ControlSurfaceListSnapshot(
            workspaceID: ws.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            surfaces: summaries + (routing.remoteRelayOwnerWorkspaceID == nil
                ? controlTopologyDocks(workspace: ws, tabManager: tabManager)
                    .flatMap { controlDockSurfaceSummaries(dock: $0) }
                : [])
        )
    }

    // MARK: - current

    func controlSurfaceCurrent(routing: ControlRoutingSelectors) -> ControlSurfaceCurrentSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let surfaceId = dock.focusedPanelId ?? orderedPanels(in: dock).first?.id
            let paneId = surfaceId.flatMap { dock.paneId(forPanelId: $0)?.id }
            return ControlSurfaceCurrentSnapshot(
                windowID: dockResultWindowId(for: dock, tabManager: tabManager),
                workspaceID: dock.workspaceId,
                paneID: paneId,
                surfaceID: surfaceId,
                surfaceTypeRawValue: surfaceId.flatMap { dock.panels[$0]?.panelType.rawValue }
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }
        let containerPanelID: UUID?
        containerPanelID = ws.focusedPanelId ?? orderedPanels(in: ws).first?.id
        let projection = containerPanelID.flatMap {
            ws.controlSurfaceProjection(forContainerPanelID: $0)
        }
        return ControlSurfaceCurrentSnapshot(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            paneID: projection?.paneID,
            surfaceID: projection?.surfaceID,
            surfaceTypeRawValue: projection?.panel.panelType.rawValue
        )
    }

    // MARK: - health

    func controlSurfaceHealth(routing: ControlRoutingSelectors) -> ControlSurfaceHealthSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let items: [ControlSurfaceHealthEntry] = orderedPanels(in: dock).map { panel in
                controlSurfaceHealthEntry(
                    for: panel,
                    terminalTarget: dock.controlSocketTerminalTarget(for: panel.id)
                )
            }
            return ControlSurfaceHealthSnapshot(
                workspaceID: dock.workspaceId,
                windowID: dockResultWindowId(for: dock, tabManager: tabManager),
                surfaces: items
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }
        let items: [ControlSurfaceHealthEntry] = controlSurfacePanels(workspace: ws).map { panel in
            controlSurfaceHealthEntry(
                for: panel,
                terminalTarget: ws.controlSocketTerminalTarget(for: panel.id)
            )
        }
        return ControlSurfaceHealthSnapshot(
            workspaceID: ws.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            surfaces: items
        )
    }

    // MARK: - focus

    func controlSurfaceJumpToLastPrompt() -> ControlSurfaceFocusResolution? {
        guard let app = AppDelegate.shared, let target = app.jumpToLastPrompt() else { return nil }
        return .focused(
            windowID: v2ResolveWindowId(tabManager: app.tabManagerFor(tabId: target.workspaceId)),
            workspaceID: target.workspaceId,
            surfaceID: target.panelId
        )
    }

    func controlSurfaceFocus(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlSurfaceFocusResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        if let windowDock = windowDockContainingPanel(surfaceID) {
            // An explicit window_id or Dock-owner workspace_id naming a
            // different window's Dock fails closed.
            if windowDockMismatchesExplicitSelectors(routing, dock: windowDock, aliasTabManager: tabManager) {
                return .surfaceNotFound(surfaceID)
            }
            guard focusAndRevealWindowDock(for: windowDock, fallback: tabManager) else {
                return .dockUnavailable(message: dockFocusUnavailableMessage())
            }
            windowDock.focusPanelFromDockInteraction(surfaceID, window: nil)
            return .focused(
                windowID: windowDock.workspaceId,
                workspaceID: windowDock.workspaceId,
                surfaceID: surfaceID
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        let isWorkspaceSurface = ws.panels[surfaceID] != nil
        guard isWorkspaceSurface else {
            return .surfaceNotFound(surfaceID)
        }
        if let windowId = v2ResolveWindowId(tabManager: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            setActiveTabManager(tabManager)
        }
        // Record explicit intent before selection schedules focus restoration.
        tabManager.focusTab(ws.id, surfaceId: surfaceID, suppressFlash: true)
        return .focused(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceID
        )
    }
}
