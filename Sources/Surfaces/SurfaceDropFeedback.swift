import AppKit

/// Owns a transient warning above AppKit portals without taking keyboard focus.
@MainActor
final class SurfaceDropFeedback {
    private var badgeView: FileDropHintBadgeView?
    var badge: FileDropHintBadgeView {
        if let badgeView { return badgeView }
        let view = FileDropHintBadgeView(frame: .zero)
        badgeView = view
        return view
    }

    func update(over target: NSView, text: String = "") {
        let host = target.window?.contentView?.superview ?? target
        let targetBounds = host.convert(target.bounds, from: target)
        let visibleBounds = host.bounds.intersection(targetBounds)
        guard !visibleBounds.isEmpty else { clear(); return }
        if badge.superview !== host {
            badge.removeFromSuperview()
            host.addSubview(badge, positioned: .above, relativeTo: nil)
        }
        // Keep the warning out of the adjacent sidebar. Retain the window's
        // vertical room so the full message stays visible above a short split.
        let layoutBounds = NSRect(x: visibleBounds.minX, y: host.bounds.minY,
                                  width: visibleBounds.width, height: host.bounds.height)
        badge.show(
            text: text,
            centeredIn: targetBounds,
            clippedTo: layoutBounds,
            warning: true
        )
    }

    func clear() {
        badgeView?.hideImmediately()
        badgeView?.removeFromSuperview()
    }
}
