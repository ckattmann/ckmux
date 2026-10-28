import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceProvider {
    func materializeValidated(
        _ resource: SurfaceResource,
        remoteView: SurfaceRemoteView?,
        at destination: SurfaceDestination,
        focus: Bool,
        adopting reservation: CloudTerminalPaneReservation?,
        loadingReservation: CloudMachineLoadingReservation? = nil
    ) async throws -> SurfaceProjection {
        let projection = try await materialize(resource, remoteView: remoteView, at: destination, focus: focus, adopting: reservation)
        guard projection.resource == resource.id, projection.workspaceID == destination.workspaceID else {
            discardMaterialization(projection)
            throw SurfaceCatalogError.destinationNotFound(destination.workspaceID.uuidString)
        }
        return projection
    }
}
