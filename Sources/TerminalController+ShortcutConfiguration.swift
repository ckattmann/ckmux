import AppKit

#if DEBUG
extension TerminalController {
    func setShortcut(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "ERROR: Usage: set_shortcut <name> <combo|clear>"
        }

        let name = parts[0].lowercased()
        let combo = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

        let action: KeyboardShortcutSettings.Action?
        switch name {
        case "focus_left", "focusleft":
            action = .focusLeft
        case "focus_right", "focusright":
            action = .focusRight
        case "focus_up", "focusup":
            action = .focusUp
        case "focus_down", "focusdown":
            action = .focusDown
        case "split_right", "splitright":
            action = .splitRight
        case "split_down", "splitdown":
            action = .splitDown
        case "resize_pane_left", "resizepaneleft", "resize-pane-left":
            action = .resizePaneLeft
        case "resize_pane_right", "resizepaneright", "resize-pane-right":
            action = .resizePaneRight
        case "resize_pane_up", "resizepaneup", "resize-pane-up":
            action = .resizePaneUp
        case "resize_pane_down", "resizepanedown", "resize-pane-down":
            action = .resizePaneDown
        case "workspace_digits", "workspace_number", "select_workspace_by_number":
            action = .selectWorkspaceByNumber
        case "surface_digits", "surface_number", "select_surface_by_number":
            action = .selectSurfaceByNumber
        case "focus_sidebar", "focussidebar":
            action = .focusSidebar
        case "pane_digits", "pane_number", "focus_pane_by_number":
            action = .focusPaneByNumber
        default:
            action = nil
        }

        guard let action else {
            return "ERROR: Unknown shortcut name. Supported: focus_left, focus_right, focus_up, focus_down, split_right, split_down, resize_pane_left, resize_pane_right, resize_pane_up, resize_pane_down, workspace_digits, surface_digits, focus_sidebar, pane_digits"
        }

        if combo.lowercased() == "clear" || combo.lowercased() == "unbound" || combo.lowercased() == "none" {
            KeyboardShortcutSettings.clearShortcut(for: action)
            return "OK"
        }

        if combo.lowercased() == "default" || combo.lowercased() == "reset" {
            KeyboardShortcutSettings.resetShortcut(for: action)
            return "OK"
        }

        return "ERROR: shortcut simulation is unavailable in this build"
    }

}
#endif
