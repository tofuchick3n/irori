import AppKit
import SwiftUI

/// A reply's markdown in a native, selectable, non-scrolling text view. Unlike SwiftUI text with
/// geometry readers, it does no work when the transcript scrolls.
struct MarkdownText: NSViewRepresentable {
    let markdown: String
    var menuItems: [NSMenuItem] = []
    /// Find matches in the rendered text; `current` is the one the find bar is on.
    var highlights: [NSRange] = []
    var current: NSRange?
    /// Handles a clicked link first; returning false lets the system open it.
    var openLink: ((URL) -> Bool)?
    var folding: MarkdownRenderer.CodeFolding?
    /// Opens or folds the long code block with this id.
    var toggleCode: ((Int) -> Void)?

    func makeNSView(context _: Context) -> MarkdownTextView {
        let view = MarkdownTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: MarkdownTextView, context _: Context) {
        view.extraMenuItems = menuItems
        view.openLink = openLink
        view.toggleCode = toggleCode
        if view.markdown != markdown || view.folding != folding {
            view.markdown = markdown
            view.folding = folding
            let previous = view.textStorage?.string ?? ""
            let rendered = MarkdownRenderer.render(markdown, folding: folding)
            view.replaceChangedTail(with: rendered)
            let shown = (previous as NSString).length
            // Only a pure append fades. Any other edit, like a closed fence replacing its line count,
            // moves earlier text, so ranges still fading may name other characters.
            if folding?.streaming == true, highlights.isEmpty, shown > 0, rendered.length > shown, rendered.string.hasPrefix(previous) {
                view.fadeIn(NSRange(location: shown, length: rendered.length - shown))
            } else {
                view.stopFading()
            }
            view.cachedSizes = [:]
            // Find colors from the old text must be cleared; with none shown there's nothing to redo,
            // and clearing anyway would wipe the fade.
            if view.shownHighlights.map({ !$0.all.isEmpty || $0.current != nil }) == true {
                view.shownHighlights = nil
            }
            view.needsLayout = true
        }
        view.showHighlights(highlights, current: current)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MarkdownTextView, context _: Context) -> CGSize? {
        let width = proposal.width ?? 600
        if let cached = view.cachedSizes[width] {
            return cached
        }
        // The window's minimum size probes at widths like 0, where wrapping puts every character on
        // its own line; laying a long reply out that way on each streamed chunk pinned the main thread.
        guard width >= 60 else { return CGSize(width: width, height: 0) }
        // Measure off to the side: SwiftUI probes widths like 0 and 6 before the real one, and
        // laying out the visible view at a probe width would leave its text wrapped there.
        let size = CGSize(width: width, height: view.measuredHeight(at: width))
        view.cachedSizes[width] = size
        return size
    }
}

extension NSAttributedString {
    /// The first index where this and `other` differ, in text or in attributes.
    func firstDifference(from other: NSAttributedString) -> Int {
        let common = (string as NSString).commonPrefix(with: other.string, options: .literal)
        let same = (common as NSString).length
        var index = 0
        while index < same {
            let rest = NSRange(location: index, length: same - index)
            var mine = NSRange()
            var theirs = NSRange()
            let lhs = attributes(at: index, longestEffectiveRange: &mine, in: rest)
            let rhs = other.attributes(at: index, longestEffectiveRange: &theirs, in: rest)
            guard NSDictionary(dictionary: lhs).isEqual(to: rhs) else { return index }
            index = min(NSMaxRange(mine), NSMaxRange(theirs))
        }
        return same
    }
}

/// A scratch TextKit stack laid out the same way as `MarkdownTextView`, for measuring.
@MainActor
enum MarkdownMeasure {
    private static let storage = NSTextStorage()
    private static let layout = NSLayoutManager()
    private static let container: NSTextContainer = {
        let container = NSTextContainer()
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        return container
    }()

    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        storage.setAttributedString(text)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }
}

final class MarkdownTextView: NSTextView {
    var markdown: String?
    /// Sizes by proposed width; SwiftUI probes a few widths before settling on one.
    var cachedSizes: [CGFloat: CGSize] = [:]
    var extraMenuItems: [NSMenuItem] = []
    var openLink: ((URL) -> Bool)?
    var folding: MarkdownRenderer.CodeFolding?
    var toggleCode: ((Int) -> Void)?
    var shownHighlights: (all: [NSRange], current: NSRange?)?
    private var copyButtons: [CodeCopyButton] = []
    /// Text that just streamed in, and when it arrived; it fades in over `fadeDuration`.
    private var fading: [(range: NSRange, start: CFTimeInterval)] = []
    private var fadeTimer: Timer?
    private static let fadeDuration: CFTimeInterval = 0.2
    private var toggleButtons: [CodeToggleButton] = []

    /// Marks find matches with temporary attributes, which leave the text and its measured size alone.
    func showHighlights(_ ranges: [NSRange], current: NSRange?) {
        if let shown = shownHighlights, shown.all == ranges, shown.current == current { return }
        // Find colors share the temporary foreground with the fade, which would clear them as it ends.
        if !ranges.isEmpty { stopFading() }
        let movedToThis = current != nil && shownHighlights?.current != current
        shownHighlights = (ranges, current)
        guard let layout = layoutManager, let length = textStorage?.length else { return }
        let whole = NSRange(location: 0, length: length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        let fits = { (range: NSRange) in NSMaxRange(range) <= length }
        for range in ranges where fits(range) {
            layout.addTemporaryAttribute(
                .backgroundColor,
                value: NSColor.findHighlightColor.withAlphaComponent(0.35),
                forCharacterRange: range
            )
        }
        guard let current, fits(current) else { return }
        // Dark text on the bright find color, so the current match stays readable in dark mode too.
        layout.addTemporaryAttributes(
            [.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black],
            forCharacterRange: current
        )
        if movedToThis {
            // After SwiftUI has scrolled the row into view, bring the match itself in and flash it.
            DispatchQueue.main.async { [weak self] in
                self?.scrollRangeToVisible(current)
                self?.showFindIndicator(for: current)
            }
        }
    }

    /// Fades newly streamed text in with a temporary color, which leaves layout alone. AppKit
    /// redraws only this view, so SwiftUI does no work per frame.
    func fadeIn(_ range: NSRange) {
        fading.append((range, CACurrentMediaTime()))
        stepFade()
        guard fadeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.stepFade() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    func stopFading() {
        guard !fading.isEmpty || fadeTimer != nil else { return }
        if let layout = layoutManager, let length = textStorage?.length {
            for fade in fading {
                let range = NSIntersectionRange(fade.range, NSRange(location: 0, length: length))
                if range.length > 0 { layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range) }
            }
        }
        fading = []
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    private func stepFade() {
        guard let layout = layoutManager, let length = textStorage?.length else { return }
        let now = CACurrentMediaTime()
        var still: [(range: NSRange, start: CFTimeInterval)] = []
        for fade in fading {
            let range = NSIntersectionRange(fade.range, NSRange(location: 0, length: length))
            let progress = (now - fade.start) / Self.fadeDuration
            guard range.length > 0 else { continue }
            if progress >= 1 {
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            } else {
                let color = NSColor.label(alpha: 0.15 + 0.85 * progress)
                layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
                still.append(fade)
            }
        }
        fading = still
        if fading.isEmpty {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }

    /// Swaps in a new rendering from where it first differs, so text that streamed in earlier
    /// keeps its layout and only the tail is typeset again.
    func replaceChangedTail(with rendered: NSAttributedString) {
        guard let storage = textStorage else { return }
        let start = storage.firstDifference(from: rendered)
        guard start < max(storage.length, rendered.length) else { return }
        storage.replaceCharacters(
            in: NSRange(location: start, length: storage.length - start),
            with: rendered.attributedSubstring(from: NSRange(location: start, length: rendered.length - start))
        )
    }

    /// The text's height at `width`, from this view's own layout when it's already at that width,
    /// so the visible text isn't laid out a second time to the side.
    func measuredHeight(at width: CGFloat) -> CGFloat {
        if let layout = layoutManager, let container = textContainer, abs(container.size.width - width) < 0.5 {
            layout.ensureLayout(for: container)
            return ceil(layout.usedRect(for: container).height)
        }
        return MarkdownMeasure.height(of: textStorage ?? NSTextStorage(), width: width)
    }

    /// Lay the text out at the view's own width, inside its inset, whatever width was last measured.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let width = max(newSize.width - textContainerInset.width * 2, 0)
        if let container = textContainer, abs(container.size.width - width) > 0.5 {
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        needsLayout = true
    }

    /// Code block buttons go in once the text has its final width, not at each update or probe size.
    override func layout() {
        super.layout()
        placeCopyButtons()
        placeToggleButtons()
    }

    /// The full-width box a block of text sits in, in view coordinates.
    private func blockRect(_ range: NSRange) -> NSRect {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var box = layout.boundingRect(forGlyphRange: glyphs, in: container)
        box.origin.x = 0
        box.size.width = container.size.width
        return box.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// One copy button in the top-right corner of each code block.
    private func placeCopyButtons() {
        guard let storage = textStorage else { return }
        var blocks: [NSRange] = []
        storage.enumerateAttribute(.markdownCodeBlock, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { blocks.append(range) }
        }
        while copyButtons.count > blocks.count {
            copyButtons.removeLast().removeFromSuperview()
        }
        while copyButtons.count < blocks.count {
            let button = CodeCopyButton()
            addSubview(button)
            copyButtons.append(button)
        }
        for (button, range) in zip(copyButtons, blocks) {
            button.code = storage.attribute(.markdownCodeText, at: NSMaxRange(range) - 1, effectiveRange: nil) as? String ?? ""
            let box = blockRect(range).insetBy(dx: 0, dy: -6)
            button.frame = NSRect(x: box.maxX - 28, y: box.minY + 4, width: 24, height: 24)
        }
    }

    /// A Show All or Show Less button on each long code block's last line.
    private func placeToggleButtons() {
        guard let storage = textStorage else { return }
        var toggles: [(range: NSRange, title: String, block: Int)] = []
        storage.enumerateAttribute(.markdownCodeToggle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let title = value as? String,
                  let block = storage.attribute(.markdownCodeBlock, at: range.location, effectiveRange: nil) as? Int else { return }
            toggles.append((range, title, block))
        }
        while toggleButtons.count > toggles.count {
            toggleButtons.removeLast().removeFromSuperview()
        }
        while toggleButtons.count < toggles.count {
            let button = CodeToggleButton { [weak self] block in self?.toggleCode?(block) }
            addSubview(button)
            toggleButtons.append(button)
        }
        let inset = MarkdownRenderer.codeInset
        let whole = NSRange(location: 0, length: storage.length)
        for (button, toggle) in zip(toggleButtons, toggles) {
            button.show(title: toggle.title, block: toggle.block)
            // The toggle's line is the block's last; its empty text has no glyph box of its own.
            var code = NSRange()
            _ = storage.attribute(.markdownCodeBlock, at: toggle.range.location, longestEffectiveRange: &code, in: whole)
            let box = blockRect(code)
            let line = NSRect(x: box.minX, y: box.maxY - MarkdownRenderer.codeToggleHeight, width: box.width, height: MarkdownRenderer.codeToggleHeight)
            let size = button.fittingSize
            button.frame = NSRect(x: line.minX + inset - 4, y: line.midY - size.height / 2, width: size.width, height: size.height)
        }
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        if let url = link as? URL, openLink?(url) == true { return }
        super.clicked(onLink: link, at: charIndex)
    }

    /// NSTextView sets the I-beam on every mouse move, over its subviews too, and under anything
    /// floating above it, like the composer's mention list.
    override func mouseMoved(with event: NSEvent) {
        if overCopyButton(event) || isCovered(event) { NSCursor.arrow.set() } else { super.mouseMoved(with: event) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if overCopyButton(event) || isCovered(event) { NSCursor.arrow.set() } else { super.cursorUpdate(with: event) }
    }

    private func isCovered(_ event: NSEvent) -> Bool {
        guard let hit = window?.contentView?.superview?.hitTest(event.locationInWindow) else { return false }
        return !hit.isDescendant(of: self)
    }

    private func overCopyButton(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return copyButtons.contains { $0.frame.contains(point) } || toggleButtons.contains { $0.frame.contains(point) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard !extraMenuItems.isEmpty else { return menu }
        menu.insertItem(.separator(), at: 0)
        for item in extraMenuItems.reversed() {
            menu.insertItem(item.copy() as? NSMenuItem ?? item, at: 0)
        }
        return menu
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)

        storage.enumerateAttribute(.markdownCodeBlock, in: whole) { value, range, _ in
            guard value != nil else { return }
            let box = blockRect(range).insetBy(dx: 0, dy: -6)
            NSColor.quaternarySystemFill.setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        }
        storage.enumerateAttribute(.markdownQuote, in: whole) { value, range, _ in
            guard value != nil else { return }
            let box = blockRect(range)
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: box.minX, y: box.minY, width: 3, height: box.height), xRadius: 1.5, yRadius: 1.5).fill()
        }
        storage.enumerateAttribute(.markdownRule, in: whole) { value, range, _ in
            guard value != nil else { return }
            let box = blockRect(range)
            NSColor.separatorColor.setFill()
            NSRect(x: box.minX, y: box.midY, width: box.width, height: 1).fill()
        }
    }
}

/// Copies a code block's text, and shows a checkmark for a moment after.
final class CodeCopyButton: NSButton {
    var code = ""

    init() {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        toolTip = "Copy"
        target = self
        action = #selector(copyCode)
        showIcon("doc.on.doc")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func showIcon(_ symbol: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Copy")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }

    @objc private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        showIcon("checkmark")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.showIcon("doc.on.doc")
        }
    }
}

/// Opens or folds a long code block.
final class CodeToggleButton: NSButton {
    private var block = 0
    private let toggle: (Int) -> Void

    init(toggle: @escaping (Int) -> Void) {
        self.toggle = toggle
        super.init(frame: .zero)
        bezelStyle = .push
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        imagePosition = .imageTrailing
        imageHugsTitle = true
        target = self
        action = #selector(run)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(title: String, block: Int) {
        self.block = block
        guard self.title != title else { return }
        self.title = title
        let symbol = title == "Show Less" ? "chevron.up" : "chevron.down"
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
    }

    @objc private func run() {
        toggle(block)
    }
}

/// A menu item that runs a closure, for adding SwiftUI actions to an AppKit context menu.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        ClosureMenuItem(title, handler: handler)
    }
}
