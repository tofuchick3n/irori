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
    /// True while the sidebar animates open or closed.
    private(set) var isSliding = false

    func attach(_ controller: NSSplitViewController) {
        guard splitViewController !== controller else { return }
        splitViewController = controller
        controller.splitViewItems.first?.canCollapse = false
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
        // A sidebar that can't collapse can't be toggled either, so allow it for the animation only.
        sidebar.canCollapse = true
        isSliding = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            sidebar.animator().isCollapsed = collapsed
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.isSliding = false
                self?.lockOpenSidebar()
            }
        }
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
