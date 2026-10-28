import Bonsplit
import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// The staged restore identity owns a placeholder until its provider materializes it.
    /// Retains workspace coordinates so routing can validate ownership in the same read.
    func projectionIncludingPendingRestore(forPanel panelID: UUID) -> SurfaceProjection? {
        pendingRestoredProjections.projection(forPanel: panelID) ?? projection(forPanel: panelID)
    }

    /// Captures the authoritative identity, including Cloud resources still awaiting a provider.
    /// Pending remote identity takes precedence over a live local placeholder.
    func projectionRecord(forPanel panelID: UUID) -> SurfaceProjectionRecord? {
        guard let projection = projectionIncludingPendingRestore(forPanel: panelID) else { return nil }
        return SurfaceProjectionRecord(
            panelID: panelID,
            resource: projection.resource,
            remoteWorkspaceID: projection.remoteWorkspaceID,
            remoteTabID: projection.remoteTabID
        )
    }

    /// Only a provider's remote materialization supersedes a pending Cloud identity.
    /// The local shell/browser registered during restore is still its placeholder.
    func consumePendingProjectionIfMaterialized(_ projection: SurfaceProjection) {
        if !projection.resource.machine.isLocal {
            pendingRestoredProjections.remove(panelID: projection.panelID)
        }
    }

    func projection(forPanel panelID: UUID) -> SurfaceProjection? {
        projections.first { $0.panelID == panelID }
    }


    /// Restored projections retain their owner even before the provider reconnects.
    func machineOwningPanel(_ panelID: UUID) -> SurfaceMachineID? {
        projectionIncludingPendingRestore(forPanel: panelID)?.resource.machine
    }

    func validateOwnership(of resources: [SurfaceResourceID], at destination: SurfaceDestination) throws {
        guard let workspace = Workspace.liveWorkspace(id: destination.workspaceID) else {
            throw SurfaceCatalogError.destinationNotFound(destination.workspaceID.uuidString)
        }
        if let rejection = ownershipRejection(for: resources, policy: workspace.surfaceOwnershipPolicy) {
            throw rejection
        }
    }

    /// Provider work may suspend. Check the live destination again before its
    /// receipt can enter the catalog, and retire only the just-created view.
    func validateMaterializationOwnership(_ projection: SurfaceProjection, provider: any SurfaceProvider) throws {
        do {
            if DockSplitStore.liveStore(containingPanel: projection.panelID)?.scope == .global {
                return
            }
            try validateOwnership(of: [projection.resource], at: .workspace(id: projection.workspaceID, placement: .tab))
        } catch {
            provider.discardMaterialization(projection)
            throw error
        }
    }

    func canRestoreProjection(_ projection: SurfaceProjection) -> Bool {
        if DockSplitStore.liveStore(containingPanel: projection.panelID)?.scope == .global {
            return true
        }
        do {
            try validateOwnership(of: [projection.resource], at: .workspace(id: projection.workspaceID, placement: .tab))
            return true
        } catch {
            return false
        }
    }

    func ownershipRejection(for resources: [SurfaceResourceID]) -> SurfaceTransferRejection? { nil }

}


/// Local-only replacements for the cloud projection machinery.
struct CloudTerminalPaneReservation {
    let workspaceID: UUID
    let panelID: UUID
    let remoteWorkspaceID: String?
}

struct CloudMachineLoadingReservation {
    let panelID: UUID
    let workspaceID: UUID
    let machineID: SurfaceMachineID
    init?(_ id: SurfaceResourceID, at destination: SurfaceDestination, remoteView: SurfaceRemoteView?) { nil }
}

struct SurfaceTransferRejection: Error {
    let message: String
}

struct SurfaceOwnershipPolicy {
    var cloudMachine: SurfaceMachineID? { nil }
    func rejection(for machine: SurfaceMachineID?, kind: SurfaceResourceKind? = nil) -> SurfaceTransferRejection? { nil }
}

enum SurfaceProjectionEndReason {
    case replaced
    case closed
}

extension SurfaceResource {
    func catalogPrecedes(_ other: SurfaceResource) -> Bool {
        id.rawValue < other.id.rawValue
    }
}

@MainActor
extension Workspace {
    static func liveWorkspace(id: UUID) -> Workspace? {
        AppDelegate.shared?.tabManagerFor(tabId: id)?.tabs.first(where: { $0.id == id })
    }
    var surfaceOwnershipPolicy: SurfaceOwnershipPolicy { SurfaceOwnershipPolicy() }
    func discardCloudMachineLoadingPanel(panelID: UUID, machineID: SurfaceMachineID) -> Bool { true }
}

@MainActor
extension DockSplitStore {
    var surfaceOwnershipPolicy: SurfaceOwnershipPolicy { SurfaceOwnershipPolicy() }
    var ownershipPolicy: SurfaceOwnershipPolicy { SurfaceOwnershipPolicy() }
}

@MainActor
extension AppDelegate {
    var policy: SurfaceOwnershipPolicy { SurfaceOwnershipPolicy() }
    func ownershipRejection(forBonsplitTab tabID: UUID, policy: SurfaceOwnershipPolicy) -> SurfaceTransferRejection? { nil }
}

@MainActor
extension SurfaceCatalog {
    func beginProjectionMutation(for resources: [SurfaceResourceID]) -> Int { 0 }
    func resourceForPresentation(_ resource: SurfaceResource) -> SurfaceResource { resource }
    func attachRemoteView(_ view: SurfaceRemoteView?, to projection: SurfaceProjection) -> SurfaceProjection { projection }
    func reconcileCloudWorkspaceBinding(localWorkspaceID: UUID) {}
    var displayCreationMachines: Set<SurfaceMachineID> { [] }
    func cloudDisplayMemberships() -> [CloudVMDisplayMembership] { [] }
    func requestPortDiscovery(for machine: SurfaceMachineID) {}
    func createDisplay(on machine: SurfaceMachineID) async throws -> SurfaceResource {
        throw SurfaceCatalogError.noProvider(machine)
    }
    func ownershipRejection(for resources: [SurfaceResourceID], policy: SurfaceOwnershipPolicy) -> SurfaceTransferRejection? { nil }
    func remoteView(for resource: SurfaceResourceID, tabID: String?, workspaceID: String?) async throws -> SurfaceRemoteView? { nil }
}

final class SurfaceResourceDragRegistry {
    static let shared = SurfaceResourceDragRegistry()
    func group(id: UUID) -> SurfaceResourceGroup? { nil }
    func discard(id: UUID) {}
}
