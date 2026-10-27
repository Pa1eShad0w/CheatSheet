import CheatSheetCore
import Foundation

/// Shared by the packer and the view so every packed row fits without measuring text.
enum ShortcutColumnMetrics {
    static let rowHeight: CGFloat = 22
    static let headingTopInset: CGFloat = 16
    static let headingHeight: CGFloat = headingTopInset + rowHeight
    static let groupSpacing: CGFloat = 0
    static let columnSpacing: CGFloat = 20
    static let horizontalInset: CGFloat = 16
    static let verticalInset: CGFloat = 0
    static let shortcutWidth: CGFloat = 74
    static let shortcutSpacing: CGFloat = 4
    static let keyWidth: CGFloat = 18
    static let longKeyWidth: CGFloat = 30
    static let footerHeight: CGFloat = 48
    // Reserve space for the horizontal scroller even when the system always shows it.
    static let scrollerHeight: CGFloat = 16

    static let visibleColumnCount = 4

    static func columnWidth(viewportWidth: CGFloat) -> CGFloat {
        let usableWidth = max(0, viewportWidth - 2 * horizontalInset)
        return max(0, (usableWidth - 3 * columnSpacing) / 4)
    }
}

struct ShortcutColumnFragment: Identifiable {
    struct ID: Hashable {
        let sectionIndex: Int
        let startIndex: Int
    }

    let id: ID
    let section: ShortcutSection
    let range: Range<Int>

    var height: CGFloat {
        ShortcutColumnMetrics.headingHeight + CGFloat(range.count) * ShortcutColumnMetrics.rowHeight
    }
}

struct ShortcutColumn: Identifiable {
    let id: Int
    var fragments: [ShortcutColumnFragment] = []
    var height: CGFloat = 0
}

/// Packs in menu order, never backfilling an earlier column with later menu items.
/// The viewport must have room for at least one heading and one row.
func packShortcutColumns(sections: [ShortcutSection], height: CGFloat) -> [ShortcutColumn] {
    let headingHeight = ShortcutColumnMetrics.headingHeight
    let rowHeight = ShortcutColumnMetrics.rowHeight
    precondition(height >= headingHeight + rowHeight)
    let fullColumnCapacity = Int(((height - headingHeight) / rowHeight).rounded(.down))
    var columns = [ShortcutColumn(id: 0)]

    for (sectionIndex, section) in sections.enumerated() where !section.shortcuts.isEmpty {
        var start = 0
        while start < section.shortcuts.count {
            let columnIndex = columns.count - 1
            let gap: CGFloat = columns[columnIndex].fragments.isEmpty ? 0 : ShortcutColumnMetrics.groupSpacing
            let availableHeight = height - columns[columnIndex].height - gap
            let capacity = max(0, Int(((availableHeight - headingHeight) / rowHeight).rounded(.down)))
            let remaining = section.shortcuts.count - start

            // Every continuation retains its heading so the group's context is
            // visible without scrolling back to an earlier column.
            if capacity == 0 || (start == 0 && remaining <= fullColumnCapacity && remaining > capacity) {
                columns.append(ShortcutColumn(id: columns.count))
                continue
            }

            let end = start + min(remaining, capacity)
            let fragment = ShortcutColumnFragment(
                id: .init(sectionIndex: sectionIndex, startIndex: start),
                section: section,
                range: start..<end
            )
            columns[columnIndex].fragments.append(fragment)
            columns[columnIndex].height += gap + fragment.height
            start = end
        }
    }

    return columns
}
