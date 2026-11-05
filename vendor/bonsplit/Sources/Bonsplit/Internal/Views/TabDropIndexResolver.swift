import CoreGraphics

/// Resolves a pointer in a horizontal tab strip to an insertion index.
struct TabDropIndexResolver {
    /// A live tab frame paired with its index in the pane model.
    struct IndexedFrame {
        let index: Int
        let frame: CGRect
    }

    /// Resolves frames whose offsets already match their pane-model indices.
    func insertionIndex(
        at location: CGPoint,
        in bounds: CGRect,
        tabFrames: [CGRect]
    ) -> Int? {
        insertionIndex(
            at: location,
            in: bounds,
            indexedTabFrames: tabFrames.enumerated().map { IndexedFrame(index: $0.offset, frame: $0.element) },
            tabCount: tabFrames.count
        )
    }

    /// Resolves leading-to-trailing live frames while preserving their pane-model indices.
    func insertionIndex(
        at location: CGPoint,
        in bounds: CGRect,
        indexedTabFrames: [IndexedFrame],
        tabCount: Int
    ) -> Int? {
        guard bounds.contains(location), tabCount >= 0 else { return nil }
        guard tabCount > 0 else { return 0 }
        guard !indexedTabFrames.isEmpty,
              indexedTabFrames.allSatisfy({ item in
                  (0..<tabCount).contains(item.index)
                      && item.frame.width > 0
                      && item.frame.midX.isFinite
              }) else {
            return nil
        }

        let rows = rowsInModelOrder(indexedTabFrames)
        let rowsAreVisuallyOrdered = rows.allSatisfy { row in
            zip(row, row.dropFirst()).allSatisfy { lhs, rhs in
                lhs.index < rhs.index && lhs.frame.midX <= rhs.frame.midX
            }
        }
        guard rowsAreVisuallyOrdered, let targetRow = row(containing: location, in: rows) else { return nil }

        for item in targetRow where location.x < item.frame.midX {
            return item.index
        }

        guard let lastItem = targetRow.last else { return nil }
        return min(lastItem.index + 1, tabCount)
    }

    /// Splits model-ordered frames into visual rows; a single-row strip yields one row.
    private func rowsInModelOrder(_ items: [IndexedFrame]) -> [[IndexedFrame]] {
        var rows: [[IndexedFrame]] = []
        for item in items {
            if let previous = rows.last?.last,
               abs(previous.frame.midY - item.frame.midY) < max(1, min(previous.frame.height, item.frame.height) / 2) {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows
    }

    private func row(containing location: CGPoint, in rows: [[IndexedFrame]]) -> [IndexedFrame]? {
        rows.min { lhs, rhs in
            verticalDistance(from: location.y, to: lhs) < verticalDistance(from: location.y, to: rhs)
        }
    }

    private func verticalDistance(from y: CGFloat, to row: [IndexedFrame]) -> CGFloat {
        guard let minY = row.map(\.frame.minY).min(), let maxY = row.map(\.frame.maxY).max() else {
            return .infinity
        }
        if y < minY { return minY - y }
        if y > maxY { return y - maxY }
        return 0
    }
}
