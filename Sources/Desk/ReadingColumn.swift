import SwiftUI

/// The transcript's reading column: up to `maxWidth` wide, centered, with `inset` on each side.
/// While `holdsWidth` is set (a sidebar or the files drawer sliding), it keeps the width it last
/// had and only moves, so replies aren't rewrapped and measured again on every frame of the slide.
/// When the slide ends it takes its new width, rewrapping once. Content shorter than `minHeight`
/// sits at the bottom of that height.
struct ReadingColumn: Layout {
    static let columnWidth: CGFloat = 720

    var maxWidth: CGFloat = Self.columnWidth
    var inset: CGFloat = 24
    var holdsWidth = false
    var minHeight: CGFloat = 0

    struct Cache {
        var width: CGFloat?
        /// The content's height at a width, measured while sizing and reused while placing.
        var measured: (width: CGFloat, height: CGFloat)?
    }

    func makeCache(subviews _: Subviews) -> Cache {
        Cache()
    }

    /// Keeps the width across changes to `holdsWidth`, which would otherwise start a new cache.
    func updateCache(_: inout Cache, subviews _: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let available = proposal.width ?? maxWidth + inset * 2
        let width = holdsWidth ? cache.width ?? fittingWidth(available) : fittingWidth(available)
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) }
        // At least as wide as the content allows, so the composer's minimum still reaches the
        // window's. A held width is no minimum: the column overflows until the slide ends.
        let needed = holdsWidth ? 0 : (sizes.map(\.width).max() ?? 0) + inset * 2
        let height = sizes.map(\.height).max() ?? 0
        cache.measured = (width, height)
        return CGSize(width: max(available, needed), height: max(height, minHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        // Only a real placement is remembered; SwiftUI also sizes the column at probe widths.
        if !holdsWidth || cache.width == nil {
            cache.width = fittingWidth(bounds.width)
        }
        let width = cache.width ?? fittingWidth(bounds.width)
        // Centered while it fits; held wider than the space, it keeps to the leading edge.
        let x = max(bounds.minX + inset, bounds.midX - width / 2)
        for subview in subviews {
            let height = cache.measured.flatMap { $0.width == width ? $0.height : nil }
                ?? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            let y = bounds.minY + max(bounds.height - height, 0)
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: height))
        }
    }

    private func fittingWidth(_ available: CGFloat) -> CGFloat {
        max(min(maxWidth, available - inset * 2), 0)
    }
}
