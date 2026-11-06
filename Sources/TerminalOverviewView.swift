import AppKit
import SwiftUI

enum TerminalOverviewArrangement: String, CaseIterable, Identifiable {
    case byWorkspace
    case newestFirst

    var id: String { rawValue }

    var label: String {
        switch self {
        case .byWorkspace:
            String(localized: "terminalOverview.arrangement.byWorkspace", defaultValue: "By Workspace")
        case .newestFirst:
            String(localized: "terminalOverview.arrangement.newestFirst", defaultValue: "Newest First")
        }
    }
}

struct TerminalOverviewView: View {
    @ObservedObject var tabManager: TabManager
    let onOpen: (TerminalOverviewRow) -> Void
    @StateObject private var model = TerminalOverviewModel()
    @State private var filterText = ""
    @AppStorage("terminalOverview.arrangement") private var arrangement: TerminalOverviewArrangement = .byWorkspace

    private static let contentMaxWidthPt: CGFloat = 960

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    content
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .frame(maxWidth: Self.contentMaxWidthPt)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("TerminalOverview")
        .onAppear { model.attach(tabManager) }
        .onDisappear { model.detach() }
    }

    @ViewBuilder
    private var content: some View {
        switch arrangement {
        case .byWorkspace:
            let sections = filteredSections
            if sections.isEmpty {
                emptyState
            } else {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            rowView(row, showsWorkspace: false)
                        }
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
        case .newestFirst:
            let rows = model.newestFirstRows.filter(matchesFilter)
            if rows.isEmpty {
                emptyState
            } else {
                ForEach(rows) { row in
                    rowView(row, showsWorkspace: true)
                }
                .padding(.top, 8)
            }
        }
    }

    private var totalCount: Int {
        model.sections.reduce(0) { $0 + $1.rows.count }
    }

    private var filteredSections: [TerminalOverviewWorkspaceSection] {
        model.sections.compactMap { section in
            let rows = section.rows.filter(matchesFilter)
            return rows.isEmpty ? nil : TerminalOverviewWorkspaceSection(
                id: section.id,
                title: section.title,
                isSelected: section.isSelected,
                rows: rows
            )
        }
    }

    private func matchesFilter(_ row: TerminalOverviewRow) -> Bool {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [row.title, row.workspaceTitle, row.directory, row.agentStatus?.text]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(String(localized: "terminalOverview.title", defaultValue: "Terminals"))
                .font(.system(size: 17, weight: .bold))
            Text(totalCount, format: .number)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Picker(selection: $arrangement) {
                ForEach(TerminalOverviewArrangement.allCases) { option in
                    Text(option.label).tag(option)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            TextField(
                String(localized: "terminalOverview.filter.placeholder", defaultValue: "Filter terminals"),
                text: $filterText
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: Self.contentMaxWidthPt)
        .frame(maxWidth: .infinity)
    }

    private func sectionHeader(_ section: TerminalOverviewWorkspaceSection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(section.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(section.rows.count, format: .number)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func rowView(_ row: TerminalOverviewRow, showsWorkspace: Bool) -> some View {
        TerminalOverviewListRow(
            row: row,
            showsWorkspace: showsWorkspace,
            groups: model.groups,
            canMove: { groupId in canMove(row, to: groupId) },
            onOpen: { onOpen(row) },
            onMove: { groupId in move(row, to: groupId) }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(totalCount == 0
                ? String(localized: "terminalOverview.empty", defaultValue: "No open terminals")
                : String(localized: "terminalOverview.noMatches", defaultValue: "No terminals match the filter"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func canMove(_ row: TerminalOverviewRow, to groupId: UUID?) -> Bool {
        AppDelegate.shared?.canMoveTerminal(panelId: row.id, toWorkspaceGroup: groupId, in: tabManager) ?? false
    }

    private func move(_ row: TerminalOverviewRow, to groupId: UUID?) {
        guard AppDelegate.shared?.moveTerminal(panelId: row.id, toWorkspaceGroup: groupId, in: tabManager) == true else {
            NSSound.beep()
            return
        }
    }
}

private struct TerminalOverviewListRow: View {
    let row: TerminalOverviewRow
    let showsWorkspace: Bool
    let groups: [WorkspaceGroupMenuSnapshot.Item]
    let canMove: (UUID?) -> Bool
    let onOpen: () -> Void
    let onMove: (UUID?) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            activityIndicator
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 12)
            stateLabel
            Text(row.createdAt, style: .relative)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(row.isFocused ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button(String(localized: "terminalOverview.open", defaultValue: "Open"), action: onOpen)
            Menu(String(localized: "terminalOverview.moveToGroup", defaultValue: "Move to Group")) {
                moveMenuItems
            }
        }
    }

    private var subtitle: String? {
        let directory = row.directory.flatMap { $0.isEmpty ? nil : ($0 as NSString).abbreviatingWithTildeInPath }
        let parts = [showsWorkspace ? row.workspaceTitle : nil, directory].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var activityIndicator: some View {
        if let status = row.status, let symbolName = status.symbolName {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(status.colorHex.flatMap { Color(hex: $0) } ?? Color.secondary)
                .help(status.text)
        } else {
            Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1).frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        if let agent = row.agentStatus {
            let tint = agent.colorHex.flatMap { Color(hex: $0) } ?? Color.secondary
            HStack(spacing: 4) {
                if let icon = agent.icon {
                    Image(systemName: icon).font(.system(size: 10))
                }
                Text(agent.text).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
        } else {
            Text(activityText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var activityText: String {
        switch row.activity {
        case .running: String(localized: "terminalOverview.activity.running", defaultValue: "Running")
        case .idle: String(localized: "terminalOverview.activity.idle", defaultValue: "Idle")
        case .unknown: ""
        }
    }

    @ViewBuilder
    private var moveMenuItems: some View {
        ForEach(groups) { group in
            Button {
                onMove(group.id)
            } label: {
                if row.groupId == group.id {
                    Label(group.name, systemImage: "checkmark")
                } else {
                    Text(group.name)
                }
            }
            .disabled(row.groupId == group.id || !canMove(group.id))
        }
        if !groups.isEmpty {
            Divider()
        }
        Button(String(localized: "terminalOverview.removeFromGroup", defaultValue: "Remove from Group")) {
            onMove(nil)
        }
        .disabled(row.groupId == nil || !canMove(nil))
    }
}
