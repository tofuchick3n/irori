import SwiftUI

/// The detail column runs under the sidebar, with the sidebar's width as its leading safe area.
/// Inside `.inspector`, that inset is counted twice in the column's minimum width, so showing the
/// sidebar raised the window's minimum by twice its width and AppKit widened the window.
/// This takes the extra `inset` back off whenever the content asks for more than it's offered.
struct SidebarInsetDiscount: Layout {
    var inset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(proposal)
        guard let offered = proposal.width, size.width > offered else { return size }
        return CGSize(width: max(offered, size.width - inset), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

extension View {
    func discountingSidebarInset(_ inset: CGFloat) -> some View {
        SidebarInsetDiscount(inset: inset) { self }
    }
}
