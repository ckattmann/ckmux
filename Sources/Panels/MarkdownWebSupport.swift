import CMUXDebugLog
import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import WebKit

@MainActor
final class WeakMarkdownScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Owns the Markdown viewer's AppKit/WebKit lifecycle state.
///
/// `NSView` callbacks can arrive while SwiftUI is laying out an ancestor. The
/// coordinator records those callbacks synchronously, then coalesces the one
/// WebKit action that is safe to perform after the host transaction unwinds.
/// Keeping the state machine here gives window, geometry, and tab-visibility
/// transitions one owner and makes the transition contract independently
/// testable without relying on WebKit's pixel output.
@MainActor
final class MarkdownWebRenderingCoordinator {
    /// The one deferred platform action emitted by the lifecycle state machine.
    enum Action: Equatable {
        case hide(reason: String)
        case refresh(reason: String, forceLifecycleRefresh: Bool)
    }

    private let scheduler: MainActorDeferredActionScheduler
    private let isActuallyVisible: @MainActor () -> Bool
    private let applyAction: @MainActor (Action) -> Void
    private let onReenterWindow: @MainActor () -> Void

    private var attachedToWindow = false
    private var desiredVisibility = true
    private var needsRenderingReattach = false
    private var renderingStateIsHidden = false
    private var lastObservedBoundsSize: CGSize
    private var pendingRefreshReason = "initial"
    private var pendingForceLifecycleRefresh = false
    private var pendingWindowReentryNotification = false

    /// Creates a coordinator with an injectable action sink for transition tests.
    init(
        initialBoundsSize: CGSize,
        scheduler: MainActorDeferredActionScheduler? = nil,
        isActuallyVisible: @escaping @MainActor () -> Bool,
        applyAction: @escaping @MainActor (Action) -> Void,
        onReenterWindow: @escaping @MainActor () -> Void = {}
    ) {
        self.scheduler = scheduler ?? MainActorDeferredActionScheduler()
        self.isActuallyVisible = isActuallyVisible
        self.applyAction = applyAction
        self.onReenterWindow = onReenterWindow
        lastObservedBoundsSize = initialBoundsSize
    }

    /// Records a view-to-window transition without entering WebKit inline.
    func viewDidMoveToWindow(isAttached: Bool) {
        attachedToWindow = isAttached
        if isAttached {
            // Reparenting can preserve SwiftUI identity while WebKit loses its
            // in-window layer state. Always repair on the deferred turn.
            pendingWindowReentryNotification = true
            schedule(reason: "viewDidMoveToWindow.visible", forceLifecycleRefresh: true)
        } else {
            needsRenderingReattach = true
            pendingWindowReentryNotification = false
            schedule(reason: "viewDidMoveToWindow.hidden", forceLifecycleRefresh: false)
        }
    }

    /// Records an exact geometry change. Fractional-point divider movement is
    /// meaningful to WebKit, so no epsilon is applied here.
    func layoutDidChange(to boundsSize: CGSize) {
        let sizeChanged = lastObservedBoundsSize != boundsSize
        lastObservedBoundsSize = boundsSize
        if sizeChanged {
            schedule(reason: "boundsChanged", forceLifecycleRefresh: false)
        } else if needsRenderingReattach,
                  desiredVisibility,
                  attachedToWindow,
                  isActuallyVisible() {
            // SwiftUI can finish an opacity/hidden transition without changing
            // the view's size. A settled layout callback is the platform signal
            // that lets a previously hidden repair try again.
            schedule(reason: "visibilitySettled", forceLifecycleRefresh: true)
        }
    }

    /// Requests a lifecycle-aware repaint after an AppKit live resize ends.
    func viewDidEndLiveResize() {
        schedule(reason: "viewDidEndLiveResize", forceLifecycleRefresh: true)
    }

    /// Records whether SwiftUI intends this keep-alive viewer to be visible.
    func setVisibleInUI(_ visible: Bool) {
        let changed = desiredVisibility != visible
        desiredVisibility = visible
        if visible {
            if changed ||
                needsRenderingReattach ||
                renderingStateIsHidden ||
                pendingWindowReentryNotification {
                schedule(reason: "visibility.visible", forceLifecycleRefresh: true)
            }
        } else if changed {
            needsRenderingReattach = true
            schedule(reason: "visibility.hidden", forceLifecycleRefresh: false)
        }
    }

    /// Replaces the pending action so a resize burst produces one settled pass.
    private func schedule(reason: String, forceLifecycleRefresh: Bool) {
        pendingRefreshReason = reason
        pendingForceLifecycleRefresh = pendingForceLifecycleRefresh || forceLifecycleRefresh
        // The queued action reads the latest state when it runs. Keep one
        // scheduler task for a resize/visibility burst instead of repeatedly
        // cancelling and recreating MainActor tasks while AppKit is laying out.
        guard !scheduler.isScheduled else { return }
        scheduler.schedule { [weak self] in
            self?.performPendingAction()
        }
    }

    /// Applies the latest state snapshot after the host layout callback returns.
    private func performPendingAction() {
        let forceLifecycleRefresh = pendingForceLifecycleRefresh
        pendingForceLifecycleRefresh = false
        let reason = pendingRefreshReason

        guard desiredVisibility, attachedToWindow else {
            applyHiddenAction(reason: reason)
            return
        }

        guard isActuallyVisible() else {
            // AppKit may still be completing the hide/unhide transaction. Keep
            // the reattach intent; the next settled geometry/visibility callback
            // will run this same state transition again.
            needsRenderingReattach = true
            pendingForceLifecycleRefresh = pendingForceLifecycleRefresh || forceLifecycleRefresh
            return
        }

        let shouldReenter = forceLifecycleRefresh || needsRenderingReattach || renderingStateIsHidden
        if shouldReenter {
            needsRenderingReattach = false
            renderingStateIsHidden = false
        }
        applyAction(.refresh(reason: reason, forceLifecycleRefresh: shouldReenter))

        if pendingWindowReentryNotification {
            pendingWindowReentryNotification = false
            onReenterWindow()
        }
    }

    /// Moves WebKit out of its in-window lifecycle exactly once per hide period.
    private func applyHiddenAction(reason: String) {
        guard !renderingStateIsHidden else { return }
        renderingStateIsHidden = true
        needsRenderingReattach = true
        applyAction(.hide(reason: reason))
    }
}

@MainActor
final class MarkdownWebView: CmuxUndoableWebView {
    var onPointerDown: (() -> Void)?
    /// Invoked after this view is attached to a window. Keep this separate
    /// from pointer focus so a panel can complete a focus request made before
    /// SwiftUI mounted the WebKit view.
    var onAttachToWindow: (() -> Void)?
    /// Invoked when the view leaves its window (the detach half of a pane
    /// re-parent). Lets the renderer coordinator record whether the document
    /// was healthy at detach time so re-entry recovery can tell a detach
    /// artifact apart from an attached crash loop.
    var onLeaveWindow: (() -> Void)?
    /// Invoked when the view re-enters a window after being detached. Lets the
    /// renderer coordinator recover content WebKit dropped while the view was
    /// out of the window (e.g. a pane drag re-parented the hosting views).
    var onReenterWindow: (() -> Void)?

    /// The coordinator is the only owner of deferred WebKit lifecycle work.
    private var renderingCoordinator: MarkdownWebRenderingCoordinator?
    private var editableFocusStateConfirmed = false
    private var editableElementFocused = false
    private let viewerNavigationKeyRouter = ViewerNavigationKeyRouter(actions: [
        .diffViewerScrollDown, .diffViewerScrollUp,
        .diffViewerScrollHalfPageDown, .diffViewerScrollHalfPageUp,
        .diffViewerScrollDownEmacs, .diffViewerScrollUpEmacs,
        .diffViewerScrollToBottom, .diffViewerScrollToTop,
    ])

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        Self.installEditableFocusTracking(on: configuration.userContentController)
        super.init(frame: frame, configuration: configuration)
        renderingCoordinator = makeRenderingCoordinator(initialBoundsSize: bounds.size)
    }

    override func isWebContentUndoRedoCommandEquivalent(_ event: NSEvent) -> Bool {
        event.cmuxIsUndoRedoCommandEquivalent
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        Self.installEditableFocusTracking(on: configuration.userContentController)
        renderingCoordinator = makeRenderingCoordinator(initialBoundsSize: bounds.size)
    }

    private static func installEditableFocusTracking(on controller: WKUserContentController) {
        let name = MarkdownEditableFocusMessageHandler.name
        controller.add(MarkdownEditableFocusMessageHandler.shared, name: name)
        controller.addUserScript(WKUserScript(
            source: """
            (() => {
              const handler = window.webkit?.messageHandlers?.['\(name)'];
              if (!handler) return;
              const deepestActiveElement = () => {
                let element = document.activeElement;
                while (element?.shadowRoot?.activeElement) {
                  element = element.shadowRoot.activeElement;
                }
                return element;
              };
              const publish = () => {
                const element = deepestActiveElement();
                const editable = !!element?.closest?.("input, textarea, select, [contenteditable]:not([contenteditable='false'])");
                handler.postMessage({ editable });
              };
              document.addEventListener('focusin', publish, true);
              document.addEventListener('focusout', () => queueMicrotask(publish), true);
              document.addEventListener('pointerdown', () => requestAnimationFrame(publish), true);
              document.addEventListener('DOMContentLoaded', publish, { once: true });
              publish();
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    func markdownEditableFocusDidChange(_ editable: Bool) {
        editableFocusStateConfirmed = true
        editableElementFocused = editable
        if editable {
            viewerNavigationKeyRouter.reset()
        }
    }

    var isViewerNavigationEditableElementFocused: Bool {
        editableElementFocused
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        editableFocusStateConfirmed = false
        onPointerDown?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleViewerNavigationKey(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            editableFocusStateConfirmed = false
        }
        if handleViewerNavigationKey(event) {
            return
        }
        super.keyDown(with: event)
    }

    func handleViewerNavigationKey(_ event: NSEvent) -> Bool {
        return viewerNavigationKeyRouter.handle(event, isAllowed: { action, event in
            AppDelegate.shared?.shortcutWhenClauseAllows(action: action, event: event) ?? true
        }, perform: { [weak self] action in
            self?.performViewerNavigationAction(action)
        })
    }

    private func performViewerNavigationAction(_ action: KeyboardShortcutSettings.Action) {
        evaluateJavaScript("window.__cmuxPerformViewerNavigationAction?.('\(action.rawValue)')")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderingCoordinator?.viewDidMoveToWindow(isAttached: window != nil)
        if window == nil {
            // This callback only records renderer health. All WebKit lifecycle
            // selectors and layout/display work stay on the deferred path.
            onLeaveWindow?()
        } else {
            onAttachToWindow?()
        }
    }

    override func layout() {
        super.layout()
        // A divider/window resize can leave a live WKWebView with valid scroll
        // geometry but stale backing tiles. Invalidate and repair after this
        // layout callback returns; never flush the SwiftUI-owned ancestor here.
        renderingCoordinator?.layoutDidChange(to: bounds.size)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        renderingCoordinator?.viewDidEndLiveResize()
    }

    /// Updates the SwiftUI visibility intent for this viewer. Workspace panes
    /// keep all tabs alive, so an opacity-hidden tab must explicitly leave
    /// WebKit's in-window lifecycle or ProcessThrottler may park its process;
    /// the selected tab gets a deferred enter/paint pass on reveal.
    func setVisibleInUI(_ visible: Bool) {
        renderingCoordinator?.setVisibleInUI(visible)
    }

    private func makeRenderingCoordinator(initialBoundsSize: CGSize) -> MarkdownWebRenderingCoordinator {
        MarkdownWebRenderingCoordinator(
            initialBoundsSize: initialBoundsSize,
            isActuallyVisible: { [weak self] in
                guard let self else { return false }
                return self.window != nil && !self.isHiddenOrHasHiddenAncestor
            },
            applyAction: { [weak self] action in
                self?.applyRenderingAction(action)
            },
            onReenterWindow: { [weak self] in
                self?.onReenterWindow?()
            }
        )
    }

    private func applyRenderingAction(_ action: MarkdownWebRenderingCoordinator.Action) {
        switch action {
        case .hide:
            callVoidSelectorIfAvailable("viewDidHide")
            callVoidSelectorIfAvailable("_exitInWindow")
        case let .refresh(_, forceLifecycleRefresh):
            if forceLifecycleRefresh {
                callVoidSelectorIfAvailable("viewDidUnhide")
                callVoidSelectorIfAvailable("_enterInWindow")
                callVoidSelectorIfAvailable("_endDeferringViewInWindowChangesSync")
            }

            needsLayout = true
            needsDisplay = true
            setNeedsDisplay(bounds)
            // This is deliberately below the deferred scheduler boundary. It
            // flushes only the Markdown WebKit view after SwiftUI/AppKit has
            // unwound, so no enclosing scroll view or NSHostingView is
            // synchronously re-entered.
            layoutSubtreeIfNeeded()
            displayIfNeeded()
        }
    }

    /// Calls a private WKWebView lifecycle selector when present. Guarded by
    /// `responds(to:)` so it degrades to a no-op if the selector is removed.
    private func callVoidSelectorIfAvailable(_ rawSelector: String) {
        let selector = NSSelectorFromString(rawSelector)
        guard responds(to: selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
    }
}

struct MarkdownWebTheme: Equatable {
    let isDark: Bool
    let background: String
    let mutedBackground: String
    let neutralMutedBackground: String
    let border: String
    let mutedBorder: String

    static func resolve(backgroundColor: NSColor) -> MarkdownWebTheme {
        let base = backgroundColor.markdownOpaqueSRGB
        let isDark = !base.isLightColor
        let overlayColor: NSColor = isDark ? .white : .black
        let muted = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.09 : 1.06,
            of: overlayColor
        )
        let neutralMuted = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.35 : 1.20,
            of: overlayColor
        )
        let border = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.92 : 1.43,
            of: overlayColor
        )
        return MarkdownWebTheme(
            isDark: isDark,
            background: "transparent",
            mutedBackground: muted.markdownCSSColor,
            neutralMutedBackground: neutralMuted.markdownCSSColor,
            border: border.markdownCSSColor,
            mutedBorder: border.withAlphaComponent(border.alphaComponent * 0.70).markdownCSSColor
        )
    }
}

/// Panel-owned renderer session for a markdown preview.
///
/// SwiftUI may recreate `MarkdownWebRenderer` wrappers during split/tab layout
/// updates. The session keeps the WebKit coordinator identity tied to the
/// logical `MarkdownPanel` instead of the transient representable instance.
@MainActor
final class MarkdownRendererSession {
    private let ownedCoordinator = MarkdownWebRenderer.Coordinator()

    /// The live preview web view — the panel's keyboard surface in preview
    /// mode, and the evaluation target for find-in-page scripts. `nil` until
    /// the renderer has been mounted once.
    var webView: WKWebView? {
        ownedCoordinator.webView
    }

    /// Invoked after the shell re-renders the markdown content (initial load,
    /// content change, or crash recovery). Find highlights are DOM `<mark>`
    /// wrappers that a re-render wipes, so an active search must re-run.
    var onMarkdownRendered: (() -> Void)? {
        get { ownedCoordinator.onMarkdownRendered }
        set { ownedCoordinator.onMarkdownRendered = newValue }
    }

    func coordinator(
        panelId: UUID,
        workspaceId: UUID,
        filePath: String
    ) -> MarkdownWebRenderer.Coordinator {
        ownedCoordinator.bind(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
        return ownedCoordinator
    }

    func close() {
        ownedCoordinator.close()
    }

    func renderedHTML(markdown: String? = nil) async -> String? {
        await ownedCoordinator.renderedHTML(markdown: markdown)
    }

    func renderedText() async -> String? {
        await ownedCoordinator.renderedText()
    }

    func readSurfaceSelection(filePath: String) async -> SurfaceSelectionReadResult {
        await ownedCoordinator.readSurfaceSelection(filePath: filePath)
    }
}

extension NSColor {
    var markdownOpaqueSRGB: NSColor {
        (usingColorSpace(.sRGB) ?? self).withAlphaComponent(1)
    }

    var markdownCSSColor: String {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let r = min(255, max(0, Int((red * 255).rounded())))
        let g = min(255, max(0, Int((green * 255).rounded())))
        let b = min(255, max(0, Int((blue * 255).rounded())))
        let a = min(1, max(0, alpha))
        return String(format: "rgba(%d, %d, %d, %.3f)", r, g, b, Double(a))
    }

    func markdownThemeOverlay(targetContrast: CGFloat, of color: NSColor) -> NSColor {
        let base = markdownOpaqueSRGB
        let overlay = color.markdownOpaqueSRGB
        var low: CGFloat = 0
        var high: CGFloat = 1
        var result: CGFloat = 1

        for _ in 0..<18 {
            let mid = (low + high) / 2
            let candidate = base.blended(withFraction: mid, of: overlay) ?? base
            if candidate.markdownContrastRatio(with: base) < Double(targetContrast) {
                low = mid
            } else {
                high = mid
                result = mid
            }
        }

        return overlay.withAlphaComponent(result)
    }

    var markdownRelativeLuminance: Double {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            if value <= 0.04045 {
                return value / 12.92
            }
            return pow((value + 0.055) / 1.055, 2.4)
        }

        return (0.2126 * linear(red)) + (0.7152 * linear(green)) + (0.0722 * linear(blue))
    }

    func markdownContrastRatio(with other: NSColor) -> Double {
        let first = markdownRelativeLuminance
        let second = other.markdownRelativeLuminance
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

// MARK: - Web view base class (from the former CmuxBrowser package)
import AppKit
import WebKit

/// Base class for every WebKit view that cmux embeds in an app window.
///
/// WebKit registers page edit commands through the view's `undoManager`.
/// `NSResponder` otherwise resolves that property to the window's shared
/// manager, which lets commands from a closed web view remain in a different
/// object's undo stack and later message a dangling target.
open class CmuxUndoableWebView: WKWebView {
    public let webContentUndoManager = UndoManager()

    // WebKit reads the responder's undo manager from framework callbacks; do
    // not make that Objective-C getter enter a Swift MainActor check.
    open nonisolated override var undoManager: UndoManager? { webContentUndoManager }

    /// Whether `event` is the keyboard-layout-aware Cmd+Z or Cmd+Shift+Z
    /// chord this view completes. The keyboard layout lookup lives in the
    /// app, so each concrete web view class overrides this; the base class
    /// recognizes no chord.
    open func isWebContentUndoRedoCommandEquivalent(_ event: NSEvent) -> Bool {
        false
    }

    /// Completes a routed WebKit undo command after the page declines it.
    open override func keyDown(with event: NSEvent) {
        if performWebContentUndoRedo(for: event) {
            return
        }
        super.keyDown(with: event)
    }
}

extension NSWindow {
    /// Finds an embedded WebKit view from a responder without depending on
    /// browser-only panel state. Agent-session and Markdown views use this
    /// path when their web content owns first responder.
    public func cmuxOwningUndoableWebView(for responder: NSResponder) -> CmuxUndoableWebView? {
        if let webView = responder as? CmuxUndoableWebView {
            return webView
        }
        if let view = responder as? NSView {
            var current: NSView? = view.superview
            while let candidate = current {
                if let webView = candidate as? CmuxUndoableWebView {
                    return webView
                }
                current = candidate.superview
            }
        }
        var current = responder.nextResponder
        var hops = 0
        while let next = current, hops < 64 {
            if let webView = next as? CmuxUndoableWebView {
                return webView
            }
            current = next.nextResponder
            hops += 1
        }
        return nil
    }
}

// Cmd+Z / Cmd+Shift+Z for embedded WebKit views.
//
// WebKit registers every web-content edit command on the web view's
// `undoManager` (`WebViewImpl::registerEditCommand` calls
// `[m_view undoManager]`). NSResponder's default implementation resolves that
// to the window's shared undo manager, which mixes edit commands from every
// web view in the window into one stack whose registered targets can outlive
// their web view — the stale-target crash behind
// https://github.com/manaflow-ai/cmux/issues/7272. The fix for that crash
// routes the undo/redo chords away from the AppKit Edit menu whenever a
// browser web view is focused, which also silenced in-page undo/redo because
// nothing performed the command anymore
// (https://github.com/manaflow-ai/cmux/issues/9677).
//
// Owning an undo manager per WebKit view restores both invariants:
// - web-content edit commands never reach the window's shared undo manager
//   and never outlive their web view, so the stale-target class of crashes is
//   impossible by construction;
// - the routed chords can perform undo/redo directly on the focused web
//   view's own stack, matching Safari's Edit-menu behavior.
extension CmuxUndoableWebView {
    /// Performs the page's native editing undo/redo for a routed
    /// Cmd+Z / Cmd+Shift+Z chord.
    ///
    /// Returns `false` when `event` is not an undo/redo command equivalent.
    /// Otherwise the chord is consumed even when the relevant stack is empty,
    /// mirroring a disabled Edit-menu item rather than re-forwarding the key.
    ///
    /// Browser automation's keys (``NSEvent/isBrowserAutomationKeyEvent``:
    /// a REPL session's, `cmux browser press`') are never consumed here:
    /// they go to WebKit, so the page gets the keydown first and can cancel
    /// it, and only a key no page handled runs Undo or Redo afterwards. The
    /// REPL runs it through the frame gate, which refuses a focused frame
    /// or document the session's authority blocks; done here, the undo
    /// would reach the tab's last edit wherever the focus is.
    public func performWebContentUndoRedo(for event: NSEvent) -> Bool {
        let isRedo = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift)
        performWebContentUndoRedo(redo: isRedo)
        return true
    }

    /// Undoes or redoes the web view's last edit on its own undo stack, if
    /// there is one.
    public func performWebContentUndoRedo(redo isRedo: Bool) {
#if DEBUG
        CMUXDebugLog.logDebugEvent(
            "browser.webContentUndoRedo \(isRedo ? "redo" : "undo") " +
            "web=\(ObjectIdentifier(self)) " +
            "canUndo=\(webContentUndoManager.canUndo ? 1 : 0) " +
            "canRedo=\(webContentUndoManager.canRedo ? 1 : 0)"
        )
#endif
        if isRedo {
            if webContentUndoManager.canRedo {
                webContentUndoManager.redo()
            }
        } else if webContentUndoManager.canUndo {
            webContentUndoManager.undo()
        }
    }
}


enum GhosttyBackgroundTheme {
    static func clampedOpacity(_ opacity: Double) -> CGFloat {
        WindowAppearanceSnapshot.clampedOpacity(opacity)
    }

    static func color(backgroundColor: NSColor, opacity: Double) -> NSColor {
        WindowAppearanceSnapshot.compositedTerminalColor(
            backgroundColor: backgroundColor,
            opacity: opacity
        )
    }

    static func color(
        from notification: Notification?,
        fallbackColor: NSColor,
        fallbackOpacity: Double
    ) -> NSColor {
        let userInfo = notification?.userInfo
        let backgroundColor =
            (userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor)
            ?? fallbackColor

        let opacity: Double
        if let value = userInfo?[GhosttyNotificationKey.backgroundOpacity] as? Double {
            opacity = value
        } else if let value = userInfo?[GhosttyNotificationKey.backgroundOpacity] as? NSNumber {
            opacity = value.doubleValue
        } else {
            opacity = fallbackOpacity
        }

        return color(backgroundColor: backgroundColor, opacity: opacity)
    }

    static func color(from notification: Notification?) -> NSColor {
        color(
            from: notification,
            fallbackColor: GhosttyApp.shared.defaultBackgroundColor,
            fallbackOpacity: GhosttyApp.shared.defaultBackgroundOpacity
        )
    }

    /// Resolves a live background notification against the terminal theme's
    /// concrete light/dark base. This is the variant used by detached browser
    /// and Dock chrome; the legacy `color(from:)` helper remains available for
    /// callers that explicitly need the window ambient composition.
    static func resolvedColor(from notification: Notification?) -> NSColor {
        let userInfo = notification?.userInfo
        let backgroundColor =
            (userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor)
            ?? GhosttyApp.shared.defaultBackgroundColor
        let opacity: Double
        if let value = userInfo?[GhosttyNotificationKey.backgroundOpacity] as? Double {
            opacity = value
        } else if let value = userInfo?[GhosttyNotificationKey.backgroundOpacity] as? NSNumber {
            opacity = value.doubleValue
        } else {
            opacity = GhosttyApp.shared.defaultBackgroundOpacity
        }
        return WindowAppearanceSnapshot.resolvedChromeBackgroundColor(
            backgroundColor: backgroundColor,
            opacity: opacity,
            colorScheme: GhosttyApp.shared.effectiveTerminalColorSchemePreference == .dark ? .dark : .light
        )
    }

    static func currentColor() -> NSColor {
        WindowAppearanceSnapshot.resolvedChromeBackgroundColor(
            backgroundColor: GhosttyApp.shared.defaultBackgroundColor,
            opacity: GhosttyApp.shared.defaultBackgroundOpacity,
            colorScheme: GhosttyApp.shared.effectiveTerminalColorSchemePreference == .dark ? .dark : .light
        )
    }
}
