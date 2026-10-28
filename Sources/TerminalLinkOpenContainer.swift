import AppKit
import Foundation

/// Host operations needed to give terminal links identical behavior in the
/// workspace grid and the Dock.
@MainActor
protocol TerminalLinkOpenContainer: AnyObject {
    var terminalLinkContainerDebugName: String { get }

    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String?

    func deferRemoteTerminalFileLinkOpen(sourcePanelId: UUID, rawValue: String) -> Bool


    @discardableResult
    func deferTerminalFileLinkOpen(
        sourcePanelId: UUID,
        filePath: String,
        fallback: @escaping @MainActor @Sendable () -> Void
    ) -> Bool

    @discardableResult
    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID, focus: Bool) -> Bool
}

struct CloudTerminalLinkTarget: Sendable, Equatable {
    let url: URL
}

extension TerminalLinkOpenContainer {
    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool { false }
    func cloudTerminalLinkTarget(url: URL, sourcePanelId: UUID) -> CloudTerminalLinkTarget? { nil }
    @discardableResult
    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID, focus: Bool) -> Bool { NSWorkspace.shared.open(url) }
    func deferRemoteTerminalFileLinkOpen(sourcePanelId: UUID, rawValue: String) -> Bool { false }

    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID) -> Bool {
        openTerminalBrowserLink(url: url, sourcePanelId: sourcePanelId, focus: true)
    }
}
