import CmuxFoundation
import SwiftUI

struct SidebarTerminalOverviewRow: View {
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.cmuxAccentColor) private var cmuxAccent
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
            Text(String(localized: "sidebar.terminalOverview.title", defaultValue: "All Terminals"))
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(background)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onSelect)
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        .padding(.top, 4)
        .frame(height: SidebarWorkspaceListMetrics.terminalOverviewRowHeight, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("SidebarTerminalOverviewRow")
    }

    private var background: Color {
        if isSelected { return cmuxAccent.color }
        if isHovered { return Color.primary.opacity(0.07) }
        return Color.primary.opacity(0.035)
    }
}
