import CmuxTerminal
import Foundation

extension WorkspaceTerminalFontSizePanelDiscovery {
    struct Candidate {
        let panelId: UUID
        let origin: Origin

        @MainActor
        func mountedTerminalPanel(
            in workspace: Workspace?,
            windowDock: DockSplitStore?
        ) -> TerminalPanel? {
            switch origin {
            case .workspace:
                return workspace?.panels[panelId] as? TerminalPanel
            case .workspaceDock:
                return workspace?._dockSplit?.panels[panelId]
                    as? TerminalPanel
            case .windowDock:
                return windowDock?.panels[panelId] as? TerminalPanel
            case .remoteMirror:
                return nil
            }
        }
    }
}
