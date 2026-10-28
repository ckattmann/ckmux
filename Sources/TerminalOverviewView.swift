import AppKit
import SwiftUI

struct TerminalOverviewView: View {
    @ObservedObject var tabManager: TabManager
    let onOpen: (TerminalOverviewRow) -> Void
    @StateObject private var model = TerminalOverviewModel()
    @State private var filterText = ""

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                header
                if filteredSections.isEmpty {
                    emptyState
                } else {
                    ForEach(filteredSections) { section in
                        sectionView(section)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("TerminalOverview")
        .onAppear { model.attach(tabManager) }
        .onDisappear { model.detach() }
    }

    private var allRows: [TerminalOverviewRow] {
        model.sections.flatMap(\.rows)
    }

    private var filteredSections: [TerminalOverviewSection] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.sections }
        return model.sections.compactMap { section in
            let rows = section.rows.filter { row in
                [row.title, row.workspaceTitle, row.directory, row.gitBranch, section.name]
                    .compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
            return rows.isEmpty ? nil : TerminalOverviewSection(
                id: section.id,
                name: section.name,
                colorHex: section.colorHex,
                rows: rows
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "terminalOverview.title", defaultValue: "Terminals"))
                    .font(.system(size: 24, weight: .bold))
                Spacer()
                TextField(
                    String(localized: "terminalOverview.filter.placeholder", defaultValue: "Filter terminals"),
                    text: $filterText
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
            }
            HStack(spacing: 10) {
                statTile(
                    value: allRows.count,
                    label: String(localized: "terminalOverview.stat.terminals", defaultValue: "Terminals"),
                    symbol: "terminal"
                )
                statTile(
                    value: allRows.filter { $0.activity == .running }.count,
                    label: String(localized: "terminalOverview.stat.running", defaultValue: "Running"),
                    symbol: "play.circle"
                )
                statTile(
                    value: allRows.filter { $0.agentSource != nil }.count,
                    label: String(localized: "terminalOverview.stat.agents", defaultValue: "Agents"),
                    symbol: "sparkles"
                )
                statTile(
                    value: Set(allRows.map(\.workspaceId)).count,
                    label: String(localized: "terminalOverview.stat.workspaces", defaultValue: "Workspaces"),
                    symbol: "rectangle.stack"
                )
            }
        }
    }

    private func statTile(value: Int, label: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(value, format: .number)
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minWidth: 120, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(allRows.isEmpty
                ? String(localized: "terminalOverview.empty", defaultValue: "No open terminals")
                : String(localized: "terminalOverview.noMatches", defaultValue: "No terminals match the filter"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func sectionView(_ section: TerminalOverviewSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(section.colorHex.flatMap { Color(hex: $0) } ?? Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(section.name ?? String(localized: "terminalOverview.ungrouped", defaultValue: "No Group"))
                    .font(.system(size: 13, weight: .semibold))
                Text(section.rows.count, format: .number)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(section.rows) { row in
                    TerminalOverviewCard(
                        row: row,
                        groups: model.groups,
                        canMove: { groupId in canMove(row, to: groupId) },
                        onOpen: { onOpen(row) },
                        onMove: { groupId in move(row, to: groupId) }
                    )
                }
            }
        }
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

private struct TerminalOverviewCard: View {
    let row: TerminalOverviewRow
    let groups: [WorkspaceGroupMenuSnapshot.Item]
    let canMove: (UUID?) -> Bool
    let onOpen: () -> Void
    let onMove: (UUID?) -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleLine
            detailLine(symbol: row.isRemote ? "network" : "rectangle.portrait.on.rectangle.portrait", text: row.workspaceTitle)
            if let directory = row.directory, !directory.isEmpty {
                detailLine(symbol: "folder", text: (directory as NSString).abbreviatingWithTildeInPath, monospaced: true)
            }
            if row.gitBranch != nil || row.pullRequestNumber != nil || !row.ports.isEmpty {
                chips
            }
            if let agentSource = row.agentSource {
                detailLine(
                    symbol: "sparkles",
                    text: [Self.agentName(agentSource), row.agentState].compactMap { $0 }.joined(separator: " · ")
                )
            }
            if let prompt = row.lastPrompt, !prompt.isEmpty {
                lastPromptView(prompt)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.07 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(row.isFocused ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .contextMenu {
            Button(String(localized: "terminalOverview.open", defaultValue: "Open"), action: onOpen)
            Menu(String(localized: "terminalOverview.moveToGroup", defaultValue: "Move to Group")) {
                moveMenuItems
            }
        }
    }

    private var titleLine: some View {
        HStack(spacing: 8) {
            activityIndicator
            Text(row.title)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if row.isFocused {
                Text(String(localized: "terminalOverview.focused", defaultValue: "Focused"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }
        }
    }

    @ViewBuilder
    private var activityIndicator: some View {
        switch row.activity {
        case .running:
            Circle().fill(Color.green).frame(width: 8, height: 8)
                .help(String(localized: "terminalOverview.activity.running", defaultValue: "Command running"))
        case .idle:
            Circle().fill(Color.secondary.opacity(0.6)).frame(width: 8, height: 8)
                .help(String(localized: "terminalOverview.activity.idle", defaultValue: "Idle at prompt"))
        case .unknown:
            Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1).frame(width: 8, height: 8)
        }
    }

    private func detailLine(symbol: String, text: String, monospaced: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(text)
                .font(monospaced ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            if let branch = row.gitBranch {
                chip(symbol: "arrow.triangle.branch", text: branch, tint: row.gitIsDirty ? .orange : nil)
                    .help(row.gitIsDirty
                        ? String(localized: "terminalOverview.git.dirty", defaultValue: "Uncommitted changes")
                        : branch)
            }
            if let number = row.pullRequestNumber {
                if let url = row.pullRequestURL {
                    Link(destination: url) { chip(symbol: "arrow.triangle.pull", text: "#\(number)", tint: .accentColor) }
                        .buttonStyle(.plain)
                } else {
                    chip(symbol: "arrow.triangle.pull", text: "#\(number)", tint: nil)
                }
            }
            ForEach(row.ports.prefix(4), id: \.self) { port in
                chip(symbol: "network", text: ":\(port)", tint: nil)
            }
        }
    }

    private func chip(symbol: String, text: String, tint: Color?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9.5))
            Text(text).font(.system(size: 11, design: .monospaced)).lineLimit(1)
        }
        .foregroundStyle(tint ?? Color.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill((tint ?? Color.primary).opacity(0.1)))
    }

    private func lastPromptView(_ prompt: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(prompt)
                    .font(.system(size: 12))
                    .lineLimit(2)
                if let submittedAt = row.lastPromptAt {
                    Text(submittedAt, style: .relative)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                Label(String(localized: "terminalOverview.open", defaultValue: "Open"), systemImage: "arrow.up.forward.square")
            }
            .controlSize(.small)
            Menu {
                moveMenuItems
            } label: {
                Label(String(localized: "terminalOverview.moveToGroup", defaultValue: "Move to Group"), systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            Spacer()
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

    private static func agentName(_ source: String) -> String {
        source.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
