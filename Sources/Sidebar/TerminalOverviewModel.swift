import Combine
import CmuxSidebar
import CmuxWorkspaces
import Foundation

struct TerminalOverviewRow: Identifiable, Equatable {
    enum Activity: Equatable {
        case unknown
        case idle
        case running
    }

    let id: UUID
    let workspaceId: UUID
    let title: String
    let workspaceTitle: String
    let directory: String?
    let groupId: UUID?
    let isSelectedWorkspace: Bool
    let isFocused: Bool
    let activity: Activity
    let gitBranch: String?
    let gitIsDirty: Bool
    let pullRequestNumber: Int?
    let pullRequestURL: URL?
    let ports: [Int]
    let agentSource: String?
    let agentState: String?
    let lastPrompt: String?
    let lastPromptAt: Date?
    let isRemote: Bool
}

struct TerminalOverviewSection: Identifiable, Equatable {
    let id: UUID?
    let name: String?
    let colorHex: String?
    let rows: [TerminalOverviewRow]
}

@MainActor
final class TerminalOverviewModel: ObservableObject {
    @Published private(set) var sections: [TerminalOverviewSection] = []
    @Published private(set) var groups: [WorkspaceGroupMenuSnapshot.Item] = []

    private weak var tabManager: TabManager?
    private var managerCancellables: Set<AnyCancellable> = []
    private var workspaceCancellables: [AnyCancellable] = []
    private var refreshTimer: Timer?
    private var isRebuildScheduled = false

    func attach(_ tabManager: TabManager) {
        guard self.tabManager !== tabManager || managerCancellables.isEmpty else { return }
        detach()
        self.tabManager = tabManager
        tabManager.tabsPublisher
            .sink { [weak self] tabs in
                self?.observeWorkspaces(tabs)
                self?.scheduleRebuild()
            }
            .store(in: &managerCancellables)
        tabManager.workspaceGroupsPublisher
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &managerCancellables)
        tabManager.selectedTabIdPublisher
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &managerCancellables)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        rebuild()
    }

    func detach() {
        managerCancellables.removeAll()
        workspaceCancellables.removeAll()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func observeWorkspaces(_ workspaces: [Workspace]) {
        workspaceCancellables = workspaces.flatMap { workspace -> [AnyCancellable] in
            [
                workspace.objectWillChange.sink { [weak self] _ in self?.scheduleRebuild() },
                workspace.panelsPublisher.sink { [weak self] _ in self?.scheduleRebuild() },
                workspace.paneLayoutVersionPublisher.sink { [weak self] _ in self?.scheduleRebuild() },
            ]
        }
    }

    private func scheduleRebuild() {
        guard !isRebuildScheduled else { return }
        isRebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRebuildScheduled = false
            self.rebuild()
        }
    }

    private func rebuild() {
        guard let tabManager else {
            sections = []
            groups = []
            return
        }
        let workspaceGroups = tabManager.workspaceGroups
        let groupIdByAnchor = Dictionary(
            workspaceGroups.compactMap { group in group.liveAnchorWorkspaceId.map { ($0, group.id) } },
            uniquingKeysWith: { first, _ in first }
        )
        let knownGroupIds = Set(workspaceGroups.map(\.id))
        let selectedWorkspaceId = tabManager.selectedTabId

        var rowsByGroupId: [UUID?: [TerminalOverviewRow]] = [:]
        for workspace in tabManager.tabs {
            let groupId = groupIdByAnchor[workspace.id]
                ?? workspace.groupId.flatMap { knownGroupIds.contains($0) ? $0 : nil }
            let isSelectedWorkspace = workspace.id == selectedWorkspaceId
            let focusedPanelId = workspace.focusedPanelId
            for panelId in workspace.orderedPanelIds {
                guard let terminal = workspace.panels[panelId] as? TerminalPanel else { continue }
                rowsByGroupId[groupId, default: []].append(row(
                    terminal: terminal,
                    in: workspace,
                    groupId: groupId,
                    isSelectedWorkspace: isSelectedWorkspace,
                    isFocused: isSelectedWorkspace && focusedPanelId == panelId
                ))
            }
        }

        var nextSections = workspaceGroups.compactMap { group -> TerminalOverviewSection? in
            guard let rows = rowsByGroupId[group.id], !rows.isEmpty else { return nil }
            return TerminalOverviewSection(id: group.id, name: group.name, colorHex: group.customColor, rows: rows)
        }
        if let ungroupedRows = rowsByGroupId[UUID?.none], !ungroupedRows.isEmpty {
            nextSections.append(TerminalOverviewSection(id: nil, name: nil, colorHex: nil, rows: ungroupedRows))
        }
        let nextGroups = workspaceGroups.map { WorkspaceGroupMenuSnapshot.Item(id: $0.id, name: $0.name) }
        if sections != nextSections { sections = nextSections }
        if groups != nextGroups { groups = nextGroups }
    }

    private func row(
        terminal: TerminalPanel,
        in workspace: Workspace,
        groupId: UUID?,
        isSelectedWorkspace: Bool,
        isFocused: Bool
    ) -> TerminalOverviewRow {
        let panelId = terminal.id
        let directory = workspace.effectivePanelDirectory(
            panelId: panelId,
            localFallback: terminal.directory.isEmpty ? nil : terminal.directory
        )
        let activity: TerminalOverviewRow.Activity
        switch workspace.panelShellActivityStates[panelId] {
        case .promptIdle: activity = .idle
        case .commandRunning: activity = .running
        case .unknown, nil: activity = .unknown
        }
        let branch = workspace.panelGitBranches[panelId]
        let pullRequest = workspace.panelPullRequests[panelId]
        let prompt = workspace.panelPrompts[panelId]
        let agent: (source: String?, state: String?)? = nil
        return TerminalOverviewRow(
            id: panelId,
            workspaceId: workspace.id,
            title: workspace.panelTitle(panelId: panelId) ?? terminal.displayTitle,
            workspaceTitle: workspace.customTitle ?? workspace.title,
            directory: directory,
            groupId: groupId,
            isSelectedWorkspace: isSelectedWorkspace,
            isFocused: isFocused,
            activity: activity,
            gitBranch: branch?.branch,
            gitIsDirty: branch?.isDirty ?? false,
            pullRequestNumber: pullRequest?.number,
            pullRequestURL: pullRequest?.url,
            ports: (workspace.surfaceListeningPorts[panelId] ?? []).sorted(),
            agentSource: agent?.source,
            agentState: agent?.state,
            lastPrompt: prompt?.message,
            lastPromptAt: prompt?.submittedAt,
            isRemote: workspace.isRemoteWorkspace
        )
    }
}
