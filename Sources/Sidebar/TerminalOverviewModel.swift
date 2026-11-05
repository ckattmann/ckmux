import Bonsplit
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

    struct AgentStatus: Equatable {
        let text: String
        let icon: String?
        let colorHex: String?
    }

    let id: UUID
    let workspaceId: UUID
    let title: String
    let workspaceTitle: String
    let directory: String?
    let groupId: UUID?
    let isFocused: Bool
    let activity: Activity
    let agentStatus: AgentStatus?
    let status: TabStatus?
    let createdAt: Date
}

struct TerminalOverviewWorkspaceSection: Identifiable, Equatable {
    let id: UUID
    let title: String
    let isSelected: Bool
    let rows: [TerminalOverviewRow]
}

@MainActor
final class TerminalOverviewModel: ObservableObject {
    @Published private(set) var sections: [TerminalOverviewWorkspaceSection] = []
    @Published private(set) var groups: [WorkspaceGroupMenuSnapshot.Item] = []

    private weak var tabManager: TabManager?
    private var managerCancellables: Set<AnyCancellable> = []
    private var workspaceCancellables: [AnyCancellable] = []
    private var refreshTimer: Timer?
    private var isRebuildScheduled = false

    var newestFirstRows: [TerminalOverviewRow] {
        sections.flatMap(\.rows).sorted { $0.createdAt > $1.createdAt }
    }

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

        let nextSections = tabManager.tabs.compactMap { workspace -> TerminalOverviewWorkspaceSection? in
            let groupId = groupIdByAnchor[workspace.id]
                ?? workspace.groupId.flatMap { knownGroupIds.contains($0) ? $0 : nil }
            let isSelectedWorkspace = workspace.id == selectedWorkspaceId
            let focusedPanelId = workspace.focusedPanelId
            let workspaceTitle = tabManager.resolvedWorkspaceWindowTitle(for: workspace)
            let rows = workspace.orderedPanelIds.compactMap { panelId -> TerminalOverviewRow? in
                guard let terminal = workspace.panels[panelId] as? TerminalPanel else { return nil }
                return row(
                    terminal: terminal,
                    in: workspace,
                    workspaceTitle: workspaceTitle,
                    groupId: groupId,
                    isFocused: isSelectedWorkspace && focusedPanelId == panelId
                )
            }
            guard !rows.isEmpty else { return nil }
            return TerminalOverviewWorkspaceSection(
                id: workspace.id,
                title: workspaceTitle,
                isSelected: isSelectedWorkspace,
                rows: rows
            )
        }
        let nextGroups = workspaceGroups.map { WorkspaceGroupMenuSnapshot.Item(id: $0.id, name: $0.name) }
        if sections != nextSections { sections = nextSections }
        if groups != nextGroups { groups = nextGroups }
    }

    private func row(
        terminal: TerminalPanel,
        in workspace: Workspace,
        workspaceTitle: String,
        groupId: UUID?,
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
        let agentStatus = workspace.agentStatusEntriesByPanelId[panelId]?.values
            .max { $0.priority < $1.priority }
            .map { TerminalOverviewRow.AgentStatus(text: $0.value, icon: $0.icon, colorHex: $0.color) }
        return TerminalOverviewRow(
            id: panelId,
            workspaceId: workspace.id,
            title: workspace.panelTitle(panelId: panelId) ?? terminal.displayTitle,
            workspaceTitle: workspaceTitle,
            directory: directory,
            groupId: groupId,
            isFocused: isFocused,
            activity: activity,
            agentStatus: agentStatus,
            status: workspace.terminalTabStatus(forPanelId: panelId),
            createdAt: terminal.createdAt
        )
    }
}
