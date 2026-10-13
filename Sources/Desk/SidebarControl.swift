import AppKit
import SwiftUI

/// Dragging the sidebar narrower makes AppKit collapse it instantly, while the toolbar
/// button animates. Desk turns off collapse-by-drag (the sidebar stops at its minimum
/// width) and hides it only through `toggle()`, which always animates.
@MainActor
@Observable
final class SidebarControl {
    @ObservationIgnored private weak var splitViewController: NSSplitViewController?
    /// Set when the sidebar was hidden to make room for a trailing panel, so closing it brings the sidebar back.
    @ObservationIgnored private var hidForRoom = false
    /// The split view's columns, bound to the NavigationSplitView so SwiftUI animates the slide.
    var visibility = NavigationSplitViewVisibility.all
    /// True while the sidebar animates open or closed.
    private(set) var isSliding = false
    /// How far the sidebar overlaps the detail column, for `SidebarInsetDiscount`. It changes only at
    /// the ends of a slide: opening, it holds the open width from the start; closing, until the end.
    /// Following the slide frame by frame re-ran the detail's layout and the window's minimum each frame.
    private(set) var overlap: CGFloat = 0
    @ObservationIgnored private var openWidth: CGFloat = 0
    @ObservationIgnored private var resizeObserver: NSObjectProtocol?
    @ObservationIgnored private var collapseObservation: NSKeyValueObservation?
    /// Counts slides, so a retoggle mid-slide isn't ended by the earlier slide's timer.
    @ObservationIgnored private var slideGeneration = 0
    private static let slideDuration = 0.25

    func attach(_ controller: NSSplitViewController) {
        guard splitViewController !== controller else { return }
        splitViewController = controller
        controller.splitViewItems.first?.canCollapse = false
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: controller.splitView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.measureOverlap() }
        }
        // SwiftUI sets canCollapse behind our back when it applies the visibility binding,
        // so the drag lock is enforced continuously: anything may collapse the sidebar only
        // mid-slide or while hidden to make room.
        collapseObservation?.invalidate()
        if let item = controller.splitViewItems.first {
            collapseObservation = item.observe(\.canCollapse, options: [.new]) { [weak self] _, change in
                // Only true-sets matter; our own veto back to false is ignored, so this can't loop.
                guard change.newValue == true else { return }
                MainActor.assumeIsolated { [weak self] in
                    guard let self, !self.isSliding, !self.hidForRoom else { return }
                    self.lockOpenSidebar()
                }
            }
        }
        measureOverlap()
    }

    func toggle() {
        hidForRoom = false
        setCollapsed(splitViewController?.splitViewItems.first?.isCollapsed == false)
    }

    /// Hides the sidebar when the window is too narrow to add `width` beside the content, so
    /// opening a panel doesn't make AppKit widen the window.
    func makeRoom(for width: CGFloat) {
        guard let controller = splitViewController, let window = controller.view.window,
              let sidebar = controller.splitViewItems.first, !sidebar.isCollapsed,
              window.frame.width < window.minSize.width + width else { return }
        hidForRoom = true
        // At once, not animated: the panel's width is settled in this same layout pass.
        sidebar.canCollapse = true
        sidebar.isCollapsed = true
        visibility = .detailOnly
    }

    /// Shows the sidebar again if `makeRoom(for:)` hid it.
    func giveBackRoom() {
        guard hidForRoom else { return }
        hidForRoom = false
        setCollapsed(false)
    }

    private func setCollapsed(_ collapsed: Bool) {
        guard let controller = splitViewController, let sidebar = controller.splitViewItems.first,
              sidebar.isCollapsed != collapsed else { return }
        // A sidebar that can't collapse can't be toggled either, so allow it for the animation
        // only. isSliding first: the collapse observer vetoes canCollapse while settled.
        isSliding = true
        slideGeneration += 1
        sidebar.canCollapse = true
        let generation = slideGeneration
        if !collapsed { overlap = openWidth > 0 ? openWidth : sidebar.viewController.view.frame.width }
        withAnimation(.smooth(duration: Self.slideDuration)) {
            visibility = collapsed ? .detailOnly : .all
        }
        // Not the animation's completion: it fires on the next turn, while the split view is
        // still sliding. Ending there zeroed the overlap mid-hide and widened the window again.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.slideDuration + 0.1))
            guard let self, self.slideGeneration == generation else { return }
            self.isSliding = false
            self.lockOpenSidebar()
            self.measureOverlap()
        }
    }

    private func measureOverlap() {
        guard !isSliding, let sidebar = splitViewController?.splitViewItems.first else { return }
        let width = sidebar.isCollapsed ? 0 : sidebar.viewController.view.frame.width
        if width > 0 { openWidth = width }
        if overlap != width { overlap = width }
    }

    /// Once the sidebar is showing again, dragging must not collapse it.
    private func lockOpenSidebar() {
        guard let sidebar = splitViewController?.splitViewItems.first, !sidebar.isCollapsed else { return }
        sidebar.canCollapse = false
    }
}

/// Finds the split view controller SwiftUI's NavigationSplitView builds and hands it to `SidebarControl`.
struct SidebarControlAnchor: NSViewRepresentable {
    let control: SidebarControl

    func makeNSView(context _: Context) -> NSView {
        AnchorView(control: control)
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class AnchorView: NSView {
        let control: SidebarControl

        init(control: SidebarControl) {
            self.control = control
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var view: NSView? = superview
            while let current = view {
                if let split = current as? NSSplitView, let controller = split.delegate as? NSSplitViewController {
                    control.attach(controller)
                    return
                }
                view = current.superview
            }
        }
    }
}
