import CmuxSurfaceCatalogModel
import AppKit
import Bonsplit
import CmuxCommandPalette
import CmuxPanes
import CmuxSettings
import CmuxTerminal
import CmuxWorkspaces
import Foundation

enum DockShortcutCommand {
    case selectNextSurface
    case selectPreviousSurface
    case selectSurface(number: Int)
    case moveSurface(offset: Int)
    case moveSurfaceToPane(
        SurfacePaneMovement,
        allowMissingDestinationSplit: Bool
    )
    case focusPane(NavigationDirection)
    case cyclePaneFocus(forward: Bool)
    case togglePaneZoom
    case resizePane(ResizeDirection)
    case equalizeSplits
    case focusHistoryBack
    case focusHistoryForward
    case focusHistoryLast
    case triggerFlash
    case renameSurface(presentingWindow: NSWindow?)
    case closeOtherTabsInPane
    case toggleTerminalCopyMode
    case focusTextBoxInput
    case attachTextBoxFile
    case sendCtrlFToTerminal
    case pasteLastScreenshot
    case clearScreenKeepScrollback
    case startFind
    case findNext
    case findPrevious
    case hideFind
    case useSelectionForFind
    case toggleReactGrab
    case reopenClosedPanel

    var isFocusHistoryNavigation: Bool {
        switch self {
        case .focusHistoryBack, .focusHistoryForward, .focusHistoryLast:
            true
        default:
            false
        }
    }
}

extension DockSplitStore {
    /// Executes surface and focus commands against the Dock's own Bonsplit tree.
    /// AppDelegate resolves configured key bindings and sends only the semantic
    /// command here, keeping every Dock entrypoint on the same ownership path.
    @discardableResult
    func performShortcutCommand(_ command: DockShortcutCommand) -> Bool {
        guard !isRetired else { return false }
        switch command {
        case .selectNextSurface:
            bonsplitController.selectNextTab()
            applyFocusedShortcutSelection()
            return true
        case .selectPreviousSurface:
            bonsplitController.selectPreviousTab()
            applyFocusedShortcutSelection()
            return true
        case .selectSurface(let number):
            return selectDockSurface(number: number)
        case .moveSurface(let offset):
            return moveSelectedDockSurface(by: offset)
        case let .moveSurfaceToPane(
            movement,
            allowMissingDestinationSplit
        ):
            return moveFocusedDockSurface(
                to: movement,
                allowMissingDestinationSplit:
                    allowMissingDestinationSplit
            )
        case .focusPane(let direction):
            bonsplitController.navigateFocus(direction: direction)
            applyFocusedShortcutSelection()
            return true
        case .cyclePaneFocus(let forward):
            return cycleDockPaneFocus(forward: forward)
        case .togglePaneZoom:
            guard let pane = bonsplitController.focusedPaneId else { return false }
            return toggleDockPaneZoom(inPane: pane)
        case .resizePane(let direction):
            return resizeFocusedPane(direction: direction)
        case .equalizeSplits:
            return equalizeDockSplits()
        case .focusHistoryBack:
            return focusHistoryNavigation.navigateBack()
        case .focusHistoryForward:
            return focusHistoryNavigation.navigateForward()
        case .focusHistoryLast:
            return focusHistoryNavigation.navigateToLastFocused()
        case .triggerFlash:
            guard let focusedPanelId else { return false }
            triggerUserInitiatedFocusFlash(panelId: focusedPanelId)
            return true
        case .renameSurface(let presentingWindow):
            return requestPaletteRenameFocusedDockSurface(
                presentingWindow: presentingWindow
            )
        case .closeOtherTabsInPane:
            return closeOtherDockTabsInFocusedPane()
        case .toggleTerminalCopyMode:
            guard let terminal = focusedDockTerminalPanel else {
                return false
            }
            return terminal.surface.toggleKeyboardCopyMode()
        case .focusTextBoxInput:
            return focusedDockTerminalPanel?
                .focusTextBoxInputOrTerminal() ?? false
        case .attachTextBoxFile:
            return focusedDockTerminalPanel?
                .attachFileToTextBoxInput() ?? false
        case .sendCtrlFToTerminal:
            guard let terminal = focusedDockTerminalPanel else {
                return false
            }
            let result = terminal.sendNamedKeyResult("ctrl-f")
            if result == .sent {
                terminal.surface.forceRefresh(
                    reason: "dock.sendCtrlFToFocusedTerminal"
                )
            }
            return result.accepted
        case .pasteLastScreenshot:
            guard let terminal = focusedDockTerminalPanel else {
                return false
            }
            terminal.pasteLastScreenshot()
            return true
        case .clearScreenKeepScrollback:
            guard let terminal = focusedDockTerminalPanel else {
                return false
            }
            let didClear = terminal.clearScreenKeepingScrollback()
            if didClear {
                terminal.surface.forceRefresh(
                    reason: "dock.clearFocusedTerminalKeepingScrollback"
                )
            }
            return didClear
        case .startFind:
            return startDockFind()
        case .findNext:
            return performDockFindNavigation(.next)
        case .findPrevious:
            return performDockFindNavigation(.previous)
        case .hideFind:
            return hideDockFind()
        case .useSelectionForFind:
            return useDockSelectionForFind()
        case .toggleReactGrab:
            return false
        case .reopenClosedPanel:
            return reopenMostRecentlyClosedPanel()
        }
    }

    private func applyFocusedShortcutSelection() {
        guard let pane = bonsplitController.focusedPaneId,
              let tab = bonsplitController.selectedTab(inPane: pane),
              let panelId = surfaceIdToPanelId[tab.id] else { return }
        focusPanelFromDockInteraction(panelId, window: nil)
    }

    private func selectDockSurface(number: Int) -> Bool {
        guard let pane = bonsplitController.focusedPaneId else { return false }
        let tabs = bonsplitController.tabs(inPane: pane)
        let tab: Bonsplit.Tab?
        if number == 9 {
            tab = tabs.last
        } else if tabs.indices.contains(number - 1) {
            tab = tabs[number - 1]
        } else {
            tab = nil
        }
        guard let tab else { return true }
        noteKeyboardFocusIntent(window: NSApp.keyWindow ?? NSApp.mainWindow)
        bonsplitController.selectTab(tab.id)
        applyFocusedShortcutSelection()
        return true
    }

    private func moveSelectedDockSurface(by offset: Int) -> Bool {
        guard let pane = bonsplitController.focusedPaneId,
              let selectedTab = bonsplitController.selectedTab(inPane: pane) else { return false }
        let tabs = bonsplitController.tabs(inPane: pane)
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTab.id }), !tabs.isEmpty else {
            return false
        }
        let finalIndex = min(max(currentIndex + offset, tabs.startIndex), tabs.index(before: tabs.endIndex))
        guard finalIndex != currentIndex else { return true }
        let insertionIndex = finalIndex > currentIndex ? finalIndex + 1 : finalIndex
        return bonsplitController.reorderTab(selectedTab.id, toIndex: insertionIndex)
    }

    private var focusedDockTerminalPanel: TerminalPanel? {
        guard let focusedPanelId else { return nil }
        return panels[focusedPanelId] as? TerminalPanel
    }

    private func requestPaletteRenameFocusedDockSurface(
        presentingWindow: NSWindow?
    ) -> Bool {
        guard let panelId = focusedPanelId,
              let tabId = surfaceId(forPanelId: panelId) else {
            return false
        }
        return requestPaletteRenameDockSurface(
            tabId: tabId,
            presentingWindow: presentingWindow
        )
    }

    /// Dock tabs have no inline title editor, so rename opens the palette
    /// editor for this tab. The target carries the Dock owner id, which the
    /// palette resolves back to this store.
    func requestPaletteRenameDockSurface(
        tabId: TabID,
        presentingWindow: NSWindow?
    ) -> Bool {
        guard let panel = panel(for: tabId),
              let tab = bonsplitController.tab(tabId),
              let app = AppDelegate.shared else {
            return false
        }
        app.requestCommandPaletteRename(
            CommandPaletteRenameTarget(
                kind: .tab(workspaceId: workspaceId, panelId: panel.id),
                currentName: tab.title
            ),
            preferredWindow: presentingWindow,
            source: "dock.renameTab"
        )
        return true
    }

    @discardableResult
    func setDockPanelCustomTitle(
        panelId: UUID,
        title: String?
    ) -> Bool {
        guard let tabId = surfaceId(forPanelId: panelId),
              let panel = panels[panelId] else {
            return false
        }
        let customTitle = title?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        bonsplitController.updateTab(
            tabId,
            title: customTitle.isEmpty
                ? panel.displayTitle
                : customTitle,
            hasCustomTitle: !customTitle.isEmpty
        )
        return true
    }

    private func cycleDockPaneFocus(forward: Bool) -> Bool {
        let orderedPaneIds = bonsplitController.treeSnapshot()
            .orderedPaneIds
            .compactMap(UUID.init(uuidString:))
        guard let targetPaneId = PaneCycleNavigator().targetPane(
            orderedPaneIds: orderedPaneIds,
            livePaneIds: bonsplitController.allPaneIds,
            focusedPaneId: bonsplitController.focusedPaneId,
            forward: forward
        ) else {
            return false
        }
        focusPaneFromDockInteraction(
            targetPaneId,
            window: NSApp.keyWindow ?? NSApp.mainWindow
        )
        applyFocusedShortcutSelection()
        return true
    }

    private func moveFocusedDockSurface(
        to movement: SurfacePaneMovement,
        allowMissingDestinationSplit: Bool
    ) -> Bool {
        guard let panelId = focusedPanelId,
              let tabId = surfaceId(forPanelId: panelId),
              let sourcePaneId = paneId(forPanelId: panelId) else {
            return false
        }

        let destinationPaneId = dockDestinationPane(
            from: sourcePaneId,
            for: movement
        )
        let directionalSplit = allowMissingDestinationSplit
            ? dockDirectionalSplit(for: movement)
            : nil
        guard destinationPaneId != nil || directionalSplit != nil else {
            return false
        }

        let zoomedPaneId = bonsplitController.zoomedPaneId
        if let zoomedPaneId {
            _ = toggleDockPaneZoom(inPane: zoomedPaneId)
        }

        noteKeyboardFocusIntent(window: NSApp.keyWindow ?? NSApp.mainWindow)
        let didMove: Bool
        if let destinationPaneId {
            let destinationTabs =
                bonsplitController.tabs(inPane: destinationPaneId)
            let insertionIndex: Int
            if let selectedTabId = bonsplitController
                .selectedTab(inPane: destinationPaneId)?.id,
               let selectedIndex = destinationTabs.firstIndex(
                   where: { $0.id == selectedTabId }
               ) {
                insertionIndex = selectedIndex + 1
            } else {
                insertionIndex = destinationTabs.count
            }
            didMove = bonsplitController.moveTab(
                tabId,
                toPane: destinationPaneId,
                atIndex: insertionIndex
            )
            if didMove {
                focusPaneFromDockInteraction(
                    destinationPaneId,
                    window: NSApp.keyWindow ?? NSApp.mainWindow
                )
                bonsplitController.selectTab(tabId)
                applyFocusedShortcutSelection()
            }
        } else if let directionalSplit,
                  let newPaneId = bonsplitController.splitPane(
                      sourcePaneId,
                      orientation: directionalSplit.orientation,
                      movingTab: tabId,
                      insertFirst: directionalSplit.insertFirst
                  ) {
            focusPaneFromDockInteraction(
                newPaneId,
                window: NSApp.keyWindow ?? NSApp.mainWindow
            )
            bonsplitController.selectTab(tabId)
            applyFocusedShortcutSelection()
            didMove = true
        } else {
            didMove = false
        }

        if !didMove, let zoomedPaneId {
            _ = toggleDockPaneZoom(inPane: zoomedPaneId)
        }
        return didMove
    }

    private func dockDestinationPane(
        from sourcePaneId: PaneID,
        for movement: SurfacePaneMovement
    ) -> PaneID? {
        if let direction =
            dockDirectionalSplit(for: movement)?.direction {
            return bonsplitController.adjacentPane(
                to: sourcePaneId,
                direction: direction
            )
        }

        let orderedPaneIds = bonsplitController.treeSnapshot()
            .orderedPaneIds
            .compactMap(UUID.init(uuidString:))
        guard orderedPaneIds.count > 1,
              let sourceIndex = orderedPaneIds.firstIndex(
                  of: sourcePaneId.id
              ) else {
            return nil
        }
        let offset = movement == .previous ? -1 : 1
        let destinationIndex =
            (sourceIndex + offset + orderedPaneIds.count)
            % orderedPaneIds.count
        let destinationId = orderedPaneIds[destinationIndex]
        return bonsplitController.allPaneIds.first {
            $0.id == destinationId
        }
    }

    private func dockDirectionalSplit(
        for movement: SurfacePaneMovement
    ) -> (
        direction: NavigationDirection,
        orientation: SplitOrientation,
        insertFirst: Bool
    )? {
        switch movement {
        case .left:
            (.left, .horizontal, true)
        case .right:
            (.right, .horizontal, false)
        case .up:
            (.up, .vertical, true)
        case .down:
            (.down, .vertical, false)
        case .previous, .next:
            nil
        }
    }

    private func closeOtherDockTabsInFocusedPane() -> Bool {
        guard let paneId =
                bonsplitController.focusedPaneId
                ?? bonsplitController.allPaneIds.first else {
            return true
        }
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let selectedTabId =
                bonsplitController.selectedTab(inPane: paneId)?.id
                ?? tabs.first?.id else {
            return true
        }
        return closeDockTabs(
            tabs.lazy.filter { $0.id != selectedTabId }.map(\.id),
            inPane: paneId,
            confirmationPolicy: .allTabs
        )
    }

    private func startDockFind() -> Bool {
        if let terminal = focusedDockTerminalPanel {
            let hadExistingSearch = terminal.searchState != nil
            terminal.hostedView.preparePanelFocusIntentForActivation(
                .findField
            )
            let recoveredNeedle = hadExistingSearch
                ? ""
                : terminal.surface.lastSearchNeedle
            return startOrFocusTerminalSearch(
                terminal.surface,
                initialNeedle: recoveredNeedle
            ) { surface in
                NotificationCenter.default.post(
                    name: .ghosttySearchFocus,
                    object: surface,
                    userInfo: [
                        FindFocusNotificationKey.selectAll:
                            !hadExistingSearch
                            && !recoveredNeedle.isEmpty
                    ]
                )
            }
        }
        return false
    }

    private func performDockFindNavigation(
        _ navigation: TerminalSearchNavigation
    ) -> Bool {
        if let terminal = focusedDockTerminalPanel {
            return navigation.perform {
                terminal.performBindingAction($0)
            }
        }
        return false
    }

    private func hideDockFind() -> Bool {
        if let terminal = focusedDockTerminalPanel {
            terminal.surface.closeSearchFromExplicitInput()
            return true
        }
        return false
    }

    private func useDockSelectionForFind() -> Bool {
        guard let terminal = focusedDockTerminalPanel else {
            return false
        }
        if terminal.searchState == nil {
            terminal.searchState = TerminalSurface.SearchState()
        }
        NotificationCenter.default.post(
            name: .ghosttySearchFocus,
            object: terminal.surface
        )
        _ = terminal.performBindingAction("search_selection")
        return true
    }


    /// Cancels pending Dock React Grab work when a newer command supersedes it
    /// or its owning browser is torn down.
    func cancelDockReactGrabTask(
        targetingPanelId panelId: UUID? = nil
    ) {
        if let panelId, reactGrabTaskPanelId != panelId {
            return
        }
        reactGrabTask?.cancel()
        reactGrabTask = nil
        reactGrabTaskID = nil
        reactGrabTaskPanelId = nil
    }
}

extension DockSplitStore: FocusHistoryHosting {
    var selectedWorkspaceId: UUID? { panels.isEmpty ? nil : workspaceId }

    func workspaceExists(_ workspaceId: UUID) -> Bool {
        self.workspaceId == workspaceId && !panels.isEmpty
    }

    func panelExists(workspaceId: UUID, panelId: UUID) -> Bool {
        self.workspaceId == workspaceId && panels[panelId] != nil
    }

    func workspaceTitle(_ workspaceId: UUID) -> String? {
        self.workspaceId == workspaceId ? sourceLabel : nil
    }

    func panelTitle(workspaceId: UUID, panelId: UUID) -> String? {
        guard self.workspaceId == workspaceId else { return nil }
        return panels[panelId]?.displayTitle
    }

    func rememberedFocusedPanelId(_ workspaceId: UUID) -> UUID? {
        self.workspaceId == workspaceId ? focusedPanelId : nil
    }

    func workspaceFocusedPanelId(_ workspaceId: UUID) -> UUID? {
        rememberedFocusedPanelId(workspaceId)
    }

    func firstPanelIdSortedByUUIDString(_ workspaceId: UUID) -> UUID? {
        guard self.workspaceId == workspaceId else { return nil }
        return panels.keys.min { $0.uuidString < $1.uuidString }
    }

    func selectWorkspace(_ workspaceId: UUID) {}

    func rememberFocusedSurface(workspaceId: UUID, surfaceId: UUID) {}

    func focusPanel(workspaceId: UUID, panelId: UUID) {
        guard self.workspaceId == workspaceId else { return }
        focusPanelFromDockInteraction(panelId, window: nil)
    }

    func triggerFocusFlash(workspaceId: UUID, panelId: UUID) {
        guard self.workspaceId == workspaceId else { return }
        triggerFocusFlash(panelId: panelId)
    }

    func focusSelectedWorkspacePanel() {
        guard let focusedPanelId else { return }
        focusPanelFromDockInteraction(focusedPanelId, window: nil)
    }

    func focusHistoryRevisionDidChange() {}
}

extension DockSplitStore {
    @discardableResult
    func closePanel(
        _ panelId: UUID,
        force: Bool = false,
        recordsHistory: Bool = true
    ) -> Bool {
        guard let tabId = surfaceId(forPanelId: panelId) else { return false }
        if recordsHistory, !force {
            markDockCloseHistoryEligible(panelId: panelId)
        }
        if force { forceCloseDockTabIds.insert(tabId) }
        let closed = bonsplitController.closeTab(tabId)
        if force && !closed { forceCloseDockTabIds.remove(tabId) }
        if !closed,
           !pendingCloseConfirmDockTabIds.contains(tabId) {
            discardDockClosedPanelHistory(tabId: tabId)
        }
        return closed
    }

    func machineOwningSurface(_ panelID: UUID) -> SurfaceMachineID? { nil }
}

extension AppDelegate {
    @discardableResult
    func closeFocusedDockPanelForCommand(preferredWindow: NSWindow?) -> Bool {
        guard let dock = focusedDockStoreForShortcut(
            action: .closeTab,
            preferredWindow: preferredWindow
        ) else {
            return false
        }
        guard let panelId = dock.focusedPanelId else { return true }
        if dock.closePanel(panelId, force: false) {
            notificationStore?.clearNotifications(
                forTabId: dock.workspaceId,
                surfaceId: panelId
            )
        }
        return true
    }
}
