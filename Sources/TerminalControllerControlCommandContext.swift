import CmuxControlSocket
import CmuxSidebar
import Foundation

/// `TerminalController` conforms to ``ControlCommandContext`` as the interim
/// composition owner for the stage-3c ``ControlCommandCoordinator``: it reads
/// live `AppDelegate` / `TabManager` state on the main actor so the coordinator
/// (which runs on main, inside the active `withSocketCommandPolicy` stack) can
/// execute moved command domains without the package importing the app target.
///
/// `ControlCommandContext` is the umbrella; `TerminalController` satisfies it by
/// conforming to each domain constituent (one extension per domain file). The
/// umbrella carries one requirement of its own: the worker-lane resolution hop.
extension TerminalController: ControlCommandContext {
    /// The worker-lane resolution hop primitive: forwards to `v2MainSync` (so
    /// the hop collapses to an inline call when the caller is already on the
    /// main thread, propagates the focus-allowance stack, and records per-hop
    /// timing exactly like every other socket main hop) and refreshes the
    /// known `kind:N` refs FIRST, mirroring the main-lane dispatch preamble
    /// (`v2MainActorResponse`) byte-for-byte so caller-supplied refs resolve.
    /// NOTE: the refresh covers only main-window workspace topology; dock-hosted
    /// surfaces/panes (the per-window `DockSplitStore`s, post-#7144) are
    /// first-minted by each body's in-hop mint pass, so every mint pass MUST
    /// preserve its payload's literal mint order — that ordering, not the
    /// refresh, is what keeps `kind:N` ordinals identical to the legacy build.
    /// The body receives `self` back as its main-actor seam parameter (see the
    /// protocol requirement's doc).
    nonisolated func controlResolveOnMain<T: Sendable>(
        _ body: @MainActor (any ControlCommandContext) -> T
    ) -> T {
        v2MainSync {
            self.v2RefreshKnownRefs()
            return body(self)
        }
    }
}

/// The window-domain witnesses are the byte-faithful bodies of the former
/// `v2Window*` dispatchers, minus the per-read `v2MainSync` hop: the coordinator
/// already runs on the main actor inside the socket-command policy scope, so each
/// hop would re-apply the identical thread-local focus-allowance stack — a no-op.
extension TerminalController: ControlWindowContext {
    func controlWindowCloseStrings() -> ControlWindowCloseStrings {
        ControlWindowCloseStrings(
            confirmationRequired: String(
                localized: "cli.socket.error.windowCloseConfirmationRequired",
                defaultValue: "One or more workspaces or Dock surfaces have a running process; retry with --force"
            )
        )
    }

    func controlWindowSummaries() -> [ControlWindowSummary] {
        (AppDelegate.shared?.listMainWindowSummaries() ?? []).map { summary in
            ControlWindowSummary(
                windowID: summary.windowId,
                isKeyWindow: summary.isKeyWindow,
                isVisible: summary.isVisible,
                workspaceCount: summary.workspaceCount,
                selectedWorkspaceID: summary.selectedWorkspaceId
            )
        }
    }

    func controlResolveCurrentWindow(
        routing: ControlRoutingSelectors
    ) -> ControlCurrentWindowResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let windowId = AppDelegate.shared?.windowId(for: tabManager) else {
            return .windowNotFound
        }
        return .resolved(windowId)
    }

    func controlFocusWindow(id: UUID) -> Bool {
        AppDelegate.shared?.focusMainWindow(windowId: id) ?? false
    }

    func controlCreateWindowAndActivate(title: String?) -> UUID? {
        guard let windowId = AppDelegate.shared?.createMainWindow(initialWorkspaceTitle: title) else { return nil }
        // The new window should become key, but setActiveTabManager defensively
        // (preserves the legacy v2WindowCreate side effect and ordering).
        if let tabManager = AppDelegate.shared?.tabManagerFor(windowId: windowId) {
            setActiveTabManager(tabManager)
        }
        return windowId
    }

    func controlCloseWindow(id: UUID) -> Bool {
        AppDelegate.shared?.closeMainWindow(windowId: id) ?? false
    }

    func controlCloseWindow(id: UUID, force: Bool) -> ControlWindowCloseResolution {
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(windowId: id) else {
            return .notFound
        }
        let activeWorkspaceIDs = manager.tabs
            .filter { $0.needsConfirmClose() }
            .map(\.id)
        let dockNeedsConfirmation = app.existingWindowDock(for: manager)?.needsConfirmClose() == true
        guard force || (activeWorkspaceIDs.isEmpty && !dockNeedsConfirmation) else {
            return .confirmationRequired(workspaceIDs: activeWorkspaceIDs)
        }
        return app.closeMainWindow(windowId: id) ? .resolved : .notFound
    }

    func controlAvailableDisplays() -> [ControlDisplayInfo] {
        (AppDelegate.shared?.availableDisplays() ?? []).map { display in
            ControlDisplayInfo(
                name: display.name,
                index: display.index,
                displayID: display.displayID,
                isMain: display.isMain,
                frameX: display.frame.origin.x,
                frameY: display.frame.origin.y,
                frameWidth: display.frame.width,
                frameHeight: display.frame.height
            )
        }
    }

    func controlWindowExists(id: UUID) -> Bool {
        AppDelegate.shared?.windowForMainWindowId(id) != nil
    }

    func controlMoveWindow(id: UUID, toDisplayMatching query: String) -> String? {
        AppDelegate.shared?.moveMainWindow(windowId: id, toDisplayMatching: query)
    }

    func controlMoveAllWindows(toDisplayMatching query: String) -> ControlMoveAllWindowsResult? {
        guard let result = AppDelegate.shared?.moveAllMainWindows(toDisplayMatching: query) else {
            return nil
        }
        return ControlMoveAllWindowsResult(display: result.display, windowIDs: result.windowIds)
    }
}

extension TerminalController {
    func controlBrowserPanelAvailabilityEnabled() -> Bool { false }
    func controlBrowserPanelCurrentURLString(panelID: UUID) -> String? { nil }
    func controlBrowserPanelFocusWebView(panelID: UUID) -> ControlBrowserPanelFocusWebViewResolution { .panelNotFound }
    func controlBrowserPanelGoBack(panelID: UUID) -> Bool { false }
    func controlBrowserPanelGoForward(panelID: UUID) -> Bool { false }
    func controlBrowserPanelIsWebViewFocused(panelID: UUID) -> ControlBrowserPanelWebViewFocusState { .panelNotFound }
    func controlBrowserPanelNavigate(panelID: UUID, urlString: String) -> Bool { false }
    func controlBrowserPanelOpen(url: URL?) -> UUID? { nil }
    func controlBrowserPanelOpenURLExternally(_ url: URL) -> Bool { false }
    func controlBrowserPanelReload(panelID: UUID) -> Bool { false }
    func controlBrowserPanelTabManagerAvailable() -> Bool { false }
    func controlCanvasAlign( routing: ControlRoutingSelectors, command: ControlCanvasAlignCommand ) -> ControlCanvasActionResolution { .workspaceNotFound }
    func controlCanvasBreak( routing: ControlRoutingSelectors, surfaceID: UUID ) -> ControlCanvasActionResolution { .workspaceNotFound }
    func controlCanvasInfo(routing: ControlRoutingSelectors) -> ControlCanvasInfoSnapshot? { nil }
    func controlCanvasJoin( routing: ControlRoutingSelectors, surfaceID: UUID, targetSurfaceID: UUID ) -> ControlCanvasActionResolution { .workspaceNotFound }
    func controlCanvasNewPane( routing: ControlRoutingSelectors, type: String ) -> ControlCanvasActionResolution { .workspaceNotFound }
    func controlCanvasReveal( routing: ControlRoutingSelectors, surfaceID: UUID? ) -> ControlCanvasActionResolution { .workspaceNotFound }
    func controlCanvasSelectTab( routing: ControlRoutingSelectors, surfaceID: UUID ) -> ControlCanvasActionResolution { .workspaceNotFound }
    func controlCanvasSetFrame( routing: ControlRoutingSelectors, surfaceID: UUID, frame: ControlCanvasFrame ) -> ControlCanvasActionResolution { .workspaceNotFound }
    func controlCanvasSetMode( routing: ControlRoutingSelectors, mode: String ) -> ControlCanvasActionResolution { .workspaceNotFound }
    func controlCanvasSetViewport( routing: ControlRoutingSelectors, centerX: Double, centerY: Double, magnification: Double? ) -> ControlCanvasActionResolution { .workspaceNotFound }
    func controlCanvasToggleOverview( routing: ControlRoutingSelectors ) -> ControlCanvasActionResolution { .workspaceNotFound }
    func controlCanvasZoom( routing: ControlRoutingSelectors, direction: ControlCanvasZoomDirection ) -> ControlCanvasActionResolution { .workspaceNotFound }
    func controlConfigureWorkspaceRemote( params: [String: JSONValue], workspaceID: UUID ) -> ControlCallResult { .err(code: "unsupported", message: "Unavailable in this build", data: nil) }
    func controlDisconnectWorkspaceRemote( workspaceID: UUID, clearConfiguration: Bool ) -> ControlWorkspaceRemoteResolution { .notConfigured(workspaceID: workspaceID) }
    func controlMobileChatSessionsDump() -> ControlCallResult { .err(code: "unsupported", message: "Unavailable in this build", data: nil) }
    func controlMobileDevStackAuthSetToken(_ token: String?) {}
    func controlMobileHostStatus(params: [String: JSONValue]) -> ControlCallResult { .err(code: "unsupported", message: "Unavailable in this build", data: nil) }
    func controlMobileTaskAttachmentUpload( params: [String: JSONValue] ) -> ControlCallResult { .err(code: "unsupported", message: "Unavailable in this build", data: nil) }
    func controlMobileTerminalCreate(params: [String: JSONValue]) -> ControlCallResult { .err(code: "unsupported", message: "Unavailable in this build", data: nil) }
    func controlMobileTerminalInput(params: [String: JSONValue]) -> ControlCallResult { .err(code: "unsupported", message: "Unavailable in this build", data: nil) }
    func controlMobileTerminalMouse(params: [String: JSONValue]) -> ControlCallResult { .err(code: "unsupported", message: "Unavailable in this build", data: nil) }
    func controlMobileTerminalPaste(params: [String: JSONValue]) async -> ControlCallResult { .err(code: "unsupported", message: "Unavailable in this build", data: nil) }
    func controlMobileTerminalReplay(params: [String: JSONValue]) -> ControlCallResult { .err(code: "unsupported", message: "Unavailable in this build", data: nil) }
    func controlMobileTerminalScroll(params: [String: JSONValue]) -> ControlCallResult { .err(code: "unsupported", message: "Unavailable in this build", data: nil) }
    func controlMobileTerminalViewport(params: [String: JSONValue]) -> ControlCallResult { .err(code: "unsupported", message: "Unavailable in this build", data: nil) }
    func controlMobileWorkspaceList(params: [String: JSONValue]) -> ControlCallResult { .err(code: "unsupported", message: "Unavailable in this build", data: nil) }
    func controlReconnectWorkspaceRemote( workspaceID: UUID, surfaceID: UUID? ) -> ControlWorkspaceRemoteResolution { .notConfigured(workspaceID: workspaceID) }
    func controlSidebarApplyRightSidebarRemoteCommand(tokens: [String]) -> ControlSidebarRightSidebarResolution { .failure(message: "Unavailable in this build") }
    func controlSimulatorBeginOperation( routing: ControlRoutingSelectors, operation: ControlSimulatorOperation ) -> ControlSimulatorOperationStartResolution { .unavailable("Unavailable in this build") }
    func controlSimulatorBeginType( routing: ControlRoutingSelectors, text: String ) -> ControlSimulatorTypeStartResolution { .inputUnavailable }
    func controlSimulatorBeginWebInspectorAttach( routing: ControlRoutingSelectors, targetID: String ) -> ControlSimulatorWebInspectorStartResolution { .unavailable }
    func controlSimulatorBeginWebInspectorHighlight( routing: ControlRoutingSelectors, enabled: Bool ) -> ControlSimulatorWebInspectorStartResolution { .unavailable }
    func controlSimulatorBeginWebInspectorRelease( routing: ControlRoutingSelectors ) -> ControlSimulatorWebInspectorStartResolution { .unavailable }
    func controlSimulatorBeginWebInspectorSend( routing: ControlRoutingSelectors, json: String ) -> ControlSimulatorWebInspectorStartResolution { .unavailable }
    func controlSimulatorBeginWebInspectorTargets( routing: ControlRoutingSelectors ) -> ControlSimulatorWebInspectorStartResolution { .unavailable }
    func controlWorkspaceRemoteForegroundAuthReady( workspaceID: UUID, foregroundAuthToken: String?, resolvedControlPath: String? ) -> ControlWorkspaceRemoteResolution { .notConfigured(workspaceID: workspaceID) }
    func controlWorkspaceRemotePTYAttachEnd( workspaceID: UUID, surfaceID: UUID, sessionID: String ) -> ControlWorkspaceRemotePTYAttachEndResolution { .notFound }
    func controlWorkspaceRemoteStatus(workspaceID: UUID) -> ControlWorkspaceRemoteResolution { .notConfigured(workspaceID: workspaceID) }
    func controlWorkspaceRemoteTerminalSessionConnected( workspaceID: UUID, surfaceID: UUID, authority: ControlWorkspaceRemoteTerminalAuthority, attemptID: UUID, commitLease: (any ControlRemotePTYLifecycleCommitLease)? ) -> ControlWorkspaceRemoteTerminalSessionConnectedResolution { .notFound }
    func controlWorkspaceRemoteTerminalSessionEnd( workspaceID: UUID, surfaceID: UUID, relayPort: Int?, terminalLifecycleID: UUID?, sessionID: String?, lifecycleID: String?, lifecycleOnly: Bool ) -> ControlWorkspaceRemoteTerminalSessionEndResolution { .notFound }
    func controlWorkspaceRemoteTerminalSessionLaunching( workspaceID: UUID, surfaceID: UUID, terminalLifecycleID: UUID, attemptID: UUID ) -> ControlWorkspaceRemoteTerminalSessionConnectedResolution { .notFound }
}

extension TerminalController {
    nonisolated func controlSidebarScheduleScopedGitBranchUpdate(
        scope: ControlSidebarPanelScope,
        branch: String,
        isDirty: Bool?
    ) {
        Task { @MainActor in
            guard let tab = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceID)?.tabs.first(where: { $0.id == scope.workspaceID }) else { return }
            tab.panelGitBranches[scope.panelID] = SidebarGitBranchState(branch: branch, isDirty: isDirty ?? false)
        }
    }
    func controlSidebarUpdateGitBranch(tabArg: String?, branch: String, isDirty: Bool?) -> Bool {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else { return false }
        tab.gitBranch = SidebarGitBranchState(branch: branch, isDirty: isDirty ?? false)
        return true
    }

    nonisolated func controlSidebarScheduleScopedGitBranchClear(scope: ControlSidebarPanelScope) {
        Task { @MainActor in
            guard let tab = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceID)?.tabs.first(where: { $0.id == scope.workspaceID }) else { return }
            tab.clearPanelGitBranch(panelId: scope.panelID)
        }
    }

    nonisolated func controlSidebarSchedulePanelPullRequestUpdate(
        target: ControlSidebarPanelMutationTarget,
        number: Int,
        label: String,
        url: URL,
        statusRawValue: String,
        branch: String?
    ) {}

    nonisolated func controlSidebarSchedulePanelPullRequestAction(
        target: ControlSidebarPanelMutationTarget,
        action: String,
        actionTarget: String?
    ) {}

    nonisolated func controlCurrentRemotePTYLifecycleOwner(
        sessionID: String,
        lifecycleID: String
    ) -> ControlRemotePTYLifecycleOwner? { nil }
}
