import Foundation

/// A short state label drawn after a tab's title, such as an agent's "Idle" or "Needs input".
public struct TabStatus: Hashable, Sendable {
    public var text: String
    public var symbolName: String?
    /// `#rrggbb`; nil uses the tab's secondary text color.
    public var colorHex: String?

    public init(text: String, symbolName: String? = nil, colorHex: String? = nil) {
        self.text = text
        self.symbolName = symbolName
        self.colorHex = colorHex
    }
}
