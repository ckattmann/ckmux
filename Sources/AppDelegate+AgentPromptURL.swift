import AppKit
import Foundation

/// `ckmux://prompt?text=…&cwd=…&agent=claude|codex&name=…&token=…`
struct AgentPromptLaunchRequest: Equatable {
    enum Agent: String {
        case claude
        case codex
    }

    static let tokenFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ckmux/prompt-url-token", isDirectory: false)

    let agent: Agent
    let prompt: String
    let workingDirectory: String?
    let title: String?
    let token: String?

    init?(url: URL) {
        guard !url.isFileURL,
              url.host?.lowercased() == "prompt",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            guard let raw = items.first(where: { $0.name == name })?.value,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return raw
        }
        guard let prompt = value("text") ?? value("prompt"),
              let agent = Agent(rawValue: (value("agent") ?? Agent.claude.rawValue).lowercased()) else { return nil }
        self.agent = agent
        self.prompt = prompt
        self.workingDirectory = value("cwd").map { ($0 as NSString).expandingTildeInPath }
        self.title = value("name")
        self.token = value("token")
    }

    var terminalInput: String {
        "\(agent.rawValue) '\(prompt.replacingOccurrences(of: "'", with: "'\\''"))'\r"
    }

    var resolvedTitle: String {
        if let title { return title }
        let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        return firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine
    }

    var hasValidToken: Bool {
        guard let token,
              let expected = try? String(contentsOf: Self.tokenFileURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty else { return false }
        return token == expected
    }
}

extension AppDelegate {
    func handleAgentPromptLaunchRequest(_ request: AgentPromptLaunchRequest) {
        var directory: ObjCBool = false
        let workingDirectory = request.workingDirectory.flatMap { path in
            FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue ? path : nil
        }
        guard request.hasValidToken || confirmAgentPromptLaunch(request, workingDirectory: workingDirectory) else { return }
        if addWorkspaceInPreferredMainWindow(
            title: request.resolvedTitle,
            titleSource: .auto,
            workingDirectory: workingDirectory,
            initialTerminalInput: request.terminalInput,
            shouldBringToFront: true,
            debugSource: "agentPromptURL"
        ) != nil {
            return
        }
        _ = createMainWindow(
            initialWorkspaceTitle: request.resolvedTitle,
            initialWorkingDirectory: workingDirectory,
            initialTerminalInput: request.terminalInput
        )
    }

    private func confirmAgentPromptLaunch(
        _ request: AgentPromptLaunchRequest,
        workingDirectory: String?
    ) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(
            format: String(localized: "agentPromptURL.confirm.title", defaultValue: "Start %@ with this prompt?"),
            request.agent.rawValue
        )
        let directoryText = workingDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath }
            ?? String(localized: "agentPromptURL.confirm.defaultDirectory", defaultValue: "default directory")
        alert.informativeText = "\(directoryText)\n\n\(request.prompt)"
        alert.addButton(withTitle: String(localized: "agentPromptURL.confirm.run", defaultValue: "Run"))
        alert.addButton(withTitle: String(localized: "agentPromptURL.confirm.cancel", defaultValue: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
