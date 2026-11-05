import Bonsplit
import Foundation

/// Resolves the provider mark for a local terminal tab from the same agent
/// definitions used by process and hook detection.
struct TerminalTabAgentIconResolver {
    func assetName(forStatusKey statusKey: String) -> String? {
        let normalized = statusKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return CmuxTaskManagerCodingAgentDefinition.builtIns.first { definition in
            definition.id == normalized
                || definition.launchKinds.contains(normalized)
                || definition.directBasenames.contains(normalized)
        }?.assetName
    }
}

extension Workspace {
    /// Returns the current provider mark for one terminal panel, if known.
    func terminalTabAgentIconAsset(forPanelId panelId: UUID) -> String? {
        let resolver = TerminalTabAgentIconResolver()
        let statusKeys = Set(agentPIDKeysByPanelId[panelId, default: []].map(agentStatusKey(forAgentPIDKey:)))
            .union(agentStatusEntriesByPanelId[panelId].map { Array($0.keys) } ?? [])
            .union(agentLifecycleStatesByPanelId[panelId].map { Array($0.keys) } ?? [])
            .sorted()
        if let asset = statusKeys.compactMap(resolver.assetName(forStatusKey:)).first {
            return asset
        }
        // A restored snapshot outlives its agent (completed sessions stay for
        // history), so it only names the tab while that agent is running.
        guard let restored = restoredAgentSnapshotsByPanelId[panelId],
              restoredAgentIsRunning(panelId: panelId) else { return nil }
        return restored.registration?.iconAssetName ?? resolver.assetName(forStatusKey: restored.kind.rawValue)
    }

    private func restoredAgentIsRunning(panelId: UUID) -> Bool {
        switch restoredAgentResumeStatesByPanelId[panelId] {
        case .autoResumeCommandRunning, .observedAgentCommandRunning:
            return true
        case .manualResumeAvailable, .awaitingAutoResumeCommand, .completedAgentExit, nil:
            return false
        }
    }

    func terminalTabStatus(forPanelId panelId: UUID) -> TabStatus? {
        let hasStatusEntry = agentStatusEntriesByPanelId[panelId]?.isEmpty == false
        let lifecycle = AgentHibernationLifecycleState.aggregate(
            statusKeyedStates: agentLifecycleStatesByPanelId[panelId] ?? [:],
            fallback: nil
        )
        switch lifecycle {
        case .running, .backgroundWorkPending:
            return .running
        case .needsInput:
            return .needsInput
        case .idle:
            return .idle
        case .unknown:
            if hasStatusEntry { return .idle }
        }
        return panelShellActivityStates[panelId] == .commandRunning ? .running : nil
    }

    func syncTerminalTabStatus(forPanelId panelId: UUID) {
        guard panels[panelId] is TerminalPanel, let tabID = surfaceIdFromPanelId(panelId) else { return }
        bonsplitController.updateTab(tabID, status: .some(terminalTabStatus(forPanelId: panelId)))
    }

    /// Reconciles a terminal tab's provider mark after agent lifecycle state changes.
    func syncTerminalTabAgentIconAsset(forPanelId panelId: UUID) {
        syncTerminalTabStatus(forPanelId: panelId)
        guard panels[panelId] is TerminalPanel,
              let tabID = surfaceIdFromPanelId(panelId),
              let tab = bonsplitController.tab(tabID) else { return }
        let asset = terminalTabAgentIconAsset(forPanelId: panelId)
#if DEBUG
        dlog("tab.agentIcon panel=\(panelId.uuidString.prefix(5)) pid=\(agentPIDKeysByPanelId[panelId, default: []].sorted()) entries=\(agentStatusEntriesByPanelId[panelId].map { Array($0.keys) } ?? []) lifecycle=\(agentLifecycleStatesByPanelId[panelId].map { Array($0.keys) } ?? []) current=\(tab.iconAsset ?? "nil") asset=\(asset ?? "nil")")
#endif
        guard tab.iconAsset != asset else { return }
        bonsplitController.updateTab(tabID, iconAsset: .some(asset))
    }
}

extension TabStatus {
    static let running = TabStatus(
        text: String(localized: "tab.status.running", defaultValue: "Running"),
        symbolName: "bolt.circle.fill",
        colorHex: "#0A84FF"
    )
    static let needsInput = TabStatus(
        text: String(localized: "tab.status.needsInput", defaultValue: "Needs input"),
        symbolName: "exclamationmark.circle.fill",
        colorHex: "#FF9F0A"
    )
    static let idle = TabStatus(
        text: String(localized: "tab.status.idle", defaultValue: "Idle"),
        symbolName: "checkmark.circle.fill",
        colorHex: "#30D158"
    )
}
