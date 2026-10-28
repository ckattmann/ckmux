import Combine
import Foundation
import CmuxSidebar

extension Workspace {
    private func normalizedSidebarDirectory(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A workspace can host a local terminal when its own lifecycle is local.
    /// Mixed local/cloud workspaces remain eligible when they contain at least
    /// one local surface; a cloud-only projection is not a safe staging target
    /// until it has a local host pane.
    var canHostLocalTerminal: Bool {
        guard !isRemoteWorkspace, !isRemoteTmuxMirror, cloudVMBinding == nil else { return false }
        let hasCloudProjection = panels.keys.contains { cloudDirectoryProvenanceRequired(panelId: $0) }
        return !hasCloudProjection || panels.keys.contains { machineOwningSurface($0)?.isLocal == true }
    }

    var presentedCurrentDirectory: String? {
        normalizedSidebarDirectory(currentDirectory)
    }

    func reportedPanelDirectory(panelId: UUID) -> String? {
        if !allowsLocalDirectoryFallback(panelId: panelId) {
            return trustedReportedPanelDirectory(panelId: panelId)
        }
        return normalizedSidebarDirectory(panelDirectories[panelId])
    }

    private func trustedReportedPanelDirectory(panelId: UUID) -> String? {
        guard remoteDirectoryReportPanelIds.contains(panelId) else { return nil }
        return normalizedSidebarDirectory(panelDirectories[panelId])
    }

    func effectivePanelDirectory(panelId: UUID, localFallback: String? = nil) -> String? {
        if let directory = reportedPanelDirectory(panelId: panelId) {
            return directory
        }
        guard allowsLocalDirectoryFallback(panelId: panelId) else { return nil }
        return normalizedSidebarDirectory(localFallback)
            ?? normalizedSidebarDirectory(terminalPanel(for: panelId)?.requestedWorkingDirectory)
    }

    func allowsLocalDirectoryFallback(panelId: UUID) -> Bool {
        guard !remoteDirectoryTrustRequiredPanelIds.contains(panelId),
              !isRemoteTerminalSurface(panelId),
              !isRemoteTmuxMirror else { return false }
        if let agentPanel = panels[panelId] as? AgentSessionPanel {
            return normalizedSidebarDirectory(agentPanel.workingDirectory) != nil
        }
        return terminalPanel(for: panelId) != nil
    }

    func clearDemotedRemoteDirectoryState(panelIds: Set<UUID>) {
        guard !panelIds.isEmpty else { return }
        let removedDirectories = Set(panelIds.compactMap { normalizedSidebarDirectory(panelDirectories[$0]) })
        for panelId in panelIds {
            if let agentPanel = panels[panelId] as? AgentSessionPanel,
               let workingDirectory = normalizedSidebarDirectory(agentPanel.workingDirectory),
               removedDirectories.contains(workingDirectory) {
                agentPanel.clearWorkingDirectory()
            }
            panelDirectories.removeValue(forKey: panelId)
            panelDirectoryDisplayLabels.removeValue(forKey: panelId)
            clearPanelGitBranch(panelId: panelId)
        }
        guard let current = normalizedSidebarDirectory(currentDirectory),
              removedDirectories.contains(current) else { return }
        currentDirectory = demotedRemoteDirectoryReplacement(excluding: panelIds)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func demotedRemoteDirectoryReplacement(excluding excludedPanelIds: Set<UUID>) -> String? {
        for panelId in sidebarOrderedPanelIds() where !excludedPanelIds.contains(panelId) {
            if let directory = normalizedSidebarDirectory(panelDirectories[panelId]) { return directory }
            if allowsLocalDirectoryFallback(panelId: panelId),
               let directory = normalizedSidebarDirectory(terminalPanel(for: panelId)?.requestedWorkingDirectory) {
                return directory
            }
        }
        return nil
    }

    func currentDirectoryChangeRevisionPublisher() -> AnyPublisher<UInt64, Never> {
        NotificationCenter.default
            .publisher(for: .workspaceCurrentDirectoryDidChange)
            .filter { [weak self] notification in
                guard let self else { return false }
                return notification.userInfo?["workspaceId"] as? UUID == self.id &&
                    notification.userInfo?["presentedDirectoryOnly"] as? Bool == true
            }
            .map { _ in () }
            .scan(UInt64(0)) { revision, _ in revision &+ 1 }
            .prepend(0)
            .eraseToAnyPublisher()
    }

    private func sidebarHomeDirectoryForCanonicalization(
        resolvedPanelDirectories: [UUID: String]
    ) -> String? {
        guard usesRemoteDirectoryProvenance else { return FileManager.default.homeDirectoryForCurrentUser.path }
        let trustedRemoteDirectories = resolvedPanelDirectories.keys.compactMap {
            trustedReportedPanelDirectory(panelId: $0)
        }
        return SidebarBranchOrdering().inferredRemoteHomeDirectory(
            from: trustedRemoteDirectories,
            fallbackDirectory: nil
        )
    }

    private func sidebarResolvedDirectory(for panelId: UUID) -> String? {
        if let directory = effectivePanelDirectory(panelId: panelId) {
            return directory
        }
        guard !usesRemoteDirectoryProvenance,
              allowsLocalDirectoryFallback(panelId: panelId),
              panelId == focusedPanelId else { return nil }
        return normalizedSidebarDirectory(currentDirectory)
    }

    private func sidebarResolvedPanelDirectories(orderedPanelIds: [UUID]) -> [UUID: String] {
        var resolved: [UUID: String] = [:]
        for panelId in orderedPanelIds {
            if let directory = sidebarResolvedDirectory(for: panelId) {
                resolved[panelId] = directory
            }
        }
        return resolved
    }

    /// One sidebar directory row: the text to render and whether it is a reporter-supplied display label.
    struct SidebarDisplayedDirectory: Equatable {
        let text: String
        let isDisplayLabel: Bool
    }

    func sidebarDirectoriesInDisplayOrder(orderedPanelIds: [UUID], includeFallback: Bool = true) -> [String] {
        sidebarDisplayedDirectoriesInDisplayOrder(
            orderedPanelIds: orderedPanelIds,
            includeFallback: includeFallback
        ).map(\.text)
    }

    func sidebarDisplayedDirectoriesInDisplayOrder(
        orderedPanelIds: [UUID],
        includeFallback: Bool = true
    ) -> [SidebarDisplayedDirectory] {
        sidebarOrderedUniqueDirectories(
            orderedPanelIds: orderedPanelIds,
            includeFallback: includeFallback,
            preferDisplayLabels: true
        )
    }

    func sidebarFilesystemDirectoriesInDisplayOrder(orderedPanelIds: [UUID], includeFallback: Bool = true) -> [String] {
        sidebarOrderedUniqueDirectories(
            orderedPanelIds: orderedPanelIds,
            includeFallback: includeFallback,
            preferDisplayLabels: false
        ).map(\.text)
    }

    func sidebarFilesystemDirectoriesInDisplayOrder() -> [String] {
        sidebarFilesystemDirectoriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    private func sidebarOrderedUniqueDirectories(
        orderedPanelIds: [UUID],
        includeFallback: Bool,
        preferDisplayLabels: Bool
    ) -> [SidebarDisplayedDirectory] {
        let resolvedDirectories = sidebarResolvedPanelDirectories(orderedPanelIds: orderedPanelIds)
        let homeDirectoryForCanonicalization = sidebarHomeDirectoryForCanonicalization(
            resolvedPanelDirectories: resolvedDirectories
        )
        var ordered: [SidebarDisplayedDirectory] = []
        var orderedIndexByKey: [String: Int] = [:]

        for panelId in orderedPanelIds {
            guard let directory = resolvedDirectories[panelId],
                  let key = SidebarBranchOrdering().canonicalDirectoryKey(
                      directory,
                      homeDirectoryForTildeExpansion: homeDirectoryForCanonicalization
                  ) else { continue }
            let displayLabel = preferDisplayLabels
                ? normalizedSidebarDirectory(panelDirectoryDisplayLabels[panelId])
                : nil
            if let existingIndex = orderedIndexByKey[key] {
                if let displayLabel, !ordered[existingIndex].isDisplayLabel {
                    ordered[existingIndex] = SidebarDisplayedDirectory(text: displayLabel, isDisplayLabel: true)
                }
                continue
            }
            orderedIndexByKey[key] = ordered.count
            ordered.append(SidebarDisplayedDirectory(
                text: displayLabel ?? directory,
                isDisplayLabel: displayLabel != nil
            ))
        }

        if includeFallback, ordered.isEmpty, let fallbackDirectory = presentedCurrentDirectory {
            return [SidebarDisplayedDirectory(text: fallbackDirectory, isDisplayLabel: false)]
        }
        return ordered
    }

    func sidebarDirectoriesInDisplayOrder() -> [String] {
        sidebarDirectoriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarGitBranchesInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarGitBranchState] {
        SidebarBranchOrdering()
            .orderedUniqueBranches(
                orderedPanelIds: orderedPanelIds,
                panelBranches: sidebarPanelGitBranches(orderedPanelIds: orderedPanelIds),
                fallbackBranch: presentedGitBranch
            )
            .map { SidebarGitBranchState(branch: $0.name, isDirty: $0.isDirty) }
    }

    func sidebarGitBranchesInDisplayOrder() -> [SidebarGitBranchState] {
        sidebarGitBranchesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder(
        orderedPanelIds: [UUID]
    ) -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        let resolvedDirectories = sidebarResolvedPanelDirectories(orderedPanelIds: orderedPanelIds)
        return SidebarBranchOrdering().orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: orderedPanelIds,
            panelBranches: sidebarPanelGitBranches(orderedPanelIds: orderedPanelIds),
            panelDirectories: resolvedDirectories,
            panelDirectoryDisplayLabels: panelDirectoryDisplayLabels,
            defaultDirectory: presentedCurrentDirectory,
            homeDirectoryForTildeExpansion: sidebarHomeDirectoryForCanonicalization(
                resolvedPanelDirectories: resolvedDirectories
            ),
            fallbackBranch: presentedGitBranch
        )
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder() -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    private func sidebarPanelGitBranches(orderedPanelIds: [UUID]) -> [UUID: SidebarGitBranchState] {
        var branches: [UUID: SidebarGitBranchState] = [:]
        for panelId in orderedPanelIds {
        }
        return branches
    }
}

extension Workspace {
    func reportedPanelGitBranch(panelId: UUID) -> SidebarGitBranchState? {
        panelGitBranches[panelId]
    }

    var presentedGitBranch: SidebarGitBranchState? {
        gitBranch
    }
}
