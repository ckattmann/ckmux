import CmuxControlSocket
import CmuxSettings
import CmuxSurfaceCatalogModel
import Foundation

// The socket face of the surface catalog: `surface.catalog`, `surface.project`,
// `surface.new_terminal`, `surface.new_display`, and the `vm.tree` / `vm.terminal_open` / `vm.terminal_new` /
// `vm.desktop_open` / `vm.port_open` / `vm.link_socket` verbs that are now thin wrappers
// over the same catalog. Every entrypoint (sidebar, CLI, agents) opens a surface through
// `SurfaceCatalog.project`, so "is it open?" and "where does it land?" have one answer.
//
// Lane (ControlCommandExecutionPolicy): socket worker. These await main-actor catalog work
// that can sit on the network (a cloud provider materializing a pane), so they must never
// hold the main actor; `v2VmCall` parks the worker while the catalog runs on the main actor.
// Focus policy: `focus` defaults to false for every open, so an agent or script never
// pulls the person away from what they are typing in; the CLI sends `focus: true` for an
// interactive open or an explicit `--focus`. A pane opened without focus is marked
// unread (`markBackgroundOpen`). The catalog never activates the app either way.
extension TerminalController {
    /// Handles the synchronous in-process surface socket adapter. Network socket
    /// connections use the async display path below so cloud display creation
    /// never parks a socket worker thread behind `v2VmCall`.
    nonisolated func socketWorkerSurfaceResponse(method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "surface.catalog":
            let machine = Self.surfaceMachineFilter(params["machine"])
            // `refresh` forces a provider pass; `ensure_linked` only connects a
            // machine that has no live graph yet (a just-created VM) and is free
            // for one that is already linked. `refresh` wins when both are sent.
            let mode: SurfaceCatalogReadMode
            if Self.surfaceBool(params["refresh"]) == true {
                mode = .forced
            } else if Self.surfaceBool(params["ensure_linked"]) == true {
                mode = .linked
            } else {
                mode = .cached
            }
            return v2VmCall(id: id, timeoutSeconds: 120) {
                let query = await Self.surfaceCatalogQuery(catalog: .shared)
                let export = await query.read(machine: machine, mode: mode)
                return Self.surfaceCatalogPayload(export, machine: machine)
            }

        case "surface.project":
            guard let raw = Self.surfaceString(params["resource"]), let resource = SurfaceResourceID(rawValue: raw) else {
                return v2Error(id: id, code: "invalid_params", message: "surface.project requires `resource` (an id from `cmux surface ls --json`, e.g. vivid-newt/terminal/term_…).")
            }
            let focus = Self.surfaceBool(params["focus"]) ?? false
            let reuse = Self.surfaceBool(params["reuse"]) ?? true
            let remoteTabID = Self.surfaceString(params["remote_tab_id"])
            let remoteWorkspaceID = Self.surfaceString(params["remote_workspace_id"])
            guard let workspaceID = surfaceTargetWorkspaceID(params) else {
                let requested = ["workspace_id", "pane_id", "surface_id"]
                    .compactMap { Self.surfaceString(params[$0]) }.joined(separator: ", ")
                let message = requested.isEmpty
                    ? "surface.project: no target workspace (pass `workspace_id`, or select one)."
                    : SurfaceCatalogError.destinationNotFound(requested).localizedDescription
                return v2Error(id: id, code: "invalid_params", message: message)
            }
            let destination = Self.surfaceDestination(surfaceResolvedParams(params), workspaceID: workspaceID)
            return v2VmCall(id: id, timeoutSeconds: 180) {
                let catalog = await SurfaceCatalog.shared
                let remoteView = try await catalog.remoteView(
                    for: resource,
                    tabID: remoteTabID,
                    workspaceID: remoteWorkspaceID
                )
                let opened = try await catalog.project(
                    resource,
                    into: destination,
                    focus: focus,
                    reuseExisting: reuse,
                    remoteView: remoteView
                )
                return await Self.markBackgroundOpen(Self.surfaceProjectPayload(opened.projection, reused: opened.reused), focus: focus)
            }

        case "surface.new_terminal":
            guard let machineRaw = Self.surfaceString(params["machine"]), !machineRaw.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "surface.new_terminal requires `machine` (\"local\" or a cloud machine id).")
            }
            let machine = SurfaceMachineID(rawValue: machineRaw)
            let command = Self.surfaceStringArray(params["command"])
            let cwd = Self.surfaceString(params["cwd"])
            let name = Self.surfaceString(params["name"])
            let remoteWorkspaceID = Self.surfaceString(params["remote_workspace_id"])
            let open = Self.surfaceBool(params["open"]) ?? true
            let focus = Self.surfaceBool(params["focus"]) ?? false
            let workspaceID = open ? surfaceTargetWorkspaceID(params, strictExplicit: true) : nil
            if open, workspaceID == nil {
                return v2Error(id: id, code: "invalid_params", message: "surface.new_terminal: no target workspace to open into (pass `workspace_id`, select one, or send `open: false`).")
            }
            let destination = workspaceID.map { Self.surfaceDestination(surfaceResolvedParams(params), workspaceID: $0) }
            return v2VmCall(id: id, timeoutSeconds: 240) {
                let payload = try await Self.surfaceNewTerminal(
                    machine: machine,
                    command: command.isEmpty ? nil : command,
                    cwd: cwd,
                    name: name,
                    remoteWorkspaceID: remoteWorkspaceID,
                    destination: destination,
                    focus: focus
                )
                return await Self.markBackgroundOpen(payload, focus: focus)
            }

        case "surface.new_display":
            let options: SurfaceNewDisplayOptions
            switch validateSurfaceNewDisplay(params, id: id) {
            case .invalid(let response): return response
            case .valid(let validated): options = validated
            }
            let destination = options.open ? surfaceNewDisplayDestination(params) : nil
            if options.open, destination == nil { return surfaceNewDisplayWorkspaceError(id: id) }
            return v2VmCall(
                id: id,
                timeoutSeconds: 240,
                mapError: { $0 is SurfaceDisplayCreationBusy ? self.surfaceNewDisplayBusyError(id: id) : nil }
            ) {
                try await Self.surfaceNewDisplay(options, destination: destination)
            }

        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    /// Handles `surface.new_display` on the suspendable socket connection task.
    /// Only the adapter owns its deadline and error envelope; creation is shared.
    nonisolated func socketWorkerSurfaceNewDisplayResponseAsync(_ request: ControlRequest) async -> String {
        let params = request.params.mapValues(\.foundationObject)
        let id = request.id?.foundationObject
        let options: SurfaceNewDisplayOptions
        switch validateSurfaceNewDisplay(params, id: id) {
        case .invalid(let response): return response
        case .valid(let validated): options = validated
        }
        do {
            let destination: SurfaceDestination?
            if options.open {
                // Resolve both workspace and pane on the main actor. The socket
                // task suspends while queued, and the legacy helpers run inline.
                destination = try await v2MainAsync {
                    self.surfaceNewDisplayDestination(request.params.mapValues(\.foundationObject))
                }
                if destination == nil { return surfaceNewDisplayWorkspaceError(id: id) }
            } else {
                destination = nil
            }
            return v2Ok(id: id, result: try await Self.surfaceNewDisplay(options, destination: destination))
        } catch let timeout as SocketMainActorHopTimeout {
            return await socketMainHopTimeoutResponse(
                id: request.id, method: request.method, isV2: true, error: timeout
            )
        } catch is SurfaceDisplayCreationBusy {
            return surfaceNewDisplayBusyError(id: id)
        } catch is CancellationError {
            return v2Error(
                id: id,
                code: "timeout",
                message: String(
                    localized: "socket.surface.newDisplay.timedOut",
                    defaultValue: "Creating the cloud display timed out. Check the catalog before retrying."
                )
            )
        } catch let error as SurfaceCatalogError {
            let code = switch error {
            case .nothingToOpen: "not_ready"
            case .destinationNotFound: "not_found"
            default: "vm_error"
            }
            return v2Error(id: id, code: code, message: error.localizedDescription)
        } catch {
            return v2Error(
                id: id,
                code: "vm_error",
                message: String(
                    localized: "socket.surface.newDisplay.failed",
                    defaultValue: "Could not create the cloud display. Check the machine status and retry."
                )
            )
        }
    }

    private struct SurfaceNewDisplayOptions: Sendable {
        let machine: SurfaceMachineID
        let open: Bool
        let focus: Bool
    }

    private enum SurfaceNewDisplayValidation {
        case valid(SurfaceNewDisplayOptions)
        case invalid(String)
    }

    /// Keeps validation order, localized errors, and defaults identical across adapters.
    private nonisolated func validateSurfaceNewDisplay(_ params: [String: Any], id: Any?) -> SurfaceNewDisplayValidation {
        guard let machineRaw = Self.surfaceString(params["machine"]), !machineRaw.isEmpty else {
            return .invalid(v2Error(
                id: id,
                code: "invalid_params",
                message: String(
                    localized: "socket.surface.newDisplay.machineRequired",
                    defaultValue: "surface.new_display requires `machine` (a cloud machine id)."
                )
            ))
        }
        let machine = SurfaceMachineID(rawValue: machineRaw)
        guard machine.cloudMachineID != nil else {
            return .invalid(v2Error(
                id: id,
                code: "invalid_params",
                message: String(
                    localized: "socket.surface.newDisplay.cloudOnly",
                    defaultValue: "surface.new_display requires a cloud machine id; local display creation is not supported."
                )
            ))
        }
        return .valid(SurfaceNewDisplayOptions(
            machine: machine,
            open: Self.surfaceBool(params["open"]) ?? true,
            focus: Self.surfaceBool(params["focus"]) ?? false
        ))
    }

    /// Called inline by the legacy worker and inside one async main-actor hop by sockets.
    private nonisolated func surfaceNewDisplayDestination(_ params: [String: Any]) -> SurfaceDestination? {
        guard let workspaceID = surfaceTargetWorkspaceID(params, strictExplicit: true) else { return nil }
        return Self.surfaceDestination(surfaceResolvedParams(params), workspaceID: workspaceID)
    }

    private nonisolated func surfaceNewDisplayWorkspaceError(id: Any?) -> String {
        v2Error(
            id: id,
            code: "invalid_params",
            message: String(
                localized: "socket.surface.newDisplay.workspaceRequired",
                defaultValue: "surface.new_display: no target workspace to open into (pass `workspace_id`, select one, or send `open: false`)."
            )
        )
    }

    private nonisolated func surfaceNewDisplayBusyError(id: Any?) -> String {
        v2Error(
            id: id,
            code: "busy",
            message: String(
                localized: "socket.surface.newDisplay.busy",
                defaultValue: "A display is already being created on this machine, or the machine changed. Wait for it to finish and retry."
            )
        )
    }

    /// One creation/projection action for both adapters. A failed projection retains
    /// the created resource; transport cancellation still reaches the caller.
    private nonisolated static func surfaceNewDisplay(
        _ options: SurfaceNewDisplayOptions,
        destination: SurfaceDestination?
    ) async throws -> [String: Any] {
        let catalog = await SurfaceCatalog.shared
        guard try await surfaceProvider(for: options.machine, catalog: catalog) != nil else {
            throw SurfaceCatalogError.noProvider(options.machine)
        }
        let resource: SurfaceResource
        do {
            resource = try await catalog.createDisplay(on: options.machine)
        } catch is CancellationError where !Task.isCancelled {
            throw SurfaceDisplayCreationBusy()
        }
        var payload = surfaceResourcePayload(resource, projections: [])
        payload["resource"] = resource.id.rawValue
        payload["open"] = options.open
        if let destination {
            do {
                let opened = try await catalog.project(
                    resource.id, into: destination, focus: options.focus, reuseExisting: false
                )
                payload = surfaceResourcePayload(resource, projections: [opened.projection])
                payload["resource"] = resource.id.rawValue
                payload.merge(surfaceProjectPayload(opened.projection, reused: opened.reused)) { _, new in new }
            } catch {
                if error is CancellationError, Task.isCancelled { throw error }
                payload["open"] = false
                payload["projection_failed"] = true
                payload["projection_error"] = surfaceDisplayProjectionFailureMessage
            }
        }
        return await markBackgroundOpen(payload, focus: options.focus)
    }

    /// The catalog can cancel creation while the request itself remains live.
    private struct SurfaceDisplayCreationBusy: Error {}

    private nonisolated static let surfaceDisplayProjectionFailureMessage = String(
        localized: "socket.surface.newDisplay.projectionFailed",
        defaultValue: "The display was created, but it could not be opened in the selected workspace. Retry with `cmux surface open <resource>`."
    )

    // MARK: - Shared pieces

    /// The catalog's provider for `machine`; a cloud machine the catalog has not seen yet
    /// (just created) gets one fleet re-read before the caller reports "no provider".
    nonisolated static func surfaceProvider(for machine: SurfaceMachineID, catalog: SurfaceCatalog) async throws -> (any SurfaceProvider)? {
        let query = await surfaceCatalogQuery(catalog: catalog)
        return await query.provider(for: machine)
    }

    @MainActor
    private static func surfaceCatalogQuery(catalog: SurfaceCatalog) -> SurfaceCatalogQueryService {
        SurfaceCatalogQueryService(catalog: catalog, projectionIdentities: { projections in
            let owners = AppDelegate.shared?.workspacesForRead(tabIds: Set(projections.map(\.workspaceID))) ?? [:]
            return SurfaceProjectionIdentity.capture(
                projections: projections,
                workspacesByID: owners
            )
        }) { _ in
        }
    }

    /// The local workspace an open lands in: `workspace_id` (UUID or `workspace:N` ref), else
    /// the workspace of a given `pane_id`/`surface_id`, else the selected workspace. When
    /// `strictExplicit` is true, an explicit but stale/malformed pane or surface is rejected
    /// instead of silently falling through to the selected workspace (used by `vm.port_open`).
    nonisolated func surfaceTargetWorkspaceID(_ params: [String: Any], strictExplicit: Bool = true) -> UUID? {
        if strictExplicit {
            var explicitWorkspaceID: UUID?
            if v2HasNonNullParam(params, "workspace_id") {
                guard let explicit = v2UUID(params, "workspace_id") else { return nil }
                let exists = v2MainSync {
                    self.tabManager?.tabs.contains { $0.id == explicit }
                        == true
                        || AppDelegate.shared?.tabManagerFor(tabId: explicit)?.tabs.contains { $0.id == explicit }
                        == true
                }
                guard exists else { return nil }
                explicitWorkspaceID = explicit
            }
            if v2HasNonNullParam(params, "pane_id") {
                guard let paneID = v2UUID(params, "pane_id") else {
                    return nil
                }
                let locatedWorkspaceID = v2MainSync { () -> UUID? in
                    if let explicitWorkspaceID {
                        let workspace = self.tabManager?.tabs.first(where: { $0.id == explicitWorkspaceID })
                            ?? AppDelegate.shared?.tabManagerFor(tabId: explicitWorkspaceID)?.tabs.first(where: { $0.id == explicitWorkspaceID })
                        return workspace?.bonsplitController.allPaneIds.contains(where: { $0.id == paneID }) == true
                            ? explicitWorkspaceID
                            : nil
                    }
                    return self.v2LocatePane(paneID)?.workspace.id
                }
                guard let locatedWorkspaceID else { return nil }
                if let explicitWorkspaceID, explicitWorkspaceID != locatedWorkspaceID {
                    return nil
                }
                explicitWorkspaceID = locatedWorkspaceID
            }
            if v2HasNonNullParam(params, "surface_id") {
                guard let surfaceID = v2UUID(params, "surface_id") else { return nil }
                let owner = v2MainSync { () -> UUID? in
                    self.surfaceWorkspace(containing: surfaceID, preferredWorkspaceID: explicitWorkspaceID)?.id
                }
                guard let owner else { return nil }
                if let explicitWorkspaceID, explicitWorkspaceID != owner {
                    return nil
                }
                explicitWorkspaceID = owner
            }
            if let explicitWorkspaceID { return explicitWorkspaceID }
        }
        if let explicit = v2UUID(params, "workspace_id") {
            return explicit
        }
        if let paneID = v2UUID(params, "pane_id"), let located = v2MainSync({ self.v2LocatePane(paneID) }) {
            return located.workspace.id
        }
        if let surfaceID = v2UUID(params, "surface_id") {
            let owner = v2MainSync { () -> UUID? in
                self.surfaceWorkspace(containing: surfaceID)?.id
            }
            if let owner { return owner }
        }
        return v2MainSync { self.tabManager?.selectedTabId }
    }

    /// Resolves the live surface owner across windows, including projected panes.
    /// A surface UUID is never used as a workspace lookup key.
    @MainActor
    private func surfaceWorkspace(containing surfaceID: UUID, preferredWorkspaceID: UUID? = nil) -> Workspace? {
        if let preferredWorkspaceID,
           let workspace = tabManager?.workspacesById[preferredWorkspaceID],
           workspace.surfaceOwnershipTarget(for: surfaceID) != nil {
            return workspace
        }
        if let owner = AppDelegate.shared?.workspaceContainingPanel(
            panelId: surfaceID, preferredWorkspaceId: preferredWorkspaceID
        ) {
            return owner.workspace
        }
        return tabManager?.tabs.first { $0.surfaceOwnershipTarget(for: surfaceID) != nil }
    }

    /// `pane_id` / `surface_id` may be UUIDs or handle refs (`pane:3`, `surface:7`); the pure
    /// destination mapper needs pane UUIDs, so resolve refs here and turn a surface into the
    /// pane that holds it.
    nonisolated func surfaceResolvedParams(_ params: [String: Any]) -> [String: Any] {
        var resolved = params
        if let paneID = v2UUID(params, "pane_id") {
            resolved["pane_id"] = paneID.uuidString
        }
        if resolved["pane_id"] == nil, let surfaceID = v2UUID(params, "surface_id") {
            let preferredWorkspaceID = v2UUID(params, "workspace_id")
            let paneID = v2MainSync { () -> String? in
                guard let workspace = self.surfaceWorkspace(
                    containing: surfaceID, preferredWorkspaceID: preferredWorkspaceID
                ) else { return nil }
                return workspace.controlSurfaceTarget(for: surfaceID)?.paneID?.uuidString
            }
            if let paneID {
                resolved["pane_id"] = paneID
                resolved["surface_id"] = nil
            }
        }
        return resolved
    }

    /// Destination from the shared params: `pane_id` + `direction` → split that pane on that
    /// side; `pane_id` + `tab_index` (or `placement: tab`) → a tab in that pane; otherwise the
    /// workspace's focused pane (`placement`, default split). Pure.
    nonisolated static func surfaceDestination(_ params: [String: Any], workspaceID: UUID) -> SurfaceDestination {
        let paneID = surfaceString(params["pane_id"]) ?? surfaceString(params["surface_id"])
        let placement = surfaceString(params["placement"]).flatMap { SurfacePlacement(rawValue: $0.lowercased()) } ?? .split
        let direction = surfaceString(params["direction"]).flatMap { SurfaceSplitDirection(rawValue: $0.lowercased()) }
        let tabIndex = surfaceInt(params["tab_index"])
        if let paneID, let direction {
            return .split(workspaceID: workspaceID, paneID: paneID, direction: direction)
        }
        if let paneID, (tabIndex != nil || placement == .tab) {
            return .tab(workspaceID: workspaceID, paneID: paneID, index: tabIndex)
        }
        if let paneID {
            return .split(workspaceID: workspaceID, paneID: paneID, direction: .right)
        }
        return .workspace(id: workspaceID, placement: placement)
    }

    nonisolated static func surfaceMachineFilter(_ raw: Any?) -> SurfaceMachineID? {
        guard let value = surfaceString(raw), !value.isEmpty else { return nil }
        return SurfaceMachineID(rawValue: value)
    }

    // MARK: Wire payloads (snake_case; the same shape the CLI and the sidebar read)

    nonisolated static func surfaceCatalogPayload(_ export: SurfaceCatalogExport, machine: SurfaceMachineID?, cloudOnly: Bool = false) -> [String: Any] {
        let snapshot = export.catalog
        let machines = snapshot.machines.filter { info in
            if cloudOnly, info.id.isLocal { return false }
            if let machine { return info.id == machine }
            return true
        }
        let included = Set(machines.map { $0.id })
        let resources = snapshot.resources.filter { included.contains($0.machine) }
        let resourceIDs = Set(resources.map { $0.id })
        let projections = snapshot.projections.filter { resourceIDs.contains($0.resource) }
        let cloudStates = export.cloudStates.filter { state in
            included.contains(state.machine)
        }
        let cloudStateObservations = export.cloudStateObservations
        var openPanels: [SurfaceResourceID: [SurfaceProjection]] = [:]
        for projection in projections {
            openPanels[projection.resource, default: []].append(projection)
        }
        return [
            "machines": machines.map(surfaceMachinePayload),
            "resources": resources.map { surfaceResourcePayload($0, projections: openPanels[$0.id] ?? []) },
            "projections": projections.map {
                surfaceProjectionPayload($0, identity: export.projectionIdentities[$0])
            },
            "cloud_states": cloudStates.map { state in
                surfaceCloudStatePayload(
                    state,
                    observation: cloudStateObservations[state.machine] ?? .current
                )
            },
        ]
    }

    nonisolated static func surfaceMachinePayload(_ info: SurfaceMachineInfo) -> [String: Any] {
        [
            "id": info.id.rawValue,
            "name": info.name,
            "status": info.status,
            "has_desktop": info.hasDesktop,
        ]
    }

    @MainActor
    static func surfaceNewTerminal(
        machine: SurfaceMachineID,
        command: [String]?,
        cwd: String?,
        name: String?,
        remoteWorkspaceID: String?,
        destination: SurfaceDestination?,
        focus: Bool
    ) async throws -> [String: Any] {
        let catalog = SurfaceCatalog.shared
        guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
        let resource = try await provider.createTerminal(command: command, cwd: cwd, name: name, remoteWorkspaceID: remoteWorkspaceID)
        var payload = surfaceResourcePayload(resource, projections: [])
        if let destination {
            let result = try await catalog.project(resource.id, into: destination, focus: focus, reuseExisting: false)
            payload.merge(surfaceProjectPayload(result.projection, reused: result.reused)) { _, new in new }
        }
        return payload
    }

    nonisolated static func surfaceResourcePayload(_ resource: SurfaceResource, projections: [SurfaceProjection]) -> [String: Any] {
        var payload: [String: Any] = [
            "id": resource.id.rawValue,
            "machine": resource.machine.rawValue,
            "kind": resource.kind.rawValue,
            "key": resource.id.key,
            "title": resource.title,
            "detail": resource.detail ?? NSNull(),
            "lifecycle": resource.lifecycle.rawValue,
            "port": resource.port ?? NSNull(),
            "url": resource.url ?? NSNull(),
            "open": !projections.isEmpty,
            "open_surface_ids": projections.map { $0.panelID.uuidString },
            "open_workspace_ids": projections.map { $0.workspaceID.uuidString },
        ]
        if let agent = resource.agent {
            payload["agent"] = ["state": agent.state, "source": agent.source ?? NSNull()] as [String: Any]
        } else {
            payload["agent"] = NSNull()
        }
        if let workspace = resource.remoteWorkspace {
            payload["remote_workspace"] = surfaceRemoteWorkspacePayload(workspace)
        } else {
            payload["remote_workspace"] = NSNull()
        }
        // All views of the resource (one per daemon tab). null = the provider does not
        // model views; [] = alive with zero views (the machine's pool).
        if let views = resource.remoteViews {
            payload["view_count"] = views.count
            payload["remote_views"] = views.map { view in
                [
                    "tab_id": view.tabID,
                    "workspace": surfaceRemoteWorkspacePayload(view.workspace),
                    "screen_id": view.screenID ?? NSNull(),
                    "pane_id": view.paneID ?? NSNull(),
                    "name": view.name ?? NSNull(),
                    "index": view.index ?? NSNull(),
                    "focused": view.focused ?? NSNull(),
                    "screen_index": view.screenIndex ?? NSNull(),
                    "pane_index": view.paneIndex ?? NSNull(),
                ] as [String: Any]
            }
        } else {
            payload["view_count"] = NSNull()
            payload["remote_views"] = NSNull()
        }
        return payload
    }

    nonisolated static func surfaceRemoteWorkspacePayload(_ workspace: SurfaceRemoteWorkspace) -> [String: Any] {
        [
            "id": workspace.id,
            "name": workspace.name,
            "index": workspace.index,
            "focused": workspace.focused,
        ]
    }

    nonisolated static func surfaceProjectionPayload(
        _ projection: SurfaceProjection,
        identity: SurfaceProjectionIdentity? = nil
    ) -> [String: Any] {
        [
            "resource": projection.resource.rawValue,
            "workspace_id": projection.workspaceID.uuidString,
            "panel_id": projection.panelID.uuidString,
            "surface_id": projection.panelID.uuidString,
            "stable_surface_id": identity?.stableSurfaceID.uuidString ?? NSNull(),
            "stable_workspace_id": identity?.stableWorkspaceID.uuidString ?? NSNull(),
            "remote_workspace_id": projection.remoteWorkspaceID ?? NSNull(),
            "remote_tab_id": projection.remoteTabID ?? NSNull(),
        ]
    }

    /// An open that did not take focus marks the pane it created unread, so the person
    /// sees that something landed without being pulled to it
    /// (`SurfacePaneFactory.markOpenedInBackground`). A reused pane was already there.
    /// Returns `payload` unchanged.
    nonisolated static func markBackgroundOpen(_ payload: [String: Any], focus: Bool) async -> [String: Any] {
        guard !focus, payload["reused"] as? Bool != true,
              let workspaceID = (payload["workspace_id"] as? String).flatMap(UUID.init(uuidString:)),
              let panelID = ((payload["surface_id"] as? String) ?? (payload["surface_ids"] as? [String])?.first)
                .flatMap(UUID.init(uuidString:)) else { return payload }
        await SurfacePaneFactory.markOpenedInBackground(panelID: panelID, in: workspaceID)
        return payload
    }

    nonisolated static func surfaceProjectPayload(_ projection: SurfaceProjection, reused: Bool) -> [String: Any] {
        [
            "resource": projection.resource.rawValue,
            "workspace_id": projection.workspaceID.uuidString,
            "surface_id": projection.panelID.uuidString,
            "panel_id": projection.panelID.uuidString,
            "reused": reused,
            "remote_workspace_id": projection.remoteWorkspaceID ?? NSNull(),
            "remote_tab_id": projection.remoteTabID ?? NSNull(),
        ]
    }

    /// Agent-facing complete state. The typed graph makes common joins cheap;
    /// snapshot retains every daemon field, including fields this build does not
    /// know yet, after credential-like fields pass through the redaction boundary.
    /// Synchronization keeps the unredacted bytes internally.
    nonisolated static func surfaceCloudStatePayload(
        _ state: CloudVMState,
        observation: CloudVMStateObservation = .current
    ) -> [String: Any] {
        func optional(_ value: String?) -> Any { value ?? NSNull() }
        let snapshot: Any = state.agentSnapshotObject() ?? NSNull()
        let cursor: Any = state.cursor.map { [
            "generation": $0.generation,
            "revision": String($0.revision),
        ] as [String: Any] } ?? NSNull()
        let pendingWrites: [[String: Any]] = (observation.pendingWrites ?? []).map { pending in
            [
                "kind": pending.kind.rawValue,
                "resource": pending.resource?.rawValue ?? NSNull(),
                "remote_workspace_id": pending.remoteWorkspaceID ?? NSNull(),
                "remote_tab_id": pending.remoteTabID ?? NSNull(),
                "name": pending.name ?? NSNull(),
                "receipt": pending.receipt.map {
                    ["generation": $0.generation, "revision": String($0.revision)] as [String: Any]
                } ?? NSNull(),
            ]
        }
        return [
            "machine": state.machine.rawValue,
            "cursor": cursor,
            "sync_mode": state.syncMode.rawValue,
            "freshness": observation.freshness.rawValue,
            "stale_reason": observation.reason ?? NSNull(),
            "pending_writes": pendingWrites,
            "workspaces": state.workspaces.map { [
                "id": $0.id, "name": $0.name, "index": $0.index, "focused": $0.focused,
            ] as [String: Any] },
            "screens": state.screens.map { [
                "id": $0.id, "workspace_id": $0.workspaceID, "name": optional($0.name),
                "index": $0.index, "focused": $0.focused, "layout": $0.layout.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull(),
            ] as [String: Any] },
            "panes": state.panes.map { [
                "id": $0.id, "screen_id": $0.screenID, "name": optional($0.name),
                "focused": $0.focused, "zoomed": $0.zoomed, "tab_ids": $0.tabIDs,
            ] as [String: Any] },
            "tabs": state.tabs.map { [
                "id": $0.id, "pane_id": $0.paneID, "name": optional($0.name),
                "index": $0.index, "focused": $0.focused, "content_kind": $0.contentKind, "content_id": $0.contentID,
            ] as [String: Any] },
            "terminals": state.terminals.map { [
                "id": $0.id, "tab_ids": $0.tabIDs, "title": $0.title, "cwd": optional($0.cwd),
                "lifecycle": $0.lifecycle, "cols": $0.cols ?? NSNull(), "rows": $0.rows ?? NSNull(), "running": $0.running ?? NSNull(),
            ] as [String: Any] },
            "browsers": state.browsers.map { [
                "id": $0.id, "tab_id": $0.tabID, "url": $0.url, "title": $0.title, "status": $0.status,
            ] as [String: Any] },
            "agents": state.agents.map { [
                "id": optional($0.id), "terminal_id": $0.terminalID, "state": $0.state, "source": optional($0.source),
            ] as [String: Any] },
            "other_entities": state.otherEntities.map { entity in
                [
                    "kind": entity.kind,
                    "id": entity.id ?? NSNull(),
                    "value": state.agentEntityObject(entity),
                ] as [String: Any]
            },
            "snapshot_redacted": true,
            "snapshot": snapshot,
        ]
    }

    // MARK: Param helpers (nonisolated; the worker parses before hopping to the main actor)

    nonisolated static func surfaceString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Reads a required string while preserving an explicit empty value. Most
    /// identifiers use ``surfaceString`` because empty means missing there.
    /// Rename commands are different: an empty string is the wire-level clear
    /// operation, while a missing or null value is a malformed request.
    nonisolated static func surfaceStringPreservingEmpty(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func surfaceBool(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        if let text = raw as? String {
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    nonisolated static func surfaceInt(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    nonisolated static func surfaceStringArray(_ raw: Any?) -> [String] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { surfaceString($0) }
    }
}
