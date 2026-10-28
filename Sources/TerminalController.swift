import CmuxMobileHost
import CmuxSettingsUI
import AppKit
import CmuxCore
import CmuxFeedback
import CmuxControlSocket
import CmuxFoundation
import CmuxPanes
import CmuxSurfaceCatalogModel
import CmuxTerminal
import CmuxTerminalSizing
import CmuxSettings
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXAgentLaunch
import CmuxAgentChat
import Foundation
import os
import Bonsplit
import WebKit
import CmuxSidebar
import CmuxWorkspaces
import CmuxNotifications
private let mobileReconnectDebugLog = Logger(subsystem: "dev.cmux", category: "mobile-reconnect-debug")
extension Notification.Name {
    static let socketListenerDidStart = Notification.Name("cmux.socketListenerDidStart")
    static let terminalSurfaceHostedViewDidMoveToWindow = Notification.Name("cmux.terminalSurfaceHostedViewDidMoveToWindow")
    static let mainWindowContextsDidChange = Notification.Name("cmux.mainWindowContextsDidChange")
    static let browserDownloadEventDidArrive = Notification.Name("cmux.browserDownloadEventDidArrive")
    /// Posted on the main thread by a browser panel when its main frame commits a new document.
    static let browserMainFrameDidCommit = Notification.Name("cmux.browserMainFrameDidCommit")
    static let reactGrabDidCopySelection = Notification.Name("cmux.reactGrabDidCopySelection")
    static let workstreamEventReceived = Notification.Name("cmux.workstreamEventReceived")
}

struct CodeRouterHandoffSessionBinding: Sendable, Equatable {
    let authSessionGeneration: UInt64
    let resolvedTeamID: String?
}

private struct SocketLineProcessingResult: Sendable {
    let response: String?
    let passwordAuthorization: SocketPasswordAuthorization
    /// AuthCoordinator session and selected-team state captured before a
    /// CodeRouter handoff worker starts. A lease response is written only
    /// while both values are still current on the main actor.
    let codeRouterHandoffSessionBinding: CodeRouterHandoffSessionBinding?
}
// Agent notification gating types (AgentTurnCompleteMode / AgentNotificationMeta /
// agentNotificationShouldDeliver) live in AgentNotificationGate.swift;
// AgentNotifyCategory lives in the CmuxSettings package.
#if DEBUG
/// Accumulated worker→main `v2MainSync` hop time for the socket command
/// currently executing on a worker thread. Confined to one thread: it lives in
/// that thread's `threadDictionary`, `processSocketLine` installs a fresh
/// instance per command, `v2MainSync` mutates it in place (no per-hop
/// allocation), and the end-of-command debug log on the same thread reads the
/// totals. It never crosses threads, so it is intentionally not Sendable.
private final class SocketCommandMainHopAccumulator {
    var queueWaitNanos: UInt64 = 0
    var bodyNanos: UInt64 = 0
    var hopCount: Int = 0
}
#endif
private struct RemotePTYSocketTarget {
    let windowId: UUID?
    let windowRef: Any
    let workspaceId: UUID
    let workspaceRef: Any
    let workspaceTitle: String
}
nonisolated func remotePTYSessionListErrorIsUnsupportedDaemon(_ error: Error) -> Bool {
    let nsError = error as NSError
    guard nsError.domain == "cmux.remote.daemon.rpc", nsError.code == 14 else {
        return false
    }
    return error.localizedDescription
        .range(of: "pty.list failed (method_not_found)", options: [.caseInsensitive]) != nil
}
nonisolated private func v2RemotePTYUserFacingErrorMessage(_ error: Error) -> String {
    v2RemotePTYUserFacingErrorMessage(error.localizedDescription)
}
nonisolated private func v2RemotePTYUserFacingErrorMessage(_ message: String) -> String {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "remote PTY operation failed" }
    let lowered = trimmed.lowercased()
    if lowered.contains("missing required capability") ||
        lowered.contains("pty.session") ||
        lowered.contains("method_not_found") {
        return "remote daemon does not support persistent SSH PTY sessions; reconnect the remote workspace to update cmux"
    }
    if lowered.contains("pty_session_not_found") ||
        (lowered.contains("persistent ssh pty session") && lowered.contains("not running")) ||
        (lowered.contains("persistent pty session") && lowered.contains("not running")) {
        return "persistent SSH PTY session is no longer running"
    }
    if lowered.contains("pty_input_queue_full") || lowered.contains("pty input queue is full") {
        return "remote PTY input is temporarily backed up"
    }
    if lowered.contains("remote connection is not active") {
        return "remote connection is not active"
    }
    if lowered.contains("remote daemon is not ready") || lowered.contains("remote daemon tunnel is not ready") {
        return "remote daemon is not ready"
    }
    if lowered.contains("missing workspace_id in ssh pty session list response") {
        return "missing workspace_id in SSH PTY session list response"
    }
    if lowered.contains("missing session_id in ssh pty session list response") {
        return "missing session_id in SSH PTY session list response"
    }
    if lowered.contains("timed out") || lowered.contains("timeout") {
        return "remote daemon did not respond in time"
    }
    return "remote PTY operation failed"
}
/// Unix socket-based controller for programmatic terminal control
/// Allows automated testing and external control of terminal tabs
@MainActor
class TerminalController {
    static let shared = TerminalController()
    /// Bounded socket-worker deadline around the hosted CodeRouter mint.
    nonisolated static let codeRouterHandoffWorkerTimeoutSeconds: TimeInterval = 22
    private enum ReloadConfigurationWaitResult: Sendable {
        case committed
        case failed
        case busy
    }
#if DEBUG
    nonisolated let windowScreenshotCaptureCoordinator =
        WindowScreenshotCaptureCoordinator()
#endif
    private nonisolated static let maximumConcurrentReloadConfigurationWaiters =
        4
    private nonisolated let remotePTYControllerAvailabilityCondition = NSCondition()
    private nonisolated(unsafe) var remotePTYControllerAvailabilityGeneration: UInt64 = 0
    /// Actor-isolated ten-minute cache for mobile task model discovery.
    nonisolated let mobileTaskModelDiscovery: MobileTaskModelDiscovery
    var tabManager: TabManager?
    let workspaceCreateIdempotencyCache = WorkspaceCreateIdempotencyCache(capacity: 256)
    @MainActor private(set) var caffeineController: CaffeineController?
    @MainActor var agentChatTranscriptService: AgentChatTranscriptService?
    /// App-lifetime automation engine, attached by the composition root after
    /// the initial TabManager and notification store are ready.
    @MainActor var automationEngine: AutomationEngine?
    nonisolated let terminalArtifactAuthorizationStore: TerminalArtifactAuthorizationStore
    /// Main-actor grants for the file currently displayed by each mobile panel.
    /// The live panel inventory and artifact reads share this owner so a closed
    /// or replaced panel cannot retain an old file authorization.
    let panelArtifactAuthorizationStore: PanelArtifactAuthorizationStore
    // Sendable value type; injected at construction so socket auth never reaches a global.
    nonisolated let passwordStore: SocketControlPasswordStore
    private nonisolated let socketPasswordFileWatcher: FileWatcher?
    nonisolated let socketClientCapabilityAuthority: SocketClientCapabilityAuthority
    private nonisolated let socketClientPreauthorizationLimiter: SocketClientPreauthorizationLimiter
    /// Bounds worker threads and completion contexts parked for synchronous
    /// `reload_config` acknowledgements. Excess callers receive backpressure.
    private nonisolated let reloadConfigurationWaiterAdmission =
        SocketReloadConfigurationWaiterAdmission(
            maximumConcurrentWaiters:
                maximumConcurrentReloadConfigurationWaiters
        )
    private nonisolated let agentHookDeliveryQueue: AgentHookDeliveryQueue
    // Stateless Sendable structs from CmuxControlSocket; injected at construction.
    // `transport` is internal so sibling-file extensions (CmuxEventStream) can write through it.
    nonisolated let transport: SocketTransport
    // The package-owned listener: path/bind/lock lifecycle, accept source,
    // backoff/rearm recovery, and the generation-counted state machine.
    nonisolated let socketServer: SocketControlServer
    /// App-owned discovery marker store injected into the listener event seam.
    nonisolated let socketPathMarkerStore: SocketPathMarkerStore
    // Accepted-connection consumer; runs until process exit (singleton).
    private nonisolated let socketConnectionsTask: Task<Void, Never>
    /// Bounded async connection admission. The pool owns task lifetimes; an
    /// admitted connection owns its descriptor until its async handler exits.
    nonisolated let socketClientWorkerPool = ControlClientWorkerPool(
        maximumConcurrentJobs: TerminalController.socketClientMaximumConcurrentJobs,
        maximumPendingJobs: TerminalController.socketClientMaximumPendingJobs,
        maximumPendingAgeNanoseconds: TerminalController.socketPendingConnectionMaximumAgeNanoseconds,
        maximumParkedJobs: TerminalController.socketClientMaximumParkedJobs
    )
    /// Answers connections the pool cannot serve with a real `overloaded`
    /// error instead of a closed descriptor (#13369).
    nonisolated let socketOverloadResponder = TerminalController.makeSocketOverloadResponder()
    /// Deduplicates the once-per-episode Sentry captures for socket-lane stalls.
    nonisolated let socketLaneHealth = SocketLaneHealth()
    /// Latest main-actor-published read results. Socket workers consult this
    /// mirror synchronously before falling back to a live command path.
    nonisolated let socketReadSnapshotStore = ControlReadSnapshotStore()
    /// Coalesced main-actor publication task for topology/read snapshots.
    var socketReadSnapshotRefreshTask: Task<Void, Never>? = nil
    /// Topology notifications that invalidate the published read mirror.
    private var socketReadSnapshotObservers: [NSObjectProtocol] = []
    // Per-surface dedupe for high-frequency report_* socket telemetry.
    // Cross-thread contract (reintroduced by the tranche-B v1 worker lane):
    // the nonisolated seam witness controlSidebarScheduleScopedShellState
    // captures this on per-connection socket-worker threads and runs the
    // compare-and-set inside the drained @MainActor bus closure, so the
    // reference crosses threads even though the mutating calls land on main.
    // The package type's Sendable conformance and internal lock are
    // load-bearing for that contract (and for any future off-main caller) —
    // do not downgrade its locking on the assumption that all callers are
    // main-isolated.
    let socketFastPathState = SocketFastPathState()
    // Stateless sidebar-metadata/command argument parser (CmuxSidebar).
    // Pure transforms over the raw arg string; holds no state and reaches no
    // app singletons, so the `report_*`/sidebar-mutation handlers forward to it.
    private nonisolated let sidebarMetadataArgumentParser = SidebarMetadataArgumentParser()
    private nonisolated let myPid = getpid()
    private nonisolated static let socketCommandFocusAllowanceStackKey = "cmux.socketCommandFocusAllowanceStack"
    private nonisolated static let socketCommandKeyStackKey = "cmux.socketCommandKeyStack"
    /// Signposter for the worker→main `v2MainSync` hop. Intervals are named
    /// "main-hop" and carry the active socket command key plus queue-wait and
    /// body durations, so Instruments can attribute main-thread occupancy per
    /// socket command.
    ///
    /// Backed by the `.dynamicTracing` OSLog category deliberately: with a
    /// plain string category, `isEnabled` reports true on a normal boot
    /// (unified logging buffers signposts by default; verified empirically),
    /// which would make the per-hop clock reads and command-key bookkeeping
    /// unconditional in Release. `.dynamicTracing` stays disabled until a
    /// tool such as Instruments records signposts, so
    /// `socketMainHopSignpostingActive` genuinely gates all per-hop work.
    private nonisolated static let socketMainHopSignposter = OSSignposter(
        subsystem: "com.cmux.socket",
        category: .dynamicTracing
    )
    /// True while a tool (e.g. Instruments' os_signpost instrument) is
    /// recording the main-hop signposts. The single predicate consulted by
    /// both `withSocketCommandPolicy` (command-key stack bookkeeping) and
    /// `v2MainSync` (clock reads + interval emission).
    private nonisolated static var socketMainHopSignpostingActive: Bool {
        socketMainHopSignposter.isEnabled
    }
    private nonisolated static let v2ConsumedBrowserDownloadIDLimit = 128
    struct MobileViewportReport {
        var columns: Int; var rows: Int; var updatedAt: Date; var generation: UInt64? = nil
        /// Device identity the phone reported with its viewport (shared sizing).
        var deviceKind: TerminalDeviceKind = .iphone; var deviceName: String? = nil
        /// The viewer's stable per-install `device_id`, when it sent one.
        var deviceID: String? = nil
        /// Sticky reports come from the dedicated `mobile.terminal.viewport`
        /// RPC and live for the client's connection lifetime (cleared on
        /// disconnect or surface detach), so an idle paired device keeps its
        /// viewport border. Non-sticky reports piggyback on `terminal.input`
        /// and expire on the TTL so a client that only ever typed once does
        /// not pin the grid forever.
        var sticky: Bool = false
    }
    private static let mobileViewportReportTTL: TimeInterval = 5
    /// Stability window for a governed cap-to-cap grid change: long enough to
    /// coalesce the pre/post keyboard-inset double report, short enough that a
    /// legitimate keyboard resize is not felt as lag.
    private static let mobileViewportCapApplyStabilityWindow: Duration = .milliseconds(400)
    /// Stability window for a governed uncap. Deliberately long: an uncap only
    /// restores the Mac pane after the last phone leaves, so nobody is hurt by
    /// waiting, and a remount's re-apply of the same grid must arrive inside
    /// this window (relay round trips inflate that gap to seconds) to cancel
    /// the clear+re-apply resize flap (issue 13474).
    private static let mobileViewportUncapApplyStabilityWindow: Duration = .seconds(3)
    var mobileViewportReportsBySurfaceID: [UUID: [String: MobileViewportReport]] = [:]; private var mobileViewportGenerationsBySurfaceID: [UUID: [String: UInt64]] = [:]
    private var mobileTerminalPasteInFlightSurfaceIDs: Set<UUID> = []
    /// The one size panel popover, anchored at a terminal's tab.
    private var mobileViewportGovernorFlushTasksBySurfaceID: [UUID: Task<Void, Never>] = [:]
#if DEBUG
    private nonisolated static let socketCommandDebugLogEnvironmentKey = "CMUX_DEBUG_SOCKET_COMMAND_LOG"
    private nonisolated static let socketCommandSlowThresholdMs: Double = 500
#endif
    // The terminal-input message/error statics are nonisolated: pure,
    // thread-safe bundle lookups, used by the v1 send bodies' off-main reply
    // mapping (tranche E) as well as main-actor callers.
    nonisolated static var terminalProcessExitedMessage: String {
        String(
            localized: "socket.terminal.processExited",
            defaultValue: "The terminal session has ended; reopen it or create a new terminal session."
        )
    }
    nonisolated static var terminalInputQueueFullMessage: String {
        String(
            localized: "socket.terminal.inputQueueFull",
            defaultValue: "The terminal can't accept more input right now. Wait a moment and retry, or reopen the terminal if it stays unavailable."
        )
    }
    nonisolated static var terminalSurfaceUnavailableMessage: String {
        String(
            localized: "socket.terminal.surfaceUnavailable",
            defaultValue: "The terminal surface is no longer available; reopen it or create a new terminal session."
        )
    }
    /// The command that shows, and so wakes, a hibernated terminal.
    nonisolated static func terminalWakeCommand(workspaceID: UUID, surfaceID: UUID) -> String {
        "cmux focus-panel --workspace \(workspaceID.uuidString) --panel \(surfaceID.uuidString)"
    }

    /// Explains why a terminal has no running runtime and how to get one.
    nonisolated static func terminalNotRunningMessage(
        reason: TerminalSurfaceRuntimeUnavailableReason,
        wakeCommand: String?
    ) -> String {
        switch reason {
        case .hibernated:
            if let wakeCommand {
                return String.localizedStringWithFormat(
                    String(
                        localized: "socket.terminal.notRunning.hibernated",
                        defaultValue: "The terminal is hibernated: cmux suspended its idle agent to save memory. Wake it by showing it (this brings its window to the front), then retry: %@"
                    ),
                    wakeCommand
                )
            }
            return String(
                localized: "socket.terminal.notRunning.hibernatedNoCommand",
                defaultValue: "The terminal is hibernated: cmux suspended its idle agent to save memory. Show the terminal in cmux to wake it, then retry."
            )
        case .awaitingRestore:
            return String(
                localized: "socket.terminal.notRunning.awaitingRestore",
                defaultValue: "cmux is still restoring the terminal after it reopened and is checking which agent session to resume. Retry in a few seconds."
            )
        case .starting:
            return String(
                localized: "socket.terminal.notRunning.starting",
                defaultValue: "The terminal has not started yet. Retry in a few seconds."
            )
        case .closing:
            return String(
                localized: "socket.terminal.notRunning.closing",
                defaultValue: "The terminal is closing and cannot be read."
            )
        }
    }
    private nonisolated static var terminalProcessExitedSocketError: String {
        "ERROR: \(terminalProcessExitedMessage)"
    }
    private nonisolated static var terminalInputQueueFullSocketError: String {
        "ERROR: \(terminalInputQueueFullMessage)"
    }

    private nonisolated static let focusIntentV1Commands: Set<String> = [
        "__internal_flags",
        "focus_window",
        "select_workspace",
        "focus_surface",
        "focus_pane",
        "focus_surface_by_panel",
        "focus_webview",
        "focus_notification",
        "activate_app",
        "debug_right_sidebar_focus",
    ]

    private nonisolated static let focusIntentV2Methods: Set<String> = [
        "window.focus",
        "workspace.select",
        "workspace.next",
        "workspace.previous",
        "workspace.last",
        "workspace.group.focus",
        "workspace.cloud_vm_open",
        "surface.focus", "surface.jump_to_last_prompt",
        "pane.focus",
        "pane.last",
        "file.open", "workspace.todo.open",
        "browser.focus_webview",
        "browser.focus",
        "browser.focus_mode.set",
        "browser.tab.switch",
        "notification.open",
        "notification.jump_to_unread",
        "debug.command_palette.toggle", "debug.pro_welcome_checklist.show",
        "debug.native_pricing.show",
        "debug.notification.focus",
        "debug.app.activate", "debug.cloudtree.spacing",
        "debug.right_sidebar.focus",
        "feed.jump",
        // Shows Chief Home in the target window, like workspace.select.
        "chief.open"
    ]

    nonisolated static func commandHasFocusIntent(
        commandKey: String,
        isV2: Bool,
        params: [String: Any]
    ) -> Bool {
        if isV2 {
            return focusIntentV2Methods.contains(commandKey)
                || explicitFocusParamAllowsFocus(commandKey: commandKey, params: params)
        }
        return focusIntentV1Commands.contains(commandKey)
    }

    /// Returns the encoded error when task-local automation policy suppresses
    /// a focus-oriented v2 command; otherwise returns `nil`.
    nonisolated static func focusSuppressionResponse(
        method: String,
        id: Any?,
        params: [String: Any]
    ) -> String? {
        guard CmuxAutomationInvocationContext.focusAllowed == false,
              commandHasFocusIntent(commandKey: method, isV2: true, params: params) else {
            return nil
        }
        guard let idValue = v2WireId(id) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return v2Encoder.error(
            id: idValue,
            code: "focus_suppressed",
            message: automationFocusSuppressedMessage(),
            data: nil
        )
    }

    /// The main-actor RPC dispatch coordinator (CmuxControlSocket). Owns the
    /// `kind:N` handle registry and the moved command domains (window so far,
    /// growing per stage-3c sub-stage); this controller is its interim
    /// composition owner and ``ControlCommandContext`` conformer. Constructed in
    /// `init`; its `context` is wired to `self` once `self` is available.
    let controlCommandCoordinator = ControlCommandCoordinator()
    nonisolated let codexRestoreHookEvidence = CodexRestoreHookEvidence(storeURL: RestorableAgentKind.codex.hookStoreFileURL())

    private final class V2BrowserUndefinedSentinel: Sendable {}

    private nonisolated static let v2BrowserEvalEnvelopeTypeKey = "__cmux_t"
    private nonisolated static let v2BrowserEvalEnvelopeValueKey = "__cmux_v"
    private nonisolated static let v2BrowserEvalEnvelopeTypeUndefined = "undefined"
    private nonisolated static let v2BrowserEvalEnvelopeTypeValue = "value"

    private var v2BrowserDownloadEventsBySurface: [UUID: [[String: Any]]] = [:]
    private var v2ConsumedBrowserDownloadKeysBySurface: [UUID: [String]] = [:]
    private var v2BrowserUnsupportedNetworkRequestsBySurface: [UUID: [[String: Any]]] = [:]
    private nonisolated let v2BrowserUndefinedSentinel = V2BrowserUndefinedSentinel()
    private var browserDownloadObserver: NSObjectProtocol?
    private var browserMainFrameCommitObserver: NSObjectProtocol?

    func cleanupSurfaceState(
        surfaceIds: [UUID],
        paneIds: [UUID] = [],
        workspaceID: UUID? = nil
    ) {
        let uniqueSurfaceIds = Set(surfaceIds)
        socketFastPathState.removeShellActivity(panelIds: uniqueSurfaceIds)
        if let workspaceID {
            for surfaceId in uniqueSurfaceIds {
                panelArtifactAuthorizationStore.invalidate(
                    workspaceID: workspaceID.uuidString,
                    surfaceID: surfaceId.uuidString
                )
            }
        }
        for surfaceId in uniqueSurfaceIds {
            v2BrowserDownloadEventsBySurface.removeValue(forKey: surfaceId)
            v2ConsumedBrowserDownloadKeysBySurface.removeValue(forKey: surfaceId)
            v2BrowserUnsupportedNetworkRequestsBySurface.removeValue(forKey: surfaceId)
            controlCommandCoordinator.removeRef(kind: .surface, uuid: surfaceId)
        }
        for paneId in Set(paneIds) { controlCommandCoordinator.removeRef(kind: .pane, uuid: paneId) }
    }

    /// Bridges the package server's event closures back to the controller.
    /// Assigned exactly once during `init`, before the listener can start, and
    /// read-only afterward; the controller is an app-lifetime singleton.
    final class ServerEventTarget: @unchecked Sendable {
        weak var controller: TerminalController?
    }

    /// Queues a session hook the app observed for a remote agent (the cmux-tui agent
    /// roster of a `cmux ssh` machine) through the same relay-backed delivery
    /// lane as `agent.hook.enqueue`, routed to the local pane showing it.
    /// - Returns: `false` when the socket is not listening, the event is
    ///   invalid for queued delivery, or the queue is full.
    nonisolated func enqueueMirroredAgentHook(
        agent: String,
        subcommand: String,
        payload: String,
        workspaceID: UUID,
        surfaceID: UUID
    ) -> Bool {
        guard let socketPath = currentSocketPathForRemoteRestore(),
              let event = AgentHookDeliveryEvent.mirrored(
                  agent: agent,
                  subcommand: subcommand,
                  payload: payload,
                  workspaceID: workspaceID,
                  surfaceID: surfaceID,
                  deliverySocketPath: socketPath
              ) else {
            return false
        }
        return agentHookDeliveryQueue.enqueue(event)
    }

    private init(
        passwordStore: SocketControlPasswordStore = SocketControlPasswordStore(),
        transport: SocketTransport = SocketTransport(),
        listenerPolicy: SocketListenerPolicy = SocketListenerPolicy(),
        socketClientPreauthorizationLimiter: SocketClientPreauthorizationLimiter = .init(
            maximumConcurrentClaims: TerminalController.socketClientPreauthorizationMaximumClaims
        ),
        mobileTaskModelDiscovery: MobileTaskModelDiscovery = .live(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            shellPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        ),
        terminalArtifactAuthorizationStore: TerminalArtifactAuthorizationStore = .init(),
        panelArtifactAuthorizationStore: PanelArtifactAuthorizationStore? = nil,
        agentHookDeliveryQueue: AgentHookDeliveryQueue = AgentHookDeliveryQueue()
    ) {
        self.passwordStore = passwordStore
        let socketPasswordFileWatcher = passwordStore.passwordFileURL.map {
            FileWatcher(path: $0.path)
        }
        self.socketPasswordFileWatcher = socketPasswordFileWatcher
        self.socketClientCapabilityAuthority = Self.makeSocketClientCapabilityAuthority()
        self.socketClientPreauthorizationLimiter = socketClientPreauthorizationLimiter
        self.agentHookDeliveryQueue = agentHookDeliveryQueue
        self.mobileTaskModelDiscovery = mobileTaskModelDiscovery
        self.terminalArtifactAuthorizationStore = terminalArtifactAuthorizationStore
        self.panelArtifactAuthorizationStore =
            panelArtifactAuthorizationStore ?? PanelArtifactAuthorizationStore()
        self.transport = transport
        let socketMarkerFileManager = FileManager.default
        let socketMarkerBundleIdentifier = Bundle.main.bundleIdentifier
        let socketMarkerEnvironment = ProcessInfo.processInfo.environment
        let socketMarkerVariant = SocketPathMarkerFiles.variant(
            bundleIdentifier: socketMarkerBundleIdentifier,
            environment: socketMarkerEnvironment,
            baseDebugBundleIdentifier: SocketControlSettings.baseDebugBundleIdentifier
        )
        let socketPathMarkerStore = SocketPathMarkerStore(
            bundleIdentifier: socketMarkerBundleIdentifier,
            environment: socketMarkerEnvironment,
            stateDirectory: CmuxStateDirectory.url(
                homeDirectory: socketMarkerFileManager.homeDirectoryForCurrentUser
            ),
            legacyDirectory: CmuxStateDirectory.legacyApplicationSupportURL(
                fileManager: socketMarkerFileManager
            ),
            tmpMarkerPath: socketMarkerVariant.tmpPath,
            fileManager: socketMarkerFileManager
        )
        self.socketPathMarkerStore = socketPathMarkerStore
        // Managed Cloud VM daemon endpoints go stale when the machine's preview rotates
        // (sandbox recreation, preview re-creation). Before each proxy retry, re-mint the
        // endpoint through the backend so the broker never redials a dead URL forever.
        let serverEventTarget = ServerEventTarget()
        let socketServer = SocketControlServer(
            transport: transport,
            listenerPolicy: listenerPolicy, notificationCenter: .default,
            effectivePasswordProvider: {
                passwordStore.configuredPassword(allowLazyKeychainFallback: true)
            },
            authorizationChangeSignals: socketPasswordFileWatcher?.events,
            events: Self.makeSocketServerEvents(
                target: serverEventTarget,
                markerStore: socketPathMarkerStore,
                failureCaptureGate: SocketListenerFailureCaptureGate(
                    // Deleted /tmp dev sockets are routine on dev machines
                    // (cleanup scripts) and the path monitor self-heals, so
                    // debug builds keep path.missing as breadcrumbs only.
                    capturesPathMissingFailures: !SocketControlSettings.isDebugLikeBundleIdentifier(
                        socketMarkerBundleIdentifier
                    )
                )
            )
        )
        self.socketServer = socketServer
        // Single consumer of the accepted-connection stream. Accepted
        // descriptors are admitted to the bounded async pool; the listener
        // itself never creates one detached NSThread per client.
        self.socketConnectionsTask = Task.detached {
            for await connection in socketServer.connections {
                guard let controller = serverEventTarget.controller else {
                    close(connection.socket)
                    continue
                }
                await controller.spawnClientHandler(
                    socket: connection.socket,
                    peerPid: connection.peerProcessID,
                    peerAuditToken: connection.peerAuditToken,
                    peerProcessStartTime: connection.peerProcessStartTime,
                    authorizationGeneration: connection.authorizationGeneration,
                    authorizationRevocationSignal: connection.authorizationRevocationSignal
                )
            }
        }
        serverEventTarget.controller = self
        controlCommandCoordinator.context = self
        socketReadSnapshotObservers = [
            Notification.Name.mainWindowContextsDidChange,
            Notification.Name.workspaceOrderDidChange,
            Notification.Name.workspacePaneGeometryDidChange,
            Notification.Name.workspaceTitleDidChange,
            Notification.Name.workspaceCurrentDirectoryDidChange,
        ].map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                // These topology notifications are posted by MainActor-owned
                // workspace/window mutations. A nil queue keeps invalidation
                // synchronous at the notification boundary.
                queue: nil
            ) { [weak self] notification in
                let topologyChanged = name == .mainWindowContextsDidChange
                    || name == .workspaceOrderDidChange
                    || (name == .workspacePaneGeometryDidChange
                        && notification.userInfo?[GhosttyNotificationKey.topologyChanged] as? Bool == true)
                // This observer is explicitly installed on the main queue.
                // Invalidate before creating the deferred publication task so
                // a queued socket read cannot observe a completed claim after
                // the topology has already changed.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if topologyChanged {
                        self.invalidateSocketHandleTopologyRefresh()
                    }
                    self.scheduleSocketReadSnapshotRefresh()
                }
            }
        }
        browserDownloadObserver = NotificationCenter.default.addObserver(
            forName: .browserDownloadEventDidArrive,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let surfaceId = note.userInfo?["surfaceId"] as? UUID,
                  let event = note.userInfo?["event"] as? [String: Any] else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.v2RecordBrowserDownloadEvent(surfaceId: surfaceId, event: event)
            }
        }
        browserMainFrameCommitObserver = NotificationCenter.default.addObserver(
            forName: .browserMainFrameDidCommit,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let surfaceId = note.userInfo?["surfaceId"] as? UUID else { return }
            // The panel posts from its main-thread commit callback and this
            // observer is on the main queue, so the block runs before the post
            // returns. Drop the old page's frame and refs here, not in a
            // deferred task, so no command can use them against the new page.
            MainActor.assumeIsolated {
            }
        }
    }
    nonisolated static func shouldSuppressSocketCommandActivation() -> Bool {
        !currentSocketCommandFocusAllowanceStack().isEmpty
    }

    nonisolated static func socketCommandAllowsInAppFocusMutations() -> Bool {
        allowsInAppFocusMutationsForActiveSocketCommand()
    }

    private nonisolated static func allowsInAppFocusMutationsForActiveSocketCommand() -> Bool {
        currentSocketCommandFocusAllowanceStack().last ?? false
    }

    private func socketCommandAllowsInAppFocusMutations() -> Bool {
        Self.allowsInAppFocusMutationsForActiveSocketCommand()
    }

    func v2FocusAllowed(requested: Bool = true) -> Bool {
        requested && socketCommandAllowsInAppFocusMutations()
    }

    func v2MaybeFocusWindow(for tabManager: TabManager) {
        guard socketCommandAllowsInAppFocusMutations(),
              let windowId = v2ResolveWindowId(tabManager: tabManager) else { return }
        _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
        setActiveTabManager(tabManager)
    }

    func v2MaybeSelectWorkspace(_ tabManager: TabManager, workspace: Workspace) {
        guard socketCommandAllowsInAppFocusMutations() else { return }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
    }

    nonisolated static func socketCommandAllowsInAppFocusMutations(commandKey: String, isV2: Bool, params: [String: Any] = [:]) -> Bool {
        // Automation actions run through the same dispatcher as socket/CLI
        // calls, but their default is deliberately focus-neutral. A task-local
        // override lets an action opt into focus without weakening the normal
        // command policy for user and external CLI traffic.
        if let automationOverride = CmuxAutomationInvocationContext.focusAllowed {
            return automationOverride
        }
        if isV2 {
            return commandHasFocusIntent(commandKey: commandKey, isV2: true, params: params)
        }
        if commandKey == "right_sidebar" {
            return rightSidebarCommandAllowsInAppFocusMutations(args: params["args"] as? String ?? "")
        }
        return focusIntentV1Commands.contains(commandKey)
    }

    private nonisolated static func rightSidebarCommandAllowsInAppFocusMutations(args: String) -> Bool {
        let parsed = RightSidebarRemoteRequest.parse(tokens: Self.tokenizeArgs(args))
        guard case .success(let request) = parsed else { return false }
        switch request.command {
        case .toggle, .show, .focus:
            return true
        case .setMode(_, let focus), .setCustomSidebar(_, let focus):
            return focus
        case .hide, .getState:
            return false
        }
    }

    nonisolated func withSocketCommandPolicy<T>(commandKey: String, isV2: Bool, params: [String: Any] = [:], _ body: () -> T) -> T {
        let allowsFocusMutation = Self.socketCommandAllowsInAppFocusMutations(commandKey: commandKey, isV2: isV2, params: params)
        var stack = Self.currentSocketCommandFocusAllowanceStack()
        stack.append(allowsFocusMutation)
        Self.setCurrentSocketCommandFocusAllowanceStack(stack)
        // The command-key stack exists solely to attribute main-hop signpost
        // intervals, so its threadDictionary bookkeeping only runs while a
        // tool is recording. The entry-time decision is captured so a
        // mid-command enablement flip can neither pop a frame it never pushed
        // nor leak one it did (and the pop stays isEmpty-guarded).
        let recordsCommandKey = Self.socketMainHopSignpostingActive
        if recordsCommandKey {
            var keyStack = Self.currentSocketCommandKeyStack()
            keyStack.append(commandKey)
            Self.setCurrentSocketCommandKeyStack(keyStack)
        }
        defer {
            var stack = Self.currentSocketCommandFocusAllowanceStack()
            if !stack.isEmpty {
                _ = stack.popLast()
            }
            Self.setCurrentSocketCommandFocusAllowanceStack(stack)
            if recordsCommandKey {
                var keyStack = Self.currentSocketCommandKeyStack()
                if !keyStack.isEmpty {
                    _ = keyStack.popLast()
                }
                Self.setCurrentSocketCommandKeyStack(keyStack)
            }
        }
        return body()
    }

    nonisolated static func currentSocketCommandFocusAllowanceStack() -> [Bool] {
        Thread.current.threadDictionary[socketCommandFocusAllowanceStackKey] as? [Bool] ?? []
    }

    nonisolated static func setCurrentSocketCommandFocusAllowanceStack(_ stack: [Bool]) {
        if stack.isEmpty {
            Thread.current.threadDictionary.removeObject(forKey: socketCommandFocusAllowanceStackKey)
        } else {
            Thread.current.threadDictionary[socketCommandFocusAllowanceStackKey] = stack
        }
    }

    nonisolated static func withSocketCommandPolicyStack<T>(_ stack: [Bool], _ body: () throws -> T) rethrows -> T {
        let previous = currentSocketCommandFocusAllowanceStack()
        setCurrentSocketCommandFocusAllowanceStack(stack)
        defer { setCurrentSocketCommandFocusAllowanceStack(previous) }
        return try body()
    }

    /// The stack of socket command keys currently executing on this thread
    /// (parallel to the focus-allowance stack pushed by
    /// `withSocketCommandPolicy`). `v2MainSync` reads the innermost key to
    /// attribute its main-hop signpost interval; nothing propagates the key
    /// stack across the hop because timing is recorded on the worker side.
    private nonisolated static func currentSocketCommandKeyStack() -> [String] {
        Thread.current.threadDictionary[socketCommandKeyStackKey] as? [String] ?? []
    }

    private nonisolated static func setCurrentSocketCommandKeyStack(_ stack: [String]) {
        if stack.isEmpty {
            Thread.current.threadDictionary.removeObject(forKey: socketCommandKeyStackKey)
        } else {
            Thread.current.threadDictionary[socketCommandKeyStackKey] = stack
        }
    }

    private nonisolated static func currentSocketCommandKey() -> String? {
        currentSocketCommandKeyStack().last
    }

#if DEBUG
    static func debugSocketCommandPolicySnapshot(
        commandKey: String,
        isV2: Bool,
        params: [String: Any] = [:]
    ) -> (insideSuppressed: Bool, insideAllowsFocus: Bool, outsideSuppressed: Bool, outsideAllowsFocus: Bool) {
        var insideSuppressed = false
        var insideAllowsFocus = false
        _ = Self.shared.withSocketCommandPolicy(commandKey: commandKey, isV2: isV2, params: params) {
            insideSuppressed = Self.shouldSuppressSocketCommandActivation()
            insideAllowsFocus = Self.socketCommandAllowsInAppFocusMutations()
            return 0
        }
        return (
            insideSuppressed: insideSuppressed,
            insideAllowsFocus: insideAllowsFocus,
            outsideSuppressed: Self.shouldSuppressSocketCommandActivation(),
            outsideAllowsFocus: Self.socketCommandAllowsInAppFocusMutations()
        )
    }

    static func debugNotifyTargetQueuedResponseForTesting(_ args: String) -> String {
        Self.shared.notifyTargetQueued(args)
    }
#endif

    nonisolated static func shouldReplaceStatusEntry(
        current: SidebarStatusEntry?,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: SidebarMetadataFormat,
        workState: SidebarAgentWorkState?
    ) -> Bool {
        guard let current else { return true }
        return current.key != key ||
            current.value != value ||
            current.icon != icon ||
            current.color != color ||
            current.url != url ||
            current.priority != priority ||
            current.format != format ||
            current.workState != workState
    }

    nonisolated static func shouldReplaceMetadataBlock(
        current: SidebarMetadataBlock?,
        key: String,
        markdown: String,
        priority: Int
    ) -> Bool {
        guard let current else { return true }
        return current.key != key || current.markdown != markdown || current.priority != priority
    }

    nonisolated static func shouldReplaceProgress(
        current: SidebarProgressState?,
        value: Double,
        label: String?
    ) -> Bool {
        guard let current else { return true }
        return current.value != value || current.label != label
    }

    nonisolated static func shouldReplaceGitBranch(
        current: SidebarGitBranchState?,
        branch: String,
        isDirty: Bool
    ) -> Bool {
        guard let current else { return true }
        return current.branch != branch || current.isDirty != isDirty
    }

    nonisolated static func shouldReplacePullRequest(
        current: SidebarPullRequestState?,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String?
    ) -> Bool {
        guard let current else { return true }
        let normalizedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBranch: String? = {
            if let normalizedBranch, !normalizedBranch.isEmpty {
                return normalizedBranch
            }
            guard current.number == number,
                  current.label == label,
                  current.url == url,
                  current.status == status else {
                return nil
            }
            return current.branch
        }()
        return current.number != number
            || current.label != label
            || current.url != url
            || current.status != status
            || current.branch != effectiveBranch
            || current.isStale
    }

    nonisolated static func shouldReplacePorts(current: [Int]?, next: [Int]) -> Bool {
        let currentSorted = Array(Set(current ?? [])).sorted()
        let nextSorted = Array(Set(next)).sorted()
        return currentSorted != nextSorted
    }

    nonisolated static func explicitSocketScope(
        options: [String: String]
    ) -> (workspaceId: UUID, panelId: UUID)? {
        guard let tabRaw = options["tab"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tabRaw.isEmpty,
              let panelRaw = (options["panel"] ?? options["surface"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !panelRaw.isEmpty,
              let workspaceId = UUID(uuidString: tabRaw),
              let panelId = UUID(uuidString: panelRaw) else {
            return nil
        }
        return (workspaceId, panelId)
    }

    nonisolated static func normalizeReportedDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), !url.path.isEmpty {
            return url.path
        }
        return trimmed
    }

    nonisolated static func normalizedExportedScreenPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed),
           url.isFileURL,
           !url.path.isEmpty {
            return url.path
        }
        return trimmed.hasPrefix("/") ? trimmed : nil
    }

    nonisolated static func shouldRemoveExportedScreenFile(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let standardizedFile = fileURL.standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        return standardizedFile.path.hasPrefix(temporary.path + "/")
    }

    nonisolated static func shouldRemoveExportedScreenDirectory(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        return directory.path.hasPrefix(temporary.path + "/")
    }

    nonisolated static func normalizedMobileVTExportText(_ text: String) -> String {
        // Ghostty's VT formatter writes row separators as CRLF. Swift treats
        // CRLF as one Character, so split(separator: "\n") would miss rows.
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    nonisolated static func parseReportedShellActivityState(
        _ rawState: String
    ) -> PanelShellActivityState? {
        switch rawState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "prompt", "idle":
            return .promptIdle
        case "running", "busy", "command":
            return .commandRunning
        case "unknown", "clear":
            return .unknown
        default:
            return nil
        }
    }

    /// Update which window's TabManager receives socket commands.
    /// This is used when the user switches between multiple terminal windows.
    func setActiveTabManager(_ tabManager: TabManager?) {
        if let tabManager {
        }
        self.tabManager = tabManager
    }

    func activeTabManagerForCallerNotification() -> TabManager? { tabManager }

    // MARK: - Process Ancestry Check

    /// Check if `pid` is a descendant of this process by walking the process tree.
    nonisolated func isDescendant(_ pid: pid_t) -> Bool {
        transport.isProcessDescendant(pid, of: myPid)
    }

    /// Inject the auth graph. Call once at the composition root, before the
    /// socket listener accepts auth commands.
    @MainActor
    func attachAuth(
    ) {
    }

    /// Inject the app-lifetime power controller before socket or mobile calls
    /// can reach the caffeine methods.
    @MainActor
    func attachCaffeineController(_ controller: CaffeineController) {
        caffeineController = controller
    }

    func start(
        tabManager: TabManager,
        socketPath: String,
        accessMode: SocketControlMode,
        preserveAcceptFailureStreak: Bool = false
    ) {
        self.tabManager = tabManager
        socketServer.start(
            socketPath: socketPath,
            accessMode: accessMode,
            preserveAcceptFailureStreak: preserveAcceptFailureStreak
        )
    }

    /// Invoked synchronously inside the server's `start()` on the main
    /// actor, at the exact lifecycle point the legacy implementation posted
    /// `.socketListenerDidStart`.
    func socketListenerDidStart(path: String) {
        NotificationCenter.default.post(
            name: .socketListenerDidStart,
            object: self,
            userInfo: ["path": path]
        )

        // Wire batched port scanner results back to workspace state.
        PortScanner.shared.onPortsUpdated = { [weak self] workspaceId, panelId, ports in
            self?.applyPanelPortPublication(workspaceId: workspaceId, panelId: panelId, ports: ports)
        }
        PortScanner.shared.onAgentPortsUpdated = { [weak self] workspaceId, ports in
            self?.applyAgentPortPublication(workspaceId: workspaceId, ports: ports) ?? false
        }
        PortScanner.shared.setTrackedAgentScanningPaused(!NSApplication.shared.isActive)
        scheduleSocketReadSnapshotRefresh()
    }

    func applyPanelPortPublication(workspaceId: UUID, panelId: UUID, ports: [Int]) {
        guard let workspace = portPublicationWorkspace(workspaceId: workspaceId),
              workspace.panels[panelId] != nil else { return }
        let nextPorts: [Int]? = ports.isEmpty ? nil : ports
        guard workspace.surfaceListeningPorts[panelId] != nextPorts else { return }
        workspace.surfaceListeningPorts[panelId] = nextPorts
        workspace.recomputeListeningPorts()
    }

    func applyAgentPortPublication(workspaceId: UUID, ports: [Int]) -> Bool {
        guard let workspace = portPublicationWorkspace(workspaceId: workspaceId) else { return false }
        if workspace.agentListeningPorts != ports {
            workspace.agentListeningPorts = ports
            workspace.recomputeListeningPorts()
        }
        return true
    }

    private func portPublicationWorkspace(workspaceId: UUID) -> Workspace? {
        AppDelegate.shared?.tabManagerFor(tabId: workspaceId)?.tabs.first { $0.id == workspaceId }
    }

    func restartSocketListenerIfPathMissing(path: String, generation: UInt64) {
        let restartMode = socketServer.accessMode
        guard socketServer.shouldRestartForMissingPath(path: path, generation: generation) else { return }

        if let appDelegate = AppDelegate.shared {
            appDelegate.reconcileSocketListenerConfiguration(source: "path_monitor")
            return
        }

        stop(cleanupDiscoveryState: false)
        startSocketTransport(
            SocketControlServerConfiguration(accessMode: restartMode, preferredSocketPath: path),
            socketPath: path
        )
    }

    private nonisolated func writeSocketResponse(_ response: String, to socket: Int32) -> Bool {
        let payload = response + "\n"
        return transport.writeAll(Data(payload.utf8), to: socket)
    }

    nonisolated static func codeRouterHandoffSessionBindingIsCurrent(
        expectedGeneration: UInt64?,
        expectedTeamID: String?,
        currentGeneration: UInt64,
        currentTeamID: String?,
        isAuthenticated: Bool
    ) -> Bool {
        guard isAuthenticated,
              let expectedGeneration else {
            return false
        }
        return expectedGeneration == currentGeneration
            && expectedTeamID == currentTeamID
    }

    /// Interim bridged view of a decoded `ControlRequest` with Foundation
    /// (`Any`) field shapes, so the existing command bodies keep their
    /// `[String: Any]` params until they migrate onto the typed DTOs in the
    /// ControlCommandCoordinator stage.
    struct V2SocketRequest {
        let id: Any?
        let method: String
        let params: [String: Any]

        init(bridging request: ControlRequest) {
            id = request.id.map(\.foundationObject)
            method = request.method
            params = request.params.mapValues { $0.foundationObject }
        }
    }

    /// Wire-protocol helpers (parse/encode) shared with the package;
    /// stateless, so single instances serve every thread.
    nonisolated static let v2Parser = ControlRequestParser()
    nonisolated static let v2Encoder = ControlResponseEncoder()

    nonisolated static func executionPolicy(forV2Method method: String) -> ControlCommandExecutionPolicy {
        ControlCommandExecutionPolicy(forMethod: method)
    }

    /// Runs one worker-lane v2 request on the calling socket-worker thread and
    /// returns its encoded response, or `nil` when the command sends no reply
    /// (`feed.push` without an id). The caller (the socket execution-policy
    /// dispatcher) has already parsed the line and checked the policy.
    /// Worker-lane v2 methods whose body IS the shared main-actor dispatch
    /// (`v2MainActorResponse`, i.e. known-ref refresh + coordinator + legacy
    /// switch) behind a single `v2MainSync` hop, with response encoding on the
    /// worker. Byte-identical to the main lane by construction; being on the
    /// worker lane moves the policy wrapper, JSON bridging, and encode off the
    /// main thread and keeps the connection thread (not the main queue) as
    /// the place the command waits. The hop keeps each reply synchronous with
    /// its effect — the deliberately-synchronous first relay
    /// `surface.report_tty` (cmux-zsh-integration.zsh `_cmux_report_tty_once`)
    /// must see the TTY registration applied before its reply so subsequent
    /// `surface.ports_kick` scans resolve the surface.
    nonisolated static let socketWorkerCoordinatorHopMethods: Set<String> = [
        "surface.report_pwd",
        "surface.report_git_branch",
        "surface.clear_git_branch",
        "surface.report_shell_state",
        "surface.report_tty",
        "surface.ports_kick",
        // The notification-create family (coordinator domain, plus the
        // app-side create_for_caller resolver in the legacy switch) and
        // workspace.set_auto_title. The synchronous hop keeps each reply
        // ordered after its hop body, matching the legacy main-lane ordering
        // exactly, and keeps set_auto_title's apply-then-reply semantics for
        // naming engines. NOTE: for the create verbs that is NOT an
        // unconditional read-your-write guarantee — with notification policy
        // hooks configured, TerminalNotificationStore.addNotification defers
        // the store apply into a Task past its return, so the create reply
        // can precede store visibility (identical to baseline); do not build
        // on create-then-list ordering.
        "notification.create",
        "notification.create_for_surface",
        "notification.create_for_target",
        "notification.create_for_caller",
        "workspace.set_auto_title",
    ]

    nonisolated func socketWorkerV2Response(
        handling parsedRequest: ControlRequest,
        codeRouterTeamID: String? = nil
    ) -> String? {
        let request = V2SocketRequest(bridging: parsedRequest)
        return withSocketCommandPolicy(commandKey: request.method, isV2: true, params: request.params) {
            if let workspaceParamError = v2UnsupportedWorkspaceAliasError(method: request.method, params: request.params) {
                return v2Result(id: request.id, workspaceParamError)
            }
            if request.method == "surface.sync_codex_native_title" {
                return v2Error(
                    id: request.id,
                    code: "invalid_dispatch",
                    message: String(
                        localized: "socket.surfaceSyncCodexNativeTitle.asyncDispatchRequired",
                        defaultValue: "surface.sync_codex_native_title requires asynchronous socket dispatch"
                    )
                )
            }
            if Self.socketWorkerCoordinatorHopMethods.contains(request.method) {
                // Mirror processParsedV2Command's tail: one main hop for the
                // command body, encode after the hop on this worker thread.
                let outcome = v2MainSync {
                    self.v2MainActorResponse(
                        request: parsedRequest,
                        id: request.id,
                        method: request.method,
                        params: request.params
                    )
                }
                switch outcome {
                case .callResult(let result):
                    return Self.v2Encoder.response(id: parsedRequest.id, result)
                case .encoded(let response):
                    return response
                }
            }
            if request.method == "surface.read_selection" {
                return v2AsyncResultCall(
                    id: request.id,
                    timeoutSeconds: 5
                ) {
                    await self.v2SurfaceReadSelection(params: parsedRequest.params)
                }
            }
            if ["mobile.task.models.list", "mobile.chat.send", "mobile.chat.interrupt", "mobile.terminal.paste", "terminal.paste"].contains(request.method) {
                return v2AsyncResultCall(
                    id: request.id,
                    timeoutSeconds: 7
                ) {
                    guard let result = await self.controlCommandCoordinator
                        .handleMobileHostAsync(
                            parsedRequest,
                            context: self
                        ) else {
                        return .err(
                            code: "method_not_found",
                            message: String(
                                localized: "socket.error.unknownMethod",
                                defaultValue: "Unknown method"
                            ),
                            data: nil
                        )
                    }
                    switch result {
                    case .ok(let payload):
                        return .ok(payload.foundationObject)
                    case let .err(code, message, data):
                        return .err(
                            code: code,
                            message: message,
                            data: data?.foundationObject
                        )
                    }
                }
            }
            if let feedResult = controlCommandCoordinator.handleSocketWorkerFeed(
                parsedRequest,
                context: self
            ) {
                return Self.v2Encoder.response(id: parsedRequest.id, feedResult)
            }
            // Coordinator-owned worker-lane bodies (the tranche-D resolution
            // reads): nonisolated coordinator code runs on this worker thread
            // — pure parse plus JSON payload build — with ONE
            // controlResolveOnMain hop (known-ref refresh + witness + ref
            // minting) inside; the encode runs here, on this thread, through
            // the same encoder as the main lane. `self` is the coordinator's
            // wired ControlCommandContext, passed explicitly because the
            // coordinator's `context` property is main-actor-isolated.
            if let coordinatorResult = controlCommandCoordinator.handleSocketWorkerV2(
                parsedRequest,
                context: self
            ) {
                return Self.v2Encoder.response(id: parsedRequest.id, coordinatorResult)
            }
            if request.method == "feed.push", request.id == nil {
                guard let waitTimeout = Self.feedPushWaitTimeoutSeconds(params: request.params) else {
                    return v2Error(
                        id: request.id,
                        code: "invalid_params",
                        message: "feed.push wait_timeout_seconds must be numeric and between 0 and 120"
                    )
                }
                guard waitTimeout == 0 else {
                    return v2Error(
                        id: request.id,
                        code: "invalid_params",
                        message: "feed.push without an id requires wait_timeout_seconds 0"
                    )
                }
                _ = socketWorkerV2Response(
                    request,
                    codeRouterTeamID: codeRouterTeamID
                )
                return nil
            }
            return socketWorkerV2Response(
                request,
                codeRouterTeamID: codeRouterTeamID
            )
        }
    }

    /// Runs a worker-lane v1 command on the calling socket-worker thread,
    /// mirroring `socketWorkerV2Response(handling:)` for the space-delimited
    /// protocol. Returns `handled: false` when the command is not on the v1
    /// worker lane (the dispatcher falls through to the main hop). `response`
    /// stays optional so future fire-and-forget v1 telemetry can reply with
    /// nothing, matching the v2 lane's contract.
    nonisolated func socketWorkerV1ResponseIfHandled(cmd: String, args: String) -> (handled: Bool, response: String?) {
        guard ControlCommandExecutionPolicy(forV1Command: cmd).runsOnSocketWorker else {
            return (false, nil)
        }
        return withSocketCommandPolicy(commandKey: cmd, isV2: false) {
            switch cmd {
            case "ping":
                return (true, "PONG")
            // The v1 notification family: nonisolated bodies on this
            // controller (parse on this worker thread; notify_target_async and
            // clear_notifications are pure bus enqueues, the others carry one
            // v2MainSync hop).
            case "notify":
                return (true, notifyCurrent(args))
            case "notify_surface":
                return (true, notifySurface(args))
            case "notify_target":
                return (true, notifyTarget(args))
            case "notify_target_async":
                return (true, notifyTargetQueued(args))
            case "list_notifications":
                return (true, listNotifications())
            case "clear_notifications":
                return (true, clearNotifications(args))
            // The v1 agent-journal family: the append commits durably on this
            // worker thread (the reply is the emitting hook's durable
            // acknowledgement); reduction and sidebar application run on the
            // journal center's ordered consumer.
            case "agent_journal_append":
                return (true, agentJournalAppend(args))
            // The v1 terminal-read family (tranche C): the Ghostty capture
            // takes one v2MainSync hop, the (possibly multi-MB) formatting
            // runs here on this worker thread. NOT mainThreadCallable — the
            // invalid_dispatch guard rejects main-thread in-process callers so
            // the formatting can never run inline on the main thread.
            case "read_screen":
                return (true, readScreenText(args))
            // The v1 diagnostic-read family: the host's iroh DiagnosticLog is
            // actor-owned, so the snapshot await bridges to this worker via
            // the established semaphore pattern. NOT mainThreadCallable — the
            // wait must never block the main thread.
            case "list_windows":
                return (true, listWindows())
            case "current_window":
                return (true, currentWindow())
            case "list_workspaces":
                return (true, listWorkspaces())
            case "list_surfaces":
                return (true, listSurfaces(args))
            case "current_workspace":
                return (true, currentWorkspace())
            // The v1 send lane (tranche E): unescape/split/reply mapping run
            // here on this worker thread around one narrow v2MainSync hop
            // (resolve target + inject input + forceRefresh). All
            // mainThreadCallable; the bodies are shared with the legacy
            // processCommand dispatch.
            case "send":
                return (true, sendInput(args))
            case "send_key":
                return (true, sendKey(args))
            case "send_surface":
                return (true, sendInputToSurface(args))
            case "send_key_surface":
                return (true, sendKeyToSurface(args))
            case "send_workspace":
#if DEBUG
                return (true, sendInputToWorkspace(args))
#else
                // send_workspace is DEBUG-only app-side (its processCommand
                // case is compiled out); the policy lists it unconditionally,
                // so mirror the Release main lane's legacy unknown-command
                // reply instead of the internal-error backstop below (the
                // debug.sidebar.simulate_drag precedent).
                return (true, "ERROR: Unknown command 'send_workspace'. Use 'help' for available commands.")
#endif
            case "screenshot":
#if DEBUG
                return (true, captureScreenshot(args))
#else
                return (true, "ERROR: Unknown command 'screenshot'. Use 'help' for available commands.")
#endif
            case "reload_config":
                return (true, reloadConfigurationAndWait(args))
            default:
                // The sidebar telemetry family: nonisolated coordinator bodies
                // (parse/format on this worker thread, deferred mutations on
                // the ordered TerminalMutationBus, at most one v2MainSync hop
                // per command via controlSidebarOnMain). `self` is the
                // coordinator's wired ControlCommandContext; it is passed
                // explicitly because the coordinator's `context` property is
                // main-actor-isolated.
                if let response = controlCommandCoordinator.handleSidebarTelemetryV1(
                    command: cmd,
                    args: args,
                    context: self
                ) {
                    return (true, response)
                }
                // A policy-listed v1 worker command MUST have a body here.
                // Falling back to the main lane would silently diverge from
                // the invalid_dispatch guard (which already rejected
                // main-thread callers on the promise that this command runs on
                // the worker), so mirror the v2 lane's always-handled
                // invariant with a loud internal error instead.
                return (true, "ERROR: internal: v1 worker command '\(cmd)' has no worker handler")
            }
        }
    }

    private nonisolated func reloadConfigurationAndWait(
        _ args: String
    ) -> String {
        guard args.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return "ERROR: Usage: reload_config"
        }
        guard let waiterLease =
                reloadConfigurationWaiterAdmission.claim() else {
            return "ERROR: reload_config busy"
        }
        let reloadResult: ReloadConfigurationWaitResult? = socketAwaitCallback(
            timeout: 30
        ) { completion in
            Task { @MainActor in
                let completionWasAdmitted =
                    self.controlSidebarReloadConfigWithAdmission(
                        commitCompletion: { committed in
                            completion(
                                committed ? .committed : .failed
                            )
                            waiterLease.retire()
                        }
                    )
                if !completionWasAdmitted {
                    // The reload request is still queued even when this
                    // caller's optional commit callback could not be retained.
                    // Report backpressure, not a false configuration failure.
                    completion(.busy)
                    waiterLease.retire()
                }
            }
        }
        guard let reloadResult else {
            return "ERROR: reload_config timed out"
        }
        switch reloadResult {
        case .committed:
            return "OK Reloaded config"
        case .failed:
            return "ERROR: reload_config failed"
        case .busy:
            return "ERROR: reload_config busy"
        }
    }
    nonisolated static func feedPushWaitTimeoutSeconds(params: [String: Any]) -> TimeInterval? {
        guard let rawTimeout = params["wait_timeout_seconds"] else {
            return 0
        }
        let seconds: Double?
        if let number = rawTimeout as? NSNumber {
            seconds = number.doubleValue
        } else if let value = rawTimeout as? Double {
            seconds = value
        } else if let value = rawTimeout as? Int {
            seconds = Double(value)
        } else {
            seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds >= 0, seconds <= 120 else {
            return nil
        }
        return seconds
    }

    private nonisolated func socketWorkerV2Response(
        _ request: V2SocketRequest,
        codeRouterTeamID: String? = nil
    ) -> String {
        switch request.method {
        case "session.agent_recovery.list":
            return v2Result(id: request.id, v2AgentRecoveryList(params: request.params))
        case "session.agent_recovery.restore":
            return v2Result(id: request.id, v2AgentRecoveryRestore(params: request.params))
        case "feedback.submit":
            return v2Result(id: request.id, v2FeedbackSubmit(params: request.params))
        case "feed.push":
            return v2Result(
                id: request.id,
                v2FeedPush(
                    params: request.params,
                    requiresIngestionAcknowledgment: request.id != nil,
                    automationOrigin: CmuxAutomationInvocationContext.eventOrigin
                )
            )
        case "feed.permission.reply":
            return v2Result(id: request.id, v2FeedPermissionReply(params: request.params))
        case "feed.question.reply":
            return v2Result(id: request.id, v2FeedQuestionReply(params: request.params))
        case "feed.exit_plan.reply":
            return v2Result(id: request.id, v2FeedExitPlanReply(params: request.params))
        case "agent.hook.enqueue":
            // Relay provenance survives only after the ingress gate authorized
            // the owner workspace and surface selectors.
            let enqueueParams: [String: Any]? = request.params
            let hookParams: [String: Any]
            if let enqueueParams,
               enqueueParams["relay_backed"] as? Bool == true,
               enqueueParams["caller_tty"] != nil {
                hookParams = v2MainSync {
                    self.agentHookParametersResolvingRelayTTY(enqueueParams)
                }
            } else {
                hookParams = enqueueParams ?? [:]
            }
            guard let localSocketPath = currentSocketPathForRemoteRestore(),
                  let event = AgentHookDeliveryEvent(
                      params: hookParams,
                      deliverySocketPath: localSocketPath
                  ) else {
                return v2Error(
                    id: request.id,
                    code: "invalid_params",
                    message: String(
                        localized: "socket.agentHook.error.invalidEvent",
                        defaultValue: "Invalid agent hook event"
                    )
                )
            }
            guard agentHookDeliveryQueue.enqueue(event) else {
                return v2Error(
                    id: request.id,
                    code: "queue_full",
                    message: String(
                        localized: "socket.agentHook.error.queueFull",
                        defaultValue: "Agent hook delivery queue is full"
                    )
                )
            }
            return v2Ok(id: request.id, result: ["queued": true])
        case "agent.hook.barrier":
            let hookParams: [String: Any]
            if request.params["relay_backed"] as? Bool == true,
               request.params["caller_tty"] != nil {
                hookParams = v2MainSync {
                    self.agentHookParametersResolvingRelayTTY(request.params)
                }
            } else {
                hookParams = request.params
            }
            guard let localSocketPath = currentSocketPathForRemoteRestore(),
                  let orderingKey = AgentHookDeliveryEvent.orderingKey(
                      params: hookParams,
                      deliverySocketPath: localSocketPath
                  ) else {
                return v2Error(
                    id: request.id,
                    code: "invalid_params",
                    message: String(
                        localized: "socket.agentHook.error.invalidBarrier",
                        defaultValue: "Invalid agent hook barrier"
                    )
                )
            }
            guard agentHookDeliveryQueue.waitForPriorDeliveries(
                orderingKey: orderingKey,
                timeout: 18
            ) else {
                return v2Error(
                    id: request.id,
                    code: "barrier_timeout",
                    message: String(
                        localized: "socket.agentHook.error.barrierTimeout",
                        defaultValue: "Agent hook barrier timed out"
                    )
                )
            }
            return v2Ok(id: request.id, result: ["completed": true])
        case "window.record.start", "window.record.stop", "window.record.status",
             "window.record.note", "window.record.list":
            return v2Result(
                id: request.id,
                v2WindowRecordingCommandOnSocketWorker(
                    method: request.method,
                    params: request.params
                )
            )
        case "window.screenshot":
            return v2Result(
                id: request.id,
                v2WindowScreenshotOnSocketWorker(params: request.params)
            )
        case "system.ping":
            return v2Ok(id: request.id, result: ["pong": true])
        case "system.top":
            return v2AsyncResultCall(id: request.id, timeoutSeconds: 30) {
                await self.socketLegacyMainHopBridge {
                    let response = try await self.v2SystemTopAsync(ControlRequest(
                        id: nil, method: "system.top", params: request.params.compactMapValues { JSONValue(foundationObject: $0) }
                    ))
                    guard let typed = Self.controlCallResult(fromEncodedResponse: response) else {
                        return .err(code: "internal_error", message: "Invalid system.top payload", data: nil)
                    }
                    switch typed {
                    case .ok(let value): return .ok(value.foundationObject)
                    case .err(let code, let message, let data): return .err(code: code, message: message, data: data?.foundationObject)
                    }
                }
            }
        case "system.memory":
            return v2AsyncResultCall(id: request.id, timeoutSeconds: 30) {
                await self.socketLegacyMainHopBridge {
                    try await self.v2SystemMemory(params: request.params)
                }
            }
        case "vault.sessions":
            return v2AsyncResultCall(id: request.id, timeoutSeconds: 30) {
                await self.v2VaultSessions(params: request.params)
            }
        case "vault.search":
            return v2AsyncResultCall(id: request.id, timeoutSeconds: 60) {
                await self.v2VaultSearch(params: request.params)
            }
        case "vault.checkpoints":
            return v2AsyncResultCall(id: request.id, timeoutSeconds: 30) {
                await self.v2VaultCheckpoints(params: request.params)
            }
        case "vault.checkpoint":
            return v2AsyncResultCall(id: request.id, timeoutSeconds: 30) {
                await self.v2VaultCheckpointCreate(params: request.params)
            }
        case "vault.fork":
            return v2AsyncResultCall(id: request.id, timeoutSeconds: 60) {
                await self.v2VaultFork(params: request.params)
            }
        case "surface.read_text":
            return v2Result(id: request.id, v2SurfaceReadText(params: request.params))
        case "surface.input_state":
            return v2Result(id: request.id, v2SurfaceInputState(params: request.params))
        case "workspace.env":
            return v2Result(id: request.id, v2WorkspaceEnv(params: request.params))
        case "sidebar.custom.validate":
            return v2Result(id: request.id, v2CustomSidebarValidate(params: request.params))
        case "sidebar.custom.reload":
            return v2Result(id: request.id, v2CustomSidebarReload(params: request.params))
        case "sidebar.custom.select":
            return v2Result(id: request.id, v2CustomSidebarSelect(params: request.params))
        case "sidebar.custom.open":
            return v2Result(id: request.id, v2CustomSidebarOpen(params: request.params))
#if DEBUG
        case "debug.sidebar.simulate_drag":
            return v2Result(id: request.id, v2DebugSidebarSimulateDrag(params: request.params))
        case "debug.window_hints":
            // Hint mode's labels while they show (`active`, what is typed, each label's target).
            let payload: [String: Any] = v2MainSync {
                guard let shown = WindowHintController.shared.shown else {
                    // Why nothing shows: the flag, or no controls in the key window.
                    let candidates = (NSApp.keyWindow?.contentView).map { WindowHintTargets.collect(in: $0).count }
                    return [
                        "active": false,
                        "enabled": CmuxFeatureFlags.shared.isWindowHintsEnabled,
                        "candidates": candidates ?? -1,
                    ]
                }
                return [
                    "active": true,
                    "typed": shown.typed,
                    "hints": shown.hints.map { ["label": $0.label, "role": $0.target.role, "title": $0.target.title] },
                ]
            }
            return v2Ok(id: request.id, result: payload)
        case "debug.window.screenshot":
            let label = (request.params["label"] as? String) ?? ""
            let response = captureScreenshot(label)
            guard response.hasPrefix("OK ") else {
                return v2Error(
                    id: request.id,
                    code: "internal_error",
                    message: response
                )
            }
            let payload = String(response.dropFirst(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = payload.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                return v2Error(
                    id: request.id,
                    code: "internal_error",
                    message: "screenshot parse failed",
                    data: ["payload": payload]
                )
            }
            return v2Ok(id: request.id, result: [
                "screenshot_id": parts[0],
                "path": parts[1],
            ])
        case "debug.global_search.query":
            // The socket connection's async dispatcher owns this command so a
            // long transcript refresh never parks a worker thread behind a
            // semaphore. Keep the synchronous compatibility lane explicit.
            return v2Error(
                id: request.id,
                code: "invalid_dispatch",
                message: "debug.global_search.query requires asynchronous socket dispatch"
            )
#endif
        case "current.list":
            return socketWorkerCurrentWorkResponse(id: request.id, params: request.params)
        case "surface.catalog", "surface.project", "surface.new_terminal", "surface.new_display":
            return socketWorkerSurfaceResponse(method: request.method, id: request.id, params: request.params)
        default:
#if !DEBUG
            // debug.sidebar.simulate_drag stays policy-listed in Release but
            // its worker case above is compiled out; the Release main lane
            // answers method_not_found for debug verbs, so mirror that reply
            // instead of the internal-error backstop below.
            if request.method == "debug.sidebar.simulate_drag"
                || request.method == "debug.global_search.query"
                || request.method == "debug.window.screenshot"
                || request.method == "debug.mobile.transport.disconnect"
                || request.method == "debug.cloudtree.gallery"
                || request.method == "debug.window_hints" {
                return v2Error(id: request.id, code: "method_not_found", message: "Unknown method")
            }
#endif
            // Only reachable when a method is added to the policy's
            // socketWorkerMethods but omitted from both
            // socketWorkerCoordinatorHopMethods and the explicit cases above
            // (unknown methods classify .mainActor and never enter this
            // lane). Mirror the v1 lane's loud always-handled invariant
            // instead of handing clients a plausible-looking method_not_found
            // on a silent policy/handler drift.
            return v2Error(
                id: request.id,
                code: "internal_error",
                message: "v2 worker method '\(request.method)' has no worker handler"
            )
        }
    }

    private nonisolated func spawnClientHandler(
        socket clientSocket: Int32,
        peerPid: pid_t?,
        peerAuditToken: SocketPeerAuditToken?,
        peerProcessStartTime: SocketPeerProcessStartTime?,
        authorizationGeneration: UInt64,
        authorizationRevocationSignal: SocketAuthorizationRevocationSignal
    ) async {
        let initialReadLimits = socketClientInitialReadLimits(peerProcessID: peerPid)
        let preauthorizationLimiter = socketClientPreauthorizationLimiter
        let claimedPreauthorizationSlot = if initialReadLimits != nil {
            await preauthorizationLimiter.claim()
        } else {
            false
        }
        guard initialReadLimits == nil || claimedPreauthorizationSlot else {
            rejectSocketClient(clientSocket, reason: .preauthorizationSaturated)
            return
        }
        let overloadResponder = socketOverloadResponder
        let submission = await socketClientWorkerPool.submit { [weak self] in
            guard let self else {
                close(clientSocket)
                if claimedPreauthorizationSlot {
                    Task { await preauthorizationLimiter.release() }
                }
                return
            }
            await self.handleClientAsync(
                clientSocket,
                peerPid: peerPid,
                peerAuditToken: peerAuditToken,
                peerProcessStartTime: peerProcessStartTime,
                authorizationGeneration: authorizationGeneration,
                authorizationRevocationSignal: authorizationRevocationSignal,
                initialReadLimits: initialReadLimits,
                holdsPreauthorizationSlot: claimedPreauthorizationSlot
            )
        } onDrop: { dropReason in
            if claimedPreauthorizationSlot {
                Task { await preauthorizationLimiter.release() }
            }
            overloadResponder.reject(socket: clientSocket, reason: Self.socketOverloadReason(for: dropReason))
        }
        guard submission == .rejected else { return socketLaneHealth.recordPoolAdmission() }
        await reportSocketPoolSaturation()
    }

    /// Owns the accepted socket until the command loop and source teardown finish.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    private nonisolated func handleClientAsync(
        _ socket: Int32,
        peerPid: pid_t? = nil,
        peerAuditToken: SocketPeerAuditToken? = nil,
        peerProcessStartTime: SocketPeerProcessStartTime? = nil,
        authorizationGeneration: UInt64,
        authorizationRevocationSignal: SocketAuthorizationRevocationSignal,
        initialReadLimits: ControlClientLineReadLimits? = nil,
        holdsPreauthorizationSlot initialSlotHeld: Bool = false
    ) async {
        let pid = peerPid ?? transport.peerProcessID(of: socket)
        let peerHasSameUID = transport.peerHasSameUID(socket)
        let lineReader = ControlClientAsyncLineReader(
            socket: socket,
            initialLimits: initialReadLimits,
            authorizationRevocationSignal: authorizationRevocationSignal,
            codeRouterHandshakeMaximumBytes: 4_096
        )
        let writer = ControlClientAsyncWriter(socket: socket)

        await handleClientLoop(
            socket: socket,
            pid: pid,
            peerHasSameUID: peerHasSameUID,
            peerAuditToken: peerAuditToken,
            peerProcessStartTime: peerProcessStartTime,
            authorizationGeneration: authorizationGeneration,
            authorizationRevocationSignal: authorizationRevocationSignal,
            initialSlotHeld: initialSlotHeld,
            lineReader: lineReader,
            writer: writer
        )

        // Dispatch source cancellation is asynchronous. Await every borrowed
        // socket source before shutting down and closing the descriptor.
        await lineReader.cancelAndWait()
        await writer.cancelAndWait()
        shutdown(socket, SHUT_RDWR)
        close(socket)
    }

    /// Runs the admitted command loop while retaining ownership of its async
    /// socket readers and writer until the caller joins source cancellation.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    private nonisolated func handleClientLoop(
        socket: Int32,
        pid: pid_t?,
        peerHasSameUID: Bool,
        peerAuditToken: SocketPeerAuditToken?,
        peerProcessStartTime: SocketPeerProcessStartTime?,
        authorizationGeneration: UInt64,
        authorizationRevocationSignal: SocketAuthorizationRevocationSignal,
        initialSlotHeld: Bool,
        lineReader: ControlClientAsyncLineReader,
        writer: ControlClientAsyncWriter
    ) async {
        let preauthorizationLimiter = socketClientPreauthorizationLimiter
        var holdsPreauthorizationSlot = initialSlotHeld
        defer {
            if holdsPreauthorizationSlot {
                Task { await preauthorizationLimiter.release() }
            }
        }
        var passwordAuthorization = SocketPasswordAuthorization()
        var pendingCodeRouterHandoffChallenge:
            PendingCodeRouterHandoffChallenge?
        let rateLimiter = ControlClientRateLimiter()
        while let line = await lineReader.nextLine(shouldContinueReading: {
            self.socketServer.isConnectionAuthorizationCurrent(authorizationGeneration)
        }) {
            let receivedCommand = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !receivedCommand.isEmpty else { continue }
            // Arm, begin, and complete use an exact JSON frame. Do not let
            // Foundation trimming turn a surrounding-whitespace frame into a
            // valid proof-bearing request.
            let isCodeRouterHandshakeRoute =
                Self.isCodeRouterHandoffCommand(receivedCommand)
                    || Self.isCodeRouterHandoffBeginCommand(receivedCommand)
                    || Self.isCodeRouterHandoffArmCommand(receivedCommand)
            guard !isCodeRouterHandshakeRoute || line == receivedCommand else {
                _ = await writer.writeAll(Data((Self.socketClientAccessDeniedResponse + "\n").utf8))
                return
            }
            guard socketAuthorizationIsCurrent(
                authorizationGeneration,
                passwordAuthorization: &passwordAuthorization
            ) else {
                _ = await writer.writeAll(Data((Self.socketClientAccessDeniedResponse + "\n").utf8))
                return
            }
            let isCodeRouterPeerCommand =
                Self.isCodeRouterHandoffCommand(receivedCommand)
                    || Self.isCodeRouterHandoffBeginCommand(receivedCommand)
                    || Self.isCodeRouterHandoffArmCommand(receivedCommand)
            let currentPeerAuditToken = isCodeRouterPeerCommand
                ? transport.peerAuditToken(of: socket)
                : peerAuditToken
            let currentPeerStartTime = if isCodeRouterPeerCommand,
                                          let pid {
                transport.processStartTime(of: pid)
            } else {
                peerProcessStartTime
            }
            guard !isCodeRouterPeerCommand
                    || (peerAuditToken?.processID == pid
                        && peerAuditToken != nil
                        && currentPeerAuditToken == peerAuditToken
                        && peerProcessStartTime != nil
                        && currentPeerStartTime == peerProcessStartTime),
                  pendingCodeRouterHandoffChallenge == nil
                    || Self.isCodeRouterHandoffCommand(receivedCommand),
                  let commandAuthorization = authorizedSocketCommand(
                receivedCommand,
                peerProcessID: pid,
                peerHasSameUID: peerHasSameUID,
                peerAuditToken: peerAuditToken,
                peerProcessStartTime: peerProcessStartTime,
                authorizationGeneration: authorizationGeneration,
                pendingCodeRouterHandoffChallenge:
                    pendingCodeRouterHandoffChallenge
            ) else {
                let response = pid == nil
                    ? Self.socketClientVerificationFailedResponse
                    : Self.socketClientAccessDeniedResponse
                _ = await writer.writeAll(
                    Data((response + "\n").utf8)
                )
                return
            }
            // Recheck after admission so a policy refresh cannot cross into execution.
            guard socketAuthorizationIsCurrent(authorizationGeneration, passwordAuthorization: &passwordAuthorization) else { _ = await writer.writeAll(Data((Self.socketClientAccessDeniedResponse + "\n").utf8)); return }
            // Only a process in cmux's own descendant tree may attach the
            // internal automation envelope. Same-UID clients are authorized
            // for ordinary automation RPCs, but cannot forge a rule chain.
            let parsedCommandEnvelope = Self.automationCommandEnvelope(from: commandAuthorization.command)
            let commandEnvelope = (pid.map(isDescendant) == true)
                ? parsedCommandEnvelope
                : nil
            let trimmed = (parsedCommandEnvelope?.command ?? commandAuthorization.command)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let commandOrigin = commandEnvelope?.origin
            lineReader.clearLimits()
            if holdsPreauthorizationSlot {
                holdsPreauthorizationSlot = false
                await preauthorizationLimiter.release()
            }

            if Self.isCodeRouterHandoffBeginCommand(trimmed) {
                guard let authorization = commandAuthorization.codeRouterHandoffBeginAuthorization,
                      let challenge = Self.makeCodeRouterHandoffChallenge() else {
                    _ = await writer.writeAll(Data((Self.socketClientAccessDeniedResponse + "\n").utf8))
                    return
                }
                let response = v2Ok(
                    id: "coderouter-handoff-begin",
                    result: ["protocolVersion": 2, "challenge": challenge]
                )
                guard await writer.writeAll(Data((response + "\n").utf8)) else { return }
                pendingCodeRouterHandoffChallenge = PendingCodeRouterHandoffChallenge(
                    authorization: authorization,
                    challenge: challenge
                )
                lineReader.allowCodeRouterHandoffCompletion(timeoutMilliseconds: 2_000)
                continue
            }
            if Self.isCodeRouterHandoffArmCommand(trimmed) {
                let response = processCodeRouterHandoffArmCommand(
                    trimmed,
                    socket: socket,
                    peerAuditToken: peerAuditToken,
                    authorizationGeneration: authorizationGeneration,
                    verifiedProof: commandAuthorization.codeRouterHandoffArmProof
                )
                _ = await writer.writeAll(Data((response + "\n").utf8))
                return
            }
            if isEventsStreamRequest(trimmed) {
                if let response = authResponseIfNeeded(
                    for: trimmed,
                    passwordAuthorization: &passwordAuthorization
                ) {
                    guard await writer.writeAll(Data((response + "\n").utf8)) else { return }
                    continue
                }
                await handleEventsStreamRequest(
                    trimmed,
                    socket: socket,
                    authorizationGeneration: authorizationGeneration,
                    authorizationRevocationSignal: authorizationRevocationSignal,
                    passwordAuthorization: passwordAuthorization
                )
                return
            }
            let result = await CmuxAutomationInvocationContext.$eventOrigin.withValue(commandOrigin) {
                await SocketCommandTaskPolicy.$peerProcessID.withValue(pid) {
                    await SocketCommandTaskPolicy.$peerHasSameUID.withValue(peerHasSameUID) {
                        await processSocketLineAsync(
                            trimmed,
                            passwordAuthorization: passwordAuthorization,
                            rateLimiter: rateLimiter
                        )
                    }
                }
            }
            passwordAuthorization = result.passwordAuthorization
            if let response = result.response {
                guard await writer.writeAll(Data((response + "\n").utf8)) else { return }
                CmuxAutomationInvocationContext.$eventOrigin.withValue(commandOrigin) {
                    publishSocketEvents(command: trimmed, response: response)
                }
            }
        }

        if !socketServer.isConnectionAuthorizationCurrent(authorizationGeneration) {
            _ = await writer.writeAll(Data((Self.socketClientAccessDeniedResponse + "\n").utf8))
        }
    }

    private nonisolated func processSocketLine(
        _ command: String,
        passwordAuthorization: SocketPasswordAuthorization,
        trustedCodeRouterPeerAuditToken: SocketPeerAuditToken? = nil,
        expectedCodeRouterHandoffSessionBinding:
            CodeRouterHandoffSessionBinding? = nil
    ) -> SocketLineProcessingResult {
        let codeRouterHandoffSessionBinding: CodeRouterHandoffSessionBinding?
        if Self.isCodeRouterHandoffCommand(command) {
            // Capture the auth generation and selected team before the
            // asynchronous mint begins. The final writer rechecks both on the
            // main actor, so sign-out or a team switch cannot race a lease into
            // an already-revoked socket response.
            codeRouterHandoffSessionBinding =
                expectedCodeRouterHandoffSessionBinding
        } else {
            codeRouterHandoffSessionBinding = nil
        }
#if DEBUG
        let debugInfo = Self.socketCommandDebugInfo(command)
        let debugStart = DispatchTime.now().uptimeNanoseconds
        let debugLoggingEnabled = Self.socketCommandDebugLoggingEnabled()
        Self.installSocketCommandMainHopAccumulator()
        if debugLoggingEnabled {
            Self.debugLogSocketCommand(
                "socket.command.begin proto=\(debugInfo.protocolName) method=\(debugInfo.commandKey)"
            )
        }
#endif
        var nextPasswordAuthorization = passwordAuthorization
        if trustedCodeRouterPeerAuditToken == nil,
           let response = authResponseIfNeeded(
            for: command,
            passwordAuthorization: &nextPasswordAuthorization
        ) {
#if DEBUG
            Self.debugLogSocketCommandEndIfNeeded(
                debugInfo: debugInfo,
                startedAt: debugStart,
                response: response,
                loggingEnabled: debugLoggingEnabled
            )
#endif
            return SocketLineProcessingResult(
                response: response,
                passwordAuthorization: nextPasswordAuthorization,
                codeRouterHandoffSessionBinding:
                    codeRouterHandoffSessionBinding
            )
        }

        let response = processCommandUsingSocketExecutionPolicy(
            command,
            codeRouterTeamID: codeRouterHandoffSessionBinding?.resolvedTeamID
        )
#if DEBUG
        if let response {
            Self.debugLogSocketCommandEndIfNeeded(
                debugInfo: debugInfo,
                startedAt: debugStart,
                response: response,
                loggingEnabled: debugLoggingEnabled
            )
        }
#endif
        return SocketLineProcessingResult(
            response: response,
            passwordAuthorization: nextPasswordAuthorization,
            codeRouterHandoffSessionBinding:
                codeRouterHandoffSessionBinding
        )
    }

#if DEBUG
    private struct SocketCommandDebugInfo {
        let protocolName: String
        let commandKey: String
    }

    private nonisolated static func socketCommandDebugLoggingEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let rawValue = environment[socketCommandDebugLogEnvironmentKey] else {
            return false
        }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private nonisolated static func socketCommandDebugInfo(_ command: String) -> SocketCommandDebugInfo {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              let method = dict["method"] as? String else {
            let commandKey = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "<empty>"
            return SocketCommandDebugInfo(protocolName: "v1", commandKey: sanitizedSocketDebugToken(commandKey))
        }
        return SocketCommandDebugInfo(protocolName: "v2", commandKey: sanitizedSocketDebugToken(method))
    }

    private nonisolated static func sanitizedSocketDebugToken(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:")
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(scalars).prefix(96)
        return sanitized.isEmpty ? "<empty>" : String(sanitized)
    }

    private nonisolated static func socketCommandDebugStatus(response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ERROR:") {
            return "error"
        }
        if trimmed.hasPrefix("{") {
            let prefix = trimmed.prefix(4096)
            if topLevelJSONResponseStatus(in: prefix) == "error" {
                return "error"
            }
        }
        return "ok"
    }

    private nonisolated static func topLevelJSONResponseStatus(in text: Substring) -> String? {
        var index = text.startIndex
        skipJSONWhitespace(in: text, index: &index)
        guard index < text.endIndex, text[index] == "{" else { return nil }
        index = text.index(after: index)

        while index < text.endIndex {
            skipJSONWhitespace(in: text, index: &index)
            if index >= text.endIndex { return nil }
            if text[index] == "}" { return nil }
            if text[index] == "," {
                index = text.index(after: index)
                continue
            }
            guard text[index] == "\"",
                  let key = scanJSONString(in: text, index: &index) else {
                return nil
            }
            skipJSONWhitespace(in: text, index: &index)
            guard index < text.endIndex, text[index] == ":" else { return nil }
            index = text.index(after: index)
            skipJSONWhitespace(in: text, index: &index)

            if key == "error" {
                return "error"
            }
            if key == "ok" {
                if text[index...].hasPrefix("false") {
                    return "error"
                }
                if text[index...].hasPrefix("true") {
                    return "ok"
                }
            }
            guard skipJSONValue(in: text, index: &index) else {
                return nil
            }
        }
        return nil
    }

    private nonisolated static func scanJSONString(in text: Substring, index: inout String.Index) -> String? {
        guard index < text.endIndex, text[index] == "\"" else { return nil }
        index = text.index(after: index)
        var result = ""
        var isEscaped = false
        while index < text.endIndex {
            let char = text[index]
            index = text.index(after: index)
            if isEscaped {
                result.append(char)
                isEscaped = false
                continue
            }
            if char == "\\" {
                isEscaped = true
                continue
            }
            if char == "\"" {
                return result
            }
            result.append(char)
        }
        return nil
    }

    private nonisolated static func skipJSONValue(in text: Substring, index: inout String.Index) -> Bool {
        guard index < text.endIndex else { return false }
        switch text[index] {
        case "\"":
            return scanJSONString(in: text, index: &index) != nil
        case "{", "[":
            return skipJSONContainer(in: text, index: &index)
        default:
            while index < text.endIndex {
                switch text[index] {
                case ",", "}":
                    return true
                default:
                    index = text.index(after: index)
                }
            }
            return true
        }
    }

    private nonisolated static func skipJSONContainer(in text: Substring, index: inout String.Index) -> Bool {
        guard index < text.endIndex else { return false }
        let opener = text[index]
        let closer: Character = opener == "{" ? "}" : "]"
        var depth = 1
        index = text.index(after: index)
        var isInString = false
        var isEscaped = false
        while index < text.endIndex {
            let char = text[index]
            index = text.index(after: index)
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    isInString = false
                }
                continue
            }
            if char == "\"" {
                isInString = true
            } else if char == opener {
                depth += 1
            } else if char == closer {
                depth -= 1
                if depth == 0 {
                    return true
                }
            }
        }
        return false
    }

    private nonisolated static func skipJSONWhitespace(in text: Substring, index: inout String.Index) {
        while index < text.endIndex {
            switch text[index] {
            case " ", "\t", "\n", "\r":
                index = text.index(after: index)
            default:
                return
            }
        }
    }

    private nonisolated static func debugLogSocketCommandEndIfNeeded(
        debugInfo: SocketCommandDebugInfo,
        startedAt: UInt64,
        response: String,
        loggingEnabled: Bool
    ) {
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        let status = socketCommandDebugStatus(response: response)
        guard loggingEnabled || elapsedMs >= socketCommandSlowThresholdMs || status != "ok" else {
            return
        }
        let elapsedText = String(format: "%.2f", elapsedMs)
        // Total-vs-main-hop breakdown: how much of the command's wall time was
        // spent waiting for and occupying the main thread across its
        // `v2MainSync` hops. All formatting stays behind the guard above.
        var mainHopText = ""
        if let mainHops = currentSocketCommandMainHopAccumulator(), mainHops.hopCount > 0 {
            let waitText = String(format: "%.2f", Double(mainHops.queueWaitNanos) / 1_000_000)
            let bodyText = String(format: "%.2f", Double(mainHops.bodyNanos) / 1_000_000)
            mainHopText = " main_hops=\(mainHops.hopCount) main_wait_ms=\(waitText) main_body_ms=\(bodyText)"
        }
        debugLogSocketCommand(
            "socket.command.end proto=\(debugInfo.protocolName) method=\(debugInfo.commandKey) status=\(status) ms=\(elapsedText)\(mainHopText) bytes=\(response.utf8.count)"
        )
    }

    private nonisolated static func debugLogSocketCommand(_ message: @autoclosure () -> String) {
        cmuxDebugLog(message())
    }

    private nonisolated static let socketCommandMainHopAccumulatorKey = "cmux.socketCommandMainHopAccumulator"

    /// Installs a fresh per-command main-hop accumulator on the current
    /// (socket worker) thread. Called once per socket line so the totals in
    /// the end-of-command log cover exactly that command's hops.
    private nonisolated static func installSocketCommandMainHopAccumulator() {
        Thread.current.threadDictionary[socketCommandMainHopAccumulatorKey] = SocketCommandMainHopAccumulator()
    }

    /// Adds one `v2MainSync` hop to the current thread's accumulator, if a
    /// socket command installed one (in-process `handleSocketLine` callers
    /// have no accumulator and record nothing).
    private nonisolated static func recordSocketCommandMainHop(queueWaitNanos: UInt64, bodyNanos: UInt64) {
        guard let accumulator = Thread.current.threadDictionary[socketCommandMainHopAccumulatorKey]
                as? SocketCommandMainHopAccumulator else {
            return
        }
        accumulator.queueWaitNanos &+= queueWaitNanos
        accumulator.bodyNanos &+= bodyNanos
        accumulator.hopCount += 1
    }

    private nonisolated static func currentSocketCommandMainHopAccumulator() -> SocketCommandMainHopAccumulator? {
        Thread.current.threadDictionary[socketCommandMainHopAccumulatorKey] as? SocketCommandMainHopAccumulator
    }
#endif

    private nonisolated func processCommandUsingSocketExecutionPolicy(
        _ command: String,
        codeRouterTeamID: String? = nil
    ) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("{") {
            // v2: parse exactly once, on the calling thread (the socket-worker
            // connection thread for socket traffic). The parsed request is
            // handed to the worker lane or into the main hop; nothing
            // re-parses on the main thread.
            let parsedRequest: ControlRequest
            switch Self.v2Parser.request(fromLine: trimmed) {
            case .failure(let parseError):
                return Self.v2Encoder.response(for: parseError)
            case .success(let parsed):
                parsedRequest = parsed
            }

            let request = parsedRequest
            let automationOrigin = CmuxAutomationInvocationContext.eventOrigin
            if let focusError = Self.focusSuppressionResponse(
                method: request.method,
                id: request.id.map(\.foundationObject),
                params: request.params.mapValues(\.foundationObject)
            ) {
                return focusError
            }

            let policy = Self.executionPolicy(forV2Method: request.method)
            if Thread.isMainThread, policy == .socketWorker(mainThreadCallable: false) {
                return v2Error(
                    id: request.id.map(\.foundationObject),
                    code: "invalid_dispatch",
                    message: "\(request.method) must run off the main thread"
                )
            }
            if policy.runsOnSocketWorker {
                return CmuxAutomationInvocationContext.$eventOrigin.withValue(automationOrigin) {
                    socketWorkerV2Response(handling: request, codeRouterTeamID: codeRouterTeamID)
                }
            }
            return CmuxAutomationInvocationContext.$eventOrigin.withValue(automationOrigin) {
                processParsedV2Command(request)
            }
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard let commandToken = parts.first else {
            // Empty line: let the main-lane dispatcher produce the legacy
            // "ERROR: Empty command" reply.
            return v2MainSync {
                self.processCommand(command)
            }
        }
        let cmd = commandToken.lowercased()
        let args = parts.count > 1 ? parts[1] : ""

        if Thread.isMainThread,
           ControlCommandExecutionPolicy(forV1Command: cmd) == .socketWorker(mainThreadCallable: false) {
            return "ERROR: \(cmd) must run off the main thread"
        }

        let workerV1 = socketWorkerV1ResponseIfHandled(cmd: cmd, args: args)
        if workerV1.handled {
            return workerV1.response
        }

        return v2MainSync(commandKey: cmd) {
            self.processCommand(command)
        }
    }

    /// Public entry point mirroring the socket's `processCommand` path so
    /// in-process callers (e.g. the Feed coordinator's `feed.jump` focus
    /// request) can reuse the full V1/V2 dispatcher without duplicating
    /// its auth/policy wrappers.
    nonisolated func handleSocketLine(_ line: String) -> String {
        return processCommandUsingSocketExecutionPolicy(line) ?? ""
    }

    func processCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Empty command" }

        // v2 protocol: newline-delimited JSON.
        if trimmed.hasPrefix("{") {
            return processV2Command(trimmed)
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else { return "ERROR: Empty command" }

        let cmd = parts[0].lowercased()
        let args = parts.count > 1 ? parts[1] : ""

        let policyParams = cmd == "right_sidebar" ? ["args": args] : [:]
        return withSocketCommandPolicy(commandKey: cmd, isV2: false, params: policyParams) {
            // V1 domains migrated into CmuxControlSocket's ControlCommandCoordinator
            // (the sidebar metadata/pane/surface commands and the browser panel
            // commands) answer here; everything else falls through to the legacy
            // switch below.
            if let coordinatorV1 = controlCommandCoordinator.handleSidebarV1(command: cmd, args: args)
                ?? controlCommandCoordinator.handleBrowserPanelV1(command: cmd, args: args)
                ?? controlCommandCoordinator.handleDebugV1(command: cmd, args: args) {
                return coordinatorV1
            }
            switch cmd {
        case "ping":
            return "PONG"

        case "auth":
            return "OK: Authentication not required"

        case "__internal_flags":
            // UI-opening support command: presentation must run on the main actor.
            InternalFlagsPresenter.present()
            return "OK"

#if DEBUG
        case "__sidebar_footer_icon_balance":
            AppDelegate.shared?.debugWindowsCoordinator.showSidebarFooterIconBalanceWindow()
            return "OK"
#endif

        case "list_windows":
            return listWindows()

        case "current_window":
            return currentWindow()

        case "focus_window":
            return focusWindow(args)

        case "new_window":
            return newWindow()

        case "close_window":
            return closeWindow(args)

        case "resize_window":
            return resizeWindow(args)

        case "move_workspace_to_window":
            return moveWorkspaceToWindow(args)

        case "list_workspaces":
            return listWorkspaces()

	        case "new_workspace":
	            return newWorkspace(args)

	        case "new_split":
	            return newSplit(args)

        case "list_surfaces":
            return listSurfaces(args)

        case "focus_surface":
            return focusSurface(args)

        case "close_workspace":
            return closeWorkspace(args)

        case "select_workspace":
            return selectWorkspace(args)

        case "current_workspace":
            return currentWorkspace()

        case "send":
            return sendInput(args)

        case "send_key":
            return sendKey(args)

        case "send_surface":
            return sendInputToSurface(args)

        case "send_key_surface":
            return sendKeyToSurface(args)

        case "notify":
            return notifyCurrent(args)

        case "notify_surface":
            return notifySurface(args)

        case "notify_target":
            return notifyTarget(args)

        case "notify_target_async":
            return notifyTargetQueued(args)

        case "list_notifications":
            return listNotifications()

        case "clear_notifications":
            return clearNotifications(args)

        case "set_app_focus":
            return setAppFocusOverride(args)

        case "simulate_app_active":
            return simulateAppDidBecomeActive()

        // Sidebar metadata/reporting commands (set_status/report_meta/
        // report_meta_block/clear_status/clear_meta/clear_meta_block/list_status/
        // list_meta/list_meta_blocks/set_agent_pid/set_agent_lifecycle/
        // agent_hibernation/clear_agent_pid/log/clear_log/list_log/set_progress/
        // clear_progress/report_git_branch/clear_git_branch/report_pr/report_review/
        // clear_pr/report_ports/clear_ports/report_tty/ports_kick/report_shell_state/
        // report_pr_action/report_pwd/sidebar_state/reset_sidebar/right_sidebar)
        // handled by ControlCommandCoordinator.

        case "read_screen":
            // Socket traffic runs read_screen on the worker lane
            // (socketWorkerV1ResponseIfHandled) and never reaches this
            // main-actor switch; the case stays so any direct processCommand
            // caller keeps the legacy reply (the shared nonisolated body's
            // hop collapses inline on main).
            return readScreenText(args)

#if DEBUG
        case "send_workspace":
            return sendInputToWorkspace(args)

        case "sleepy_mode":
            return sleepyModeCommand(args)

        case "simulate_type":
            return simulateType(args)

        case "simulate_file_drop":
            return simulateFileDrop(args)

        case "seed_drag_pasteboard_fileurl":
            return seedDragPasteboardFileURL()

        case "seed_drag_pasteboard_tabtransfer":
            return seedDragPasteboardTabTransfer()

        case "seed_drag_pasteboard_sidebar_reorder":
            return seedDragPasteboardSidebarReorder()

        case "seed_drag_pasteboard_types":
            return seedDragPasteboardTypes(args)

        case "clear_drag_pasteboard":
            return clearDragPasteboard()

        case "drop_hit_test":
            return dropHitTest(args)

        case "drag_hit_chain":
            return dragHitChain(args)

        case "overlay_hit_gate":
            return overlayHitGate(args)

        case "overlay_drop_gate":
            return overlayDropGate(args)

        case "portal_hit_gate":
            return portalHitGate(args)

        case "sidebar_overlay_gate":
            return sidebarOverlayGate(args)

        case "terminal_drop_overlay_probe":
            return terminalDropOverlayProbe(args)
#endif

        case "help":
            return helpText()

        // Browser panel commands (open_browser/navigate/browser_back/browser_forward/
        // browser_reload/get_url/focus_webview/is_webview_focused) and the bonsplit
        // pane/surface commands (list_panes/list_pane_surfaces/focus_pane/
        // focus_surface_by_panel/drag_surface_to_split/new_pane/new_surface/
        // close_surface/reload_config/refresh_surfaces/surface_health) handled by
        // ControlCommandCoordinator (drag_surface_to_split forwards to the
        // still-shared v2SurfaceSplitOff).

            default:
                return "ERROR: Unknown command '\(cmd)'. Use 'help' for available commands."
            }
        }
    }

    // MARK: - V2 JSON Socket Protocol

    /// Runs a v2 command line (`{"method","params","id"}`) through the
    /// dispatcher in-process and returns the JSON response. Internal seam so
    /// in-app callers (e.g. custom-sidebar button actions) can drive the same
    /// command surface as the socket without reaching the private dispatcher.
    func runV2CommandLine(_ jsonLine: String) -> String {
        processV2Command(jsonLine)
    }

    /// Parses and dispatches a v2 line on the calling thread. Socket traffic
    /// enters through `processCommandUsingSocketExecutionPolicy`, which parses
    /// before this point; this entry serves in-process callers
    /// (`runV2CommandLine`, and `processCommand`'s v2 branch), so it may parse
    /// on its calling thread.
    private nonisolated func processV2Command(_ jsonLine: String) -> String {
        // v1 access-mode gating applies to v2 as well. We can't know which v2 method maps
        // to which v1 command without parsing, so parse first and then apply allow-list.
        switch Self.v2Parser.request(fromLine: jsonLine) {
        case .failure(let parseError):
            return Self.v2Encoder.response(for: parseError)
        case .success(let request):
            return CmuxAutomationInvocationContext.$eventOrigin.withValue(
                CmuxAutomationInvocationContext.eventOrigin
            ) {
                processParsedV2Command(request)
            }
        }
    }

    /// The main-hop outcome of one main-lane v2 command: either a typed
    /// result whose JSON bridging/serialization runs on the socket-worker
    /// thread after the hop, or a response the legacy switch already encoded
    /// on the main actor (see `v2LegacyMainActorResponse`).
    enum V2MainHopOutcome: Sendable {
        case callResult(ControlCallResult)
        case encoded(String)
    }

    /// Dispatches one already-parsed main-lane v2 request from the calling
    /// thread (the socket-worker connection thread for socket traffic; main
    /// for in-process callers). Policy checks and response encoding stay on
    /// the calling thread; only the command body crosses to the main actor,
    /// via a single `v2MainSync` hop.
    private nonisolated func processParsedV2Command(_ request: ControlRequest) -> String {
        if let focusError = Self.focusSuppressionResponse(
            method: request.method,
            id: request.id.map(\.foundationObject),
            params: request.params.mapValues(\.foundationObject)
        ) {
            return focusError
        }
        let bridged = V2SocketRequest(bridging: request)
        let id: Any? = bridged.id
        let method = bridged.method
        let params = bridged.params

        guard Self.executionPolicy(forV2Method: method) == .mainActor else {
            return v2Error(
                id: id,
                code: "invalid_dispatch",
                message: "\(method) must run on the socket worker"
            )
        }

        return withSocketCommandPolicy(commandKey: method, isV2: true, params: params) {
            if let workspaceParamError = v2UnsupportedWorkspaceAliasError(method: method, params: params) {
                return v2Result(id: id, workspaceParamError)
            }

            let outcome = v2MainSync {
                self.v2MainActorResponse(
                    request: request,
                    id: id,
                    method: method,
                    params: params
                )
            }
            switch outcome {
            case .callResult(let result):
                return Self.v2Encoder.response(id: request.id, result)
            case .encoded(let response):
                return response
            }
        }
    }

    /// The main-actor body of one main-lane v2 command: the known-ref
    /// refresh, then the coordinator, then the legacy switch. The
    /// coordinator's typed result returns unencoded so the socket worker
    /// serializes it after the hop.
    ///
    /// LOCKSTEP: `controlResolveOnMain` (TerminalControllerControlCommandContext.swift)
    /// is the worker-lane mirror of this dispatch preamble. Any step added
    /// before `controlCommandCoordinator.handle` here must also be added
    /// there, or the tranche-D worker-lane verbs silently fork from the
    /// main lane.
    func v2MainActorResponse(
        request: ControlRequest,
        id: Any?,
        method: String,
        params: [String: Any]
    ) -> V2MainHopOutcome {
        v2RefreshKnownRefs()

        // Domains migrated into CmuxControlSocket's ControlCommandCoordinator
        // answer here, on the main actor, through the same encoder/id as the
        // legacy switch (the worker encodes the typed result after the hop);
        // everything else falls through to the legacy switch below.
        if let coordinatorResult = controlCommandCoordinator.handle(request) {
            return .callResult(coordinatorResult)
        }
        return .encoded(v2LegacyMainActorResponse(
            id: id,
            method: method,
            params: params
        ))
    }

    /// The not-yet-migrated v2 main-actor command bodies.
    ///
    /// TODO(cli-off-main): these handlers still build AND encode their JSON
    /// response inside the main hop (`v2Ok`/`v2Result`/`v2Error` run here, on
    /// the main actor). As each case migrates onto the coordinator, or starts
    /// returning `V2CallResult` for the dispatcher's off-main encode tail in
    /// `processParsedV2Command`, its serialization cost leaves the main
    /// thread.
    private func v2LegacyMainActorResponse(
        id: Any?,
        method: String,
        params: [String: Any]
    ) -> String {
            switch method {
        case "system.ping":
            return v2Ok(id: id, result: ["pong": true])
        case "automation.list":
            return v2Result(id: id, v2AutomationList())
        case "automation.show":
            return v2Result(id: id, v2AutomationShow(params: params))
        case "automation.test":
            return v2Result(id: id, v2AutomationTest(params: params))
        case "automation.enable":
            return v2Result(id: id, v2AutomationSetEnabled(params: params, enabled: true))
        case "automation.disable":
            return v2Result(id: id, v2AutomationSetEnabled(params: params, enabled: false))
        case "automation.logs":
            return v2Result(id: id, v2AutomationLogs(params: params))
        case "automation.reload":
            return v2Result(id: id, v2AutomationReload())
        case "caffeine.status":
            return v2Result(id: id, v2CaffeineStatus())
        case "caffeine.set":
            return v2Result(id: id, v2CaffeineSet(params: params))
        // mobile.host.status/mobile.workspace.list/mobile.terminal.* (+terminal.*
        // aliases), mobile.terminal.paste/terminal.paste, and chat.sessions.dump
        // handled by ControlCommandCoordinator (bodies stay; shared with
        // mobileHostHandleRPC).

        // system.identify (forwards to the still-shared v2Identify), system.tree,
        // auth.login, and the DEBUG-only mobile.dev_stack_auth.configure handled
        // by ControlCommandCoordinator.

        // Windows (`window.*`) are handled above by ControlCommandCoordinator.

        // Workspaces
        // workspace.* (list/create/select/current/close/move_to_window/reorder[_many]/
        // prompt_submit/rename) + workspace.group.* handled by ControlCommandCoordinator.
        // workspace.action (forwards to the still-shared v2WorkspaceAction) and
        // extension.sidebar.snapshot handled by ControlCommandCoordinator.
        // workspace.next/previous/last/equalize_splits + workspace.remote.* (configure/
        // foreground_auth_ready/reconnect/disconnect/status/pty_attach_end/
        // terminal_session_launching/terminal_session_connected/
        // terminal_session_end) handled by
        // ControlCommandCoordinator. The worker-lane
        // workspace.remote.pty_* methods stay on the app-side worker path.
        case "workspace.set_auto_title":
            return v2Result(id: id, self.v2WorkspaceSetAutoTitle(params: params))
        case "surface.sync_codex_native_title":
            return v2Result(id: id, self.v2SurfaceSyncCodexNativeTitle(params: params))

        // Settings/session/feedback: session.restore_previous, session.import,
        // session.export, settings.open, and feedback.open handled by
        // ControlCommandCoordinator.

        // Feed (workstream): feed.jump/feed.list handled by ControlCommandCoordinator.
        case "sidebar.custom.open":
            return v2Result(id: id, self.v2CustomSidebarOpen(params: params))

        // Surfaces / input: surface.list/current/focus/split/respawn/create/close/move/
        // reorder handled by ControlCommandCoordinator (surface.move forwards to the
        // still-shared v2SurfaceMove). surface.action/tab.action and
        // surface.drag_to_split/surface.split_off (the latter forwarding to the
        // still-shared v2SurfaceSplitOff) handled by ControlCommandCoordinator too.
        // surface.refresh/health/resume.set/get/clear, debug.terminals, surface.send_text/
        // send_key/report_tty/report_pwd/report_shell_state/ports_kick/clear_history/
        // trigger_flash/read_text handled by ControlCommandCoordinator.

        // Panes
        // pane.* handled by ControlCommandCoordinator.

        // Notifications: all but notification.create_for_caller handled by
        // ControlCommandCoordinator (create_for_caller keeps its app-side resolver).
        case "notification.create_for_caller":
            return v2Result(id: id, self.v2NotificationCreateForCaller(params: params))
        case "agent.resolve_delivery_target": return v2Result(id: id, self.v2AgentResolveDeliveryTarget(params: params))
        case "agent.hibernation.session_end": return v2Result(id: id, self.v2AgentHibernationSessionEnd(params: params))
        #if DEBUG
        case "debug.cloudtree.spacing":
            // Explicit window presentation needs AppKit; the socket awaits the main-actor lane.
            return v2Ok(id: id, result: ["window": "cmux.cloudSidebarDebugLab"])
        case "debug.notification.status":
            return v2Ok(id: id, result: notificationDebugStatus())
        case "debug.notification.mode":
            guard let enabled = notificationDebugBoolParam(params, "enabled") else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(
                        localized: "debug.notification.error.missingEnabled",
                        defaultValue: "Pass enabled=true or enabled=false to turn notification debug mode on or off."
                    )
                )
            }
            NotificationDebugEmitter.shared.isModeEnabled = enabled
            return v2Ok(id: id, result: ["enabled": enabled])
        case "debug.notification.emit":
            guard let kind = notificationDebugStringParam(params, "kind"), !kind.isEmpty else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(
                        localized: "debug.notification.error.missingKind",
                        defaultValue: "Pass kind=<notification kind> to choose which debug notification to emit."
                    )
                )
            }
            let emitted = NotificationDebugEmitter.shared.emit(
                kind: kind,
                forceBanner: notificationDebugBoolParam(params, "force_banner") ?? false,
                target: notificationDebugCallerTarget(params: params)
            )
            guard emitted else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(
                        localized: "debug.notification.error.invalidKindOrTarget",
                        defaultValue: "Unknown kind or no notification target"
                    )
                )
            }
            return v2Ok(id: id, result: ["kind": kind])
        #endif


        // App focus (app.focus_override.set/app.simulate_active) handled by ControlCommandCoordinator.

        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    func v2Identify(params: [String: Any]) -> [String: Any] {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return [
                "socket_path": socketServer.currentSocketPath,
                "focused": NSNull(),
                "caller": NSNull()
            ]
        }

        var focused: [String: Any] = [:]
        v2MainSync {
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            if let wsId = tabManager.selectedTabId,
               let ws = tabManager.tabs.first(where: { $0.id == wsId }) {
                let projection = ws.focusedPanelId.flatMap {
                    ws.controlSurfaceProjection(forContainerPanelID: $0)
                }
                let paneUUID = projection?.paneID
                let surfaceUUID = projection?.surfaceID
                focused = [
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": wsId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
                    "pane_id": v2OrNull(paneUUID?.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                    "surface_id": v2OrNull(surfaceUUID?.uuidString),
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceUUID),
                    "tab_id": v2OrNull(surfaceUUID?.uuidString),
                    "tab_ref": v2TabRef(uuid: surfaceUUID),
                    "surface_type": v2OrNull(projection?.panel.panelType.rawValue),
                    "is_browser_surface": v2OrNull(projection.map { $0.panel.panelType == .browser }),
                    "file_path": v2OrNull(projection.flatMap { Self.controlSurfaceFilePath($0.panel) })
                ]
            } else {
                focused = [
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId)
                ]
            }
        }

        // Optionally validate a caller-provided location (useful for agents calling from inside a surface).
        var resolvedCaller: [String: Any]? = nil
        if let callerObj = params["caller"] as? [String: Any],
           let wsId = v2UUIDAny(callerObj["workspace_id"]) {
            let surfaceId = v2UUIDAny(callerObj["surface_id"]) ?? v2UUIDAny(callerObj["tab_id"])
            v2MainSync {
                let callerTabManager = AppDelegate.shared?.tabManagerFor(tabId: wsId) ?? tabManager
                if let ws = callerTabManager.tabs.first(where: { $0.id == wsId }) {
                    resolvedCaller = v2IdentifyCallerPayload(
                        workspace: ws,
                        surfaceId: surfaceId,
                        tabManager: callerTabManager
                    )
                }
            }
        }
        if resolvedCaller == nil, let callerTTY = params["caller_tty"] as? String {
            v2MainSync {
                resolvedCaller = v2IdentifyCallerPayload(
                    callerTTY: callerTTY,
                    fallbackTabManager: tabManager
                )
            }
        }

        var result: [String: Any] = [
            "socket_path": socketServer.currentSocketPath,
            "focused": focused.isEmpty ? NSNull() : focused,
            "caller": v2OrNull(resolvedCaller)
        ]
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            result["bundle_identifier"] = bundleIdentifier
        }
        result["app_bundle_path"] = Bundle.main.bundleURL.path
        // Lets a CLI from another build explain an unknown method
        // (`CLIVersionSkew`): product, version, and build of this process.
        result["app"] = "cmux"
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            result["version"] = version
        }
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            result["build"] = build
        }
        if let executablePath = Bundle.main.executableURL?.path {
            result["app_executable_path"] = executablePath
        }
        if let cliPath = Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: false)
            .path {
            result["app_cli_path"] = cliPath
        }
        return result
    }

    private struct V2WindowRouting {
        let includeAllWindows: Bool
        let requestedWindowId: UUID?
        let focused: [String: Any]
        let caller: [String: Any]
        let focusedWindowId: UUID?
    }

    private func v2WindowSelectorDetails(params: [String: Any]) -> [String: Any]? {
        guard let rawWindowId = params["window_id"] else { return nil }
        if let string = rawWindowId as? String {
            return ["window_id": string]
        }
        return ["window_id": String(describing: rawWindowId)]
    }

    private func parseV2WindowRouting(params: [String: Any]) -> (routing: V2WindowRouting?, error: V2CallResult?) {
        if params["all_windows"] != nil, v2Bool(params, "all_windows") == nil {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Invalid all_windows. Pass true or false, or omit it. Use --window <id|ref|index> to target one window or --all-windows to target all windows.",
                    data: nil
                )
            )
        }

        let includeAllWindows = v2Bool(params, "all_windows") ?? false
        let requestedWindowId = v2UUID(params, "window_id")
        if params["window_id"] != nil && requestedWindowId == nil {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Invalid window selector. Use --window <id|ref|index> to target one window, or run `cmux list-windows` to see available windows and retry.",
                    data: v2WindowSelectorDetails(params: params)
                )
            )
        }
        if includeAllWindows, requestedWindowId != nil {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Choose either --window <id|ref|index> or --all-windows, not both. Run `cmux list-windows` to see available windows and retry.",
                    data: v2WindowSelectorDetails(params: params)
                )
            )
        }

        var identifyParams: [String: Any] = [:]
        if let caller = params["caller"] as? [String: Any], !caller.isEmpty {
            identifyParams["caller"] = caller
        }
        if let requestedWindowId {
            identifyParams["window_id"] = requestedWindowId.uuidString
        }
        let identifyPayload = v2Identify(params: identifyParams)
        let focused = identifyPayload["focused"] as? [String: Any] ?? [:]
        let caller = identifyPayload["caller"] as? [String: Any] ?? [:]
        let focusedWindowId = v2UUIDAny(focused["window_id"]) ?? v2UUIDAny(focused["window_ref"])
        return (
            V2WindowRouting(
                includeAllWindows: includeAllWindows,
                requestedWindowId: requestedWindowId,
                focused: focused,
                caller: caller,
                focusedWindowId: focusedWindowId
            ),
            nil
        )
    }

    private func v2WindowNotFoundResult(params: [String: Any], windowId: UUID) -> V2CallResult {
        .err(
            code: "not_found",
            message: "Window not found. Run `cmux list-windows` to see available windows, then retry with --window <id|ref|index>.",
            data: v2WindowSelectorDetails(params: params) ?? ["window_id": windowId.uuidString]
        )
    }

#if DEBUG
#endif

    func v2SystemTopBasePayload(params: [String: Any]) -> V2CallResult {
        let workspaceFilter = v2UUID(params, "workspace_id")
        if params["workspace_id"] != nil && workspaceFilter == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        if params["include_processes"] != nil, v2Bool(params, "include_processes") == nil { return .err(code: "invalid_params", message: "Missing or invalid include_processes", data: nil) }
        let includeProcesses = v2Bool(params, "include_processes") ?? false
        let routingResult = parseV2WindowRouting(params: params)
        if let error = routingResult.error { return error }
        guard let routing = routingResult.routing else {
            return .err(code: "internal_error", message: "Invalid window routing payload", data: nil)
        }

        var windowNodes: [[String: Any]] = []
        var workspaceFound = (workspaceFilter == nil)
        var windowFound = (routing.requestedWindowId == nil)

        if let app = AppDelegate.shared {
            let summaries = app.listMainWindowSummaries()
            let defaultWindowId = routing.requestedWindowId ?? routing.focusedWindowId ?? summaries.first?.windowId

            for (windowIndex, summary) in summaries.enumerated() {
                if let requestedWindowId = routing.requestedWindowId, summary.windowId != requestedWindowId {
                    continue
                }
                windowFound = true
                guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }

                if let workspaceFilter {
                    guard let workspaceIndex = manager.tabs.firstIndex(where: { $0.id == workspaceFilter }) else {
                        continue
                    }
                    let workspace = manager.tabs[workspaceIndex]
                    let workspaceNode = v2TopWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                    windowNodes = [
                        v2TopWindowNode(
                            summary: summary,
                            index: windowIndex,
                            workspaceNodes: [workspaceNode]
                        )
                    ]
                    workspaceFound = true
                    break
                }

                if !routing.includeAllWindows && summary.windowId != defaultWindowId {
                    continue
                }

                let workspaceNodesForWindow = manager.tabs.enumerated().map { workspaceIndex, workspace in
                    v2TopWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                }

                windowNodes.append(
                    v2TopWindowNode(
                        summary: summary,
                        index: windowIndex,
                        workspaceNodes: workspaceNodesForWindow
                    )
                )
            }
        }

        v2AttachTopApplicationProcess(to: &windowNodes, workspaceFilter: workspaceFilter)

        if let requestedWindowId = routing.requestedWindowId, !windowFound {
            return v2WindowNotFoundResult(params: params, windowId: requestedWindowId)
        }
        if let workspaceFilter, !workspaceFound {
            return .err(
                code: "not_found",
                message: "Workspace not found",
                data: [
                    "workspace_id": workspaceFilter.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceFilter)
                ]
            )
        }

        return .ok([
            "active": routing.focused.isEmpty ? (NSNull() as Any) : routing.focused,
            "caller": routing.caller.isEmpty ? (NSNull() as Any) : routing.caller,
            "include_processes": includeProcesses,
            "windows": windowNodes
        ])
    }

    func v2TopWindowNode(
        summary: AppDelegate.MainWindowSummary,
        index: Int,
        workspaceNodes: [[String: Any]]
    ) -> [String: Any] {
        return [
            "kind": "window",
            "id": summary.windowId.uuidString,
            "ref": v2Ref(kind: .window, uuid: summary.windowId),
            "index": index,
            "key": summary.isKeyWindow,
            "visible": summary.isVisible,
            "workspace_count": workspaceNodes.count,
            "selected_workspace_id": v2OrNull(summary.selectedWorkspaceId?.uuidString),
            "selected_workspace_ref": v2Ref(kind: .workspace, uuid: summary.selectedWorkspaceId),
            "workspaces": workspaceNodes
        ]
    }

    func v2TopWorkspaceNode(
        workspace: Workspace,
        index: Int,
        selected: Bool
    ) -> [String: Any] {
        let topology = controlSystemTreeWorkspaceNode(
            workspace: workspace, index: index, selected: selected, dockStores: []
        )
        let panes = topology.panes.map { pane in
            return [
                "kind": "pane",
                "id": pane.paneID.uuidString,
                "ref": v2Ref(kind: .pane, uuid: pane.paneID),
                "index": pane.index,
                "focused": pane.isFocused,
                "surface_ids": pane.surfaceIDs.map(\.uuidString),
                "surface_refs": pane.surfaceIDs.map { v2Ref(kind: .surface, uuid: $0) },
                "selected_surface_id": v2OrNull(pane.selectedSurfaceID?.uuidString),
                "selected_surface_ref": v2Ref(kind: .surface, uuid: pane.selectedSurfaceID),
                "surface_count": pane.surfaceIDs.count,
                "surfaces": pane.surfaces.map { v2TopSurfaceNode($0, workspace: workspace) }
            ]
        }

        return [
            "kind": "workspace",
            "id": topology.workspaceID.uuidString,
            "ref": v2Ref(kind: .workspace, uuid: topology.workspaceID),
            "index": topology.index,
            "title": topology.title,
            "description": v2OrNull(topology.description),
            "selected": topology.isSelected,
            "pinned": topology.isPinned,
            "host": v2TopHostNode(workspace.hostLabel),
            "panes": panes,
            "tags": v2TopTagNodes(for: workspace)
        ]
    }

    /// Where a `system.top` workspace runs: `kind` is `local`, `ssh` or `cloud`;
    /// `label` is the host (`big-red`) and `detail` the full target.
    private func v2TopHostNode(_ host: WorkspaceHostLabel) -> [String: Any] {
        [
            "kind": host.kind.rawValue,
            "label": v2OrNull(host.label.isEmpty ? nil : host.label),
            "detail": v2OrNull(host.detail.isEmpty ? nil : host.detail),
        ]
    }

    private func v2TopSurfaceNode(
        _ surface: ControlSystemTreeSurfaceNode,
        workspace: Workspace
    ) -> [String: Any] {
        var item: [String: Any] = [
            "kind": "surface",
            "id": surface.surfaceID.uuidString,
            "ref": v2Ref(kind: .surface, uuid: surface.surfaceID),
            "index": surface.index,
            "type": surface.typeRawValue,
            "title": surface.title,
            "focused": surface.isFocused,
            "selected": surface.isSelected,
            "selected_in_pane": v2OrNull(surface.selectedInPane),
            "pane_id": v2OrNull(surface.paneID?.uuidString),
            "pane_ref": v2Ref(kind: .pane, uuid: surface.paneID),
            "index_in_pane": v2OrNull(surface.indexInPane),
            "tty": v2OrNull(surface.tty),
            "webviews": []
        ]

        item["url"] = surface.isBrowser ? (surface.url ?? "") : NSNull()
        item["browser_web_content_pid"] = NSNull()
        return item
    }

    private func v2TopTagNodes(for workspace: Workspace) -> [[String: Any]] {
        var tags: [[String: Any]] = []
        var seenKeys = Set<String>()

        for (index, entry) in workspace.sidebarStatusEntriesInDisplayOrder().enumerated() {
            let pid = workspace.agentPIDs[entry.key].flatMap { $0 > 0 ? Int($0) : nil }
            tags.append([
                "kind": "tag",
                "id": v2TopTagIdentifier(workspaceId: workspace.id, key: entry.key),
                "ref": v2TopTagRef(workspaceId: workspace.id, key: entry.key),
                "index": index,
                "key": entry.key,
                "value": entry.value,
                "icon": v2OrNull(entry.icon),
                "color": v2OrNull(entry.color),
                "url": v2OrNull(entry.url?.absoluteString),
                "priority": entry.priority,
                "format": entry.format.rawValue,
                "visible": true,
                "pid": v2OrNull(pid)
            ])
            seenKeys.insert(entry.key)
        }

        for key in workspace.agentPIDs.keys.sorted() where !seenKeys.contains(key) {
            let pid = workspace.agentPIDs[key].flatMap { $0 > 0 ? Int($0) : nil }
            tags.append([
                "kind": "tag",
                "id": v2TopTagIdentifier(workspaceId: workspace.id, key: key),
                "ref": v2TopTagRef(workspaceId: workspace.id, key: key),
                "index": tags.count,
                "key": key,
                "value": "",
                "icon": NSNull(),
                "color": NSNull(),
                "url": NSNull(),
                "priority": 0,
                "format": "plain",
                "visible": false,
                "pid": v2OrNull(pid)
            ])
        }

        return tags
    }

    // MARK: - V2 Helpers (encoding + result plumbing)
    // MARK: - V2 Helpers (encoding + result plumbing)

    nonisolated func v2OrNull(_ value: Any?) -> Any {
        // Avoid relying on `?? NSNull()` inference (Swift toolchains can disagree).
        if let value { return value }
        return NSNull()
    }

    private nonisolated static func notificationCreatedAtString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private nonisolated static func notificationListTrailingField(_ value: String) -> String {
        "pct:" + value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "|", with: "%7C")
            .replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "\r", with: "%0D")
    }

    nonisolated func v2NonEmptyString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated func v2MainSync<T>(commandKey: String? = nil, _ body: @MainActor () -> T) -> T {
        let policyStack = Self.currentSocketCommandFocusAllowanceStack()
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                Self.withSocketCommandPolicyStack(policyStack) {
                    body()
                }
            }
        }
        // Per-hop timing: queue-wait (enqueue → body start) and body duration,
        // attributed to `commandKey` (or the innermost key pushed by
        // `withSocketCommandPolicy` on this thread). Timing is recorded while
        // a tool records the `.dynamicTracing` signposts, and always in DEBUG
        // so the accumulator can feed the slow-command log. In release with
        // no tracer attached, the hop is a bare main.sync with zero extra
        // work (the early return below; compiled out of DEBUG so the
        // always-on DEBUG path does not leave it as dead code).
        let signpostingActive = Self.socketMainHopSignpostingActive
#if !DEBUG
        guard signpostingActive else {
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    Self.withSocketCommandPolicyStack(policyStack) {
                        body()
                    }
                }
            }
        }
#endif
        let signposter = Self.socketMainHopSignposter
        var signpostState: OSSignpostIntervalState?
        if signpostingActive {
            let key = commandKey ?? Self.currentSocketCommandKey() ?? "-"
            signpostState = signposter.beginInterval(
                "main-hop",
                id: signposter.makeSignpostID(),
                "\(key, privacy: .public)"
            )
        }
        let enqueuedAt = DispatchTime.now().uptimeNanoseconds
        var bodyStartedAt = enqueuedAt
        let result: T = DispatchQueue.main.sync {
            bodyStartedAt = DispatchTime.now().uptimeNanoseconds
            return MainActor.assumeIsolated {
                Self.withSocketCommandPolicyStack(policyStack) {
                    body()
                }
            }
        }
        let endedAt = DispatchTime.now().uptimeNanoseconds
        if let signpostState {
            signposter.endInterval(
                "main-hop",
                signpostState,
                "wait_ns=\(bodyStartedAt - enqueuedAt) body_ns=\(endedAt - bodyStartedAt)"
            )
        }
#if DEBUG
        Self.recordSocketCommandMainHop(
            queueWaitNanos: bodyStartedAt - enqueuedAt,
            bodyNanos: endedAt - bodyStartedAt
        )
#endif
        return result
    }
    nonisolated func v2Ok(id: Any?, result: Any) -> String {
        guard let idValue = Self.v2WireId(id),
              let payload = JSONValue(foundationObject: result) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.ok(id: idValue, result: payload)
    }
    /// Bridges a legacy `Any?` request id to the wire value: missing ids
    /// encode as JSON `null`; an unencodable id reports overall encode
    /// failure (the legacy `isValidJSONObject` behavior).
    private nonisolated static func v2WireId(_ id: Any?) -> JSONValue? {
        guard let id else { return .null }
        return JSONValue(foundationObject: id)
    }
    /// Bridge an async throws closure into a socket RPC response. Runs the work on a detached
    /// Task (so VMClient's URLSession hops are free to use any actor) and blocks the socket
    /// worker thread on a semaphore. Mirrors the auth.begin_sign_in pattern above.
    nonisolated func v2VmCall(
        id: Any?,
        timeoutSeconds: TimeInterval? = 17 * 60,
        transportUnsupportedMachineID: String? = nil,
        daemonUnavailableMessage: String? = nil,
        mapError: (Error) -> String? = { _ in nil },
        _ work: @escaping () async throws -> [String: Any]
    ) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<[String: Any], Error>?
        // Control-plane requests inside `work` state the earliest of this
        // worker's limit and the socket client's budget the dispatcher bound
        // (the Task inherits it), so the server answers before either gives up.
        let task = Task {
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        if let timeoutSeconds {
            if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
                task.cancel()
                return v2Error(
                    id: id,
                    code: "timeout",
                    message: "VM request timed out after \(Int(timeoutSeconds)) seconds"
                )
            }
        } else {
            // Opt-in for operations that enforce their own lifecycle deadline.
            semaphore.wait()
        }
        switch result {
        case .success(let payload):
            return v2Ok(id: id, result: payload)
        case .failure(let error):
            // A caller's own error codes come first; the timeout above never reaches them.
            if let mapped = mapError(error) { return mapped }
            // Network policy refusals name the offending entry; the generic
            // Cloud VM line would hide which domain or range was wrong.
            if let catalogError = error as? SurfaceCatalogError {
                switch catalogError {
                case .nothingToOpen:
                    return v2Error(id: id, code: "not_ready", message: catalogError.localizedDescription)
                case .destinationNotFound:
                    return v2Error(id: id, code: "not_found", message: catalogError.localizedDescription)
                default:
                    // Preserve the catalog's actionable ownership or transport detail.
                    // Falling through to the generic VM message hides whether the
                    // machine is disconnected, the surface is stale, or the provider
                    // cannot perform this operation.
                    return v2Error(id: id, code: "vm_error", message: catalogError.localizedDescription)
                }
            }
            return v2Error(
                id: id,
                code: "vm_error",
                message: String(describing: error),
                data: nil
            )
        case nil:
            return v2Error(
                id: id,
                code: "vm_error",
                message: "unknown vm error"
            )
        }
    }
    nonisolated func v2AsyncResultCall(
        id: Any?,
        timeoutSeconds: TimeInterval,
        _ work: @escaping () async -> V2CallResult
    ) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: V2CallResult?
        let task = Task {
            result = await work()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            task.cancel()
            return v2Error(
                id: id,
                code: "timeout",
                message: "Request timed out after \(Int(timeoutSeconds)) seconds"
            )
        }
        guard let result else {
            return v2Error(
                id: id,
                code: "request_error",
                message: "Request failed before returning a result"
            )
        }
        return v2Result(id: id, result)
    }

    nonisolated func v2Error(id: Any?, code: String, message: String, data: Any? = nil) -> String {
        guard let idValue = Self.v2WireId(id) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        var dataValue: JSONValue?
        if let data {
            guard let bridgedData = JSONValue(foundationObject: data) else {
                return ControlResponseEncoder.encodeFailureResponse
            }
            dataValue = bridgedData
        }
        return Self.v2Encoder.error(id: idValue, code: code, message: message, data: dataValue)
    }

    /// Interim `Any`-shaped twin of the package's `ControlCallResult`, kept
    /// while the command bodies still build Foundation payloads. Bodies
    /// migrate onto the typed DTO in the ControlCommandCoordinator stage.
    enum V2CallResult {
        case ok(Any)
        case err(code: String, message: String, data: Any?)
    }

    nonisolated func v2Result(id: Any?, _ res: V2CallResult) -> String {
        switch res {
        case .ok(let payload):
            return v2Ok(id: id, result: payload)
        case .err(let code, let message, let data):
            return v2Error(id: id, code: code, message: message, data: data)
        }
    }

    nonisolated func v2UnsupportedWorkspaceAliasError(method: String, params: [String: Any]) -> V2CallResult? {
        guard method.hasPrefix("workspace."), params.keys.contains("window") else { return nil }
        return .err(
            code: "invalid_params",
            message: String(
                localized: "socket.workspace.unsupportedWindowParam",
                defaultValue: "Unsupported parameter `window`; use `window_id` with a window UUID or ref from `window.list`."
            ),
            data: [
                "method": method,
                "unsupported_param": "window",
                "supported_param": "window_id"
            ]
        )
    }

    private nonisolated func v2Encode(_ object: Any) -> String {
        guard let value = JSONValue(foundationObject: object) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.encode(value)
    }

    func v2EnsureHandleRef(kind: ControlHandleKind, uuid: UUID) -> String {
        controlCommandCoordinator.ensureRef(kind: kind, uuid: uuid)
    }

    func v2ExistingHandleRef(kind: ControlHandleKind, uuid: UUID) -> String? {
        controlCommandCoordinator.existingRef(kind: kind, uuid: uuid)
    }

    func v2ResolveHandleRef(_ handle: String) -> UUID? {
        controlCommandCoordinator.resolveRef(handle)
    }

    nonisolated func v2Ref(kind: ControlHandleKind, uuid: UUID?) -> Any {
        guard let uuid else { return NSNull() }
        return v2MainSync { v2EnsureHandleRef(kind: kind, uuid: uuid) }
    }

    func v2WorkspaceRefs(for ids: [UUID]) -> [UUID: String] {
        var refs: [UUID: String] = [:]
        refs.reserveCapacity(ids.count)
        for id in ids {
            refs[id] = v2EnsureHandleRef(kind: .workspace, uuid: id)
        }
        return refs
    }

    func v2WorkspacePaneAndSurfaceRefs(
        workspaceId: UUID,
        paneId: UUID?,
        surfaceId: UUID
    ) -> (workspaceRef: String, paneRef: String?, surfaceRef: String) {
        return (
            workspaceRef: v2EnsureHandleRef(kind: .workspace, uuid: workspaceId),
            paneRef: paneId.map { v2EnsureHandleRef(kind: .pane, uuid: $0) },
            surfaceRef: v2EnsureHandleRef(kind: .surface, uuid: surfaceId)
        )
    }

    func v2TabRef(uuid: UUID?) -> Any {
        guard let uuid else { return NSNull() }
        let surfaceRef = v2EnsureHandleRef(kind: .surface, uuid: uuid)
        return surfaceRef.replacingOccurrences(of: "surface:", with: "tab:")
    }

    // Internal (not private): the `controlResolveOnMain` seam conformance in
    // TerminalControllerControlCommandContext.swift runs this refresh inside
    // the worker-lane resolution hop, mirroring the main-lane dispatch
    // preamble.
    func v2RefreshKnownRefs() {
        guard let app = AppDelegate.shared else { return }

        // #2751: skip the pre-mint pass until session restore has settled.
        // Refreshing here is only an optimization (refs otherwise mint lazily
        // on the first list/create); iterating the half-built window/tab tree
        // while restore is pending or in flight faults (EXC_BAD_ACCESS / arm64e
        // ptrauth). A v2 socket command arriving within ~1s of launch can
        // re-enter this on the main actor mid-restore, so degrade gracefully.
        guard app.didCompleteInitialSessionRestore else { return }

        // #5757: Skip the expensive full-tree scan if topology has not changed.
        // Commands calling `controlResolveOnMain` or reading surfaces otherwise force
        // O(windows * tabs * panes) handle sweeps on every RPC hop, freezing the MainActor
        // during heavy multi-agent activity.
        guard controlCommandCoordinator.needsHandleTopologyRefresh else { return }

        let windows = app.listMainWindowSummaries()
        for item in windows {
            _ = v2EnsureHandleRef(kind: .window, uuid: item.windowId)
            if let tm = app.tabManagerFor(windowId: item.windowId) {
                for ws in tm.tabs {
                    _ = v2EnsureHandleRef(kind: .workspace, uuid: ws.id)
                }
                // Mint workspace_group refs for groups that exist before any
                // workspace.group.* call so callers can pass `workspace_group:N`
                // immediately after restore (otherwise the first ref hand-off
                // happens only on `list`/`create`).
                for group in tm.workspaceGroups {
                    _ = v2EnsureHandleRef(kind: .workspaceGroup, uuid: group.id)
                }
            }
        }
        controlCommandCoordinator.markHandleTopologyRefreshCompleted()
    }

    // MARK: - V2 Context Resolution

    nonisolated func v2ResolveTabManager(params: [String: Any]) -> TabManager? {
        // Prefer explicit window_id routing. Otherwise prefer group_id (group
        // methods are the only routing key for cross-window group ops, and
        // CLI helpers always inject caller workspace_id/surface_id, which
        // would otherwise win even when the group belongs to a different
        // window). Then use workspace/surface/pane lookup and the active window.
        if v2HasNonNullParam(params, "window_id") {
            guard let windowId = v2UUID(params, "window_id") else { return nil }
            return v2MainSync { AppDelegate.shared?.tabManagerFor(windowId: windowId) }
        }
        if let groupId = v2UUID(params, "group_id") {
            if let tm = v2MainSync({ v2LocateTabManager(forGroupId: groupId) }) {
                return tm
            }
        }
        if let wsId = v2UUID(params, "workspace_id") {
            if wsId == AppDelegate.windowDockAliasWorkspaceId {
                return v2MainSync { tabManager ?? AppDelegate.shared?.currentScriptableMainWindow()?.tabManager }
            }
            if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(tabId: wsId) }) {
                return tm
            }
            // A window-Dock owner id IS its owning window's id, so a Dock-scoped
            // workspace_id routes to that window rather than the caller's.
            if let tm = v2MainSync({ AppDelegate.shared?.tabManagerForWindowDockOwner(wsId) }) {
                return tm
            }
        }
        if let surfaceId = v2UUID(params, "surface_id")
            ?? v2UUID(params, "terminal_id")
            ?? v2UUID(params, "tab_id") {
            if let manager = v2MainSync({ controlTabManager(surfaceID: surfaceId) }) { return manager }
        }
        if let paneId = v2UUID(params, "pane_id") {
            if let tm = v2MainSync({ controlTabManager(paneID: paneId) }) {
                return tm
            }
        }
        return v2MainSync { tabManager ?? AppDelegate.shared?.currentScriptableMainWindow()?.tabManager }
    }

    @MainActor
    private func v2LocateTabManager(forGroupId groupId: UUID) -> TabManager? {
        guard let app = AppDelegate.shared else { return nil }
        for summary in app.listMainWindowSummaries() {
            guard let tm = app.tabManagerFor(windowId: summary.windowId) else { continue }
            if tm.workspaceGroups.contains(where: { $0.id == groupId }) {
                return tm
            }
        }
        return nil
    }

    /// Mirrors the former `v2ResolveTabManager` precedence for the
    /// ``ControlCommandContext`` window resolution, operating on selectors the
    /// coordinator already resolved through the shared handle registry: explicit
    /// `window_id` wins (a present-but-unresolvable one yields no target), then
    /// group, workspace, surface, pane, then the caller's window, then the
    /// active scriptable window. Lives here so it can read the controller's
    /// `private` `tabManager` / `v2LocateTabManager`.
    func resolveTabManager(routing: ControlRoutingSelectors) -> TabManager? {
        if let owner = routing.remoteRelayOwnerWorkspaceID {
            guard routing.workspaceID == nil || routing.workspaceID == owner else { return nil }
            guard let workspace = AppDelegate.shared?.workspaceFor(tabId: owner) else { return nil }
            return AppDelegate.shared?.tabManagerFor(tabId: owner)
        }
        if routing.hasWindowIDParam {
            guard let windowId = routing.windowID else { return nil }
            return AppDelegate.shared?.tabManagerFor(windowId: windowId)
        }
        if let groupId = routing.groupID,
           let tm = v2LocateTabManager(forGroupId: groupId) {
            return tm
        }
        if let workspaceId = routing.workspaceID {
            if workspaceId == AppDelegate.windowDockAliasWorkspaceId {
                return tabManager ?? AppDelegate.shared?.currentScriptableMainWindow()?.tabManager
            }
            if let tm = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) {
                return tm
            }
            // A window-Dock owner id IS its owning window's id, so a Dock-scoped
            // workspace_id routes to that window rather than the caller's.
            if let tm = AppDelegate.shared?.tabManagerForWindowDockOwner(workspaceId) {
                return tm
            }
        }
        if let surfaceId = routing.surfaceID {
            if let manager = controlTabManager(surfaceID: surfaceId) { return manager }
        }
        if let paneId = routing.paneID,
           let tm = controlTabManager(paneID: paneId) {
            return tm
        }
        return tabManager ?? AppDelegate.shared?.currentScriptableMainWindow()?.tabManager
    }

    func v2ResolveWindowId(tabManager: TabManager?) -> UUID? {
        guard let tabManager else { return nil }
        return v2MainSync { AppDelegate.shared?.windowId(for: tabManager) }
    }

    private func v2ResolveWorkspaceOwner(_ workspaceId: UUID) -> TabManager? {
        v2MainSync { AppDelegate.shared?.tabManagerFor(tabId: workspaceId) }
    }

    private nonisolated func v2RequestedRemotePTYSurfaceID(params: [String: Any]) -> (
        surfaceId: UUID?,
        error: V2CallResult?
    ) {
        var surfaceId: UUID?
        var invalidSurfaceID = false
        v2MainSync {
            v2RefreshKnownRefs()
            surfaceId = v2UUID(params, "surface_id")
            invalidSurfaceID = v2HasNonNullParam(params, "surface_id") && surfaceId == nil
        }
        if invalidSurfaceID {
            return (
                nil,
                .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
            )
        }
        return (surfaceId, nil)
    }

    nonisolated func notifyRemotePTYControllerAvailabilityChanged() {
        remotePTYControllerAvailabilityCondition.lock()
        remotePTYControllerAvailabilityGeneration &+= 1
        remotePTYControllerAvailabilityCondition.broadcast()
        remotePTYControllerAvailabilityCondition.unlock()
    }

    private nonisolated func v2RemotePTYWorkspaceData(workspaceId: UUID) -> [String: Any] {
        var workspaceRef: Any = NSNull()
        v2MainSync {
            workspaceRef = v2Ref(kind: .workspace, uuid: workspaceId)
        }
        return [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": workspaceRef,
        ]
    }

    private nonisolated func v2RemotePTYTargetPayload(_ target: RemotePTYSocketTarget) -> [String: Any] {
        [
            "window_id": v2OrNull(target.windowId?.uuidString),
            "window_ref": target.windowRef,
            "workspace_id": target.workspaceId.uuidString,
            "workspace_ref": target.workspaceRef,
            "workspace_title": target.workspaceTitle,
        ]
    }

    /// `workspace.env` — read a workspace's user-defined environment (issue #5995).
    /// Resolves the workspace by `workspace_id` / surface / pane, falling back to the
    /// selected workspace only when no explicit target is supplied, and returns the
    /// raw configured set. An explicit-but-unresolvable target errors. Secret masking is a
    /// CLI presentation concern (`cmux workspace env --mask`): the local control
    /// socket already exposes the surrounding workspace state, so values are returned
    /// verbatim and the env set is deliberately kept out of `workspace.list` so a
    /// plain listing never echoes secrets.
    private nonisolated func v2WorkspaceEnv(params: [String: Any]) -> V2CallResult {
        // Validate any explicit target before resolving. This endpoint can print
        // secrets, so a malformed or stale explicit target must error rather than
        // silently fall back to the selected workspace (unlike the generic
        // v2ResolveWorkspace, which falls through to the selection).
        for key in ["workspace_id", "surface_id", "terminal_id", "tab_id", "pane_id"] {
            if v2HasNonNullParam(params, key), v2UUID(params, key) == nil {
                return .err(code: "invalid_params", message: "Missing or invalid \(key)", data: nil)
            }
        }
        return v2MainSync { () -> V2CallResult in
            v2RefreshKnownRefs()
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            // Resolve strictly for explicit targets; only fall back to the selected
            // workspace when no explicit target was supplied.
            let resolved: Workspace?
            if let wsId = v2UUID(params, "workspace_id") {
                resolved = tabManager.tabs.first(where: { $0.id == wsId })
            } else if let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "terminal_id") ?? v2UUID(params, "tab_id") {
                resolved = tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
            } else if let paneId = v2UUID(params, "pane_id") {
                if let located = v2LocatePane(paneId), located.tabManager === tabManager {
                    resolved = located.workspace
                } else {
                    resolved = nil
                }
            } else if let selectedId = tabManager.selectedTabId {
                resolved = tabManager.tabs.first(where: { $0.id == selectedId })
            } else {
                resolved = nil
            }
            guard let workspace = resolved else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            let env = workspace.workspaceEnvironment
            return .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "env": env,
                "count": env.count,
            ])
        }
    }

    private nonisolated func v2RemotePTYSessionPayload(
        _ session: [String: Any],
        target: RemotePTYSocketTarget
    ) -> [String: Any] {
        var payload = session
        payload["window_id"] = v2OrNull(target.windowId?.uuidString)
        payload["window_ref"] = target.windowRef
        payload["workspace_id"] = target.workspaceId.uuidString
        payload["workspace_ref"] = target.workspaceRef
        payload["workspace_title"] = target.workspaceTitle
        return payload
    }

    @MainActor

    func v2WorkspaceAction(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let action = v2ActionKey(params) else {
            return .err(code: "invalid_params", message: "Missing action", data: nil)
        }
        let supportedActions = [
            "pin", "unpin", "rename", "clear_name",
            "set_description", "clear_description",
            "move_up", "move_down", "move_top",
            "close_others", "close_above", "close_below",
            "mark_read", "mark_unread",
            "set_color", "clear_color", "mobile_connect"
        ]

        var result: V2CallResult = .err(code: "invalid_params", message: "Unknown workspace action", data: [
            "action": action,
            "supported_actions": supportedActions
        ])

        v2MainSync {

            let requestedWorkspaceId = v2UUID(params, "workspace_id") ?? tabManager.selectedTabId
            guard let workspaceId = requestedWorkspaceId,
                  let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            let force = v2Bool(params, "force") ?? false

            @MainActor
            func closeWorkspaces(_ workspaces: [Workspace]) -> Int? {
                let activeWorkspaceIDs = workspaces
                    .filter { $0.needsConfirmClose() }
                    .map { $0.id }
                guard force || activeWorkspaceIDs.isEmpty else {
                    result = .err(code: "confirmation_required", message: "One or more workspaces have a running process; retry with force=true", data: [
                        "workspace_ids": activeWorkspaceIDs.map { $0.uuidString }
                    ])
                    return nil
                }
                var closed = 0
                // Drain non-anchor members before group anchors so a range close
                // that targets a group promotes at most once per group instead of
                // re-promoting and rescanning per member (see anchorLastCloseOrder).
                for candidate in tabManager.anchorLastCloseOrder(workspaces) where candidate.id != workspace.id {
                    let existedBefore = tabManager.tabs.contains(where: { $0.id == candidate.id })
                    guard existedBefore else { continue }
                    tabManager.closeWorkspace(candidate)
                    if !tabManager.tabs.contains(where: { $0.id == candidate.id }) {
                        closed += 1
                    }
                }
                return closed
            }

            @MainActor
            func finish(_ extras: [String: Any] = [:]) {
                var payload: [String: Any] = [
                    "action": action,
                    "workspace_id": workspace.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId)
                ]
                for (key, value) in extras {
                    payload[key] = value
                }
                result = .ok(payload)
            }

            switch action {
            case "pin":
                tabManager.setPinned(workspace, pinned: true)
                finish(["pinned": true])

            case "unpin":
                tabManager.setPinned(workspace, pinned: false)
                finish(["pinned": false])

            case "rename":
                guard let titleRaw = v2String(params, "title"),
                      !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
                    return
                }
                let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                tabManager.setCustomTitle(tabId: workspace.id, title: title)
                finish(["title": title])

            case "clear_name":
                tabManager.clearCustomTitle(tabId: workspace.id)
                finish(["title": workspace.title])

            case "set_description":
                guard let descriptionRaw = v2String(params, "description"),
                      !descriptionRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid description", data: nil)
                    return
                }
                tabManager.setCustomDescription(tabId: workspace.id, description: descriptionRaw)
                finish(["description": v2OrNull(workspace.customDescription)])

            case "clear_description":
                tabManager.clearCustomDescription(tabId: workspace.id)
                finish(["description": NSNull()])

            case "move_up":
                _ = tabManager.reorderWorkspace(tabId: workspace.id, by: -1)
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "move_down":
                _ = tabManager.reorderWorkspace(tabId: workspace.id, by: 1)
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "move_top":
                tabManager.moveTabToTop(workspace.id)
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "close_others":
                let candidates = tabManager.tabs.filter { $0.id != workspace.id && !$0.isPinned }
                guard let closed = closeWorkspaces(candidates) else { return }
                finish(["closed": closed])

            case "close_above":
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let candidates = Array(tabManager.tabs.prefix(index)).filter { !$0.isPinned }
                guard let closed = closeWorkspaces(candidates) else { return }
                finish(["closed": closed])

            case "close_below":
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let candidates: [Workspace]
                if index + 1 < tabManager.tabs.count {
                    candidates = Array(tabManager.tabs.suffix(from: index + 1)).filter { !$0.isPinned }
                } else {
                    candidates = []
                }
                guard let closed = closeWorkspaces(candidates) else { return }
                finish(["closed": closed])

            case "mark_read":
                AppDelegate.shared?.notificationStore?.markRead(forTabId: workspace.id)
                finish()

            case "mark_unread":
                AppDelegate.shared?.notificationStore?.markUnread(forTabId: workspace.id)
                finish()

            case "set_color":
                guard let colorRaw = v2String(params, "color"),
                      !colorRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid color", data: nil)
                    return
                }
                let colorInput = colorRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                // Resolve named colors from the effective palette, including file-defined additions.
                let effectivePalette = WorkspaceTabColorSettings.palette()
                let hex: String
                if let entry = effectivePalette.first(where: {
                    $0.name.caseInsensitiveCompare(colorInput) == .orderedSame
                }) {
                    hex = entry.hex
                } else if let normalized = WorkspaceTabColorSettings.normalizedHex(colorInput) {
                    hex = normalized
                } else {
                    let colorNames = effectivePalette.map(\.name)
                    result = .err(code: "invalid_params", message: "Invalid color. Use a hex value (#RRGGBB) or a named color.", data: [
                        "named_colors": colorNames
                    ])
                    return
                }
                tabManager.setTabColor(tabId: workspace.id, color: hex)
                finish(["color": hex])

            case "clear_color":
                tabManager.setTabColor(tabId: workspace.id, color: nil)
                finish(["color": NSNull()])

            default:
                result = .err(code: "invalid_params", message: "Unknown workspace action", data: [
                    "action": action,
                    "supported_actions": supportedActions
                ])
            }
        }

        return result
    }

    // MARK: - V2 Surface Methods

    @MainActor
    @discardableResult
    func closeSurfaceRecordingHistory(in workspace: Workspace, surfaceId: UUID, force: Bool) -> Bool {
        if let tabId = workspace.surfaceIdFromPanelId(surfaceId) {
            if force {
                return workspace.requestNonInteractiveCloseTabRecordingHistory(tabId)
            }
            return workspace.requestCloseTabRecordingHistory(tabId, force: force)
        }

        workspace.markCloseHistoryEligible(panelId: surfaceId)
        return workspace.closePanel(surfaceId, force: force)
    }

    func v2ResolveWorkspace(params: [String: Any], tabManager: TabManager) -> Workspace? {
        if let wsId = v2UUID(params, "workspace_id") {
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = v2UUID(params, "surface_id")
            ?? v2UUID(params, "terminal_id")
            ?? v2UUID(params, "tab_id") {
            return tabManager.tabs.first(where: {
                $0.panels[surfaceId] != nil
            })
        }
        if let paneId = v2UUID(params, "pane_id"),
           let located = v2LocatePane(paneId) {
            guard located.tabManager === tabManager else { return nil }
            return located.workspace
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }

    @MainActor

    private func v2AgentSessionOptions(params: [String: Any]) -> (
        providerID: AgentSessionProviderID,
        rendererKind: AgentSessionRendererKind,
        error: V2CallResult?
    ) {
        let providerRaw = v2String(params, "provider_id") ?? v2String(params, "provider")
        let rendererRaw = v2String(params, "renderer_kind") ?? v2String(params, "renderer")

        let providerID: AgentSessionProviderID
        if let providerRaw {
            switch v2NormalizedToken(providerRaw) {
            case "codex":
                providerID = .codex
            case "claude", "claudecode":
                providerID = .claude
            case "opencode":
                providerID = .opencode
            default:
                return (
                    .codex,
                    .react,
                    .err(
                        code: "invalid_params",
                        message: "Invalid provider (codex|claude|opencode)",
                        data: ["provider": providerRaw]
                    )
                )
            }
        } else {
            providerID = .codex
        }

        let rendererKind: AgentSessionRendererKind
        if let rendererRaw {
            switch v2NormalizedToken(rendererRaw) {
            case "react":
                rendererKind = .react
            case "solid":
                rendererKind = .solid
            default:
                return (
                    providerID,
                    .react,
                    .err(
                        code: "invalid_params",
                        message: "Invalid renderer (react|solid)",
                        data: ["renderer": rendererRaw]
                    )
                )
            }
        } else {
            rendererKind = .react
        }

        return (providerID, rendererKind, nil)
    }

    func v2DebugTerminals(params _: [String: Any]) -> V2CallResult {
        var payload: [String: Any]?

        v2MainSync {
            guard let app = AppDelegate.shared else { return }

            struct MappedTerminalLocation {
                let windowIndex: Int
                let windowId: UUID
                let window: NSWindow?
                let workspaceIndex: Int
                let workspaceSelected: Bool
                let workspace: Workspace
                let terminalPanel: TerminalPanel
                let paneId: PaneID?
                let paneIndex: Int?
                let surfaceIndex: Int
                let selectedInPane: Bool?
                let bonsplitTabId: TabID?
            }

            func nonEmpty(_ raw: String?) -> String? {
                guard let raw else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }

            func rectPayload(_ rect: CGRect) -> [String: Double] {
                [
                    "x": Double(rect.origin.x),
                    "y": Double(rect.origin.y),
                    "width": Double(rect.size.width),
                    "height": Double(rect.size.height)
                ]
            }

            func objectPointerString(_ object: AnyObject?) -> String {
                guard let object else { return "nil" }
                return String(describing: Unmanaged.passUnretained(object).toOpaque())
            }

            func ghosttyPointerString(_ surface: ghostty_surface_t?) -> String {
                guard let surface else { return "nil" }
                return String(describing: surface)
            }

            func className(_ object: AnyObject?) -> String? {
                guard let object else { return nil }
                return String(describing: type(of: object))
            }

            let iso8601Formatter = ISO8601DateFormatter()
            let now = Date()

            func iso8601String(_ date: Date?) -> String? {
                guard let date else { return nil }
                return iso8601Formatter.string(from: date)
            }

            func ageSeconds(since date: Date?) -> Double? {
                guard let date else { return nil }
                return (now.timeIntervalSince(date) * 1000).rounded() / 1000
            }

            @MainActor
            func superviewClassChain(for view: NSView, limit: Int = 8) -> [String] {
                var chain: [String] = [String(describing: type(of: view))]
                var currentSuperview = view.superview
                while chain.count < limit, let nextSuperview = currentSuperview {
                    chain.append(String(describing: type(of: nextSuperview)))
                    currentSuperview = nextSuperview.superview
                }
                if currentSuperview != nil {
                    chain.append("...")
                }
                return chain
            }
            let windows = app.scriptableMainWindows()
            let windowIndexById = Dictionary(
                uniqueKeysWithValues: windows.enumerated().map { ($0.element.windowId, $0.offset) }
            )
            @MainActor
            func resolvedWindowMetadata(for window: NSWindow?) -> (windowId: UUID?, windowIndex: Int?) {
                guard let window else { return (nil, nil) }
                if let match = windows.enumerated().first(where: { _, state in
                    guard let stateWindow = state.window else { return false }
                    return stateWindow === window || stateWindow.windowNumber == window.windowNumber
                }) {
                    return (match.element.windowId, match.offset)
                }
                guard let raw = window.identifier?.rawValue else { return (nil, nil) }
                let prefix = "cmux.main."
                guard raw.hasPrefix(prefix),
                      let parsedWindowId = UUID(uuidString: String(raw.dropFirst(prefix.count))) else {
                    return (nil, nil)
                }
                return (parsedWindowId, windowIndexById[parsedWindowId])
            }

            var mappedLocations: [ObjectIdentifier: MappedTerminalLocation] = [:]
            for (windowIndex, state) in windows.enumerated() {
                let tabManager = state.tabManager
                for (workspaceIndex, workspace) in tabManager.tabs.enumerated() {
                    let paneIndexById = Dictionary(
                        uniqueKeysWithValues: workspace.bonsplitController.allPaneIds.enumerated().map {
                            ($0.element.id, $0.offset)
                        }
                    )
                    var selectedInPaneByPanelId: [UUID: Bool] = [:]
                    for paneId in workspace.bonsplitController.allPaneIds {
                        let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
                        for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                            guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                            selectedInPaneByPanelId[panelId] = (tab.id == selectedTab?.id)
                        }
                    }

                    for (surfaceIndex, panel) in orderedPanels(in: workspace).enumerated() {
                        guard let terminalPanel = panel as? TerminalPanel else { continue }
                        mappedLocations[ObjectIdentifier(terminalPanel.surface)] = MappedTerminalLocation(
                            windowIndex: windowIndex,
                            windowId: state.windowId,
                            window: state.window,
                            workspaceIndex: workspaceIndex,
                            workspaceSelected: workspace.id == tabManager.selectedTabId,
                            workspace: workspace,
                            terminalPanel: terminalPanel,
                            paneId: workspace.paneId(forPanelId: terminalPanel.id),
                            paneIndex: workspace.paneId(forPanelId: terminalPanel.id).flatMap { paneIndexById[$0.id] },
                            surfaceIndex: surfaceIndex,
                            selectedInPane: selectedInPaneByPanelId[terminalPanel.id],
                            bonsplitTabId: workspace.surfaceIdFromPanelId(terminalPanel.id)
                        )
                    }
                }
            }

            let surfaces = GhosttyApp.terminalSurfaceRegistry.allTerminalSurfaces()
            let terminals: [[String: Any]] = surfaces.enumerated().map { index, terminalSurface in
                let mapped = mappedLocations[ObjectIdentifier(terminalSurface)]
                let hostedView = terminalSurface.hostedView
                let hostedWindow = mapped?.window ?? terminalSurface.uiWindow
                let fallbackWindowMetadata = resolvedWindowMetadata(for: hostedWindow)
                let resolvedWindowId = mapped?.windowId ?? fallbackWindowMetadata.windowId
                let resolvedWindowIndex = mapped?.windowIndex ?? fallbackWindowMetadata.windowIndex
                let workspace = mapped?.workspace
                let panelId = mapped?.terminalPanel.id ?? terminalSurface.id
                let portalState = hostedView.portalBindingGuardState()
                let portalHostLease = terminalSurface.debugPortalHostLease()
                let gitBranchState: SidebarGitBranchState? = nil
                let listeningPorts = (workspace?.surfaceListeningPorts[panelId] ?? []).sorted()
                let title = workspace?.panelTitle(panelId: panelId)
                let paneId = mapped?.paneId
                let treeVisible = mapped?.bonsplitTabId != nil && paneId != nil
                let ttyName = workspace?.surfaceTTYNames[panelId]
                let currentDirectory = workspace.map { $0.effectivePanelDirectory(panelId: panelId, localFallback: nonEmpty(mapped?.terminalPanel.directory)) } ?? nonEmpty(mapped?.terminalPanel.directory)
                let requestedWorkingDirectory = workspace?.allowsLocalDirectoryFallback(panelId: panelId) == false ? nil : nonEmpty(terminalSurface.requestedWorkingDirectory)
                let teardownRequest = terminalSurface.debugTeardownRequest()
                let lastKnownWorkspaceId = terminalSurface.debugLastKnownWorkspaceId()
                var item: [String: Any] = [
                    "index": index,
                    "mapped": mapped != nil,
                    "tree_visible": treeVisible,
                    "window_index": v2OrNull(resolvedWindowIndex),
                    "window_id": v2OrNull(resolvedWindowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: resolvedWindowId),
                    "window_number": v2OrNull(hostedWindow?.windowNumber),
                    "window_key": hostedWindow?.isKeyWindow ?? false,
                    "window_main": hostedWindow?.isMainWindow ?? false,
                    "window_visible": hostedWindow?.isVisible ?? false,
                    "window_occluded": hostedWindow.map { !$0.occlusionState.contains(.visible) } ?? false,
                    "renderer_realized": terminalSurface.isRendererRealized,
                    "renderer_presented": terminalSurface.isRendererPresented,
                    "render_health": terminalSurface.renderHealth.rawValue,
                    "renderer_portal_visible": terminalSurface.isRendererPortalVisible,
                    "renderer_window_visible": terminalSurface.rendererWindowVisible,
                    "window_identifier": v2OrNull(hostedWindow?.identifier?.rawValue),
                    "window_title": v2OrNull(nonEmpty(hostedWindow?.title)),
                    "window_class": v2OrNull(className(hostedWindow)),
                    "window_delegate_class": v2OrNull(className(hostedWindow?.delegate as AnyObject?)),
                    "window_controller_class": v2OrNull(className(hostedWindow?.windowController)),
                    "window_level": v2OrNull(hostedWindow?.level.rawValue),
                    "window_frame": hostedWindow.map { rectPayload($0.frame) } ?? NSNull(),
                    "workspace_index": v2OrNull(mapped?.workspaceIndex),
                    "workspace_id": v2OrNull(workspace?.id.uuidString),
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspace?.id),
                    "workspace_title": v2OrNull(workspace?.title),
                    "workspace_selected": v2OrNull(mapped?.workspaceSelected),
                    "pane_index": v2OrNull(mapped?.paneIndex),
                    "pane_id": v2OrNull(paneId?.id.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneId?.id),
                    "surface_index": v2OrNull(mapped?.surfaceIndex),
                    "surface_index_in_pane": v2OrNull(workspace?.indexInPane(forPanelId: panelId)),
                    "surface_id": panelId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: panelId),
                    "surface_title": v2OrNull(title),
                    "surface_focused": v2OrNull(workspace.map { panelId == $0.focusedPanelId }),
                    "surface_selected_in_pane": v2OrNull(mapped?.selectedInPane),
                    "surface_pinned": v2OrNull(workspace.map { $0.isPanelPinned(panelId) }),
                    "surface_context": terminalSurface.debugSurfaceContextLabel(),
                    "surface_created_at": v2OrNull(iso8601String(terminalSurface.debugCreatedAt())),
                    "surface_age_seconds": v2OrNull(ageSeconds(since: terminalSurface.debugCreatedAt())),
                    "runtime_surface_created_at": v2OrNull(iso8601String(terminalSurface.debugRuntimeSurfaceCreatedAt())),
                    "runtime_surface_age_seconds": v2OrNull(ageSeconds(since: terminalSurface.debugRuntimeSurfaceCreatedAt())),
                    "bonsplit_tab_id": v2OrNull(mapped?.bonsplitTabId?.uuid.uuidString),
                    "terminal_object_ptr": objectPointerString(terminalSurface),
                    "ghostty_surface_ptr": ghosttyPointerString(terminalSurface.surface),
                    "runtime_surface_ready": terminalSurface.surface != nil,
                    "hosted_view_ptr": objectPointerString(hostedView),
                    "hosted_view_class": className(hostedView) ?? "nil",
                    "hosted_view_in_window": terminalSurface.isViewInWindow,
                    "hosted_view_in_headless_bootstrap_window": terminalSurface.isHeadlessStartupWindow(hostedView.window),
                    "hosted_view_has_superview": hostedView.superview != nil,
                    "hosted_view_hidden": hostedView.isHidden,
                    "hosted_view_hidden_or_ancestor_hidden": hostedView.isHiddenOrHasHiddenAncestor,
                    "hosted_view_alpha": hostedView.alphaValue,
                    "hosted_view_visible_in_ui": hostedView.debugPortalVisibleInUI,
                    "hosted_view_superview_chain": superviewClassChain(for: hostedView),
                    "surface_view_first_responder": hostedView.isSurfaceViewFirstResponder(),
                    "hosted_view_frame": rectPayload(hostedView.frame),
                    "hosted_view_bounds": rectPayload(hostedView.bounds),
                    "hosted_view_frame_in_window": rectPayload(hostedView.debugPortalFrameInWindow),
                    "portal_binding_state": portalState.state,
                    "portal_binding_generation": v2OrNull(portalState.generation),
                    "portal_host_id": v2OrNull(portalHostLease.hostId),
                    "portal_host_in_window": v2OrNull(portalHostLease.inWindow),
                    "portal_host_area": v2OrNull(portalHostLease.area.map(Double.init)),
                    "tty": v2OrNull(ttyName),
                    "current_directory": v2OrNull(currentDirectory),
                    "requested_working_directory": v2OrNull(requestedWorkingDirectory),
                    "initial_command": v2OrNull(nonEmpty(terminalSurface.debugInitialCommand())),
                    "tmux_start_command": v2OrNull(nonEmpty(terminalSurface.debugTmuxStartCommand())),
                    "git_branch": v2OrNull(nonEmpty(gitBranchState?.branch)),
                    "git_dirty": v2OrNull(gitBranchState?.isDirty),
                    "listening_ports": listeningPorts,
                    "key_state_indicator": v2OrNull(nonEmpty(terminalSurface.currentKeyStateIndicatorText)),
                    "last_known_workspace_id": lastKnownWorkspaceId.uuidString,
                    "last_known_workspace_ref": v2Ref(kind: .workspace, uuid: lastKnownWorkspaceId),
                    "teardown_requested": teardownRequest.requestedAt != nil,
                    "teardown_requested_at": v2OrNull(iso8601String(teardownRequest.requestedAt)),
                    "teardown_requested_age_seconds": v2OrNull(ageSeconds(since: teardownRequest.requestedAt)),
                    "teardown_requested_reason": v2OrNull(nonEmpty(teardownRequest.reason))
                ]

                if title == nil, let fallbackTitle = mapped?.terminalPanel.displayTitle, !fallbackTitle.isEmpty {
                    item["surface_title"] = fallbackTitle
                }
                return item
            }

            payload = [
                "count": terminals.count,
                "terminals": terminals
            ]
        }

        guard let payload else {
            return .err(code: "unavailable", message: "AppDelegate not available", data: nil)
        }
        return .ok(payload)
    }

    struct TerminalTextRawSnapshot {
        var viewport: String?
        var screen: String?
        var history: String?
        var active: String?
    }

    struct TerminalTextPayload: Equatable {
        let text: String
        let base64: String
    }

    struct TerminalTextPayloadError: Error, Equatable {
        let message: String
    }

    nonisolated static func terminalTextPayload(
        from snapshot: TerminalTextRawSnapshot,
        includeScrollback: Bool,
        lineLimit: Int?
    ) -> Result<TerminalTextPayload, TerminalTextPayloadError> {
        let output: String
        if includeScrollback {
            var candidates: [String] = []
            if let screen = snapshot.screen {
                candidates.append(lineLimit.map { Self.tailTerminalLines(screen, maxLines: $0) } ?? screen)
            }
            if snapshot.history != nil || snapshot.active != nil {
                var merged = lineLimit.map {
                    Self.tailTerminalLines(snapshot.history ?? "", maxLines: $0)
                } ?? (snapshot.history ?? "")
                if let active = snapshot.active {
                    if !merged.isEmpty, !merged.hasSuffix("\n"), !active.isEmpty {
                        merged.append("\n")
                    }
                    merged.append(lineLimit.map { Self.tailTerminalLines(active, maxLines: $0) } ?? active)
                }
                candidates.append(lineLimit.map { Self.tailTerminalLines(merged, maxLines: $0) } ?? merged)
            }

            guard let best = candidates.max(by: { lhs, rhs in
                let left = terminalTextCandidateScore(lhs)
                let right = terminalTextCandidateScore(rhs)
                if left.lines != right.lines {
                    return left.lines < right.lines
                }
                return left.bytes < right.bytes
            }) else {
                return .failure(TerminalTextPayloadError(message: "Failed to read terminal text"))
            }
            output = best
        } else {
            guard var viewport = snapshot.viewport else {
                return .failure(TerminalTextPayloadError(message: "Failed to read terminal text"))
            }
            if let lineLimit {
                viewport = Self.tailTerminalLines(viewport, maxLines: lineLimit)
            }
            output = viewport
        }

        let base64 = output.data(using: .utf8)?.base64EncodedString() ?? ""
        return .success(TerminalTextPayload(text: output, base64: base64))
    }

    nonisolated private static func terminalTextCandidateScore(_ text: String) -> (lines: Int, bytes: Int) {
        if text.isEmpty { return (0, 0) }
        var newlineCount = 0
        var byteCount = 0
        for byte in text.utf8 {
            byteCount += 1
            if byte == 0x0A {
                newlineCount += 1
            }
        }
        return (newlineCount + 1, byteCount)
    }

    private struct ReadTextCapture {
        let rawSnapshot: TerminalTextRawSnapshot
        let workspaceID: UUID
        let surfaceID: UUID
        let windowID: UUID?
        let workspaceRef: Any
        let surfaceRef: Any
        let windowRef: Any
    }

    private enum ReadTextCaptureOutcome {
        /// An error fully resolved on the main actor (its message and `data`
        /// need no off-main formatting), returned verbatim.
        case finished(V2CallResult)
        /// The raw Ghostty text and identity; the caller formats it off-main.
        case captured(ReadTextCapture)
        /// The target terminal had no live surface and a start is pending;
        /// the caller waits off-main and retries.
        case surfaceStarting
    }

    /// A terminal in a workspace that was never shown has no libghostty
    /// surface until something starts it (#1472). Socket reads start it and
    /// wait this long for it before reporting the terminal as unreadable.
    private nonisolated static let readTextSurfaceStartWait: TimeInterval = 2.0

    /// Starts a cold terminal for a socket read. Returns true while the read
    /// should release the main actor and retry.
    private func readTextAwaitsSurfaceStart(_ surface: TerminalSurface, deadline: Date) -> Bool {
        guard surface.liveSurfaceForGhosttyAccess(reason: "socket.readTerminalText.start") == nil else {
            return false
        }
        // A restore awaiting admission starts by itself once cmux knows which
        // agent session to resume, so wait for it. Hibernated and closing
        // terminals never start without outside action; report them now.
        if surface.runtimeUnavailableReason == .awaitingRestore {
            return Date() < deadline
        }
        guard surface.canCreateRuntimeSurface else { return false }
        // A read waits on the result, so it is input demand like socket
        // send_text, not restore-paced background priming.
        surface.requestInputDemandSurfaceStartIfNeeded()
        return Date() < deadline
    }

    /// Runs `body` on the main actor until it stops reporting a pending
    /// surface start, sleeping on the calling worker thread between tries.
    private nonisolated func v2MainSyncAwaitingSurfaceStart<Outcome>(
        isStarting: (Outcome) -> Bool,
        _ body: @MainActor (Date) -> Outcome
    ) -> Outcome {
        // On the main thread the start task cannot run while we wait, so
        // request it and read once.
        let deadline = Thread.isMainThread
            ? Date.distantPast
            : Date().addingTimeInterval(Self.readTextSurfaceStartWait)
        while true {
            let outcome = v2MainSync { body(deadline) }
            guard isStarting(outcome) else { return outcome }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// The `surface.read_text` reply for a resolved terminal with no live
    /// runtime surface to read from. `data.reason` names the cause, and
    /// `data.wake_command` is present when a command can make it readable.
    nonisolated static func readTextTerminalNotRunningResult(
        workspaceID: UUID?,
        surfaceID: UUID?,
        reason: TerminalSurfaceRuntimeUnavailableReason
    ) -> V2CallResult {
        let wakeCommand: String? = if reason == .hibernated,
            let workspaceID,
            let surfaceID {
            terminalWakeCommand(workspaceID: workspaceID, surfaceID: surfaceID)
        } else {
            nil
        }
        var data: [String: Any] = ["reason": reason.rawValue]
        if let workspaceID { data["workspace_id"] = workspaceID.uuidString }
        if let surfaceID { data["surface_id"] = surfaceID.uuidString }
        if let wakeCommand { data["wake_command"] = wakeCommand }
        return .err(
            code: "surface_unavailable",
            message: terminalNotRunningMessage(reason: reason, wakeCommand: wakeCommand),
            data: data
        )
    }

    /// `surface.read_text` worker body (issue #5757). The former
    /// `ControlCommandCoordinator.surfaceReadText` ran the whole read — including
    /// the full-scrollback line tailing, candidate scoring, and base64 encoding —
    /// on the main actor, so under heavy agent load one large scrollback read
    /// stalled the run loop and serialized every other client behind it.
    ///
    /// This splits the work: only the routing resolution and the Ghostty FFI
    /// capture take a (minimal) `v2MainSync` hop; the expensive
    /// `terminalTextPayload` formatting runs here on the socket-worker thread.
    /// The response shape, error codes, error-evaluation order (TabManager
    /// availability before the `lines` validation), and routing precedence —
    /// including the global-dock branch the witness grew after the original
    /// prototype — are byte-faithful to the coordinator witness this replaces.
    private nonisolated func v2SurfaceReadText(params: [String: Any]) -> V2CallResult {
        var includeScrollback = v2Bool(params, "scrollback") ?? false
        let lineLimit = v2Int(params, "lines")
        if lineLimit != nil {
            includeScrollback = true
        }

        // Main-actor critical section: resolve the target and read the raw
        // Ghostty text. Everything after this hop runs off the main actor.
        let outcome: ReadTextCaptureOutcome = v2MainSyncAwaitingSurfaceStart(isStarting: {
            if case .surfaceStarting = $0 { return true }
            return false
        }) { surfaceStartDeadline in
            // Mint refs for current topology so caller-supplied `kind:N` refs
            // resolve, exactly as the former main-actor dispatch did before
            // handing off to the coordinator.
            self.v2RefreshKnownRefs()
            let routing = ControlRoutingSelectors(
                hasWindowIDParam: self.v2HasNonNullParam(params, "window_id"),
                windowID: self.v2UUID(params, "window_id"),
                groupID: self.v2UUID(params, "group_id"),
                workspaceID: self.v2UUID(params, "workspace_id"),
                surfaceID: self.v2UUID(params, "surface_id")
                    ?? self.v2UUID(params, "terminal_id")
                    ?? self.v2UUID(params, "tab_id"),
                paneID: self.v2UUID(params, "pane_id"),
                remoteRelayOwnerWorkspaceID: nil
            )
            guard let tabManager = self.resolveTabManager(routing: routing) else {
                return .finished(.err(code: "unavailable", message: "TabManager not available", data: nil))
            }
            if let lineLimit, lineLimit <= 0 {
                return .finished(.err(code: "invalid_params", message: "lines must be greater than 0", data: nil))
            }
            // Consume the same terminal alias that the relay policy validates.
            let explicitSurfaceID = self.v2UUID(params, "surface_id") ?? self.v2UUID(params, "terminal_id")
            let hasSurfaceIDParam = params["surface_id"] != nil || params["terminal_id"] != nil
            let workspaceID: UUID
            let surfaceId: UUID
            let terminalSurface: TerminalSurface
            // Per-window docks (the former single global dock): the window id
            // resolves from the dock itself in the dock branch, from the
            // routed TabManager otherwise — mirroring the coordinator
            // witnesses' post-#7144 shape.
            let resolvedWindowID: UUID?
            if let dock = self.windowDockForRouting(routing, tabManager: tabManager) {
                let target = self.terminalPanel(
                    in: dock,
                    explicitSurfaceID: explicitSurfaceID,
                    hasSurfaceIDParam: hasSurfaceIDParam,
                    routing: routing
                )
                if target.invalidSurfaceID {
                    return .finished(.err(code: "not_found", message: "Surface not found for the given surface_id", data: nil))
                }
                guard let dockSurfaceId = target.surfaceID else {
                    return .finished(.err(code: "not_found", message: "No focused surface", data: nil))
                }
                guard target.terminalPanel != nil else {
                    return .finished(.err(
                        code: "invalid_params",
                        message: "Surface is not a terminal",
                        data: ["surface_id": dockSurfaceId.uuidString]
                    ))
                }
                guard self.remoteRelayDockTargetIsCurrent(
                    routing: routing,
                    dock: dock,
                    surfaceID: dockSurfaceId
                ) else {
                    return .finished(.err(
                        code: "not_found",
                        message: self.controlSurfaceNotFoundMessage(),
                        data: nil
                    ))
                }
                guard let terminalTarget = dock.controlSocketTerminalTarget(for: dockSurfaceId) else {
                    return .finished(.err(
                        code: "surface_unavailable",
                        message: Self.terminalSurfaceUnavailableMessage,
                        data: ["surface_id": dockSurfaceId.uuidString]
                    ))
                }
                workspaceID = dock.workspaceId
                surfaceId = dockSurfaceId
                terminalSurface = terminalTarget.surface
                resolvedWindowID = self.dockResultWindowId(for: dock, tabManager: tabManager)
            } else {
                guard let ws = self.resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
                    return .finished(.err(code: "not_found", message: "Workspace not found", data: nil))
                }
                if hasSurfaceIDParam {
                    guard let id = explicitSurfaceID else {
                        return .finished(.err(code: "not_found", message: "Surface not found for the given surface_id", data: nil))
                    }
                    guard ws.controlTerminalTarget(for: id) != nil else {
                        return .finished(.err(
                            code: "invalid_params",
                            message: "Surface is not a terminal",
                            data: ["surface_id": id.uuidString]
                        ))
                    }
                    guard self.remoteRelayTargetIsCurrent(
                        routing: routing,
                        workspace: ws,
                        surfaceID: id
                    ) else {
                        return .finished(.err(
                            code: "not_found",
                            message: "Surface not found for the given surface_id",
                            data: nil
                        ))
                    }
                    guard let target = ws.controlSocketTerminalTarget(for: id) else {
                        return .finished(.err(
                            code: "surface_unavailable",
                            message: Self.terminalSurfaceUnavailableMessage,
                            data: ["surface_id": id.uuidString]
                        ))
                    }
                    surfaceId = target.surfaceID
                    terminalSurface = target.surface
                } else {
                    guard let focused = ws.controlDefaultTerminalTarget(paneID: routing.paneID) else {
                        return .finished(.err(code: "not_found", message: "No focused surface", data: nil))
                    }
                    guard let target = ws.controlSocketTerminalTarget(for: focused) else {
                        return .finished(.err(
                            code: "surface_unavailable",
                            message: Self.terminalSurfaceUnavailableMessage,
                            data: ["surface_id": focused.surfaceID.uuidString]
                        ))
                    }
                    surfaceId = focused.surfaceID
                    terminalSurface = target.surface
                    guard self.remoteRelayTargetIsCurrent(
                        routing: routing,
                        workspace: ws,
                        surfaceID: surfaceId
                    ) else {
                        return .finished(.err(
                            code: "not_found",
                            message: "No focused surface",
                            data: nil
                        ))
                    }
                }
                workspaceID = ws.id
                resolvedWindowID = self.v2ResolveWindowId(tabManager: tabManager)
            }
            if self.readTextAwaitsSurfaceStart(terminalSurface, deadline: surfaceStartDeadline) {
                return .surfaceStarting
            }
            guard let rawSnapshot = self.readTerminalTextRawSnapshot(
                terminalSurface: terminalSurface,
                includeScrollback: includeScrollback
            ) else {
                // No live runtime: the terminal is hibernated, awaiting
                // restore admission, or did not start before the deadline.
                // That is surface state, not a server failure.
                return .finished(Self.readTextTerminalNotRunningResult(
                    workspaceID: workspaceID,
                    surfaceID: surfaceId,
                    reason: terminalSurface.runtimeUnavailableReason
                ))
            }
            // `terminalTextPayload`'s only failure predicate is snapshot shape
            // (O(1)), so reject here and mint refs only when a success reply is
            // guaranteed. The legacy build minted nothing on this error path,
            // and dock owner/surface ids are first-minted by the mint pass
            // below (NOT by the refresh above, which walks only main-window
            // workspace topology) — an error-path mint would shift `kind:N`
            // ordinals for every later reply on this instance.
            let payloadIsFormattable = includeScrollback
                ? (rawSnapshot.screen != nil || rawSnapshot.history != nil || rawSnapshot.active != nil)
                : rawSnapshot.viewport != nil
            guard payloadIsFormattable else {
                return .finished(.err(code: "internal_error", message: "Failed to read terminal text", data: nil))
            }
            let windowID = resolvedWindowID
            // Refs mint in the success payload's literal order (workspace,
            // surface, window). Workspace-hosted ids were pre-minted by the
            // refresh; dock-hosted ids are first-minted right here, so this
            // mint pass MUST keep the payload's literal order for ordinal
            // parity with the legacy build.
            return .captured(ReadTextCapture(
                rawSnapshot: rawSnapshot,
                workspaceID: workspaceID,
                surfaceID: surfaceId,
                windowID: windowID,
                workspaceRef: self.v2Ref(kind: .workspace, uuid: workspaceID),
                surfaceRef: self.v2Ref(kind: .surface, uuid: surfaceId),
                windowRef: self.v2Ref(kind: .window, uuid: windowID)
            ))
        }

        switch outcome {
        case let .finished(result):
            return result
        case .surfaceStarting:
            // v2MainSyncAwaitingSurfaceStart never returns this case.
            return Self.readTextTerminalNotRunningResult(
                workspaceID: nil,
                surfaceID: nil,
                reason: .starting
            )
        case let .captured(capture):
            // The full-scrollback formatting stays off the main actor.
            switch Self.terminalTextPayload(
                from: capture.rawSnapshot,
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            ) {
            case .success(let payload):
                return .ok([
                    "text": payload.text,
                    "base64": payload.base64,
                    "workspace_id": capture.workspaceID.uuidString,
                    "workspace_ref": capture.workspaceRef,
                    "surface_id": capture.surfaceID.uuidString,
                    "surface_ref": capture.surfaceRef,
                    "window_id": v2OrNull(capture.windowID?.uuidString),
                    "window_ref": capture.windowRef,
                ])
            case .failure(let error):
                return .err(code: "internal_error", message: error.message, data: nil)
            }
        }
    }

    private func readTerminalTextFromVTExportForSnapshot(
        terminalPanel: TerminalPanel? = nil,
        terminalTarget: ControlTerminalSocketTarget? = nil,
        bindingAction: String = "write_screen_file:copy,vt",
        lineLimit: Int?,
        normalizeLineEndings: Bool = true
    ) -> String? {
        guard terminalPanel != nil || terminalTarget != nil else { return nil }

        // Session persistence already caps the capture by rows and characters.
        // Use Ghostty's bounded formatter so quit does not format an
        // unbounded history and discard most of it afterward. Keep the export
        // path as a compatibility fallback for runtimes that reject the
        // bounded request.
        if let lineLimit,
           lineLimit > 0,
           let surface = terminalPanel?.surface ?? terminalTarget?.surface,
           let boundedOutput = surface.readBoundedScreenTailVT(
               maxRows: lineLimit,
               maxBytes: SessionPersistencePolicy.maxScrollbackCharactersPerTerminal * 4
           ) {
#if DEBUG
            cmuxDebugLog(
                "session.scrollbackCapture bounded=1 rows=\(lineLimit)"
            )
#endif
            return normalizeLineEndings
                ? Self.normalizedMobileVTExportText(boundedOutput)
                : boundedOutput
        }

        var actionSucceeded = false
        let exportedPath = GhosttyApp.terminalPasteboard.captureNextStandardClipboardWrite {
            let ok = terminalTarget?.performInternalBindingAction(bindingAction)
                ?? terminalPanel?.performInternalBindingAction(bindingAction)
                ?? false
            actionSucceeded = ok
            return ok
        }
        #if DEBUG
        cmuxDebugLog("mobile.vtExport action=\(bindingAction) succeeded=\(actionSucceeded) hasPath=\(exportedPath != nil)")
        #endif
        guard let exportedPath = Self.normalizedExportedScreenPath(exportedPath) else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: exportedPath)
        defer {
            if Self.shouldRemoveExportedScreenFile(fileURL: fileURL) {
                try? FileManager.default.removeItem(at: fileURL)
                if Self.shouldRemoveExportedScreenDirectory(fileURL: fileURL) {
                    try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
                }
            }
        }

        guard let data = try? Data(contentsOf: fileURL),
              let rawOutput = String(data: data, encoding: .utf8) else {
            return nil
        }
        var output = normalizeLineEndings
            ? Self.normalizedMobileVTExportText(rawOutput)
            : rawOutput
        if let lineLimit {
            output = Self.tailTerminalLines(output, maxLines: lineLimit)
        }
        return output
    }

    private func readPlainTerminalTextForSnapshot(
        terminalPanel: TerminalPanel? = nil,
        terminalTarget: ControlTerminalSocketTarget? = nil,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String? {
        let response: String
        if let terminalTarget {
            response = readTerminalTextBase64(
                terminalSurface: terminalTarget.surface,
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
        } else if let terminalPanel {
            response = readTerminalTextBase64(
                terminalPanel: terminalPanel,
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
        } else {
            return nil
        }
        guard response.hasPrefix("OK ") else { return nil }
        let base64 = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if base64.isEmpty {
            return ""
        }
        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }

    func readTerminalTextForSnapshot(
        terminalPanel: TerminalPanel? = nil,
        terminalTarget: ControlTerminalSocketTarget? = nil,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil,
        allowVTExport: Bool = true
    ) -> String? {
        guard terminalPanel != nil || terminalTarget != nil else { return nil }
        if includeScrollback,
           allowVTExport,
           let vtOutput = readTerminalTextFromVTExportForSnapshot(
               terminalPanel: terminalPanel,
               terminalTarget: terminalTarget,
               lineLimit: lineLimit
           ) {
            return vtOutput
        }

        return readPlainTerminalTextForSnapshot(
            terminalPanel: terminalPanel,
            terminalTarget: terminalTarget,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
    }

    func readTerminalTextForHibernationFingerprint(
        terminalPanel: TerminalPanel,
        lineLimit: Int
    ) -> String? {
        // This runs from the periodic hibernation timer. Sample the visible tail
        // only, rather than copying full scrollback every cycle.
        readTerminalTextForSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: false,
            lineLimit: lineLimit,
            allowVTExport: false
        )
    }

    func readTerminalTextForSessionSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String? {
        readTerminalTextForSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
    }

    private nonisolated func v2FeedbackSubmit(params: [String: Any]) -> V2CallResult {
        guard let email = params["email"] as? String else {
            return .err(code: "invalid_params", message: "Missing email", data: ["field": "email"])
        }
        guard let body = params["body"] as? String else {
            return .err(code: "invalid_params", message: "Missing body", data: ["field": "body"])
        }
        let imagePaths = params["image_paths"] as? [String] ?? []

        let semaphore = DispatchSemaphore(value: 0)
        var result: V2CallResult = .err(code: "internal_error", message: "Feedback submission failed", data: nil)

        Task {
            let resolved: V2CallResult
            do {
                let attachmentCount = try await FeedbackComposerBridge().submit(
                    email: email,
                    message: body,
                    imagePaths: imagePaths
                )
                resolved = .ok([
                    "submitted": true,
                    "attachment_count": attachmentCount,
                ])
            } catch let error as FeedbackComposerBridgeError {
                let code: String
                switch error {
                case .invalidEmail, .emptyMessage, .messageTooLong, .tooManyImages, .invalidImagePath:
                    code = "invalid_params"
                case .submissionFailed:
                    code = "request_failed"
                }
                resolved = .err(code: code, message: error.localizedDescription, data: nil)
            } catch {
                resolved = .err(code: "internal_error", message: error.localizedDescription, data: nil)
            }

            result = resolved
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 35) == .timedOut {
            return .err(code: "timeout", message: "Feedback submission timed out", data: nil)
        }

        return result
    }

    // MARK: - V2 Feed (workstream) handlers

    private nonisolated func v2FeedPush(
        params: [String: Any],
        requiresIngestionAcknowledgment: Bool,
        automationOrigin: CmuxAutomationEventOrigin? = nil
    ) -> V2CallResult {
        let waitTimeout: TimeInterval
        if let rawTimeout = params["wait_timeout_seconds"] {
            let seconds: Double?
            if let number = rawTimeout as? NSNumber {
                seconds = number.doubleValue
            } else if let value = rawTimeout as? Double {
                seconds = value
            } else if let value = rawTimeout as? Int {
                seconds = Double(value)
            } else {
                seconds = nil
            }
            guard let seconds else {
                return .err(
                    code: "invalid_params",
                    message: "feed.push wait_timeout_seconds must be numeric",
                    data: nil
                )
            }
            guard seconds.isFinite, seconds >= 0, seconds <= 120 else {
                return .err(
                    code: "invalid_params",
                    message: "feed.push wait_timeout_seconds must be between 0 and 120",
                    data: nil
                )
            }
            waitTimeout = seconds
        } else {
            waitTimeout = 0
        }
        guard params["event"] == nil || params["events"] == nil else {
            return .err(
                code: "invalid_params",
                message: v2FeedPushExclusiveEventShapeMessage(),
                data: nil
            )
        }
        let isBatch = params["events"] != nil
        let eventDicts: [[String: Any]]
        if let nested = params["event"] as? [String: Any] {
            eventDicts = [nested]
        } else if let nested = params["events"] as? [[String: Any]],
                  !nested.isEmpty,
                  nested.count <= 64 {
            eventDicts = nested
        } else if params["session_id"] != nil,
                  params["hook_event_name"] != nil,
                  params["_source"] != nil {
            eventDicts = [params]
        } else {
            return .err(
                code: "invalid_params",
                message: v2FeedPushRequiresEventMessage(),
                data: nil
            )
        }

        let events: [WorkstreamEvent]
        do {
            events = try eventDicts.map {
                let data = try JSONSerialization.data(withJSONObject: $0)
                return try JSONDecoder().decode(WorkstreamEvent.self, from: data)
            }
        } catch {
            return .err(
                code: "invalid_params",
                message: v2FeedPushDecodeFailedMessage(error),
                data: nil
            )
        }
        guard !isBatch || events.allSatisfy({
            $0.source == "pi"
                && $0.hookEventName == .postToolUse
                && $0.requestId != nil
                && $0.surfaceId != nil
        }) else {
            return .err(
                code: "invalid_params",
                message: v2FeedPushRequiresEventMessage(),
                data: nil
            )
        }
        if requiresIngestionAcknowledgment && waitTimeout == 0 {
            return v2IngestAcknowledgedFeedEvents(
                events,
                automationOrigin: automationOrigin
            )
        }
        guard let event = events.first, events.count == 1 else {
            return .err(
                code: "invalid_params",
                message: v2FeedPushRequiresEventMessage(),
                data: nil
            )
        }

        return v2IngestFeedEvent(
            event,
            waitTimeout: waitTimeout,
            automationOrigin: automationOrigin
        )
    }

    nonisolated func v2ApplyIMessageModeSideEffects(for event: WorkstreamEvent) {
        guard event.hookEventName == .userPromptSubmit || event.hookEventName == .stop,
              let rawWorkspaceId = event.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawWorkspaceId.isEmpty
        else { return }

        let iMessageModeEnabled = IMessageModeSettings.isEnabled()
        switch event.hookEventName {
        case .userPromptSubmit:
            v2MainSync {
                guard let workspaceId = v2UUIDAny(rawWorkspaceId) else { return }
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) else { return }
                _ = tabManager.handlePromptSubmit(
                    workspaceId: workspaceId,
                    message: event.submittedPromptMessage,
                    submittedLength: event.submittedPromptLength,
                    iMessageModeEnabled: iMessageModeEnabled,
                    surfaceId: event.surfaceId
                )
            }
        case .stop:
            let assistantFinalMessage = event.assistantFinalMessage
            Task { @MainActor [weak self, rawWorkspaceId, assistantFinalMessage, iMessageModeEnabled] in
                guard let self,
                      let workspaceId = self.v2UUIDAny(rawWorkspaceId) else { return }
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) else { return }
                _ = tabManager.handleAssistantFinalMessage(
                    workspaceId: workspaceId,
                    message: assistantFinalMessage,
                    iMessageModeEnabled: iMessageModeEnabled
                )
            }
        default:
            break
        }
    }

    // The three feed reply handlers are internal (not private) because the
    // mobile data plane dispatches the same bodies from
    // `TerminalController+MobileFeed.swift`'s verb family; every entrypoint
    // resolves through the single `FeedCoordinator.deliverReply` path.
    nonisolated func v2FeedPermissionReply(params: [String: Any]) -> V2CallResult {
        guard let requestId = params["request_id"] as? String else {
            return .err(
                code: "invalid_params",
                message: "feed.permission.reply requires request_id",
                data: nil
            )
        }
        guard let modeRaw = params["mode"] as? String,
              let mode = WorkstreamPermissionMode(rawValue: modeRaw)
        else {
            return .err(
                code: "invalid_params",
                message: "feed.permission.reply requires mode ∈ once|always|all|bypass|deny",
                data: nil
            )
        }
        FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            decision: .permission(mode)
        )
        return .ok(["delivered": true])
    }

    nonisolated func v2FeedQuestionReply(params: [String: Any]) -> V2CallResult {
        guard let requestId = params["request_id"] as? String else {
            return .err(
                code: "invalid_params",
                message: "feed.question.reply requires request_id",
                data: nil
            )
        }
        guard let selections = params["selections"] as? [String] else {
            return .err(
                code: "invalid_params",
                message: "feed.question.reply requires selections: [string]",
                data: nil
            )
        }
        FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            decision: .question(selections: selections)
        )
        return .ok(["delivered": true])
    }

    nonisolated func v2FeedExitPlanReply(params: [String: Any]) -> V2CallResult {
        guard let requestId = params["request_id"] as? String else {
            return .err(
                code: "invalid_params",
                message: "feed.exit_plan.reply requires request_id",
                data: nil
            )
        }
        guard let modeRaw = params["mode"] as? String,
              let mode = WorkstreamExitPlanMode(rawValue: modeRaw)
        else {
            return .err(
                code: "invalid_params",
                message: "feed.exit_plan.reply requires mode ∈ ultraplan|bypassPermissions|autoAccept|manual|deny",
                data: nil
            )
        }
        let feedback = params["feedback"] as? String
        FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            decision: .exitPlan(mode, feedback: feedback)
        )
        return .ok(["delivered": true])
    }

    // MARK: - V2 Browser Methods

    private func v2ResolveBrowserSurfaceId(
        params: [String: Any],
        workspace: Workspace
    ) -> (surfaceId: UUID?, error: V2CallResult?) {
        if let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") {
            return (surfaceId, nil)
        }
        if let paneId = v2UUID(params, "pane_id") {
            guard let pane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == paneId }) else {
                return (
                    nil,
                    .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneId.uuidString])
                )
            }
            guard let selectedTab = workspace.bonsplitController.selectedTab(inPane: pane),
                  let selectedSurface = workspace.panelIdFromSurfaceId(selectedTab.id) else {
                return (
                    nil,
                    .err(code: "not_found", message: "Pane has no selected surface", data: ["pane_id": paneId.uuidString])
                )
            }
            return (selectedSurface, nil)
        }
        return (workspace.focusedPanelId, nil)
    }

    enum V2JavaScriptResult {
        case success(Any?)
        case failure(String)
    }

    /// Sendable stand-in for `WKContentWorld` so nonisolated callers can pick a world without
    /// touching the main-actor-isolated `WKContentWorld.page`/`.defaultClient` statics. The real
    /// world is resolved on the main actor inside `v2RunJavaScript`.
    private enum V2JSContentWorld: Sendable { case page, isolated }

    private enum V2BrowserWaitOutcome {
        case met
        case timedOut
        case evaluationFailed(String)
    }

    private nonisolated func v2BrowserSelector(_ params: [String: Any]) -> String? {
        v2String(params, "selector")
            ?? v2String(params, "sel")
            ?? v2String(params, "element_ref")
            ?? v2String(params, "ref")
    }

    private func v2BrowserNotSupported(_ method: String, details: String) -> V2CallResult {
        .err(code: "not_supported", message: "\(method) is not supported on WKWebView", data: ["details": details])
    }

    private nonisolated func v2BrowserRecordUnsupportedRequest(surfaceId: UUID, request: [String: Any]) {
        v2MainSync {
            var logs = v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []
            logs.append(request)
            if logs.count > 256 {
                logs.removeFirst(logs.count - 256)
            }
            v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] = logs
        }
    }

    nonisolated func v2PNGData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private nonisolated func bestEffortPruneTemporaryFiles(
        in directoryURL: URL,
        keepingMostRecent maxCount: Int = 50,
        maxAge: TimeInterval = 24 * 60 * 60
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let datedEntries = entries.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in datedEntries.enumerated() {
            if index >= maxCount || now.timeIntervalSince(entry.date) > maxAge {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    // MARK: - Markdown

    // MARK: - Project

    // MARK: - Project state driving (debug RPC for autonomous iteration)

    private func v2ResolveProjectPanel(params: [String: Any]) -> (Workspace, ProjectPanel)? {
        guard let tabManager = v2ResolveTabManager(params: params) else { return nil }
        var result: (Workspace, ProjectPanel)?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId,
                  let panel = ws.panels[surfaceId] as? ProjectPanel else { return }
            result = (ws, panel)
        }
        return result
    }

    // MARK: - Browser

    private func v2BrowserDisabledExternalOpenResult(
        rawURL: String? = nil,
        url: URL?,
        tabManager: TabManager?
    ) -> V2CallResult {
        if let rawURL, url == nil {
            return .err(
                code: "invalid_params",
                message: "Invalid URL",
                data: ["url": rawURL]
            )
        }
        guard let url else {
            return .err(code: "browser_disabled", message: "cmux browser is disabled", data: nil)
        }

        var result: V2CallResult = .err(
            code: "external_open_failed",
            message: "Failed to open URL externally",
            data: ["url": url.absoluteString]
        )
        v2MainSync {
            guard NSWorkspace.shared.open(url) else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": v2OrNull(nil),
                "workspace_ref": v2Ref(kind: .workspace, uuid: nil),
                "pane_id": v2OrNull(nil),
                "pane_ref": v2Ref(kind: .pane, uuid: nil),
                "surface_id": v2OrNull(nil),
                "surface_ref": v2Ref(kind: .surface, uuid: nil),
                "created_split": false,
                "opened_externally": true,
                "browser_disabled": true,
                "placement_strategy": "external_browser_disabled",
                "url": url.absoluteString
            ])
        }
        return result
    }

    private nonisolated func v2BrowserURLAllowlistFailure(for url: URL) -> V2CallResult? {
        let policy = BrowserURLAllowlistPolicy(defaults: .standard)
        // Only local file documents use the trusted seam here. Other
        // user-supplied schemes (including data/blob/javascript) stay on the
        // ordinary allowlist path; cmux-owned document schemes already pass it.
        let allowsURL = url.isFileURL
            ? policy.allowsTrustedInternalURL(url)
            : policy.allows(url)
        guard !allowsURL else { return nil }
        return .err(
            code: "browser_url_blocked",
            message: String(
                localized: policy.isManaged
                    ? "cli.browser.error.urlBlockedByPolicy"
                    : "cli.browser.error.urlBlockedByUserPolicy",
                defaultValue: policy.isManaged
                    ? "Blocked by your organization's browser policy"
                    : "Blocked by the embedded-browser URL policy"
            ),
            data: nil
        )
    }

    /// Returns the URL that should be rejected for one browser-automation
    /// input. Once the browser URL resolver has produced a URL, the raw text
    /// must not be parsed again: Foundation treats `localhost:3000` as a
    /// pseudo-scheme even though the browser resolver correctly turns it into
    /// `http://localhost:3000`.
    nonisolated static func browserURLAllowlistBlockedURL(
        rawInput: String,
        resolvedURL: URL?,
        policy: BrowserURLAllowlistPolicy
    ) -> URL? {
        if let resolvedURL {
            let allowsURL = resolvedURL.isFileURL
                ? policy.allowsTrustedInternalURL(resolvedURL)
                : policy.allows(resolvedURL)
            return allowsURL ? nil : resolvedURL
        }
        guard let parsedURL = URL(string: rawInput), parsedURL.scheme != nil else {
            return nil
        }
        let allowsURL = parsedURL.isFileURL
            ? policy.allowsTrustedInternalURL(parsedURL)
            : policy.allows(parsedURL)
        return allowsURL ? nil : parsedURL
    }

    /// JavaScript snippet that sets an input element's value using the native
    /// prototype setter. Frameworks like React, Vue, and Angular override the
    /// value property on instances, so a plain `el.value = x` assignment only
    /// updates the DOM without notifying the framework's internal state.
    /// Calling the native setter from the prototype bypasses the override and
    /// triggers the framework's change-detection when followed by an `input`
    /// event. Walks the prototype chain instead of using instanceof so it
    /// works with cross-realm elements (iframes) and custom web components.
    /// Expects `el` and `newValue` to be in scope.
    private nonisolated static let reactCompatibleSetValue = """
        let nativeSetter = null;
        for (let proto = Object.getPrototypeOf(el); proto; proto = Object.getPrototypeOf(proto)) {
          const desc = Object.getOwnPropertyDescriptor(proto, 'value');
          if (desc && desc.set) { nativeSetter = desc.set; break; }
        }
        if (nativeSetter) {
          nativeSetter.call(el, newValue);
        } else {
          el.value = newValue;
        }
    """

    /// Reusable JS that dispatches framework-correct input events. Synthetic (untrusted) events do
    /// not run native default actions, and many frameworks/libraries listen on the full pointer +
    /// mouse sequence (not just `click`) or need legacy KeyboardEvent fields (keyCode/which/code).
    /// These helpers reproduce a real user gesture so React, Vue, Svelte, Angular, Solid, and
    /// vanilla handlers all fire. Define them once at the top of an injected snippet, then call
    /// `__cmuxClick(el)`, `__cmuxHover(el)`, or `__cmuxSetChecked(el, desired)`.
    private nonisolated static let browserInputHelpers = """
    function __cmuxCenter(el){const r=el.getBoundingClientRect();return {x:Math.floor(r.left+Math.min(r.width,r.width/2)),y:Math.floor(r.top+Math.min(r.height,r.height/2))};}
    function __cmuxPointer(el,type,c,buttons,bubbles){try{el.dispatchEvent(new PointerEvent(type,{bubbles:(bubbles===false?false:true),cancelable:true,composed:true,view:window,pointerId:1,pointerType:'mouse',isPrimary:true,button:0,buttons:buttons,clientX:c.x,clientY:c.y,screenX:c.x,screenY:c.y}));}catch(e){}}
    function __cmuxMouse(el,type,c,buttons,detail,bubbles){el.dispatchEvent(new MouseEvent(type,{bubbles:(bubbles===false?false:true),cancelable:true,composed:true,view:window,button:0,buttons:buttons,detail:detail||0,clientX:c.x,clientY:c.y,screenX:c.x,screenY:c.y}));}
    function __cmuxClick(el){const c=__cmuxCenter(el);
      __cmuxPointer(el,'pointerover',c,0);__cmuxMouse(el,'mouseover',c,0);
      __cmuxPointer(el,'pointerenter',c,0,false);__cmuxMouse(el,'mouseenter',c,0,0,false);
      __cmuxPointer(el,'pointermove',c,0);__cmuxMouse(el,'mousemove',c,0);
      __cmuxPointer(el,'pointerdown',c,1);__cmuxMouse(el,'mousedown',c,1,1);
      if(typeof el.focus==='function'){try{el.focus({preventScroll:true});}catch(e){try{el.focus();}catch(e2){}}}
      __cmuxPointer(el,'pointerup',c,0);__cmuxMouse(el,'mouseup',c,0,1);
      if(typeof el.click==='function'){el.click();}else{__cmuxMouse(el,'click',c,0,1);}
    }
    function __cmuxHover(el){const c=__cmuxCenter(el);
      __cmuxPointer(el,'pointerover',c,0);__cmuxMouse(el,'mouseover',c,0);
      __cmuxPointer(el,'pointerenter',c,0,false);__cmuxMouse(el,'mouseenter',c,0,0,false);
      __cmuxPointer(el,'pointermove',c,0);__cmuxMouse(el,'mousemove',c,0);
    }
    function __cmuxSetChecked(el,desired){
      // A click event runs the checkbox/radio activation behavior (it TOGGLES a checkbox / SELECTS a
      // radio) even when dispatched, and is also what React maps onChange to. So the correct way to
      // reach a target state is to click only when it differs; that fires input + change + (React)
      // onChange and leaves checked === desired. Setting el.checked directly does not update React's
      // controlled state and a separate click would toggle it back.
      if(el.checked===desired) return;
      // A radio cannot be turned OFF by clicking (clicking a radio only ever selects it). For that
      // one case set the property directly via the native setter and notify listeners.
      if(desired===false && el.type==='radio'){
        let ns=null;
        for(let p=Object.getPrototypeOf(el);p;p=Object.getPrototypeOf(p)){
          const d=Object.getOwnPropertyDescriptor(p,'checked'); if(d&&d.set){ns=d.set;break;}
        }
        if(ns){ns.call(el,false);}else{el.checked=false;}
        el.dispatchEvent(new Event('input',{bubbles:true}));
        el.dispatchEvent(new Event('change',{bubbles:true}));
        return;
      }
      if(typeof el.click==='function'){el.click();}
      else {const c=__cmuxCenter(el); __cmuxMouse(el,'click',c,0,1);}
    }
    """

    /// Builds the standard workspace/surface/window identity payload for a browser action.
    @MainActor
    private func v2BrowserActionPayload(
        workspaceId: UUID,
        surfaceId: UUID,
        tabManager: TabManager,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        var payload: [String: Any] = [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId)
        ]
        for (key, value) in extra { payload[key] = value }
        return payload
    }

    @MainActor
    private func v2BrowserActionPayload(
        workspace: Workspace,
        surfaceId: UUID,
        tabManager: TabManager,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        v2BrowserActionPayload(
            workspaceId: workspace.id,
            surfaceId: surfaceId,
            tabManager: tabManager,
            extra: extra
        )
    }

    /// Returns an error if any of the given handle params is SUPPLIED but does not resolve.
    /// v2UUID returns nil for both an absent param and a present-but-unresolvable handle (e.g. a
    /// stale `surface:2`/`workspace:99` ref), so a supplied target must not be treated as omitted
    /// and silently fall back to the focused/selected context. Returns nil when all are valid.
    // Internal (not private): the Dock browser resolvers in
    // TerminalController+WindowDockBrowserRouting.swift apply the same
    // supplied-but-unresolvable rejection before their Dock fallbacks.
    func v2RejectUnresolvedHandles(_ params: [String: Any], _ keys: [String]) -> V2CallResult? {
        // Use v2HasNonNullParam (not v2String) for presence: v2String trims empties to nil, so an
        // empty/whitespace explicit handle would otherwise look absent and silently fall back.
        for key in keys where v2HasNonNullParam(params, key) && v2UUID(params, key) == nil {
            return .err(code: "invalid_params", message: "Unresolved \(key)", data: nil)
        }
        return nil
    }

    private enum V2BrowserFrameProbe {
        case sameOriginFrame
        case crossOrigin
        case notFound
        case scriptFailed(String)
    }

    private struct V2BrowserDownloadWaitSnapshot {
        let workspaceId: UUID
        let workspaceRef: Any
        let surfaceId: UUID
        let surfaceRef: Any
        let queuedEvent: [String: Any]?
        let error: V2CallResult?
    }

    private enum V2DownloadFileWaitResult: Sendable {
        case ready
        case timeout
        case watcherSetupFailed(errnoCode: Int32)
    }

    private nonisolated static func v2WorkerString(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func v2WorkerInt(_ params: [String: Any], _ key: String) -> Int? {
        if let intValue = params[key] as? Int {
            return intValue
        }
        if let number = params[key] as? NSNumber {
            return number.intValue
        }
        if let raw = v2WorkerString(params, key) {
            return Int(raw)
        }
        return nil
    }

    func v2RecordBrowserDownloadEvent(surfaceId: UUID, event: [String: Any]) {
        guard v2ShouldStoreBrowserDownloadEvent(event, surfaceId: surfaceId), (event["type"] as? String) != "started" else { return }
        var queue = v2BrowserDownloadEventsBySurface[surfaceId] ?? []
        if v2IsTerminalBrowserDownloadEvent(event),
           let downloadID = v2DownloadID(from: event) {
            queue.removeAll { v2DownloadID(from: $0) == downloadID }
        }
        queue.append(event)
        if queue.count > Self.v2ConsumedBrowserDownloadIDLimit { queue.removeFirst(queue.count - Self.v2ConsumedBrowserDownloadIDLimit) }
        v2BrowserDownloadEventsBySurface[surfaceId] = queue
    }

    func v2PopBrowserDownloadEvent(surfaceId: UUID) -> [String: Any]? {
        var remaining = v2BrowserDownloadEventsBySurface[surfaceId] ?? []
        while !remaining.isEmpty {
            let first = remaining.removeFirst()
            v2BrowserDownloadEventsBySurface[surfaceId] = remaining
            guard v2ShouldStoreBrowserDownloadEvent(first, surfaceId: surfaceId), (first["type"] as? String) != "started" else { continue }
            v2MarkBrowserDownloadEventConsumed(first, surfaceId: surfaceId)
            return first
        }
        return nil
    }

    private func v2DownloadID(from event: [String: Any]) -> String? {
        (event["download_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func v2IsTerminalBrowserDownloadEvent(_ event: [String: Any]) -> Bool {
        let type = event["type"] as? String
        return type == "saved" || type == "cancelled" || type == "failed"
    }

    private func v2ShouldStoreBrowserDownloadEvent(_ event: [String: Any], surfaceId: UUID) -> Bool {
        guard let downloadID = v2DownloadID(from: event) else { return true }
        let consumed = v2ConsumedBrowserDownloadKeysBySurface[surfaceId] ?? []
        if consumed.contains(downloadID) { return false }
        guard let type = (event["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return true }
        return !consumed.contains("\(type)\u{0}\(downloadID)")
    }

    func v2MarkBrowserDownloadEventConsumed(_ event: [String: Any], surfaceId: UUID) {
        guard let downloadID = v2DownloadID(from: event), let type = (event["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return }
        let isTerminal = v2IsTerminalBrowserDownloadEvent(event)
        let eventKey = "\(type)\u{0}\(downloadID)"
        let consumedKey = isTerminal ? downloadID : eventKey
        var consumed = v2ConsumedBrowserDownloadKeysBySurface[surfaceId] ?? []
        consumed.removeAll { $0 == consumedKey }
        consumed.append(consumedKey)
        if consumed.count > Self.v2ConsumedBrowserDownloadIDLimit { consumed.removeFirst(consumed.count - Self.v2ConsumedBrowserDownloadIDLimit) }
        v2ConsumedBrowserDownloadKeysBySurface[surfaceId] = consumed
        v2BrowserDownloadEventsBySurface[surfaceId]?.removeAll {
            if isTerminal { return v2DownloadID(from: $0) == downloadID }
            return v2DownloadID(from: $0) == downloadID && (($0["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty == type)
        }
    }

    private nonisolated func v2WaitForDownloadFile(path: String, timeout: TimeInterval) -> V2DownloadFileWaitResult {
        let fm = FileManager.default
        let pathIsReady = {
            guard fm.fileExists(atPath: path),
                  let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber else {
                return false
            }
            return size.intValue > 0
        }
        if pathIsReady() {
            return .ready
        }

        let watchedPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let fd = open(watchedPath, O_EVTONLY)
        guard fd >= 0 else {
            return .watcherSetupFailed(errnoCode: errno)
        }

        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var finished = false
        nonisolated(unsafe) var ready = false
        let finishOnce: (Bool) -> Void = { value in
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            ready = value
            lock.unlock()
            semaphore.signal()
        }

        let watcherQueue = DispatchQueue(label: "com.cmux.browser.download.wait.file")
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .rename],
            queue: watcherQueue
        )
        source.setEventHandler {
            if pathIsReady() {
                finishOnce(true)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        if pathIsReady() {
            finishOnce(true)
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            finishOnce(pathIsReady())
        }
        source.cancel()
        return ready ? .ready : .timeout
    }

    private nonisolated func v2WaitForDownloadEvent(surfaceId: UUID, timeout: TimeInterval) -> [String: Any]? {
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var finished = false
        nonisolated(unsafe) var event: [String: Any]?
        var observer: NSObjectProtocol?

        let finishOnce: ([String: Any]?) -> Void = { value in
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            event = value
            lock.unlock()
            semaphore.signal()
        }

        observer = NotificationCenter.default.addObserver(
            forName: .browserDownloadEventDidArrive,
            object: nil,
            queue: nil
        ) { note in
            guard let candidateSurfaceId = note.userInfo?["surfaceId"] as? UUID, candidateSurfaceId == surfaceId,
                  let event = note.userInfo?["event"] as? [String: Any],
                  (event["type"] as? String) != "started" else {
                return
            }
            guard self.v2MainSync({ self.v2ShouldStoreBrowserDownloadEvent(event, surfaceId: surfaceId) }) else { return }
            finishOnce(event)
        }

        if let queued = v2MainSync({ v2PopBrowserDownloadEvent(surfaceId: surfaceId) }) {
            finishOnce(queued)
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            finishOnce(nil)
        }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if let event {
            v2MainSync {
                v2MarkBrowserDownloadEventConsumed(event, surfaceId: surfaceId)
            }
        }
        return event
    }

    private nonisolated func v2BrowserCookieDict(_ cookie: HTTPCookie) -> [String: Any] {
        var out: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            // Foundation represents host-only cookies without a leading dot;
            // retain that distinction so state/load does not widen their scope.
            "hostOnly": !cookie.domain.hasPrefix("."),
            "path": cookie.path,
            "secure": cookie.isSecure,
            "httpOnly": cookie.isHTTPOnly,
            "session_only": cookie.isSessionOnly
        ]
        if let expiresDate = cookie.expiresDate {
            out["expires"] = Int(expiresDate.timeIntervalSince1970)
        } else {
            out["expires"] = NSNull()
        }
        return out
    }

    private func v2BrowserTraceStart(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.trace.start", details: "Playwright trace artifacts are not available on WKWebView")
    }

    private func v2BrowserTraceStop(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.trace.stop", details: "Playwright trace artifacts are not available on WKWebView")
    }

    private func v2BrowserNetworkRoute(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            v2BrowserRecordUnsupportedRequest(surfaceId: surfaceId, request: ["action": "route", "params": params])
        }
        return v2BrowserNotSupported("browser.network.route", details: "WKWebView does not provide CDP-style request interception/mocking")
    }

    private func v2BrowserNetworkUnroute(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            v2BrowserRecordUnsupportedRequest(surfaceId: surfaceId, request: ["action": "unroute", "params": params])
        }
        return v2BrowserNotSupported("browser.network.unroute", details: "WKWebView does not provide CDP-style request interception/mocking")
    }

    private func v2BrowserNetworkRequests(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            let items = v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []
            return .err(code: "not_supported", message: "browser.network.requests is not supported on WKWebView", data: [
                "details": "Request interception logs are unavailable without CDP network hooks",
                "recorded_requests": items
            ])
        }
        return v2BrowserNotSupported("browser.network.requests", details: "Request interception logs are unavailable without CDP network hooks")
    }

    private func v2BrowserScreencastStart(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.screencast.start", details: "WKWebView does not expose CDP screencast streaming")
    }

    private func v2BrowserScreencastStop(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.screencast.stop", details: "WKWebView does not expose CDP screencast streaming")
    }

    private func v2BrowserInputMouse(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_mouse", details: "Raw CDP mouse injection is unavailable; use browser.click/hover/scroll")
    }

    private func v2BrowserInputKeyboard(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_keyboard", details: "Raw CDP keyboard injection is unavailable; use browser.press/keydown/keyup")
    }

    private func v2BrowserInputTouch(params _: [String: Any]) -> V2CallResult {
        v2BrowserNotSupported("browser.input_touch", details: "Raw CDP touch injection is unavailable on WKWebView")
    }

#if DEBUG
    // MARK: - V2 Debug / Test-only Methods

#if DEBUG
#endif

#if DEBUG

    /// Drives `SidebarDragState.draggedTabId` and `dropIndicator` mutations
    /// across N steps from a starting workspace toward a target neighbor.
    /// External profilers (e.g. the `profile-pr` skill driving `xctrace`)
    /// invoke this between `xctrace record --launch` and `xctrace stop` to
    /// generate a deterministic 60Hz-style drag load without HID synthesis.
    /// Never commits the reorder; calls back with the synthesized step path.
    ///
    /// Runs on the socket worker (see `ControlCommandExecutionPolicy`) so the
    /// inter-tick `Thread.sleep` doesn't block the main actor — every
    /// dragState mutation hops to main via `v2MainSync`.
    private nonisolated func v2DebugSidebarSimulateDrag(params: [String: Any]) -> V2CallResult {
        // Dispatched on the socket worker (see ControlCommandExecutionPolicy) so the
        // inter-tick Thread.sleep doesn't block the main actor. All parameter
        // resolution (including workspace:N -> UUID ref-resolution) and the
        // SidebarDragState mutations hop to main via v2MainSync.

        enum PlanResult {
            case ok(
                windowId: UUID,
                fromTabId: UUID,
                toTabId: UUID,
                tabIds: [UUID],
                fromIndex: Int,
                toIndex: Int,
                durationMs: Int,
                requestedSteps: Int?
            )
            case err(code: String, message: String, data: [String: Any]?)
        }

        let planResult: PlanResult = v2MainSync {
            guard let windowId = v2UUID(params, "window_id") else {
                return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
            }
            // Scope to the requested window. self.tabManager is the controller's
            // primary tabManager; in multi-window runs that's the wrong list for
            // a window_id other than the primary.
            guard let windowTabManager = AppDelegate.shared?.tabManagerFor(windowId: windowId) else {
                return .err(
                    code: "not_found",
                    message: "No TabManager for window_id",
                    data: ["window_id": windowId.uuidString]
                )
            }
            guard let fromTabId = v2UUID(params, "from_tab_id") else {
                return .err(code: "invalid_params", message: "Missing or invalid from_tab_id", data: nil)
            }
            guard let toTabId = v2UUID(params, "to_tab_id") else {
                return .err(code: "invalid_params", message: "Missing or invalid to_tab_id", data: nil)
            }
            let durationMs: Int
            if v2HasNonNullParam(params, "duration_ms") {
                guard let value = v2Int(params, "duration_ms"), value > 0 else {
                    return .err(code: "invalid_params", message: "duration_ms must be a positive integer", data: nil)
                }
                durationMs = value
            } else {
                durationMs = 1000
            }
            let requestedSteps: Int?
            if v2HasNonNullParam(params, "steps") {
                guard let value = v2Int(params, "steps"), value > 0 else {
                    return .err(code: "invalid_params", message: "steps must be a positive integer", data: nil)
                }
                requestedSteps = value
            } else {
                requestedSteps = nil
            }
            guard AppDelegate.shared?.sidebarDragStateRegistry.state(forWindowId: windowId) != nil else {
                return .err(
                    code: "not_found",
                    message: "No mounted sidebar for window_id",
                    data: ["window_id": windowId.uuidString]
                )
            }
            let tabIds = windowTabManager.tabs.map(\.id)
            guard let fromIndex = tabIds.firstIndex(of: fromTabId) else {
                return .err(
                    code: "not_found",
                    message: "from_tab_id not in window's workspace list",
                    data: ["from_tab_id": fromTabId.uuidString]
                )
            }
            guard let toIndex = tabIds.firstIndex(of: toTabId) else {
                return .err(
                    code: "not_found",
                    message: "to_tab_id not in window's workspace list",
                    data: ["to_tab_id": toTabId.uuidString]
                )
            }
            guard fromIndex != toIndex else {
                return .err(code: "invalid_params", message: "from_tab_id and to_tab_id must differ", data: nil)
            }
            return .ok(
                windowId: windowId,
                fromTabId: fromTabId,
                toTabId: toTabId,
                tabIds: tabIds,
                fromIndex: fromIndex,
                toIndex: toIndex,
                durationMs: durationMs,
                requestedSteps: requestedSteps
            )
        }

        let windowId: UUID
        let fromTabId: UUID
        let toTabId: UUID
        let tabIds: [UUID]
        let fromIndex: Int
        let toIndex: Int
        let durationMs: Int
        let requestedSteps: Int?
        switch planResult {
        case let .err(code, message, data):
            return .err(code: code, message: message, data: data)
        case let .ok(w, f, t, ids, fi, ti, dur, steps):
            windowId = w; fromTabId = f; toTabId = t; tabIds = ids
            fromIndex = fi; toIndex = ti; durationMs = dur; requestedSteps = steps
        }

        let stride = fromIndex < toIndex ? 1 : -1
        let pathIndices = Swift.stride(from: fromIndex + stride, through: toIndex, by: stride).map { $0 }
        guard !pathIndices.isEmpty else {
            return .err(code: "invalid_params", message: "Empty drag path", data: nil)
        }
        // Allow requestedSteps > pathIndices.count: profiling at high tick
        // rates (e.g. 60Hz over a short row span) is a documented use case.
        // The resampling formula picks the same indicator value multiple
        // times in that regime, which is exactly the SwiftUI invalidation
        // load the skill measures.
        let steps = max(1, requestedSteps ?? pathIndices.count)
        // Resampler closure: maps step number (0..<steps) -> path index.
        // Not pre-materialized; computed inline in the simulation loop so
        // arbitrarily large --steps (e.g. 60Hz over hours) doesn't allocate
        // a giant [Int] up front.
        let pathCount = pathIndices.count
        let stepDivisor = Double(max(1, steps - 1))
        let resolveStepIndex: (Int) -> Int = { stepNumber in
            let position = Int(round(Double(stepNumber) * Double(pathCount - 1) / stepDivisor))
            return pathIndices[max(0, min(pathCount - 1, position))]
        }
        let stepIntervalMs = max(1, durationMs / steps)
        let edge: SidebarDropEdge = fromIndex < toIndex ? .bottom : .top
        // Cap the response payload's path array so very large --steps don't
        // serialize a giant JSON UUID list. The simulation still runs every
        // requested step; the response is just informational.
        let pathSampleLimit = 64

        // Start the drag. If the sidebar has already unregistered, fail loud
        // instead of silently sleeping through a no-op simulation.
        let startedOK: Bool = v2MainSync {
            guard let dragState = AppDelegate.shared?.sidebarDragStateRegistry.state(forWindowId: windowId) else { return false }
            // Simulation uses the same tokenized coordinator path as a real
            // sidebar drag, but completes explicitly because no HID source is
            // driving AppKit callbacks.
            _ = dragState.beginDragging(tabId: fromTabId)
            return true
        }
        guard startedOK else {
            return .err(
                code: "not_found",
                message: "Sidebar unregistered before simulation could start",
                data: ["window_id": windowId.uuidString]
            )
        }

        var aborted = false
        var pathSample: [String] = []
        pathSample.reserveCapacity(min(steps, pathSampleLimit))
        for stepNumber in 0..<steps {
            let tabIndex = resolveStepIndex(stepNumber)
            let targetTabId = tabIds[tabIndex]
            if pathSample.count < pathSampleLimit {
                pathSample.append(targetTabId.uuidString)
            }
            let tickOK: Bool = v2MainSync {
                guard let dragState = AppDelegate.shared?.sidebarDragStateRegistry.state(forWindowId: windowId) else { return false }
                dragState.setDropIndicator(SidebarDropIndicator(tabId: targetTabId, edge: edge))
                return true
            }
            if !tickOK {
                aborted = true
                break
            }
            if stepIntervalMs > 0 {
                Thread.sleep(forTimeInterval: TimeInterval(stepIntervalMs) / 1000.0)
            }
        }

        v2MainSync {
            guard let dragState = AppDelegate.shared?.sidebarDragStateRegistry.state(forWindowId: windowId) else { return }
            dragState.finishDrag()
        }

        if aborted {
            return .err(
                code: "aborted",
                message: "Sidebar unregistered mid-simulation",
                data: ["window_id": windowId.uuidString]
            )
        }

        var payload: [String: Any] = [
            "window_id": windowId.uuidString,
            "from_tab_id": fromTabId.uuidString,
            "to_tab_id": toTabId.uuidString,
            "steps": steps,
            "step_interval_ms": stepIntervalMs,
            "duration_ms": stepIntervalMs * steps,
            "edge": edge == .top ? "top" : "bottom",
            "path": pathSample
        ]
        if steps > pathSampleLimit {
            payload["path_truncated"] = true
            payload["path_full_size"] = steps
        }
        return .ok(payload)
    }
#endif
#endif

    private struct ReadScreenOptions {
        let surfaceArg: String
        let includeScrollback: Bool
        let lineLimit: Int?
    }

    private struct ReadScreenParseError: Error {
        let message: String
    }

    private nonisolated func parseReadScreenArgs(_ args: String) -> Result<ReadScreenOptions, ReadScreenParseError> {
        let tokens = args
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        var surfaceArg: String?
        var includeScrollback = false
        var lineLimit: Int?
        var idx = 0

        while idx < tokens.count {
            let token = tokens[idx]
            switch token {
            case "--scrollback":
                includeScrollback = true
                idx += 1
            case "--lines":
                guard idx + 1 < tokens.count, let parsed = Int(tokens[idx + 1]), parsed > 0 else {
                    return .failure(ReadScreenParseError(message: "ERROR: --lines must be greater than 0"))
                }
                lineLimit = parsed
                includeScrollback = true
                idx += 2
            default:
                guard surfaceArg == nil else {
                    return .failure(ReadScreenParseError(message: "ERROR: Usage: read_screen [id|idx] [--scrollback] [--lines <n>]"))
                }
                surfaceArg = token
                idx += 1
            }
        }

        return .success(
            ReadScreenOptions(
                surfaceArg: surfaceArg ?? "",
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
        )
    }

    nonisolated static func tailTerminalLines(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        var newlineCount = 0
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous] == "\n" {
                newlineCount += 1
                if newlineCount == maxLines {
                    return String(text[index...])
                }
            }
            index = previous
        }
        return text
    }

    private func readTerminalTextBase64(surfaceArg: String, includeScrollback: Bool = false, lineLimit: Int? = nil) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmedSurfaceArg = surfaceArg.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let panelId: UUID?
            if trimmedSurfaceArg.isEmpty {
                panelId = tab.focusedPanelId
            } else {
                panelId = resolveSurfaceId(from: trimmedSurfaceArg, tab: tab)
            }

            guard let panelId,
                  let target = tab.controlSocketTerminalInputTarget(for: panelId) else {
                result = "ERROR: Terminal surface not found"
                return
            }

            result = readTerminalTextBase64(
                terminalSurface: target.surface,
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
        }
        return result
    }

    /// The v1 `read_screen` capture outcome: either a reply string fully
    /// resolved on the main actor (parse/resolution errors), or the raw
    /// Ghostty snapshot for off-main formatting.
    private enum ReadScreenCaptureOutcome {
        case finished(String)
        case captured(TerminalTextRawSnapshot)
        case surfaceStarting
    }

    private nonisolated func readScreenText(_ args: String) -> String {
        let options: ReadScreenOptions
        switch parseReadScreenArgs(args) {
        case .success(let parsed):
            options = parsed
        case .failure(let error):
            return error.message
        }
        let trimmedSurfaceArg = options.surfaceArg.trimmingCharacters(in: .whitespacesAndNewlines)

        let outcome: ReadScreenCaptureOutcome = v2MainSyncAwaitingSurfaceStart(isStarting: {
            if case .surfaceStarting = $0 { return true }
            return false
        }) { surfaceStartDeadline in
            guard let tabManager = self.tabManager else {
                return .finished("ERROR: TabManager not available")
            }
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return .finished("ERROR: No tab selected")
            }

            let panelId: UUID?
            if trimmedSurfaceArg.isEmpty {
                panelId = tab.focusedPanelId
            } else {
                panelId = self.resolveSurfaceId(from: trimmedSurfaceArg, tab: tab)
            }

            guard let panelId,
                  let target = tab.controlSocketTerminalInputTarget(for: panelId) else {
                return .finished("ERROR: Terminal surface not found")
            }
            if self.readTextAwaitsSurfaceStart(target.surface, deadline: surfaceStartDeadline) {
                return .surfaceStarting
            }
            guard target.surface.liveSurfaceForGhosttyAccess(reason: "readTerminalTextBase64") != nil else {
                let reason = target.surface.runtimeUnavailableReason
                let wakeCommand = reason == .hibernated
                    ? Self.terminalWakeCommand(workspaceID: tab.id, surfaceID: target.surfaceID)
                    : nil
                return .finished("ERROR: \(Self.terminalNotRunningMessage(reason: reason, wakeCommand: wakeCommand))")
            }
            guard let snapshot = self.readTerminalTextRawSnapshot(
                terminalSurface: target.surface,
                includeScrollback: options.includeScrollback
            ) else {
                return .finished("ERROR: Terminal surface not found")
            }
            return .captured(snapshot)
        }

        let snapshot: TerminalTextRawSnapshot
        switch outcome {
        case .finished(let reply):
            return reply
        case .surfaceStarting:
            // v2MainSyncAwaitingSurfaceStart never returns this case.
            return "ERROR: \(Self.terminalNotRunningMessage(reason: .starting, wakeCommand: nil))"
        case .captured(let captured):
            snapshot = captured
        }

        // Off-main formatting, byte-faithful to the legacy pipeline: the
        // payload's base64 is produced, trimmed, and decoded back exactly as
        // `readScreenText` → `readTerminalTextBase64` did.
        switch Self.terminalTextPayload(
            from: snapshot,
            includeScrollback: options.includeScrollback,
            lineLimit: options.lineLimit
        ) {
        case .failure(let error):
            return "ERROR: \(error.message)"
        case .success(let payload):
            let base64 = payload.base64.trimmingCharacters(in: .whitespacesAndNewlines)
            if base64.isEmpty {
                return ""
            }
            guard let data = Data(base64Encoded: base64) else {
                return "ERROR: Failed to decode terminal text"
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func helpText() -> String {
        var text = """
        Hierarchy: Workspace (sidebar tab) > Pane (split region) > Surface (nested tab) > Panel (terminal/browser)

        Available commands:
          ping                        - Check if server is running
          list_workspaces             - List all workspaces with IDs
          new_workspace               - Create a new workspace
          select_workspace <id|index> - Select workspace by ID or index (0-based)
          current_workspace           - Get current workspace ID
          close_workspace <id>        - Close workspace by ID

        Split & surface commands:
          new_split <direction> [panel]   - Split panel (left/right/up/down)
          drag_surface_to_split <id|idx> <direction> - Move surface into a new split (drag-to-edge)
          new_pane [--type=terminal|browser] [--direction=left|right|up|down] [--url=...]
          new_surface [--type=terminal|browser] [--pane=<pane-id|index>] [--url=...]
          list_surfaces [workspace]       - List surfaces for workspace (current if omitted)
          list_panes                      - List all panes with IDs
          list_pane_surfaces [--pane=<pane-id|index>] - List surfaces in pane
          focus_surface <id|idx>          - Focus surface by ID or index
          focus_pane <pane-id|index>      - Focus a pane
          focus_surface_by_panel <panel_id> - Focus surface by panel ID
          close_surface [id|idx]          - Close surface (collapse split)
          reload_config                   - Reload Ghostty config, cmux settings, and refresh terminals
          refresh_surfaces                - Force refresh all terminals
          surface_health [workspace]      - Check view health of all surfaces

        Input commands:
          send <text>                     - Send text to current terminal
          send_key <key>                  - Send special key (ctrl-c, ctrl-d, ctrl-f, enter, tab, escape)
          send_surface <id|idx> <text>    - Send text to a specific terminal
          send_key_surface <id|idx> <key> - Send special key to a specific terminal
          read_screen [id|idx] [--scrollback] [--lines N] - Read terminal text (plain text)

        Notification commands:
          notify <title>|<subtitle>|<body>   - Notify focused panel
          notify_surface <id|idx> <payload>  - Notify a specific surface
          notify_target <workspace_id> <surface_id> <payload> - Notify by workspace+surface
          notify_target_async <workspace_uuid> <surface_uuid> <payload> - Queue notification by workspace+surface
          list_notifications              - List all notifications
          clear_notifications [--tab=X] [--panel=ID] - Clear notifications (all, per-tab, or per-panel)
          set_app_focus <active|inactive|clear> - Override app focus state
          simulate_app_active             - Trigger app active handler
          set_status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--work=running|subagents|waiting] [--tab=X] - Set a status entry
          set_agent_lifecycle <key> <unknown|running|idle|needsInput> [--tab=X] [--panel=ID] - Report coding-agent lifecycle for hibernation
          agent_hibernation <on|off> - Enable or disable routine Agent Hibernation
          report_meta <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--tab=X] - Set sidebar metadata entry
          report_meta_block <key> [--priority=N] [--tab=X] -- <markdown> - Set freeform sidebar markdown block
          clear_status <key> [--tab=X] - Remove a status entry
          clear_meta <key> [--tab=X] - Remove sidebar metadata entry
          clear_meta_block <key> [--tab=X] - Remove sidebar markdown block
          list_status [--tab=X]   - List all status entries
          list_meta [--tab=X]     - List sidebar metadata entries
          list_meta_blocks [--tab=X] - List sidebar markdown blocks
          log [--level=X] [--source=X] [--tab=X] -- <message> - Append a log entry
          clear_log [--tab=X]     - Clear log entries
          list_log [--limit=N] [--tab=X] - List log entries
          set_progress <0.0-1.0> [--label=X] [--tab=X] - Set progress bar
          clear_progress [--tab=X] - Clear progress bar
          report_git_branch <branch> [--status=dirty|clean|unknown] [--tab=X] [--panel=Y] - Report git branch
          clear_git_branch [--tab=X] [--panel=Y] - Clear git branch
          report_pr <number> <url> [--label=PR] [--state=open|merged|closed] [--branch=<name>] [--tab=X] [--panel=Y] - Report pull request / review item
          report_review <number> <url> [--label=MR] [--state=open|merged|closed] [--tab=X] [--panel=Y] - Alias for provider-specific review item
          clear_pr [--tab=X] [--panel=Y] - Clear pull request
          report_ports <port1> [port2...] [--tab=X] [--panel=Y] - Report listening ports
          report_tty <tty_name> [--tab=X] [--panel=Y] - Register TTY for batched port scanning
          ports_kick [--tab=X] [--panel=Y] [--reason=command|refresh] - Request batched port scan for panel
          report_shell_state <prompt|running> [--tab=X] [--panel=Y] - Report whether the shell is idle at a prompt or running a command
          report_pr_action <merge|close|reopen|create|checkout|ready|edit|view> [--target=X] [--tab=X] [--panel=Y] - Hint that a PR-affecting command completed in the panel
          report_pwd <path|display-label> [--path=/actual/path] [--tab=X] [--panel=Y] - Report current working directory
          clear_ports [--tab=X] [--panel=Y] - Clear listening ports
          right_sidebar <toggle|show|hide|focus|set|mode> [mode] [--tab=X] [--window=Y] [--no-focus] - Control right sidebar visibility, mode, and focus
          sidebar_state [--tab=X] - Dump sidebar metadata
          reset_sidebar [--tab=X] - Clear sidebar metadata

        Browser commands:
          open_browser [url]              - Create browser panel with optional URL
          navigate <panel_id> <url>       - Navigate browser to URL
          browser_back <panel_id>         - Go back in browser history
          browser_forward <panel_id>      - Go forward in browser history
          browser_reload <panel_id>       - Reload browser page
          get_url <panel_id>              - Get current URL of browser panel
          focus_webview <panel_id>        - Move keyboard focus into the WKWebView (for tests)
          is_webview_focused <panel_id>   - Return true/false if WKWebView is first responder

          help                            - Show this help
        """
#if DEBUG
        text += """

          focus_notification <workspace|idx> [surface|idx] - Focus via notification flow
          flash_count <id|idx>            - Read flash count for a panel
          reset_flash_counts              - Reset flash counters
          screenshot [label]              - Capture window screenshot
          set_shortcut <name> <combo|clear> - Set a keyboard shortcut (test-only)
          simulate_shortcut <combo>       - Simulate a keyDown shortcut (test-only)
          simulate_type <text>            - Insert text into the current first responder (test-only)
          sleepy_mode <cmd> [val]         - Sleepy Mode: on|off|unlock|preview|theme <t>|mascot <m>|glow <g>|toggle <k>|pets <c x o|clear> (test-only)
          simulate_file_drop <id|idx> <path[|path...]> - Simulate dropping file path(s) on terminal (test-only)
          seed_drag_pasteboard_fileurl    - Seed NSDrag pasteboard with public.file-url (test-only)
          seed_drag_pasteboard_tabtransfer - Seed NSDrag pasteboard with tab transfer type (test-only)
          seed_drag_pasteboard_sidebar_reorder - Seed NSDrag pasteboard with sidebar reorder type (test-only)
          seed_drag_pasteboard_types <types> - Seed NSDrag pasteboard with comma/space-separated types (fileurl, tabtransfer, sidebarreorder, or raw UTI)
          clear_drag_pasteboard           - Clear NSDrag pasteboard (test-only)
          drop_hit_test <x 0-1> <y 0-1> - Hit-test file-drop overlay at normalised coords (test-only)
          drag_hit_chain <x 0-1> <y 0-1> - Return hit-view chain at normalised coords (test-only)
          overlay_hit_gate <event|none> - Return true/false if file-drop overlay would capture hit-testing for event type (test-only)
          overlay_drop_gate [external|local] - Return true/false if file-drop overlay would capture drag destination routing (test-only)
          portal_hit_gate <event|none> - Return true/false if terminal portal should pass hit-testing to SwiftUI drag targets (test-only)
          sidebar_overlay_gate [active|inactive] - Return true/false if sidebar outside-drop overlay would capture (test-only)
          terminal_drop_overlay_probe [deferred|direct] - Trigger focused terminal drop-overlay show path and report animation counts (test-only)
          activate_app                    - Bring app + main window to front (test-only)
          send_workspace <workspace_id> <text> - Send text to a workspace's selected terminal (test-only)
          is_terminal_focused <id|idx>    - Return true/false if terminal surface is first responder (test-only)
          read_terminal_text [id|idx]     - Read visible terminal text (base64, test-only)
          render_stats [id|idx]           - Read terminal render stats (draw counters, test-only)
          layout_debug                    - Dump bonsplit layout + selected panel bounds (test-only)
          bonsplit_underflow_count        - Count bonsplit arranged-subview underflow events (test-only)
          reset_bonsplit_underflow_count  - Reset bonsplit underflow counter (test-only)
          empty_panel_count               - Count EmptyPanelView appearances (test-only)
          reset_empty_panel_count         - Reset EmptyPanelView appearance count (test-only)
          debug.mobile.transport.reconnect_loop - Repeatedly close mobile transports for a bounded duration (test-only)
        """
#endif
        return text
    }

#if DEBUG
    private func prepareWindowForSyntheticInput(_ window: NSWindow?) {
        guard socketCommandAllowsInAppFocusMutations(),
              let window else { return }
        // Keep socket-driven input simulation focused on the intended window without
        // paying repeated activation/order-front costs for every synthetic key event.
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !window.isKeyWindow || !window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func activateApp() -> String {
        v2MainSync {
            _ = AppDelegate.shared?.activateMainWindowFromSocket()
        }
        return "OK"
    }

    private func simulateType(_ args: String) -> String {
        let raw = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return "ERROR: Usage: simulate_type <text>"
        }

        // Socket commands are line-based; allow callers to express control chars with backslash escapes.
        let text = unescapeSocketText(raw)

        var result = "ERROR: No window"
        v2MainSync {
            // Like simulate_shortcut, prefer a visible window so debug automation doesn't
            // fail during key window transitions.
            guard let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
                ?? NSApp.windows.first else { return }
            prepareWindowForSyntheticInput(window)
            guard let fr = window.firstResponder else {
                result = "ERROR: No first responder"
                return
            }

            if let client = fr as? NSTextInputClient {
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                result = "OK"
                return
            }

            // Fall back to the responder chain insertText action.
            (fr as? NSResponder)?.insertText(text)
            result = "OK"
        }
        return result
    }

    private func simulateFileDrop(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "ERROR: Usage: simulate_file_drop <id|idx> <path[|path...]>"
        }

        let target = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPaths = parts[1]
        let paths = rawPaths
            .split(separator: "|")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            return "ERROR: Usage: simulate_file_drop <id|idx> <path[|path...]>"
        }

        var result = "ERROR: Surface not found"
        v2MainSync {
            guard let panel = resolveTerminalPanel(from: target, tabManager: tabManager) else { return }
            result = panel.hostedView.debugSimulateFileDrop(paths: paths)
                ? "OK"
                : "ERROR: Failed to simulate drop"
        }
        return result
    }

    private func seedDragPasteboardFileURL() -> String {
        return seedDragPasteboardTypes("fileurl")
    }

    private func seedDragPasteboardTabTransfer() -> String {
        return seedDragPasteboardTypes("tabtransfer")
    }

    private func seedDragPasteboardSidebarReorder() -> String {
        return seedDragPasteboardTypes("sidebarreorder")
    }

    private func seedDragPasteboardTypes(_ args: String) -> String {
        let raw = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return "ERROR: Usage: seed_drag_pasteboard_types <type[,type...]>"
        }

        let tokens = raw
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            return "ERROR: Usage: seed_drag_pasteboard_types <type[,type...]>"
        }

        var types: [NSPasteboard.PasteboardType] = []
        for token in tokens {
            guard let mapped = dragPasteboardType(from: token) else {
                return "ERROR: Unknown drag type '\(token)'"
            }
            if !types.contains(mapped) {
                types.append(mapped)
            }
        }

        v2MainSync {
            _ = NSPasteboard(name: .drag).declareTypes(types, owner: nil)
        }
        return "OK"
    }

    private func clearDragPasteboard() -> String {
        v2MainSync {
            _ = NSPasteboard(name: .drag).clearContents()
        }
        return "OK"
    }

    private func overlayHitGate(_ args: String) -> String {
        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !token.isEmpty else {
            return "ERROR: Usage: overlay_hit_gate <leftMouseDragged|rightMouseDragged|otherMouseDragged|mouseMoved|mouseEntered|mouseExited|flagsChanged|cursorUpdate|appKitDefined|systemDefined|applicationDefined|periodic|leftMouseDown|leftMouseUp|rightMouseDown|rightMouseUp|otherMouseDown|otherMouseUp|scrollWheel|none>"
        }

        let parsedEvent = parseOverlayEventType(token)
        guard parsedEvent.isKnown else {
            return "ERROR: Unknown event type '\(args.trimmingCharacters(in: .whitespacesAndNewlines))'"
        }
        let eventType = parsedEvent.eventType

        var shouldCapture = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropOverlay(
                pasteboardTypes: pb.types,
                eventType: eventType
            )
        }

        return shouldCapture ? "true" : "false"
    }

    private func overlayDropGate(_ args: String) -> String {
        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasLocalDraggingSource: Bool
        switch token {
        case "", "external":
            hasLocalDraggingSource = false
        case "local":
            hasLocalDraggingSource = true
        default:
            return "ERROR: Usage: overlay_drop_gate [external|local]"
        }

        var shouldCapture = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            shouldCapture = DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: pb.types,
                hasLocalDraggingSource: hasLocalDraggingSource
            )
        }
        return shouldCapture ? "true" : "false"
    }

    private func portalHitGate(_ args: String) -> String {
        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !token.isEmpty else {
            return "ERROR: Usage: portal_hit_gate <leftMouseDragged|rightMouseDragged|otherMouseDragged|mouseMoved|mouseEntered|mouseExited|flagsChanged|cursorUpdate|appKitDefined|systemDefined|applicationDefined|periodic|leftMouseDown|leftMouseUp|rightMouseDown|rightMouseUp|otherMouseDown|otherMouseUp|scrollWheel|none>"
        }
        let parsedEvent = parseOverlayEventType(token)
        guard parsedEvent.isKnown else {
            return "ERROR: Unknown event type '\(args.trimmingCharacters(in: .whitespacesAndNewlines))'"
        }
        let eventType = parsedEvent.eventType

        var shouldPassThrough = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            let types = pb.types
            shouldPassThrough = DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                pasteboardTypes: types,
                eventType: eventType,
                hasLiveTabTransfer: DragOverlayRoutingPolicy.hasLiveTabTransfer(
                    in: pb,
                    pasteboardTypes: types,
                    resolver: AppDelegate.shared?.liveTabDragCapabilityResolver
                ),
                hasLiveFileDropPayload: DragOverlayRoutingPolicy.hasLiveFileDropPayload(
                    from: pb,
                    pasteboardTypes: types,
                    resolver: AppDelegate.shared?.liveTabDragCapabilityResolver
                )
            )
        }
        return shouldPassThrough ? "true" : "false"
    }

    private func sidebarOverlayGate(_ args: String) -> String {
        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasSidebarDragState: Bool
        switch token {
        case "", "active":
            hasSidebarDragState = true
        case "inactive":
            hasSidebarDragState = false
        default:
            return "ERROR: Usage: sidebar_overlay_gate [active|inactive]"
        }

        var shouldCapture = false
        v2MainSync {
            let pb = NSPasteboard(name: .drag)
            let currentSessionId = AppDelegate.shared?.sidebarWorkspaceDragRegistry.currentSessionId
            shouldCapture = SidebarWorkspaceReorderDropOverlay.shouldCaptureHitTest(
                eventType: .leftMouseDragged,
                pasteboardTypes: pb.types,
                hasLiveWorkspaceDrag: hasSidebarDragState
                    && SidebarTabDragPayload.hasLiveSession(
                        in: pb,
                        currentSessionId: currentSessionId
                    )
            )
        }
        return shouldCapture ? "true" : "false"
    }

    private func terminalDropOverlayProbe(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let token = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let useDeferredPath: Bool
        switch token {
        case "", "deferred":
            useDeferredPath = true
        case "direct":
            useDeferredPath = false
        default:
            return "ERROR: Usage: terminal_drop_overlay_probe [deferred|direct]"
        }

        var result = "ERROR: No selected workspace"
        v2MainSync {
            guard let selectedId = tabManager.selectedTabId,
                  let workspace = tabManager.tabs.first(where: { $0.id == selectedId }) else {
                return
            }

            let terminalPanel = workspace.focusedTerminalInputTarget()?.panel
                ?? orderedPanels(in: workspace).compactMap { $0 as? TerminalPanel }.first
            guard let terminalPanel else {
                result = "ERROR: No terminal panel available"
                return
            }

            let probe = terminalPanel.hostedView.debugProbeDropOverlayAnimation(
                useDeferredPath: useDeferredPath
            )
            let animated = probe.after > probe.before
            let mode = useDeferredPath ? "deferred" : "direct"
            result = String(
                format: "OK mode=%@ animated=%d before=%d after=%d bounds=%.1fx%.1f",
                mode,
                animated ? 1 : 0,
                probe.before,
                probe.after,
                probe.bounds.width,
                probe.bounds.height
            )
        }
        return result
    }

    private func parseOverlayEventType(_ token: String) -> (isKnown: Bool, eventType: NSEvent.EventType?) {
        switch token {
        case "leftmousedragged":
            return (true, .leftMouseDragged)
        case "rightmousedragged":
            return (true, .rightMouseDragged)
        case "othermousedragged":
            return (true, .otherMouseDragged)
        case "mousemove", "mousemoved":
            return (true, .mouseMoved)
        case "mouseentered":
            return (true, .mouseEntered)
        case "mouseexited":
            return (true, .mouseExited)
        case "flagschanged":
            return (true, .flagsChanged)
        case "cursorupdate":
            return (true, .cursorUpdate)
        case "appkitdefined":
            return (true, .appKitDefined)
        case "systemdefined":
            return (true, .systemDefined)
        case "applicationdefined":
            return (true, .applicationDefined)
        case "periodic":
            return (true, .periodic)
        case "leftmousedown":
            return (true, .leftMouseDown)
        case "leftmouseup":
            return (true, .leftMouseUp)
        case "rightmousedown":
            return (true, .rightMouseDown)
        case "rightmouseup":
            return (true, .rightMouseUp)
        case "othermousedown":
            return (true, .otherMouseDown)
        case "othermouseup":
            return (true, .otherMouseUp)
        case "scrollwheel":
            return (true, .scrollWheel)
        case "none":
            return (true, nil)
        default:
            return (false, nil)
        }
    }

    private func dragPasteboardType(from token: String) -> NSPasteboard.PasteboardType? {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "fileurl", "file-url", "public.file-url":
            return .fileURL
        case "tabtransfer", "tab-transfer", "com.splittabbar.tabtransfer":
            return DragOverlayRoutingPolicy.bonsplitTabTransferType
        case "sidebarreorder", "sidebar-reorder", "sidebar_tab_reorder",
            "com.cmux.sidebar-tab-reorder":
            return DragOverlayRoutingPolicy.sidebarTabReorderType
        default:
            // Allow explicit UTI strings for ad-hoc debug probes.
            guard token.contains(".") else { return nil }
            return NSPasteboard.PasteboardType(token)
        }
    }

    /// Hit-tests the file-drop overlay's coordinate-to-terminal mapping.
    /// Takes normalised (0-1) x,y within the content area where (0,0) is the
    /// top-left corner and (1,1) is the bottom-right corner.  Returns the
    /// surface UUID of the terminal under that point, or "none".
    private func dropHitTest(_ args: String) -> String {
        let parts = args.split(separator: " ").map(String.init)
        guard parts.count == 2,
              let nx = Double(parts[0]), let ny = Double(parts[1]),
              (0...1).contains(nx), (0...1).contains(ny) else {
            return "ERROR: Usage: drop_hit_test <x 0-1> <y 0-1>"
        }

        var result = "ERROR: No window"
        v2MainSync {
            guard let window = NSApp.mainWindow
                ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { win in
                    guard let raw = win.identifier?.rawValue else { return false }
                    return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
                }),
                  let contentView = window.contentView,
                  let themeFrame = contentView.superview else { return }

            // Convert normalized top-left coordinates into a window point.
            let pointInTheme = NSPoint(
                x: contentView.frame.minX + (contentView.bounds.width * nx),
                y: contentView.frame.maxY - (contentView.bounds.height * ny)
            )
            let windowPoint = themeFrame.convert(pointInTheme, to: nil)

            if let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? FileDropOverlayView,
               let terminal = overlay.terminalUnderPoint(windowPoint),
               let surfaceId = terminal.terminalSurface?.id {
                result = surfaceId.uuidString.uppercased()
                return
            }

            result = "none"
        }
        return result
    }

    /// Return the hit-test chain at normalized (0-1) coordinates in the main window's
    /// content area. Used by regression tests to detect root-level drag destinations
    /// shadowing pane-local Bonsplit drop targets.
    private func dragHitChain(_ args: String) -> String {
        let parts = args.split(separator: " ").map(String.init)
        guard parts.count == 2 || parts.count == 3,
              let nx = Double(parts[0]), let ny = Double(parts[1]),
              (0...1).contains(nx), (0...1).contains(ny),
              parts.count == 2 || parts[2] == "content" || parts[2] == "theme" else {
            return "ERROR: Usage: drag_hit_chain <x 0-1> <y 0-1> [theme|content]"
        }
        // `content` reproduces the traversal Bonsplit's tab-drag veto and the
        // sidebar-divider diagnostic use (`contentView.hitTest` with a point
        // converted into the content view), and reports the geometry that
        // decides whether that traversal agrees with the theme-frame one.
        let traversesContentView = parts.count == 3 && parts[2] == "content"

        var result = "ERROR: No window"
        v2MainSync {
            guard let window = NSApp.mainWindow
                ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { win in
                    guard let raw = win.identifier?.rawValue else { return false }
                    return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
                }),
                  let contentView = window.contentView,
                  let themeFrame = contentView.superview else { return }

            let pointInTheme = NSPoint(
                x: contentView.frame.minX + (contentView.bounds.width * nx),
                y: contentView.frame.maxY - (contentView.bounds.height * ny)
            )

            let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? NSView
            if let overlay { overlay.isHidden = true }
            defer { overlay?.isHidden = false }

            let geometry = "geometry contentFrame=\(NSStringFromRect(contentView.frame)) " +
                "contentBounds=\(NSStringFromRect(contentView.bounds)) " +
                "contentFlipped=\(contentView.isFlipped) themeFlipped=\(themeFrame.isFlipped) " +
                "currentEvent=\(NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil")"
            let resolvedHit: NSView?
            if traversesContentView {
                let windowPoint = themeFrame.convert(pointInTheme, to: nil)
                resolvedHit = contentView.hitTest(contentView.convert(windowPoint, from: nil))
            } else {
                resolvedHit = themeFrame.hitTest(pointInTheme)
            }
            guard let hit = resolvedHit else {
                result = "none " + geometry
                return
            }

            var chain: [String] = []
            var current: NSView? = hit
            var depth = 0
            while let view = current, depth < 8 {
                chain.append(debugDragHitViewDescriptor(view))
                current = view.superview
                depth += 1
            }
            result = chain.joined(separator: "->") + " " + geometry
        }
        return result
    }

    private func debugDragHitViewDescriptor(_ view: NSView) -> String {
        let className = String(describing: type(of: view))
        let pointer = String(describing: Unmanaged.passUnretained(view).toOpaque())
        let types = view.registeredDraggedTypes
        let renderedTypes: String
        if types.isEmpty {
            renderedTypes = "-"
        } else {
            let raw = types.map(\.rawValue)
            renderedTypes = raw.count <= 4
                ? raw.joined(separator: ",")
                : raw.prefix(4).joined(separator: ",") + ",+\(raw.count - 4)"
        }
        return "\(className)@\(pointer){dragTypes=\(renderedTypes)}"
    }

    private func unescapeSocketText(_ input: String) -> String {
        var out = ""
        var escaping = false
        for ch in input {
            if escaping {
                switch ch {
                case "n":
                    out.append("\n")
                case "r":
                    out.append("\r")
                case "t":
                    out.append("\t")
                case "\\":
                    out.append("\\")
                default:
                    out.append("\\")
                    out.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        if escaping {
            out.append("\\")
        }
        return out
    }

    static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var r = start
        var hops = 0
        while let cur = r, hops < 64 {
            if cur === target { return true }
            r = cur.nextResponder
            hops += 1
        }
        return false
    }

    func isTerminalFocused(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: is_terminal_focused <panel_id|idx>" }

        var result = "false"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "false"
                return
            }

            guard let panelId = resolveSurfaceId(from: panelArg, tab: tab),
                  let terminalPanel = tab.terminalInputTarget(forPanelID: panelId)?.panel else {
                result = "false"
                return
            }
            result = terminalPanel.hostedView.isSurfaceViewFirstResponder() ? "true" : "false"
        }
        return result
    }

    func readTerminalText(_ args: String) -> String {
        readTerminalTextBase64(surfaceArg: args)
    }

    private struct RenderStatsResponse: Codable {
        let panelId: String
        let drawCount: Int
        let lastDrawTime: Double
        let metalDrawableCount: Int
        let metalLastDrawableTime: Double
        let presentCount: Int
        let lastPresentTime: Double
        let layerClass: String
        let layerContentsKey: String
        let inWindow: Bool
        let windowIsKey: Bool
        let windowOcclusionVisible: Bool
        let appIsActive: Bool
        let isActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
    }

    func renderStats(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)

        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let panelId: UUID?
            if panelArg.isEmpty {
                panelId = tab.focusedPanelId
            } else {
                panelId = resolveSurfaceId(from: panelArg, tab: tab)
            }

            guard let panelId,
                  let terminalPanel = tab.terminalInputTarget(forPanelID: panelId)?.panel else {
                result = "ERROR: Terminal surface not found"
                return
            }

            let stats = terminalPanel.hostedView.debugRenderStats()
            let payload = RenderStatsResponse(
                panelId: terminalPanel.id.uuidString,
                drawCount: stats.drawCount,
                lastDrawTime: stats.lastDrawTime,
                metalDrawableCount: stats.metalDrawableCount,
                metalLastDrawableTime: stats.metalLastDrawableTime,
                presentCount: stats.presentCount,
                lastPresentTime: stats.lastPresentTime,
                layerClass: stats.layerClass,
                layerContentsKey: stats.layerContentsKey,
                inWindow: stats.inWindow,
                windowIsKey: stats.windowIsKey,
                windowOcclusionVisible: stats.windowOcclusionVisible,
                appIsActive: stats.appIsActive,
                isActive: stats.isActive,
                desiredFocus: stats.desiredFocus,
                isFirstResponder: stats.isFirstResponder
            )

            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(payload),
                  let json = String(data: data, encoding: .utf8) else {
                result = "ERROR: Failed to encode render_stats"
                return
            }

            result = "OK \(json)"
        }

        return result
    }

#endif

    #if !DEBUG
    static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var responder = start
        var hops = 0
        while let current = responder, hops < 64 {
            if current === target { return true }
            responder = current.nextResponder
            hops += 1
        }
        return false
    }
    #endif

    /// `list_windows` worker body (tranche D of issue #5757): one v2MainSync
    /// snapshot hop (the handler was already hop-shaped); the line formatting
    /// runs on the calling socket-worker thread. Shared by the worker lane
    /// and the legacy processCommand dispatch (inline-collapsing hop).
    private nonisolated func listWindows() -> String {
        let summaries = v2MainSync { AppDelegate.shared?.listMainWindowSummaries() } ?? []
        guard !summaries.isEmpty else { return "No windows" }

        let lines = summaries.enumerated().map { idx, item in
            let selected = item.isKeyWindow ? "*" : " "
            let selectedWs = item.selectedWorkspaceId?.uuidString ?? "none"
            return "\(selected) \(idx): \(item.windowId.uuidString) selected_workspace=\(selectedWs) workspaces=\(item.workspaceCount)"
        }
        return lines.joined(separator: "\n")
    }

    /// The `current_window` hop outcome (reply strings selected off-main).
    private enum CurrentWindowHopOutcome {
        case tabManagerUnavailable
        case noActiveWindow
        case windowID(UUID)
    }

    /// `current_window` worker body: the main-actor `tabManager` read and the
    /// window resolution take one v2MainSync hop (the legacy body read the
    /// property at handler entry on main); uuidString formatting and the
    /// error strings run on the calling thread, in the same order.
    private nonisolated func currentWindow() -> String {
        let outcome: CurrentWindowHopOutcome = v2MainSync {
            guard let tabManager = self.tabManager else { return .tabManagerUnavailable }
            guard let windowId = self.v2ResolveWindowId(tabManager: tabManager) else { return .noActiveWindow }
            return .windowID(windowId)
        }
        switch outcome {
        case .tabManagerUnavailable: return "ERROR: TabManager not available"
        case .noActiveWindow: return "ERROR: No active window"
        case .windowID(let windowId): return windowId.uuidString
        }
    }

    private func focusWindow(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let windowId = UUID(uuidString: trimmed) else { return "ERROR: Invalid window id" }

        let ok = v2MainSync { AppDelegate.shared?.focusMainWindow(windowId: windowId) ?? false }
        guard ok else { return "ERROR: Window not found" }

        if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(windowId: windowId) }) {
            setActiveTabManager(tm)
        }
        return "OK"
    }

    private func newWindow() -> String {
        guard let windowId = v2MainSync({ self.controlCreateWindowAndActivate(title: nil) }) else {
            return "ERROR: Failed to create window"
        }
        return "OK \(windowId.uuidString)"
    }

    /// `resize_window <window_id> <width|-> <height|->` — `-` keeps that dimension.
    /// Both `-` is a frame read: nothing changes and the current size comes back.
    /// Reports the window FRAME size (title bar included), matching what
    /// `resizeMainWindow` sets and returns.
    private func resizeWindow(_ args: String) -> String {
        let parts = args.split(separator: " ").map(String.init)
        // Exactly three: the grammar has no optional tail, and silently ignoring extra
        // tokens turns a malformed command into a successful resize.
        guard parts.count == 3 else { return "ERROR: Usage resize_window <window_id> <width|-> <height|->" }
        guard let windowId = UUID(uuidString: parts[0]) else { return "ERROR: Invalid window id" }

        // A dimension must survive the CGFloat math and the Int in the reply:
        // Int(Double.nan) traps at runtime, so nothing non-finite may pass, and
        // zero or negative sizes are refusals AppKit would express as clamping.
        func parseDimension(_ raw: String, name: String) -> (value: Double?, error: String?) {
            if raw == "-" { return (nil, nil) }
            guard let value = Double(raw), value.isFinite, value > 0, value <= 100_000 else {
                return (nil, "ERROR: Invalid \(name)")
            }
            return (value, nil)
        }
        let width = parseDimension(parts[1], name: "width")
        if let error = width.error { return error }
        let height = parseDimension(parts[2], name: "height")
        if let error = height.error { return error }

        // NSWindow frames are main-thread only; parsing above stays off main.
        let size = v2MainSync {
            AppDelegate.shared?.resizeMainWindow(
                windowId: windowId,
                width: width.value.map { CGFloat($0) },
                height: height.value.map { CGFloat($0) }
            )
        }
        guard let size = size ?? nil else { return "ERROR: Window not found" }
        return "OK \(Int(size.width)) \(Int(size.height))"
    }

    private func closeWindow(_ arg: String) -> String {
        let parts = arg.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let windowId = parts.first.flatMap(UUID.init(uuidString:)),
              parts.dropFirst().allSatisfy({ $0 == "--force" }) else {
            return "ERROR: Invalid window id"
        }
        let force = parts.dropFirst().contains("--force")
        let outcome = v2MainSync { controlCloseWindow(id: windowId, force: force) }
        switch outcome {
        case .resolved:
            return "OK"
        case .notFound:
            return "ERROR: Window not found"
        case .confirmationRequired:
            return "ERROR: \(controlWindowCloseStrings().confirmationRequired)"
        }
    }

    private func moveWorkspaceToWindow(_ args: String) -> String {
        let parts = args.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return "ERROR: Usage move_workspace_to_window <workspace_id> <window_id>" }
        guard let wsId = UUID(uuidString: parts[0]) else { return "ERROR: Invalid workspace id" }
        guard let windowId = UUID(uuidString: parts[1]) else { return "ERROR: Invalid window id" }

        var ok = false
        let focus = socketCommandAllowsInAppFocusMutations()
        v2MainSync {
            guard let srcTM = AppDelegate.shared?.tabManagerFor(tabId: wsId),
                  let dstTM = AppDelegate.shared?.tabManagerFor(windowId: windowId),
                  let ws = srcTM.detachWorkspace(tabId: wsId) else {
                ok = false
                return
            }
            dstTM.attachWorkspace(ws, select: focus)
            if focus {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(dstTM)
            }
            ok = true
        }

        return ok ? "OK" : "ERROR: Move failed"
    }

    /// One `list_workspaces` row snapshot (Sendable value copies of the
    /// main-actor workspace state the formatting needs).
    private struct ListWorkspacesRow {
        let id: UUID
        let title: String
        let selected: Bool
    }

    /// `list_workspaces` worker body (tranche D of issue #5757): the
    /// main-actor `tabManager` guard and the tab snapshot take one v2MainSync
    /// hop (the legacy body read the property at handler entry on main and
    /// formatted inside its hop); the line formatting and join run on the
    /// calling socket-worker thread. Shared by the worker lane and the legacy
    /// processCommand dispatch (inline-collapsing hop).
    private nonisolated func listWorkspaces() -> String {
        let rows: [ListWorkspacesRow]? = v2MainSync {
            guard let tabManager = self.tabManager else { return nil }
            return tabManager.tabs.map { tab in
                ListWorkspacesRow(
                    id: tab.id,
                    title: tab.title,
                    selected: tab.id == tabManager.selectedTabId
                )
            }
        }
        guard let rows else { return "ERROR: TabManager not available" }
        let result = rows.enumerated().map { index, row in
            let selected = row.selected ? "*" : " "
            return "\(selected) \(index): \(row.id.uuidString) \(row.title)"
        }.joined(separator: "\n")
        return result.isEmpty ? "No workspaces" : result
    }

    private func newWorkspace(_ args: String = "") -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String? = trimmed.isEmpty ? nil : trimmed

        var newTabId: UUID?
        let focus = socketCommandAllowsInAppFocusMutations()
        v2MainSync {
            guard let workspace = tabManager.addWorkspaceIfActive(
                title: title,
                select: focus,
                eagerLoadTerminal: !focus,
                allowTextBoxFocusDefault: false
            ) else { return }
            newTabId = workspace.id
        }
        guard let newTabId else {
            return "ERROR: Failed to create workspace"
        }
        return "OK \(newTabId.uuidString)"
    }

    /// v1 socket error for a left/up split directed at a mirror workspace
    /// (kept here for the still-app-side v1 `new_split`; the coordinator-side
    /// v1 `new_pane` carries the same wording via its sidebar context).
    private static let v1MirrorDirectionError =
        "ERROR: direction left/up is not supported in a remote tmux mirror workspace"

    private func newSplit(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }

        let directionArg = parts[0]
        let panelArg = parts.count > 1 ? parts[1] : ""

        guard let direction = parseSplitDirection(directionArg) else {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }

        var result = "ERROR: Failed to create split"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // If panel arg provided, resolve it; otherwise use focused panel
            let surfaceId: UUID?
            if !panelArg.isEmpty {
                surfaceId = resolveSurfaceId(from: panelArg, tab: tab)
                if surfaceId == nil {
                    result = "ERROR: Panel not found"
                    return
                }
            } else {
                surfaceId = tab.focusedPanelId
            }

            guard let targetSurface = surfaceId else {
                result = "ERROR: No surface to split"
                return
            }

            if tab.isRemoteTmuxMirror, direction.insertFirst {
                // Routed tmux `split-window` cannot insert before the target
                // pane; reject before mutating the remote session.
                result = Self.v1MirrorDirectionError
                return
            }

            switch tab.newTerminalSplitOutcome(
                from: targetSurface,
                orientation: direction.orientation,
                insertFirst: direction.insertFirst,
                allowTextBoxFocusDefault: false,
                inheritStartupWork: false
            ) {
            case .created(let panel):
                tab.equalizeSplitsAfterCreatingSplitIfEnabled(newPanelId: panel.id)
                result = "OK \(panel.id.uuidString)"
            case .routedToRemote:
                result = "OK routed-to-remote-tmux"
            case .noSpace:
                result = "ERROR: No space for new pane"
            case .failed:
                break
            }
        }
        return result
    }

    /// The `list_surfaces` hop outcome: the (id, focused) value pairs, or the
    /// resolution error selected in the legacy order.
    private enum ListSurfacesHopOutcome {
        case tabManagerUnavailable
        case tabNotFound
        case surfaces([(id: UUID, focused: Bool)])
    }

    /// `list_surfaces` worker body (tranche D of issue #5757): the main-actor
    /// `tabManager` guard, the tab-arg resolution (over main-actor tabs), and
    /// the ordered-panel snapshot take one v2MainSync hop; line formatting
    /// and join run on the calling socket-worker thread. Shared by the worker
    /// lane and the legacy processCommand dispatch (inline-collapsing hop).
    private nonisolated func listSurfaces(_ tabArg: String) -> String {
        let outcome: ListSurfacesHopOutcome = v2MainSync {
            guard let tabManager = self.tabManager else { return .tabManagerUnavailable }
            guard let tab = self.resolveTab(from: tabArg, tabManager: tabManager) else {
                return .tabNotFound
            }
            let focusedId = tab.focusedPanelId
            return .surfaces(self.orderedPanels(in: tab).map { panel in
                (id: panel.id, focused: panel.id == focusedId)
            })
        }
        switch outcome {
        case .tabManagerUnavailable:
            return "ERROR: TabManager not available"
        case .tabNotFound:
            return "ERROR: Tab not found"
        case .surfaces(let surfaces):
            let lines = surfaces.enumerated().map { index, surface in
                let selected = surface.focused ? "*" : " "
                return "\(selected) \(index): \(surface.id.uuidString)"
            }
            return lines.isEmpty ? "No surfaces" : lines.joined(separator: "\n")
        }
    }

    private func focusSurface(_ arg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing panel id or index" }

        var success = false
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            guard let surfaceId = resolveSurfaceId(from: trimmed, tab: tab) else { return }
            success = true
        }

        return success ? "OK" : "ERROR: Panel not found"
    }

    /// `notify` — worker-lane body: the payload parse (which never fails)
    /// and the settings-gate read run on the calling thread; the
    /// TabManager/selected-tab guards and the synchronous delivery are the
    /// command's single main hop. The gate verdict applies at the legacy
    /// guard position (after the selected-tab guard, before delivery), so a
    /// gated request still reports tab errors exactly like the main lane.
    private nonisolated func notifyCurrent(_ args: String) -> String {
        let (title, subtitle, body, meta) = parseNotificationPayload(args)
        let deliver = shouldDeliverAgentNotification(meta)
        return v2MainSync {
            guard let tabManager = self.tabManager else { return "ERROR: TabManager not available" }
            guard let tabId = tabManager.selectedTabId else {
                return "ERROR: No tab selected"
            }
            let surfaceId = tabManager.focusedSurfaceId(for: tabId)
            guard deliver else { return "OK" }
            self.deliverNotificationSynchronously(
                tabId: tabId,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body,
                replyShape: TerminalNotificationReplyShape.forAgentCategory(wire: meta?.category.rawValue),
                agent: AgentNotificationDelivery.agentContext(
                    category: meta?.category,
                    pending: meta?.pending ?? false,
                    agentKind: meta?.agentKind,
                    isSubagent: meta?.isSubagent
                ),
                soundContext: meta?.soundContext,
                correlationKey: meta?.correlationKey
            )
            return "OK"
        }
    }

    /// `notify_surface` — worker-lane body: the argument split, payload
    /// parse, and settings-gate read run on the calling thread; the guards
    /// run inside the single main hop in the legacy order (TabManager first,
    /// then the missing-argument usage error) so multi-error requests report
    /// the same error as before, and the gate verdict applies after the
    /// surface resolves (the legacy gate position).
    private nonisolated func notifySurface(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let surfaceArg = parts.first ?? ""
        let payload = parts.count > 1 ? parts[1] : ""
        let (title, subtitle, body, meta) = parseNotificationPayload(payload)
        let deliver = shouldDeliverAgentNotification(meta)

        return v2MainSync {
            guard let tabManager = self.tabManager else { return "ERROR: TabManager not available" }
            guard !trimmed.isEmpty else { return "ERROR: Missing surface id or index" }
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return "ERROR: No tab selected"
            }
            guard let surfaceId = self.resolveSurfaceId(from: surfaceArg, tab: tab) else {
                return "ERROR: Surface not found"
            }
            guard deliver else { return "OK" }
            self.deliverNotificationSynchronously(
                tabId: tabId,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body,
                replyShape: TerminalNotificationReplyShape.forAgentCategory(wire: meta?.category.rawValue),
                agent: AgentNotificationDelivery.agentContext(
                    category: meta?.category,
                    pending: meta?.pending ?? false,
                    agentKind: meta?.agentKind,
                    isSubagent: meta?.isSubagent
                ),
                soundContext: meta?.soundContext,
                correlationKey: meta?.correlationKey
            )
            return "OK"
        }
    }

    /// `notify_target` — worker-lane body: split/UUID/payload parse and the
    /// settings-gate read on the calling thread; the legacy guard order
    /// (TabManager, then the usage errors, then the gate verdict, then the
    /// UUID fast path vs index/name fallback) runs inside the single main
    /// hop, which collapses the two former per-branch hops into one (the
    /// branches were mutually exclusive per request). The gate applies
    /// BEFORE target resolution — a gated request replies OK without
    /// reporting tab/panel lookup errors, exactly like the main lane.
    private nonisolated func notifyTarget(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        let tabArg = parts.count > 0 ? parts[0] : ""
        let panelArg = parts.count > 1 ? parts[1] : ""
        let payload = parts.count > 2 ? parts[2] : ""
        let (title, subtitle, body, meta) = parseNotificationPayload(payload)
        let deliver = shouldDeliverAgentNotification(meta)
        let fastPath: (workspaceId: UUID, panelId: UUID)?
        if let workspaceId = UUID(uuidString: tabArg), let panelId = UUID(uuidString: panelArg) {
            fastPath = (workspaceId, panelId)
        } else {
            fastPath = nil
        }

        return v2MainSync {
            guard let tabManager = self.tabManager else { return "ERROR: TabManager not available" }
            guard !trimmed.isEmpty else { return "ERROR: Usage: notify_target <workspace_id> <surface_id> <title>|<subtitle>|<body>" }
            guard parts.count >= 2 else { return "ERROR: Usage: notify_target <workspace_id> <surface_id> <title>|<subtitle>|<body>" }
            guard deliver else { return "OK" }

            if let fastPath {
                // The surface's current workspace wins over the claimed one (the
                // sync deliverer retargets); only a target gone everywhere errors.
                guard AppDelegate.shared?.agentNotificationDeliveryTarget(claimedTabId: fastPath.workspaceId, surfaceId: fastPath.panelId) != nil else {
                    return "ERROR: Panel not found"
                }
                self.deliverNotificationSynchronously(
                    tabId: fastPath.workspaceId,
                    surfaceId: fastPath.panelId,
                    title: title,
                    subtitle: subtitle,
                    body: body,
                    replyShape: TerminalNotificationReplyShape.forAgentCategory(wire: meta?.category.rawValue),
                    agent: AgentNotificationDelivery.agentContext(
                        category: meta?.category,
                        pending: meta?.pending ?? false,
                        agentKind: meta?.agentKind,
                        isSubagent: meta?.isSubagent
                    ),
                    soundContext: meta?.soundContext,
                    correlationKey: meta?.correlationKey
                )
                return "OK"
            }

            let tab: Tab?
            if let tabId = UUID(uuidString: tabArg) {
                tab = self.tabForSidebarMutation(id: tabId)
            } else {
                tab = self.resolveTab(from: tabArg, tabManager: tabManager)
            }
            guard let tab else {
                return "ERROR: Tab not found"
            }
            guard let panelId = UUID(uuidString: panelArg),
                  AppDelegate.shared?.agentNotificationDeliveryTarget(claimedTabId: tab.id, surfaceId: panelId) != nil else {
                return "ERROR: Panel not found"
            }
            self.deliverNotificationSynchronously(
                tabId: tab.id,
                surfaceId: panelId,
                title: title,
                subtitle: subtitle,
                body: body,
                replyShape: TerminalNotificationReplyShape.forAgentCategory(wire: meta?.category.rawValue),
                agent: AgentNotificationDelivery.agentContext(
                    category: meta?.category,
                    pending: meta?.pending ?? false,
                    agentKind: meta?.agentKind,
                    isSubagent: meta?.isSubagent
                ),
                soundContext: meta?.soundContext,
                correlationKey: meta?.correlationKey
            )
            return "OK"
        }
    }

    /// `notify_target_async` — worker-lane body with ZERO main hops: parse +
    /// mutation-bus enqueue on the calling thread (the bus coalesces and
    /// drains on the main actor). Explicitly fire-and-forget: hooks nohup it
    /// and discard the reply; existence checks are deferred to bus delivery
    /// by design.
    private nonisolated func notifyTargetQueued(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "ERROR: Usage: notify_target_async <workspace_uuid> <surface_uuid> <title>|<subtitle>|<body>"
        }

        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            return "ERROR: Usage: notify_target_async <workspace_uuid> <surface_uuid> <title>|<subtitle>|<body>"
        }
        guard let tabId = UUID(uuidString: parts[0]) else {
            return "ERROR: notify_target_async requires workspace_uuid to be a UUID"
        }
        guard let surfaceId = UUID(uuidString: parts[1]) else {
            return "ERROR: notify_target_async requires surface_uuid to be a UUID"
        }

        let payload = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            return "ERROR: Usage: notify_target_async <workspace_uuid> <surface_uuid> <title>|<subtitle>|<body>"
        }
        let (title, subtitle, body, meta) = parseNotificationPayload(payload)

        // Hook and PTY-derived agent notifications share one gate + mutation-bus path.
        guard AgentNotificationDelivery().enqueue(
            workspaceID: tabId,
            surfaceID: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            category: meta?.category,
            pending: meta?.pending ?? false,
            soundContext: meta?.soundContext,
            agentKind: meta?.agentKind,
            isSubagent: meta?.isSubagent,
            correlationKey: meta?.correlationKey
        ) else {
#if DEBUG
            if let meta {
                cmuxDebugLog(
                    "socket.notifyTargetAsync.gated category=\(meta.category.rawValue) pending=\(meta.pending) workspace=\(tabId.uuidString.prefix(8)) surface=\(surfaceId.uuidString.prefix(8))"
                )
            }
#endif
            return "OK"
        }
#if DEBUG
        cmuxDebugLog(
            "socket.notifyTargetAsync.enqueue workspace=\(tabId.uuidString.prefix(8)) surface=\(surfaceId.uuidString.prefix(8)) titleLen=\(title.count) subtitleLen=\(subtitle.count) bodyLen=\(body.count) coalesces=0"
        )
#endif
        return "OK"
    }

    /// `list_notifications` — worker-lane body: one main hop snapshots the
    /// store (plus each notification's tab title); the ISO8601 formatting,
    /// percent-escaping, and line join run on the calling thread.
    private nonisolated func listNotifications() -> String {
        let rows: [(id: UUID, tabId: UUID, surfaceText: String, readText: String, title: String, subtitle: String, body: String, createdAt: Date, tabTitle: String)] = v2MainSync {
            TerminalNotificationStore.shared.notifications.map { notification in
                (
                    id: notification.id,
                    tabId: notification.tabId,
                    surfaceText: notification.surfaceId?.uuidString ?? "none",
                    readText: notification.isRead ? "read" : "unread",
                    title: notification.title,
                    subtitle: notification.subtitle,
                    body: notification.body,
                    createdAt: notification.createdAt,
                    tabTitle: AppDelegate.shared?.tabTitle(for: notification.tabId) ?? ""
                )
            }
        }
        let lines = rows.enumerated().map { index, row in
            let createdAt = Self.notificationCreatedAtString(row.createdAt)
            let tabTitle = Self.notificationListTrailingField(row.tabTitle)
            return "\(index):\(row.id.uuidString)|\(row.tabId.uuidString)|\(row.surfaceText)|\(row.readText)|\(row.title)|\(row.subtitle)|\(row.body)|\(createdAt)|\(tabTitle)"
        }
        let result = lines.joined(separator: "\n")
        return result.isEmpty ? "No notifications" : result
    }

    /// `clear_notifications` — worker-lane body with ZERO main hops: parse on
    /// the calling thread; every branch is a lock-guarded mutation-bus enqueue
    /// (the tab/panel resolution runs inside the deferred main-actor closure,
    /// exactly as before — the bus already returned OK before apply).
    private nonisolated func clearNotifications(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            TerminalMutationBus.shared.enqueueClearAllNotifications()
            return "OK"
        }
        let parsed = parseOptions(trimmed)
        guard let tabOption = parsed.options["tab"],
              !tabOption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let usage = String(
                localized: "cli.error.clearNotificationsUsage",
                defaultValue: "clear_notifications [--tab=X] [--panel=ID] [--correlation-key=UUID]"
            )
            return "ERROR: Usage: \(usage)"
        }
        let targetResolution = parseSidebarMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: Tab not found"
        }
        let usage = String(
            localized: "cli.error.clearNotificationsUsage",
            defaultValue: "clear_notifications [--tab=X] [--panel=ID] [--correlation-key=UUID]"
        )
        let panelResolution = parseOptionalPanelIdOption(options: parsed.options, usage: usage)
        if let error = panelResolution.error {
            return error
        }
        let correlationKey: String?
        if let rawCorrelationKey = parsed.options["correlation-key"] {
            let normalized = rawCorrelationKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let uuid = UUID(uuidString: normalized) else {
                return "ERROR: " + String(
                    localized: "cli.error.clearNotificationsCorrelationKeyInvalid",
                    defaultValue: "Invalid notification correlation key"
                )
            }
            correlationKey = uuid.uuidString.lowercased()
            guard panelResolution.panelId != nil else {
                return "ERROR: " + String(
                    localized: "cli.error.clearNotificationsCorrelationKeyRequiresPanel",
                    defaultValue: "--correlation-key requires --panel"
                )
            }
        } else {
            correlationKey = nil
        }
        if case .workspace(let tabId) = target {
            if let panelId = panelResolution.panelId {
                if let correlationKey {
                    TerminalMutationBus.shared.enqueueClearNotifications(
                        forTabId: tabId,
                        surfaceId: panelId,
                        correlationKey: correlationKey
                    )
                } else {
                    TerminalMutationBus.shared.enqueueClearNotifications(forTabId: tabId, surfaceId: panelId)
                }
            } else {
                TerminalMutationBus.shared.enqueueClearNotifications(forTabId: tabId)
            }
        } else {
            let clearBoundary = TerminalMutationBus.shared.markNotificationClearBoundary()
            TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
                guard let self, let tab = self.resolveSidebarMutationTab(target) else { return }
                if let panelId = panelResolution.panelId {
                    guard tab.panels.keys.contains(panelId) else { return }
                    if let correlationKey {
                        TerminalMutationBus.shared.discardPendingNotifications(
                            forSurfaceId: panelId,
                            correlationKey: correlationKey,
                            through: clearBoundary
                        )
                        TerminalNotificationStore.shared.clearNotifications(
                            forTabId: tab.id,
                            surfaceId: panelId,
                            correlationKey: correlationKey,
                            throughNotificationGeneration: clearBoundary
                        )
                    } else {
                        TerminalMutationBus.shared.discardPendingNotifications(
                            forTabId: tab.id,
                            surfaceId: panelId,
                            through: clearBoundary
                        )
                        TerminalNotificationStore.shared.clearNotifications(
                            forTabId: tab.id,
                            surfaceId: panelId,
                            discardQueuedNotifications: false, throughNotificationGeneration: clearBoundary
                        )
                    }
                } else {
                    TerminalMutationBus.shared.discardPendingNotifications(
                        forTabId: tab.id,
                        through: clearBoundary
                    )
                    TerminalNotificationStore.shared.clearNotifications(
                        forTabId: tab.id,
                        discardQueuedNotifications: false, throughNotificationGeneration: clearBoundary
                    )
                }
            }
        }
        return "OK"
    }

    private func setAppFocusOverride(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "active", "1", "true":
            AppFocusState.overrideIsFocused = true
            return "OK"
        case "inactive", "0", "false":
            AppFocusState.overrideIsFocused = false
            return "OK"
        case "clear", "none", "":
            AppFocusState.overrideIsFocused = nil
            return "OK"
        default:
            return "ERROR: Expected active, inactive, or clear"
        }
    }

    private func simulateAppDidBecomeActive() -> String {
        v2MainSync {
            AppDelegate.shared?.applicationDidBecomeActive(
                Notification(name: NSApplication.didBecomeActiveNotification)
            )
        }
        return "OK"
    }

#if DEBUG
    /// Drives Sleepy Mode from the debug socket so automation can exercise the
    /// overlay. `on`/`off` force a state, `toggle` flips it, and unknown commands
    /// return an error (so e.g. `unlock` can never accidentally activate it).
    func sleepyModeCommand(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts.first?.lowercased() ?? ""
        let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces).lowercased() : ""
        var isActive = false
        var holding = false
        var unknown = false
        v2MainSync {
            let store = SleepyModeController.shared.store
            switch cmd {
            case "on", "activate", "start":
                SleepyModeController.shared.activate()
            case "off", "deactivate", "stop", "unlock", "wake":
                SleepyModeController.shared.deactivate()
            case "preview":
                SleepyModeController.shared.preview()
            case "theme":
                if let theme = SleepyTheme.allCases.first(where: { $0.rawValue.lowercased() == value }) { store.theme = theme }
            case "mascot":
                if let mascot = SleepyMascot.allCases.first(where: { $0.rawValue.lowercased() == value }) { store.mascot = mascot }
            case "glow":
                if let glow = SleepyGlow.allCases.first(where: { $0.rawValue.lowercased() == value }) { store.glow = glow }
            case "toggle":
                // No scene name: flip Sleepy Mode itself. A scene name flips that toggle.
                switch value {
                case "": SleepyModeController.shared.toggle()
                case "moon": store.showMoon.toggle()
                case "stars": store.showStars.toggle()
                case "zs", "z": store.showZs.toggle()
                case "clock": store.showClock.toggle()
                case "status": store.showStatus.toggle()
                case "pets": store.showPets.toggle()
                default: unknown = true
                }
            case "customcolor":
                let fields = value.split(separator: " ").map(String.init)
                if fields.count == 2 {
                    let hex = fields[1].uppercased()
                    switch fields[0] {
                    case "face": store.customFace = hex
                    case "cap": store.customCap = hex
                    case "blush": store.customBlush = hex
                    case "eyes", "ink": store.customInk = hex
                    case "logo": store.customLogo = hex
                    case "bg", "background": store.customBackground = hex
                    default: break
                    }
                }
            case "pets":
                if value == "clear" {
                    SleepyModeController.shared.agentCensus.debugOverride = nil
                } else {
                    let n = value.split(separator: " ").map { Int($0) ?? 0 }
                    SleepyModeController.shared.agentCensus.debugOverride = SleepyAgentCounts(
                        claude: n.count > 0 ? n[0] : 0,
                        codex: n.count > 1 ? n[1] : 0,
                        opencode: n.count > 2 ? n[2] : 0,
                        pi: n.count > 3 ? n[3] : 0
                    )
                }
            default:
                unknown = true
            }
            isActive = SleepyModeController.shared.isActive
            holding = SleepyModeController.shared.isHoldingPowerAssertions
        }
        if unknown {
            return "ERROR: unknown sleepy_mode command '\(cmd)' (use on/off/toggle/preview/unlock/theme/mascot/glow/pets/customcolor)"
        }
        return "OK \(isActive ? "active" : "inactive") assertions=\(holding)"
    }

    func focusFromNotification(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let tabArg = parts.first ?? ""
        let surfaceArg = parts.count > 1 ? parts[1] : ""

        var result = "OK"
        v2MainSync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            let surfaceId = surfaceArg.isEmpty ? nil : resolveSurfaceId(from: surfaceArg, tab: tab)
            if !surfaceArg.isEmpty && surfaceId == nil {
                result = "ERROR: Surface not found"
                return
            }
            if !tabManager.focusTabFromNotification(tab.id, surfaceId: surfaceId) {
                result = "ERROR: Focus failed"
            }
        }
        return result
    }

    func flashCount(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing surface id or index" }

        var result = "ERROR: Surface not found"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }
            guard let surfaceId = resolveSurfaceId(from: trimmed, tab: tab) else {
                result = "ERROR: Surface not found"
                return
            }
            let count = GhosttySurfaceScrollView.flashCount(for: surfaceId)
            result = "OK \(count)"
        }
        return result
    }

    func resetFlashCounts() -> String {
        v2MainSync {
            GhosttySurfaceScrollView.resetFlashCounts()
        }
        return "OK"
    }

#if DEBUG
    private struct PanelSnapshotState: Sendable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let rgba: Data
    }

    /// Most tests run single-threaded but socket handlers can be invoked concurrently.
    /// Keep snapshot bookkeeping simple and thread-safe.
    private static let panelSnapshotLock = NSLock()
    private static var panelSnapshots: [UUID: PanelSnapshotState] = [:]

    func panelSnapshotReset(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: panel_snapshot_reset <panel_id|idx>" }

        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }
            guard let panelId = resolveSurfaceId(from: panelArg, tab: tab),
                  let snapshotSurfaceID = tab.terminalInputTarget(forPanelID: panelId)?.surfaceID else {
                result = "ERROR: Surface not found"
                return
            }
            Self.panelSnapshotLock.lock()
            Self.panelSnapshots.removeValue(forKey: snapshotSurfaceID)
            Self.panelSnapshotLock.unlock()
            result = "OK"
        }

        return result
    }

    private static func makePanelSnapshot(from cgImage: CGImage) -> PanelSnapshotState? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = Data(count: bytesPerRow * height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ok: Bool = data.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        return PanelSnapshotState(width: width, height: height, bytesPerRow: bytesPerRow, rgba: data)
    }

    private static func countChangedPixels(previous: PanelSnapshotState, current: PanelSnapshotState) -> Int {
        // Any mismatch means we can't sensibly diff; treat as a fresh snapshot.
        guard previous.width == current.width,
              previous.height == current.height,
              previous.bytesPerRow == current.bytesPerRow else {
            return -1
        }

        let threshold = 8 // ignore tiny per-channel jitter
        var changed = 0

        previous.rgba.withUnsafeBytes { prevRaw in
            current.rgba.withUnsafeBytes { curRaw in
                guard let prev = prevRaw.bindMemory(to: UInt8.self).baseAddress,
                      let cur = curRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return
                }

                let count = min(prevRaw.count, curRaw.count)
                var i = 0
                while i + 3 < count {
                    let dr = abs(Int(prev[i]) - Int(cur[i]))
                    let dg = abs(Int(prev[i + 1]) - Int(cur[i + 1]))
                    let db = abs(Int(prev[i + 2]) - Int(cur[i + 2]))
                    // Skip alpha channel at i+3.
                    if dr + dg + db > threshold {
                        changed += 1
                    }
                    i += 4
                }
            }
        }

        return changed
    }

    func panelSnapshot(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Usage: panel_snapshot <panel_id|idx> [label]" }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let panelArg = parts.first ?? ""
        let label = parts.count > 1 ? parts[1] : ""

        // Generate unique ID for this snapshot/screenshot
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "_")
        let shortId = UUID().uuidString.prefix(8)
        let snapshotId = "\(timestamp)_\(shortId)"

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-screenshots")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let filename = label.isEmpty ? "\(snapshotId).png" : "\(label)_\(snapshotId).png"
        let outputPath = outputDir.appendingPathComponent(filename)

        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            guard let panelId = resolveSurfaceId(from: panelArg, tab: tab),
                  let terminalPanel = tab.terminalInputTarget(forPanelID: panelId)?.panel else {
                result = "ERROR: Terminal surface not found"
                return
            }

            // Capture the terminal's IOSurface directly, avoiding Screen Recording permissions.
            let view = terminalPanel.hostedView
            var cgImage = view.debugCopyIOSurfaceCGImage()
            if cgImage == nil {
                // If the surface is mid-attach we may not have contents yet. Nudge a draw and retry once.
                terminalPanel.surface.forceRefresh(reason: "terminalController.debugCopyIOSurfaceRetry")
                cgImage = view.debugCopyIOSurfaceCGImage()
            }
            guard let cgImage else {
                result = "ERROR: Failed to capture panel image"
                return
            }

            guard let current = Self.makePanelSnapshot(from: cgImage) else {
                result = "ERROR: Failed to read panel pixels"
                return
            }

            var changedPixels = -1
            Self.panelSnapshotLock.lock()
            if let previous = Self.panelSnapshots[terminalPanel.id] {
                changedPixels = Self.countChangedPixels(previous: previous, current: current)
            }
            Self.panelSnapshots[terminalPanel.id] = current
            Self.panelSnapshotLock.unlock()

            // Save PNG for postmortem debugging.
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                result = "ERROR: Failed to encode PNG"
                return
            }

            do {
                try pngData.write(to: outputPath)
            } catch {
                result = "ERROR: Failed to write file: \(error.localizedDescription)"
                return
            }

            result = "OK \(panelId.uuidString) \(changedPixels) \(current.width) \(current.height) \(outputPath.path)"
        }

        return result
    }
#endif

    private struct LayoutDebugSelectedPanel: Codable, Sendable {
        let paneId: String
        let paneFrame: PixelRect?
        let selectedTabId: String?
        let panelId: String?
        let panelType: String?
        let inWindow: Bool?
        let hidden: Bool?
        let viewFrame: PixelRect?
        let splitViews: [LayoutDebugSplitView]?
    }

    private struct LayoutDebugSplitView: Codable, Sendable {
        let isVertical: Bool
        let dividerThickness: Double
        let bounds: PixelRect
        let frame: PixelRect?
        let arrangedSubviewFrames: [PixelRect]
        let normalizedDividerPosition: Double?
    }

    private struct LayoutDebugResponse: Codable, Sendable {
        let layout: LayoutSnapshot
        let selectedPanels: [LayoutDebugSelectedPanel]
        let mainWindowNumber: Int?
        let keyWindowNumber: Int?
    }

    func layoutDebug() -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }

        var result = "ERROR: No tab selected"
        v2MainSync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let layout = tab.bonsplitController.layoutSnapshot()
            var paneFrames: [String: PixelRect] = [:]
            for pane in layout.panes {
                paneFrames[pane.paneId] = pane.frame
            }

            @MainActor
            func isHiddenOrAncestorHidden(_ view: NSView) -> Bool {
                if view.isHidden { return true }
                var current = view.superview
                while let v = current {
                    if v.isHidden { return true }
                    current = v.superview
                }
                return false
            }

            @MainActor
            func windowFrame(for view: NSView) -> CGRect? {
                guard view.window != nil else { return nil }
                // Prefer the view's frame as laid out by its superview. Some AppKit views
                // (notably scroll views) can temporarily report stale bounds during reparenting.
                if let superview = view.superview {
                    return superview.convert(view.frame, to: nil)
                }
                return view.convert(view.bounds, to: nil)
            }

            @MainActor
            func splitViewInfos(for view: NSView) -> [LayoutDebugSplitView] {
                var infos: [LayoutDebugSplitView] = []
                var current: NSView? = view
                var depth = 0
                while let v = current, depth < 12 {
                    if let sv = v as? NSSplitView {
                        // The split view can be mid-update during bonsplit structural changes; force a layout
                        // pass so our debug snapshot reflects the real state.
                        sv.layoutSubtreeIfNeeded()
                        let isVertical = sv.isVertical
                        let dividerThickness = Double(sv.dividerThickness)
                        let bounds = PixelRect(from: sv.bounds)
                        let frame = windowFrame(for: sv).map { PixelRect(from: $0) }
                        let arranged = sv.arrangedSubviews
                        let arrangedFrames = arranged.compactMap { windowFrame(for: $0).map { PixelRect(from: $0) } }

                        // Approximate divider position from the first arranged subview's size.
                        let totalSize: CGFloat = isVertical ? sv.bounds.width : sv.bounds.height
                        let availableSize = max(totalSize - sv.dividerThickness, 0)
                        var normalized: Double? = nil
                        if availableSize > 0, let first = arranged.first {
                            let dividerPos = isVertical ? first.frame.width : first.frame.height
                            normalized = Double(dividerPos / availableSize)
                        }

                        infos.append(LayoutDebugSplitView(
                            isVertical: isVertical,
                            dividerThickness: dividerThickness,
                            bounds: bounds,
                            frame: frame,
                            arrangedSubviewFrames: arrangedFrames,
                            normalizedDividerPosition: normalized
                        ))
                    }
                    current = v.superview
                    depth += 1
                }
                return infos
            }

            let selectedPanels: [LayoutDebugSelectedPanel] = tab.bonsplitController.allPaneIds.map { paneId in
                let paneIdStr = paneId.id.uuidString
                let paneFrame = paneFrames[paneIdStr]
                let selectedTabId = layout.panes.first(where: { $0.paneId == paneIdStr })?.selectedTabId

	                guard let selectedTab = tab.bonsplitController.selectedTab(inPane: paneId) else {
	                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: nil,
	                        panelType: nil,
	                        inWindow: nil,
	                        hidden: nil,
	                        viewFrame: nil,
	                        splitViews: nil
	                    )
	                }

	                guard let panelId = tab.panelIdFromSurfaceId(selectedTab.id),
	                      let panel = tab.panels[panelId] else {
	                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: nil,
	                        panelType: nil,
	                        inWindow: nil,
	                        hidden: nil,
	                        viewFrame: nil,
	                        splitViews: nil
	                    )
	                }

                if let tp = panel as? TerminalPanel {
                    let viewRect = windowFrame(for: tp.hostedView).map { PixelRect(from: $0) }
                    let splitViews = splitViewInfos(for: tp.hostedView)
		                    return LayoutDebugSelectedPanel(
	                        paneId: paneIdStr,
	                        paneFrame: paneFrame,
	                        selectedTabId: selectedTabId,
	                        panelId: panelId.uuidString,
	                        panelType: tp.panelType.rawValue,
	                        inWindow: tp.surface.isViewInWindow,
	                        hidden: isHiddenOrAncestorHidden(tp.hostedView),
	                        viewFrame: viewRect,
	                        splitViews: splitViews
	                    )
	                }


	                return LayoutDebugSelectedPanel(
	                    paneId: paneIdStr,
	                    paneFrame: paneFrame,
	                    selectedTabId: selectedTabId,
	                    panelId: panelId.uuidString,
	                    panelType: panel.panelType.rawValue,
	                    inWindow: nil,
	                    hidden: nil,
	                    viewFrame: nil,
	                    splitViews: nil
	                )
	            }

            let payload = LayoutDebugResponse(
                layout: layout,
                selectedPanels: selectedPanels,
                mainWindowNumber: NSApp.mainWindow?.windowNumber,
                keyWindowNumber: NSApp.keyWindow?.windowNumber
            )

            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(payload),
                  let json = String(data: data, encoding: .utf8) else {
                result = "ERROR: Failed to encode layout_debug"
                return
            }

            result = "OK \(json)"
        }
        return result
    }

    func emptyPanelCount() -> String {
        var result = "OK 0"
        v2MainSync {
            result = "OK \(DebugUIEventCounters.emptyPanelAppearCount)"
        }
        return result
    }

    func resetEmptyPanelCount() -> String {
        v2MainSync {
            DebugUIEventCounters.resetEmptyPanelAppearCount()
        }
        return "OK"
    }

    func bonsplitUnderflowCount() -> String {
        var result = "OK 0"
        v2MainSync {
#if DEBUG
            result = "OK \(BonsplitDebugCounters.arrangedSubviewUnderflowCount)"
#else
            result = "OK 0"
#endif
        }
        return result
    }

    func resetBonsplitUnderflowCount() -> String {
        v2MainSync {
#if DEBUG
            BonsplitDebugCounters.reset()
#endif
        }
        return "OK"
    }

#endif

    func parseSplitDirection(_ value: String) -> SplitDirection? {
        switch value.lowercased() {
        case "left", "l":
            return .left
        case "right", "r":
            return .right
        case "up", "u":
            return .up
        case "down", "d":
            return .down
        default:
            return nil
        }
    }

    private func resolveTab(from arg: String, tabManager: TabManager) -> Tab? {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard let selected = tabManager.selectedTabId else { return nil }
            return tabManager.tabs.first(where: { $0.id == selected })
        }

        if let uuid = UUID(uuidString: trimmed) {
            return tabManager.tabs.first(where: { $0.id == uuid })
        }

        if let index = Int(trimmed), index >= 0, index < tabManager.tabs.count {
            return tabManager.tabs[index]
        }

        return nil
    }

    func orderedPanels(in tab: Workspace) -> [any Panel] {
        // Single source of truth for spatial (left-to-right, top-to-bottom) panel
        // order lives on `Workspace.orderedPanelIds`, derived from bonsplit's tab
        // ordering. This avoids relying on Dictionary iteration order and keeps the
        // serializer, the reorder gate, and the mobile observer hash consistent.
        tab.orderedPanelIds.compactMap { tab.panels[$0] }
    }

    func resolveTerminalPanel(from arg: String, tabManager: TabManager) -> TerminalPanel? {
        guard let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return nil
        }

        if let uuid = UUID(uuidString: arg) {
            return tab.terminalInputTarget(forPanelID: uuid)?.panel
        }

        if let index = Int(arg), index >= 0 {
            let panels = orderedPanels(in: tab)
            guard index < panels.count else { return nil }
            return tab.terminalInputTarget(forPanelID: panels[index].id)?.panel
        }

        return nil
    }

    private func resolveSurfaceId(from arg: String, tab: Workspace) -> UUID? {
        if let uuid = UUID(uuidString: arg) {
            return uuid
        }

        if let index = Int(arg), index >= 0 {
            let panels = orderedPanels(in: tab)
            guard index < panels.count else { return nil }
            return panels[index].id
        }

        return nil
    }

    /// Parses a `title|subtitle|body` notification payload, plus an OPTIONAL 4th
    /// `meta` segment (e.g. `c=turn-complete;p=1`) that agent hooks append to gate
    /// delivery by user config. The 4th segment is only treated as meta when it
    /// begins with `c=`; otherwise it is folded back into the body, so legacy
    /// callers whose body itself contains `|` parse byte-identically to before
    /// (the fold reconstructs exactly the `maxSplits: 2` result).
    /// `nonisolated`: pure string parsing, run by the worker-lane notify
    /// bodies on the socket-worker thread.
    private nonisolated func parseNotificationPayload(_ args: String) -> (title: String, subtitle: String, body: String, meta: AgentNotificationMeta?) {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("Notification", "", "", nil) }
        var parts = trimmed.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        var meta: AgentNotificationMeta? = nil
        if parts.count == 4 {
            // The 4th segment is treated as gating metadata only when it parses
            // as the FULL `c=<category>;p=<0|1>` grammar. Anything else — including
            // a legacy body that happens to contain "|c=..." — is folded back into
            // the body so pre-meta callers parse byte-identically to before.
            // Conscious tradeoff: this reserves exactly three trailing literals
            // ("|c=turn-complete;p=<0|1>", "|c=needs-permission;p=<0|1>",
            // "|c=idle-reminder;p=<0|1>") in notify payloads; any other "c=..."
            // tail (unknown categories included) stays part of the body. Accepted
            // because the only meta producers are cmux's own agent hooks (whose
            // fields are |-sanitized) and a collision requires one of those exact
            // suffixes.
            let candidate = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.hasPrefix("c="), let parsed = AgentNotificationMeta(meta: candidate) {
                meta = parsed
            } else {
                parts[2] += "|" + parts[3]
            }
            parts.removeLast()
        }
        let title = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let subtitle = parts.count > 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let body = parts.count > 2
            ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            : (parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        return (title.isEmpty ? "Notification" : title, subtitle, body, meta)
    }

    /// Applies the user's agent-notification settings to a parsed meta tag.
    /// `nil` meta (legacy/untagged payloads) always delivers.
    /// `nonisolated`: the catalog keys read through the synchronous
    /// `DefaultsKey.value(in:)` seam (UserDefaults is documented
    /// thread-safe), so the worker-lane notify bodies evaluate the gate on
    /// the socket-worker thread and apply the verdict inside their hop at
    /// the legacy guard position.
    private nonisolated func shouldDeliverAgentNotification(_ meta: AgentNotificationMeta?) -> Bool {
        guard let meta else { return true }
        let catalog = NotificationsCatalogSection()
        let turnMode = AgentTurnCompleteMode(rawValue: catalog.agentTurnComplete.value(in: .standard)) ?? .whenIdle
        return agentNotificationShouldDeliver(
            category: meta.category,
            pending: meta.pending,
            permissionEnabled: catalog.agentPermissionPrompt.value(in: .standard),
            turnMode: turnMode,
            idleEnabled: catalog.agentIdleReminder.value(in: .standard)
        )
    }

    private func closeWorkspace(_ tabId: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let tokens = tabId.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let rawID = tokens.first,
              let uuid = UUID(uuidString: rawID) else { return "ERROR: Invalid tab ID" }
        let force = tokens.contains("--force")

        var result = "ERROR: Tab not found"
        v2MainSync {
            if let tab = tabManager.tabs.first(where: { $0.id == uuid }) {
                guard tabManager.canCloseWorkspace(tab) else {
                    result = "ERROR: \(workspaceCloseProtectedMessage())"
                    return
                }
                if !force, tabManager.workspaceNeedsConfirmCloseForClose(tab) {
                    result = "ERROR: " + String(
                        localized: "cli.socket.error.workspaceCloseConfirmationRequired",
                        defaultValue: "Workspace has a running process; retry with --force"
                    )
                    return
                }
                let closeFailure = String(localized: "cli.socket.error.workspaceNotClosed", defaultValue: "Workspace not closed")
                result = tabManager.closeWorkspaceNonInteractively(tab) ? "OK" : "ERROR: \(closeFailure)"
            }
        }
        return result
    }

    private func selectWorkspace(_ arg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        v2MainSync {
            // Try as UUID first
            if let uuid = UUID(uuidString: arg) {
                if let tab = tabManager.tabs.first(where: { $0.id == uuid }) {
                    tabManager.selectTab(tab)
                    success = true
                }
            }
            // Try as index
            else if let index = Int(arg), index >= 0, index < tabManager.tabs.count {
                tabManager.selectTab(at: index)
                success = true
            }
        }
        return success ? "OK" : "ERROR: Tab not found"
    }

    /// The `current_workspace` hop outcome.
    private enum CurrentWorkspaceHopOutcome {
        case tabManagerUnavailable
        case noTabSelected
        case workspaceID(UUID)
    }

    /// `current_workspace` worker body (tranche D of issue #5757): the
    /// main-actor `tabManager` guard and the selected-tab read take one
    /// v2MainSync hop; uuidString formatting and the error strings run on the
    /// calling socket-worker thread. Shared by the worker lane and the legacy
    /// processCommand dispatch (inline-collapsing hop).
    private nonisolated func currentWorkspace() -> String {
        let outcome: CurrentWorkspaceHopOutcome = v2MainSync {
            guard let tabManager = self.tabManager else { return .tabManagerUnavailable }
            guard let id = tabManager.selectedTabId else { return .noTabSelected }
            return .workspaceID(id)
        }
        switch outcome {
        case .tabManagerUnavailable: return "ERROR: TabManager not available"
        case .noTabSelected: return "ERROR: No tab selected"
        case .workspaceID(let id): return id.uuidString
        }
    }

    /// The shared v1 send hop outcome (tranche E of issue #5757): the hop
    /// resolves the target and injects the input on the main actor; the reply
    /// strings — including the localized terminal-input errors — are selected
    /// off-main by each verb. Parse errors surface as cases so the hop can
    /// keep the legacy evaluation order (the main-actor `tabManager` guard
    /// BEFORE the usage/UUID errors).
    private enum V1SendHopOutcome {
        case tabManagerUnavailable
        /// The precomputed parse failed (per-verb usage string off-main).
        case parseError
        /// send_workspace's workspace-id UUID parse failed.
        case invalidWorkspaceID
        case noFocusedTerminal
        case surfaceNotFound
        case workspaceNotFound
        case noSelectedTerminalInWorkspace
        /// The input was delivered or queued (both replied "OK").
        case sent
        case unknownKey
        case inputQueueFull
        case surfaceUnavailable
        case processExited
    }

    /// The legacy v1 escape-sequence unescaping (`\n` becomes `\r` — terminal
    /// Enter sends CR), a pure transform run on the worker thread.
    private nonisolated static func v1UnescapedSendText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\n", with: "\r")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    /// Maps a canonical socket target's text-send result to the shared hop
    /// outcome and runs the legacy on-success forceRefresh (main actor).
    private static func v1TextSendOutcome(
        _ target: ControlTerminalSocketTarget,
        text: String,
        refreshReason: String
    ) -> V1SendHopOutcome {
        switch target.sendInputResult(text) {
        case .sent:
            target.forceRefresh(reason: refreshReason)
            return .sent
        case .queued:
            return .sent
        case .inputQueueFull:
            return .inputQueueFull
        case .surfaceUnavailable:
            return .surfaceUnavailable
        case .processExited:
            return .processExited
        }
    }

    /// Maps a canonical socket target's named-key send result to the shared
    /// hop outcome and runs the legacy on-success forceRefresh (main actor).
    private static func v1KeySendOutcome(
        _ target: ControlTerminalSocketTarget,
        keyName: String,
        refreshReason: String
    ) -> V1SendHopOutcome {
        switch target.sendNamedKeyResult(keyName) {
        case .sent:
            target.forceRefresh(reason: refreshReason)
            return .sent
        case .queued:
            return .sent
        case .unknownKey:
            return .unknownKey
        case .inputQueueFull:
            return .inputQueueFull
        case .surfaceUnavailable:
            return .surfaceUnavailable
        case .processExited:
            return .processExited
        }
    }

    /// `send` worker body (tranche E of issue #5757): the escape-sequence
    /// unescaping runs on the calling socket-worker thread; the main-actor
    /// `tabManager` guard, the focused-terminal resolution, and the input
    /// injection + forceRefresh take one v2MainSync hop; the reply-string
    /// mapping runs off-main. Shared by the worker lane and the legacy
    /// processCommand dispatch (inline-collapsing hop).
    private nonisolated func sendInput(_ text: String) -> String {
        // Unescape common escape sequences
        // Note: \n is converted to \r for terminal (Enter key sends \r)
        let unescaped = Self.v1UnescapedSendText(text)
        let outcome: V1SendHopOutcome = v2MainSync {
            guard let tabManager = self.tabManager else { return .tabManagerUnavailable }
            guard let selectedId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == selectedId }),
                  let owned = tab.focusedTerminalInputTarget(),
                  let target = tab.controlSocketTerminalTarget(for: owned) else {
                return .noFocusedTerminal
            }
            return Self.v1TextSendOutcome(
                target,
                text: unescaped,
                refreshReason: "terminalController.sendInput"
            )
        }
        switch outcome {
        case .tabManagerUnavailable: return "ERROR: TabManager not available"
        case .noFocusedTerminal: return "ERROR: No focused terminal"
        case .sent: return "OK"
        case .inputQueueFull: return Self.terminalInputQueueFullSocketError
        case .surfaceUnavailable: return Self.terminalSurfaceUnavailableSocketError
        case .processExited: return Self.terminalProcessExitedSocketError
        default: return "ERROR: Failed to send input"
        }
    }

    /// `send_workspace` worker body (tranche E; DEBUG-only verb): the args
    /// split, workspace-UUID parse, and unescaping run on the calling
    /// socket-worker thread; the main-actor `tabManager` guard, the
    /// cross-window workspace resolution, and the input injection +
    /// forceRefresh take one v2MainSync hop (the parse errors are selected
    /// inside it, after the guard, in the legacy order); the reply-string
    /// mapping runs off-main. Shared by the worker lane and the legacy
    /// processCommand dispatch (inline-collapsing hop).
    private nonisolated func sendInputToWorkspace(_ args: String) -> String {
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        let workspaceId: UUID?
        let unescaped: String?
        if parts.count == 2 {
            workspaceId = UUID(uuidString: parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
            unescaped = Self.v1UnescapedSendText(parts[1])
        } else {
            workspaceId = nil
            unescaped = nil
        }

        let outcome: V1SendHopOutcome = v2MainSync {
            guard let tabManager = self.tabManager else { return .tabManagerUnavailable }
            guard let unescaped else { return .parseError }
            guard let workspaceId else { return .invalidWorkspaceID }
            guard let targetManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId)
                ?? (tabManager.tabs.contains(where: { $0.id == workspaceId }) ? tabManager : nil) else {
                return .workspaceNotFound
            }
            guard let tab = targetManager.tabs.first(where: { $0.id == workspaceId }) else {
                return .workspaceNotFound
            }
            guard let terminalPanel = self.sendableWorkspaceTerminalPanel(in: tab),
                  let target = tab.controlSocketTerminalTarget(for: terminalPanel.id) else {
                return .noSelectedTerminalInWorkspace
            }
            return Self.v1TextSendOutcome(
                target,
                text: unescaped,
                refreshReason: "terminalController.sendWorkspace"
            )
        }
        switch outcome {
        case .tabManagerUnavailable: return "ERROR: TabManager not available"
        case .parseError: return "ERROR: Usage: send_workspace <workspace_id> <text>"
        case .invalidWorkspaceID: return "ERROR: Invalid workspace ID"
        case .workspaceNotFound: return "ERROR: Workspace not found"
        case .noSelectedTerminalInWorkspace: return "ERROR: No selected terminal in workspace"
        case .sent: return "OK"
        case .inputQueueFull: return Self.terminalInputQueueFullSocketError
        case .surfaceUnavailable: return Self.terminalSurfaceUnavailableSocketError
        case .processExited: return Self.terminalProcessExitedSocketError
        default: return "ERROR: Failed to send input"
        }
    }

    private func sendableWorkspaceTerminalPanel(in workspace: Workspace) -> TerminalPanel? {
        func selectedTerminalPanel(in paneId: PaneID) -> TerminalPanel? {
            guard let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId),
                  let panelId = workspace.panelIdFromSurfaceId(selectedTab.id),
                  let terminalPanel = workspace.terminalInputTarget(forPanelID: panelId)?.panel else {
                return nil
            }
            return terminalPanel
        }

        func isSelectedTerminalPanel(_ terminalPanel: TerminalPanel) -> Bool {
            let containerPanelID = terminalPanel.id
            guard let surfaceId = workspace.surfaceIdFromPanelId(containerPanelID) else {
                return false
            }
            return workspace.bonsplitController.allPaneIds.contains { paneId in
                workspace.bonsplitController.selectedTab(inPane: paneId)?.id == surfaceId
            }
        }

        if let focusedPane = workspace.bonsplitController.focusedPaneId,
           let terminalPanel = selectedTerminalPanel(in: focusedPane) {
            return terminalPanel
        }

        if let rememberedTerminal = workspace.lastRememberedTerminalPanelForConfigInheritance(),
           let projected = workspace.terminalInputTarget(forPanelID: rememberedTerminal.id)?.panel,
           isSelectedTerminalPanel(projected) {
            return projected
        }

        for paneId in workspace.bonsplitController.allPaneIds {
            if let terminalPanel = selectedTerminalPanel(in: paneId) {
                return terminalPanel
            }
        }

        return nil
    }

    /// `send_surface` worker body (tranche E): the target/text split and
    /// unescaping run on the calling socket-worker thread; the main-actor
    /// `tabManager` guard, the target resolution (main-actor tab/panel maps),
    /// and the input injection + forceRefresh take one v2MainSync hop (the
    /// usage error is selected inside it, after the guard, in the legacy
    /// order); the reply-string mapping runs off-main. Shared by the worker
    /// lane and the legacy processCommand dispatch (inline-collapsing hop).
    private nonisolated func sendInputToSurface(_ args: String) -> String {
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        let target: String?
        let unescaped: String?
        if parts.count == 2 {
            target = parts[0]
            unescaped = Self.v1UnescapedSendText(parts[1])
        } else {
            target = nil
            unescaped = nil
        }

        let outcome: V1SendHopOutcome = v2MainSync {
            guard let tabManager = self.tabManager else { return .tabManagerUnavailable }
            guard let target, let unescaped else { return .parseError }
            guard let socketTarget = self.controlSocketTerminalTarget(
                fromLegacySurfaceArgument: target,
                tabManager: tabManager
            ) else {
                return .surfaceNotFound
            }
            return Self.v1TextSendOutcome(
                socketTarget,
                text: unescaped,
                refreshReason: "terminalController.sendSurface"
            )
        }
        switch outcome {
        case .tabManagerUnavailable: return "ERROR: TabManager not available"
        case .parseError: return "ERROR: Usage: send_surface <id|idx> <text>"
        case .surfaceNotFound: return "ERROR: Surface not found"
        case .sent: return "OK"
        case .inputQueueFull: return Self.terminalInputQueueFullSocketError
        case .surfaceUnavailable: return Self.terminalSurfaceUnavailableSocketError
        case .processExited: return Self.terminalProcessExitedSocketError
        default: return "ERROR: Failed to send input"
        }
    }

    /// `send_key` worker body (tranche E): the main-actor `tabManager` guard,
    /// the focused-terminal resolution, and the named-key injection +
    /// forceRefresh take one v2MainSync hop (the key-name table lives inside
    /// the panel's sendNamedKeyResult, so it stays in the hop); the
    /// reply-string mapping runs off-main. Shared by the worker lane and the
    /// legacy processCommand dispatch (inline-collapsing hop).
    private nonisolated func sendKey(_ keyName: String) -> String {
        let outcome: V1SendHopOutcome = v2MainSync {
            guard let tabManager = self.tabManager else { return .tabManagerUnavailable }
            guard let selectedId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == selectedId }),
                  let owned = tab.focusedTerminalInputTarget(),
                  let target = tab.controlSocketTerminalTarget(for: owned) else {
                return .noFocusedTerminal
            }
            return Self.v1KeySendOutcome(
                target,
                keyName: keyName,
                refreshReason: "terminalController.sendKey"
            )
        }
        switch outcome {
        case .tabManagerUnavailable: return "ERROR: TabManager not available"
        case .noFocusedTerminal: return "ERROR: No focused terminal"
        case .sent: return "OK"
        case .unknownKey: return "ERROR: Unknown key '\(keyName)'"
        case .inputQueueFull: return Self.terminalInputQueueFullSocketError
        case .surfaceUnavailable: return Self.terminalSurfaceUnavailableSocketError
        case .processExited: return Self.terminalProcessExitedSocketError
        default: return "ERROR: Failed to send key"
        }
    }

    /// `send_key_surface` worker body (tranche E): the target/key split runs
    /// on the calling socket-worker thread; the main-actor `tabManager`
    /// guard, the target resolution, and the named-key injection +
    /// forceRefresh take one v2MainSync hop (the usage error is selected
    /// inside it, after the guard, in the legacy order); the reply-string
    /// mapping runs off-main. Shared by the worker lane and the legacy
    /// processCommand dispatch (inline-collapsing hop).
    private nonisolated func sendKeyToSurface(_ args: String) -> String {
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        let target: String? = parts.count == 2 ? parts[0] : nil
        let keyName: String? = parts.count == 2 ? parts[1] : nil

        let outcome: V1SendHopOutcome = v2MainSync {
            guard let tabManager = self.tabManager else { return .tabManagerUnavailable }
            guard let target, let keyName else { return .parseError }
            guard let socketTarget = self.controlSocketTerminalTarget(
                fromLegacySurfaceArgument: target,
                tabManager: tabManager
            ) else {
                return .surfaceNotFound
            }
            return Self.v1KeySendOutcome(
                socketTarget,
                keyName: keyName,
                refreshReason: "terminalController.sendKeyToSurface"
            )
        }
        switch outcome {
        case .tabManagerUnavailable: return "ERROR: TabManager not available"
        case .parseError: return "ERROR: Usage: send_key_surface <id|idx> <key>"
        case .surfaceNotFound: return "ERROR: Surface not found"
        case .sent: return "OK"
        case .unknownKey: return "ERROR: Unknown key '\(keyName ?? "")'"
        case .inputQueueFull: return Self.terminalInputQueueFullSocketError
        case .surfaceUnavailable: return Self.terminalSurfaceUnavailableSocketError
        case .processExited: return Self.terminalProcessExitedSocketError
        default: return "ERROR: Failed to send key"
        }
    }

    // MARK: - Browser Panel Commands

    // MARK: - Bonsplit Pane Commands

    // MARK: - Option Parsing (sidebar metadata commands)

    private nonisolated static func tokenizeArgs(_ args: String) -> [String] {
        SidebarMetadataArgumentParser().tokenize(args)
    }

    private nonisolated func parseOptions(_ args: String) -> (positional: [String], options: [String: String]) {
        sidebarMetadataArgumentParser.parseOptions(args)
    }

    private func parseOptionsNoStop(_ args: String) -> (positional: [String], options: [String: String]) {
        sidebarMetadataArgumentParser.parseOptionsNoStop(args)
    }

    private func resolveTabForReport(_ args: String) -> Tab? {
        let parsed = parseOptions(args)
        if let tabArg = parsed.options["tab"], !tabArg.isEmpty {
            // First try the local tabManager if available
            if let tabManager = self.tabManager,
               let tab = resolveTab(from: tabArg, tabManager: tabManager) {
                return tab
            }
            // The tab may belong to a different window — search all contexts.
            if let uuid = UUID(uuidString: tabArg.trimmingCharacters(in: .whitespacesAndNewlines)),
               let otherManager = AppDelegate.shared?.tabManagerFor(tabId: uuid) {
                return otherManager.tabs.first(where: { $0.id == uuid })
            }
            return nil
        }
        // Only require self.tabManager when using the selected tab (no --tab arg)
        guard let tabManager = self.tabManager else { return nil }
        guard let selectedId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == selectedId })
    }

    private nonisolated func parseSidebarMutationTabTarget(
        options: [String: String]
    ) -> (target: SidebarMutationTabTarget?, error: String?) {
        // `SidebarMetadataArgumentParser.parseMutationTabTarget` already returns the
        // `CmuxSidebar.SidebarMutationTabTarget` cases this controller resolves, so
        // forward the parsed target verbatim instead of re-mapping it case-for-case
        // onto a duplicate local enum.
        let resolution = sidebarMetadataArgumentParser.parseMutationTabTarget(options: options)
        return (resolution.target, resolution.error)
    }

    private func resolveSidebarMutationTab(_ target: SidebarMutationTabTarget) -> Tab? {
        switch target {
        case .selected:
            guard let tabManager = self.tabManager,
                  let selectedId = tabManager.selectedTabId else {
                return nil
            }
            return tabManager.tabs.first(where: { $0.id == selectedId })
        case .workspace(let tabId):
            return tabForSidebarMutation(id: tabId)
        case .index(let index):
            guard let tabManager = self.tabManager,
                  index < tabManager.tabs.count else {
                return nil
            }
            return tabManager.tabs[index]
        }
    }

    private func tabForSidebarMutation(id: UUID) -> Tab? {
        if let tab = tabManager?.tabs.first(where: { $0.id == id }) {
            return tab
        }
        if let otherManager = AppDelegate.shared?.tabManagerFor(tabId: id) {
            return otherManager.tabs.first(where: { $0.id == id })
        }
        return nil
    }

    private func parseSidebarMetadataFormat(_ raw: String) -> SidebarMetadataFormat? {
        sidebarMetadataArgumentParser.parseMetadataFormat(raw)
    }

    private func normalizedOptionValue(_ value: String?) -> String? {
        sidebarMetadataArgumentParser.normalizedOptionValue(value)
    }

    private nonisolated func parseOptionalPanelIdOption(
        options: [String: String],
        usage: String
    ) -> (panelId: UUID?, error: String?) {
        let result = sidebarMetadataArgumentParser.parseOptionalPanelId(options: options, usage: usage)
        return (result.panelId, result.error)
    }

    private func scheduleSidebarMutation(
        target: SidebarMutationTabTarget,
        mutation: @escaping (TerminalController, Tab) -> Void
    ) {
        TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
            guard let self, let tab = self.resolveSidebarMutationTab(target) else { return }
            mutation(self, tab)
        }
    }

    private func schedulePanelMetadataMutation(
        args: String,
        options: [String: String],
        missingPanelUsage: String,
        mutation: @escaping (Tab, UUID) -> Void
    ) -> String {
        let rawPanelArg = options["panel"] ?? options["surface"]
        let surfaceIdFromOptions: UUID?
        if let rawPanelArg {
            if rawPanelArg.isEmpty {
                return "ERROR: Missing panel id — usage: \(missingPanelUsage)"
            }
            guard let surfaceId = UUID(uuidString: rawPanelArg) else {
                return "ERROR: Invalid panel id '\(rawPanelArg)'"
            }
            surfaceIdFromOptions = surfaceId
        } else {
            surfaceIdFromOptions = nil
        }

        if let tabArg = options["tab"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tabArg.isEmpty,
           UUID(uuidString: tabArg) == nil,
           Int(tabArg) == nil {
            return "ERROR: Tab not found"
        }

        if let scope = Self.explicitSocketScope(options: options) {
            TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
                guard let self,
                      let tab = self.tabForSidebarMutation(id: scope.workspaceId) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                mutation(tab, scope.panelId)
            }
            return "OK"
        }

        TerminalMutationBus.shared.enqueueMainActorMutation { [weak self] in
            guard let self,
                  let tab = self.resolveTabForReport(args) else {
                return
            }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard let surfaceId = surfaceIdFromOptions ?? tab.focusedPanelId else { return }
            guard validSurfaceIds.contains(surfaceId) else { return }
            mutation(tab, surfaceId)
        }
        return "OK"
    }

    private func upsertSidebarMetadata(_ args: String, missingError: String) -> String {
        let parsed = parseOptionsNoStop(args)
        guard parsed.positional.count >= 2 else { return missingError }

        let key = parsed.positional[0]
        let value = parsed.positional[1...].joined(separator: " ")
        let icon = normalizedOptionValue(parsed.options["icon"])
        let color = normalizedOptionValue(parsed.options["color"])

        let formatRaw = normalizedOptionValue(parsed.options["format"]) ?? SidebarMetadataFormat.plain.rawValue
        guard let format = parseSidebarMetadataFormat(formatRaw) else {
            return "ERROR: Invalid metadata format '\(formatRaw)' — use: plain, markdown"
        }

        let workState: SidebarAgentWorkState?
        if let rawWorkState = normalizedOptionValue(parsed.options["work"]) {
            guard let parsedWorkState = SidebarAgentWorkState.parse(rawWorkState) else {
                return "ERROR: Invalid work state '\(rawWorkState)' — use: running, subagents, waiting"
            }
            workState = parsedWorkState
        } else {
            workState = nil
        }

        let priority: Int
        if let rawPriority = normalizedOptionValue(parsed.options["priority"]) {
            guard let parsedPriority = Int(rawPriority) else {
                return "ERROR: Invalid metadata priority '\(rawPriority)' — must be an integer"
            }
            priority = max(-9999, min(9999, parsedPriority))
        } else {
            priority = 0
        }

        let parsedURL: URL?
        if let rawURL = normalizedOptionValue(parsed.options["url"] ?? parsed.options["link"]) {
            guard let candidate = URL(string: rawURL),
                  let scheme = candidate.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return "ERROR: Invalid metadata URL '\(rawURL)' — expected http(s) URL"
            }
            parsedURL = candidate
        } else {
            parsedURL = nil
        }

        let targetResolution = parseSidebarMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }
        let panelResolution = parseOptionalPanelIdOption(
            options: parsed.options,
            usage: "set_status <key> <value> [--icon=X] [--color=#hex] [--url=X] [--priority=N] [--format=plain|markdown] [--work=running|subagents|waiting] [--tab=X] [--panel=ID]"
        )
        if let error = panelResolution.error {
            return error
        }

        let pidValue: pid_t? = {
            if let rawPid = normalizedOptionValue(parsed.options["pid"]),
               let p = Int32(rawPid), p > 0 {
                return p
            }
            return nil
        }()

        scheduleSidebarMutation(target: target) { _, tab in
            if let panelId = panelResolution.panelId, !tab.panels.keys.contains(panelId) {
                return
            }
            guard Self.shouldReplaceStatusEntry(
                current: tab.statusEntries[key],
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: parsedURL,
                priority: priority,
                format: format,
                workState: workState
            ) else {
                // Still update PID tracking even if the status display hasn't changed.
                if let pidValue {
                    tab.recordAgentPID(key: key, pid: pidValue, panelId: panelResolution.panelId)
                }
                return
            }
            tab.statusEntries[key] = SidebarStatusEntry(
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: parsedURL,
                priority: priority,
                format: format,
                timestamp: Date(),
                workState: workState
            )
            if let pidValue {
                tab.recordAgentPID(key: key, pid: pidValue, panelId: panelResolution.panelId)
            }
        }
        return "OK"
    }

    private func clearSidebarMetadata(_ args: String, usage: String) -> String {
        let parsed = parseOptions(args)
        guard let key = parsed.positional.first, parsed.positional.count == 1 else {
            return "ERROR: Missing metadata key — usage: \(usage)"
        }

        let targetResolution = parseSidebarMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }

        scheduleSidebarMutation(target: target) { _, tab in
            _ = tab.statusEntries.removeValue(forKey: key)
            tab.clearAgentPID(key: key)
        }
        return "OK"
    }

    private func isAllowedAgentLifecycleKey(
        _ key: String,
        target: SidebarMutationTabTarget,
        panelId: UUID?
    ) -> Bool {
        if AgentHibernationLifecycleStatusKeys.isAllowed(key) {
            return true
        }
        guard !AgentHibernationLifecycleStatusKeys.isManualKey(key), let tab = resolveSidebarMutationTab(target),
              CmuxVaultAgentRegistration.isValidID(key) else {
            return false
        }
        let registry = CmuxVaultAgentRegistry.load(
            workingDirectory: agentLifecycleRegistryWorkingDirectory(tab: tab, panelId: panelId)
        )
        return registry.registration(id: key) != nil
    }

    private func agentLifecycleRegistryWorkingDirectory(tab: Tab, panelId: UUID?) -> String? {
        let candidates = [
            panelId.flatMap { tab.effectivePanelDirectory(panelId: $0) },
            tab.focusedPanelId.flatMap { tab.effectivePanelDirectory(panelId: $0) },
        ]
        return candidates.compactMap(normalizedOptionValue).first
    }

    private func sidebarMetadataLine(_ entry: SidebarStatusEntry) -> String {
        var line = "\(entry.key)=\(entry.value)"
        if let icon = entry.icon { line += " icon=\(icon)" }
        if let color = entry.color { line += " color=\(color)" }
        if let url = entry.url { line += " url=\(url.absoluteString)" }
        if entry.priority != 0 { line += " priority=\(entry.priority)" }
        if entry.format != .plain { line += " format=\(entry.format.rawValue)" }
        if let workState = entry.workState { line += " work=\(workState.rawValue)" }
        return line
    }

    private func listSidebarMetadata(_ args: String, emptyMessage: String) -> String {
        var result = ""
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            let entries = tab.sidebarStatusEntriesInDisplayOrder()
            if entries.isEmpty {
                result = emptyMessage
                return
            }
            result = entries.map(sidebarMetadataLine).joined(separator: "\n")
        }
        return result
    }

    private func splitMetadataBlockArgs(_ args: String) -> (optionsPart: String, markdownPart: String?) {
        sidebarMetadataArgumentParser.splitMetadataBlockArgs(args)
    }

    private func sidebarMetadataBlockLine(_ block: SidebarMetadataBlock) -> String {
        var line = "\(block.key)=\(block.markdown.replacingOccurrences(of: "\n", with: "\\n"))"
        if block.priority != 0 { line += " priority=\(block.priority)" }
        return line
    }

#if DEBUG
    func rightSidebarCommandAllowsInAppFocusMutationsForTesting(_ commandLine: String) -> Bool {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.first?.lowercased() == "right_sidebar" else { return false }
        return Self.rightSidebarCommandAllowsInAppFocusMutations(args: parts.count > 1 ? parts[1] : "")
    }

#endif

    private func viewDepth(of view: NSView, maxDepth: Int = 128) -> Int {
        var depth = 0
        var current: NSView? = view
        while let v = current, depth < maxDepth {
            current = v.superview
            depth += 1
        }
        return depth
    }

    private func isPortalHosted(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is WindowTerminalHostView { return true }
            current = v.superview
        }
        return false
    }

    // MARK: - Mobile Host V2 Methods

    #if DEBUG
    #endif

    enum MobileTerminalAliasUUID {
        case missing
        case value(UUID)
        case invalid
        case conflict
    }

    func mobileTerminalAliasUUID(params: [String: Any]) -> MobileTerminalAliasUUID {
        var selected: UUID?
        var sawAlias = false
        for key in ["surface_id", "terminal_id", "tab_id"] {
            guard v2HasNonNullParam(params, key) else {
                continue
            }
            sawAlias = true
            guard let candidate = v2UUID(params, key) else {
                return .invalid
            }
            if let selected, selected != candidate {
                return .conflict
            }
            selected = selected ?? candidate
        }
        if let selected {
            return .value(selected)
        }
        return sawAlias ? .invalid : .missing
    }

    func mobileTerminalAliasValidationError(params: [String: Any]) -> V2CallResult? {
        switch mobileTerminalAliasUUID(params: params) {
        case .missing, .value:
            return nil
        case .invalid:
            return .err(code: "invalid_params", message: "Missing or invalid terminal_id", data: nil)
        case .conflict:
            return .err(code: "invalid_params", message: "Conflicting terminal identifiers", data: nil)
        }
    }

    func mobileWorkspaceIDValidationError(params: [String: Any]) -> V2CallResult? {
        guard v2HasNonNullParam(params, "workspace_id"),
              v2UUID(params, "workspace_id") == nil else {
            return nil
        }
        return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
    }

    #if DEBUG
    func debugSetMobileViewportReportForTesting(
        surfaceID: UUID,
        clientID: String,
        columns: Int,
        rows: Int,
        updatedAt: Date = Date()
    ) {
        var reports = mobileViewportReportsBySurfaceID[surfaceID] ?? [:]
        reports[clientID] = MobileViewportReport(
            columns: columns,
            rows: rows,
            updatedAt: updatedAt
        )
        mobileViewportReportsBySurfaceID[surfaceID] = reports
    }

    func debugMobileViewportReportClientIDsForTesting(surfaceID: UUID) -> Set<String>? {
        guard let reports = mobileViewportReportsBySurfaceID[surfaceID] else {
            return nil
        }
        return Set(reports.keys)
    }
    #endif

    func terminalSocketTarget(surfaceID: UUID) -> ControlTerminalSocketTarget? {
        guard let tabManager = controlTabManager(surfaceID: surfaceID),
              let workspace = tabManager.tabs.first(where: {
                  $0.terminalInputTarget(forPanelID: surfaceID) != nil
              }) else {
            return nil
        }
        guard let owned = workspace.terminalInputTarget(forPanelID: surfaceID) else {
            return nil
        }
        return workspace.controlSocketTerminalTarget(for: owned)
    }

    // Restored: still used by the v1 close-workspace path (its v2
    // counterpart moved to ControlCommandCoordinator).
    private func workspaceCloseProtectedMessage() -> String {
        String(
            localized: "workspace.closeProtected.message",
            defaultValue: "Pinned workspaces can't be closed while pinned. Unpin the workspace first."
        )
    }

    func currentMobileViewportGrid(surfaceID: UUID) -> (columns: Int, rows: Int)? {
        guard let surface = terminalSocketTarget(surfaceID: surfaceID)?
            .surface.liveSurfaceForGhosttyAccess(reason: "mobileViewportGovernor.currentGrid") else {
            return nil
        }
        let size = ghostty_surface_size(surface)
        return (columns: max(Int(size.columns), 1), rows: max(Int(size.rows), 1))
    }

    deinit {
        if let browserDownloadObserver {
            NotificationCenter.default.removeObserver(browserDownloadObserver)
        }
        if let browserMainFrameCommitObserver {
            NotificationCenter.default.removeObserver(browserMainFrameCommitObserver)
        }
        // No stop() here: the controller is an app-lifetime singleton, so
        // deinit never runs; listener teardown is applicationWillTerminate's
        // synchronous stop() on the main actor.
    }
}
