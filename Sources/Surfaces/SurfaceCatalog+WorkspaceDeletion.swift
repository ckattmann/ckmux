import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    private func checkDeletionProvider(_ provider: any SurfaceProvider, machine: SurfaceMachineID) throws {
        try Task.checkCancellation()
        guard self.provider(for: machine) === provider else { throw CancellationError() }
    }

}
