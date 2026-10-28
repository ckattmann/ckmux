import CmuxSurfaceCatalogModel
import Foundation

/// Both Files presentations resolve through the same workspace and account authority.
@MainActor
struct FileExplorerWorkspaceRootResolver {
    let catalog: SurfaceCatalog
    let cloudEnabled: @MainActor @Sendable () -> Bool
    let managedCloudEnabled: @MainActor @Sendable () -> Bool

    init(
        catalog: SurfaceCatalog? = nil,
        cloudEnabled: @escaping @MainActor @Sendable () -> Bool = { false },
        managedCloudEnabled: @escaping @MainActor @Sendable () -> Bool = { false }
    ) {
        self.catalog = catalog ?? SurfaceCatalog.shared
        self.cloudEnabled = cloudEnabled
        self.managedCloudEnabled = managedCloudEnabled
    }

    func resolve(_ workspace: Workspace) -> FileExplorerWorkspaceRoot {
        // A cmux-tui binding is the explicit Cloud filesystem authority. A
        // legacy managedCloudVMID on an SSH workspace must keep using its SSH
        // transport, otherwise Files would silently change hosts.
        let path = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        // A local workspace may not have reported a cwd yet (fresh and
        // restored workspaces do this briefly).  Files still belongs to this
        // Mac; use its home directory instead of dropping the root entirely.
        let localPath = path.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : path
        return .local(workspaceId: workspace.id, path: localPath)
    }

}
