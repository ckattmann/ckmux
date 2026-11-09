import AppKit
import CmuxTerminal
import SwiftUI

enum TerminalSessionLinkExtractor {
    private static let pattern = try! NSRegularExpression(
        pattern: #"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#
    )
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?'\"")

    static func links(in text: String) -> [URL] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return URL(string: trimmed(String(text[matchRange])))
        }.filter { $0.host?.contains(where: { $0.isLetter || $0.isNumber }) == true }
    }

    private static func trimmed(_ candidate: String) -> String {
        var value = candidate
        while let last = value.unicodeScalars.last {
            if trailingPunctuation.contains(last) {
                value.removeLast()
            } else if last == ")", value.filter({ $0 == "(" }).count < value.filter({ $0 == ")" }).count {
                value.removeLast()
            } else if last == "]", value.filter({ $0 == "[" }).count < value.filter({ $0 == "]" }).count {
                value.removeLast()
            } else {
                break
            }
        }
        return value
    }
}

@MainActor
final class TerminalSessionLinkStore: ObservableObject {
    static let shared = TerminalSessionLinkStore()
    static let storedLinkLimit = 40

    @Published private(set) var linksByPanelId: [UUID: [URL]] = [:]

    func links(for panelId: UUID) -> [URL] {
        linksByPanelId[panelId] ?? []
    }

    func ingest(_ text: String, panelId: UUID) {
        let found = TerminalSessionLinkExtractor.links(in: text)
        guard !found.isEmpty else { return }
        var links = linksByPanelId[panelId] ?? []
        for url in found {
            links.removeAll { $0 == url }
            links.insert(url, at: 0)
        }
        links = Array(links.prefix(Self.storedLinkLimit))
        if linksByPanelId[panelId] != links { linksByPanelId[panelId] = links }
    }

    func remove(_ url: URL, panelId: UUID) {
        linksByPanelId[panelId]?.removeAll { $0 == url }
    }
}

struct TerminalSessionLinksBar: View {
    let surface: TerminalSurface
    let panelId: UUID
    let isVisibleInUI: Bool
    let appearance: PanelAppearance
    @ObservedObject private var store = TerminalSessionLinkStore.shared

    private static let pollIntervalSeconds = 1.5

    var body: some View {
        let links = store.links(for: panelId)
        VStack(spacing: 0) {
            if !links.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(links, id: \.self) { url in
                            chip(url)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                }
                .frame(height: 24)
                .background(Color(nsColor: appearance.backgroundColor))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(appearance.dividerColor).frame(height: 1)
                }
            }
        }
        .task(id: isVisibleInUI) {
            guard isVisibleInUI else { return }
            if let history = surface.readText(region: .history) {
                store.ingest(history, panelId: panelId)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
                guard !Task.isCancelled else { return }
                if let viewport = surface.visibleText() {
                    store.ingest(viewport, panelId: panelId)
                }
            }
        }
    }

    private func chip(_ url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.system(size: 9, weight: .semibold))
                Text(Self.label(for: url))
                    .cmuxFont(size: 11)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Color(nsColor: appearance.foregroundColor).opacity(0.85))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .frame(maxWidth: 260)
            .background(Capsule().fill(Color(nsColor: appearance.foregroundColor).opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
        .contextMenu {
            Button(String(localized: "terminalLinks.open", defaultValue: "Open Link")) {
                NSWorkspace.shared.open(url)
            }
            Button(String(localized: "terminalLinks.copy", defaultValue: "Copy Link")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Divider()
            Button(String(localized: "terminalLinks.remove", defaultValue: "Remove")) {
                store.remove(url, panelId: panelId)
            }
        }
    }

    private static func label(for url: URL) -> String {
        let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path == "/" ? "" : url.path
        return host + port + path
    }
}
