import AppKit
import SwiftUI

enum WorkspaceRecentFolders {
    private static let defaultsKey = "ckmux.recentWorkspaceFolders"
    private static let storedLimit = 12
    static let presetLimit = 6

    static func record(_ path: String, defaults: UserDefaults = .standard) {
        var stored = defaults.stringArray(forKey: defaultsKey) ?? []
        stored.removeAll { $0 == path }
        stored.insert(path, at: 0)
        defaults.set(Array(stored.prefix(storedLimit)), forKey: defaultsKey)
    }

    static func presets(openDirectories: [String], defaults: UserDefaults = .standard) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var seen = Set<String>()
        var result: [String] = []
        for path in (defaults.stringArray(forKey: defaultsKey) ?? []) + openDirectories {
            let standardized = (path as NSString).standardizingPath
            guard !standardized.isEmpty, standardized != home,
                  FileManager.default.fileExists(atPath: standardized),
                  seen.insert(standardized).inserted else { continue }
            result.append(standardized)
            if result.count == presetLimit { break }
        }
        return result
    }
}

struct WorkspaceFolderPresetRow: View {
    let presets: [String]
    let onChoose: (String) -> Void
    @State private var chosenPath: String?

    var body: some View {
        WorkspaceFolderChipFlow(spacing: 6) {
            ForEach(presets, id: \.self) { path in
                chip(title: (path as NSString).lastPathComponent, help: (path as NSString).abbreviatingWithTildeInPath, isChosen: chosenPath == path) {
                    choose(path)
                }
            }
            chip(
                title: String(localized: "workspaceFolderPreset.choose", defaultValue: "Choose…"),
                help: nil,
                isChosen: false,
                action: presentOpenPanel
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(title: String, help: String?, isChosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isChosen ? "checkmark" : "folder")
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .cmuxFont(size: 11.5)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isChosen ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }

    private func choose(_ path: String) {
        chosenPath = path
        WorkspaceRecentFolders.record(path)
        onChoose(path)
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "workspaceFolderPreset.openPanelPrompt", defaultValue: "Use Folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choose(url.path(percentEncoded: false))
    }
}

private struct WorkspaceFolderChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width ?? (frames.map(\.maxX).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(maxWidth: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}
