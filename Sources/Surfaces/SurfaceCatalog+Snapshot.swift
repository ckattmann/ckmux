import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Reconciles machine-summary workspace names with the accepted daemon graph.
    /// Resource rows may carry optimistic creation or rename overlays, but the
    /// authoritative snapshot must expose the last accepted name for identities
    /// already present in `cloudStates`.
    private func authoritativeMachineInfo(_ info: SurfaceMachineInfo) -> SurfaceMachineInfo {
        guard info.id.tuiMachineID != nil,
              let state = cloudStates[info.id],
              let workspaces = info.remoteWorkspaces else { return info }
        let accepted = Dictionary(uniqueKeysWithValues: state.workspaces.map { workspace in
            (workspace.id, SurfaceRemoteWorkspace(
                id: workspace.id,
                name: workspace.name,
                index: workspace.index,
                focused: workspace.focused
            ))
        })
        var adjusted = info
        adjusted.remoteWorkspaces = workspaces.map { accepted[$0.id] ?? $0 }
        return adjusted
    }

    /// The provider rows without any deletion or rename intent applied, used to
    /// enumerate destructive operations. Presentation still withholds a stale
    /// graph's cwd, and stale machines are flagged, exactly as `snapshot` does.
    var authoritativeSnapshot: SurfaceCatalogSnapshot {
        return SurfaceCatalogSnapshot(
            machines: machines.values.map(authoritativeMachineInfo).sorted {
                if $0.id.isLocal != $1.id.isLocal { return $0.id.isLocal }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            resources: resources.values.map(resourceForPresentation).sorted { $0.catalogPrecedes($1) },
            projections: projections.sorted { $0.panelID.uuidString < $1.panelID.uuidString },
            staleMachineIDs: Set(cloudStateObservations.filter { $0.value.freshness != .current }.keys),
            displayCreationMachines: displayCreationMachines.isEmpty ? nil : displayCreationMachines,
            pendingDisplayCreations: activeDisplayCreations.isEmpty ? nil : activeDisplayCreations,
            cloudDisplayMemberships: cloudDisplayMemberships()
        )
    }

    /// Projects deletion and rename intents over provider state for all
    /// sidebar/CLI readers, so every entrypoint sees one optimistic tree.
    var snapshot: SurfaceCatalogSnapshot {
        var result = authoritativeSnapshot
        applyPendingWorkspaceCreations(to: &result)
        return result
    }

    private func applyPendingWorkspaceCreations(to result: inout SurfaceCatalogSnapshot) {
        var pending: [SurfaceMachineID: [String: UUID]] = [:]
        result.pendingWorkspaceCreations = pending.isEmpty ? nil : pending
    }


}

extension SurfaceCatalog {
    /// Complete export for the local control socket. This is separate from
    /// `snapshot` because sidebar redraws do not need to copy or hash the full
    /// remote daemon documents.
    var export: SurfaceCatalogExport {
        let retainedObservations = cloudStateObservations.filter { cloudStates[$0.key] != nil }
        return SurfaceCatalogExport(
            catalog: snapshot,
            cloudStates: cloudStates.values.sorted { $0.machine.rawValue < $1.machine.rawValue },
            cloudStateObservations: retainedObservations
        )
    }

}
