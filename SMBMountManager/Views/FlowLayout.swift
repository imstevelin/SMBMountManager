import SwiftUI

/// A view that arranges its children in a flow layout (wrapping to next line if no horizontal space).
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        var width: CGFloat = 0

        for row in rows {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight
            let rowWidth = row.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +) + CGFloat(max(row.count - 1, 0)) * spacing
            width = max(width, rowWidth)
        }

        height += CGFloat(max(rows.count - 1, 0)) * spacing
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX

            for view in row {
                let viewSize = view.sizeThatFits(.unspecified)
                view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += viewSize.width + spacing
            }

            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubview]] {
        var rows: [[LayoutSubview]] = [[]]
        var currentRow = 0
        var remainingWidth = proposal.width ?? .infinity

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if size.width > remainingWidth && !rows[currentRow].isEmpty {
                currentRow += 1
                rows.append([view])
                remainingWidth = (proposal.width ?? .infinity) - size.width - spacing
            } else {
                rows[currentRow].append(view)
                remainingWidth -= size.width + spacing
            }
        }
        return rows
    }
}
