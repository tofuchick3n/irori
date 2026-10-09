import AppKit
import SwiftUI

/// One line of secondary text with a bright band sweeping across it. Core Animation runs the
/// sweep, so it costs the main thread nothing per frame; as a SwiftUI animation it re-rendered
/// the whole transcript on every frame while an agent worked.
struct ShimmerText: NSViewRepresentable {
    let text: String

    func makeNSView(context _: Context) -> ShimmerLabel {
        ShimmerLabel()
    }

    func updateNSView(_ view: ShimmerLabel, context _: Context) {
        view.text = Self.plain(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ShimmerLabel, context _: Context) -> CGSize? {
        let natural = view.naturalSize
        return CGSize(width: min(natural.width, proposal.width ?? natural.width), height: natural.height)
    }

    /// Step titles carry inline markdown, like `code`; the label shows just the words.
    static func plain(_ text: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else { return text }
        return String(parsed.characters)
    }
}

final class ShimmerLabel: NSView {
    private let base = ShimmerLabel.field(color: .secondaryLabelColor)
    private let bright = ShimmerLabel.field(color: .labelColor)
    private let band = CAGradientLayer()
    private var sweptWidth: CGFloat = 0

    var text = "" {
        didSet {
            guard text != oldValue else { return }
            base.stringValue = text
            bright.stringValue = text
            invalidateIntrinsicContentSize()
        }
    }

    var naturalSize: CGSize {
        base.intrinsicContentSize
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(base)
        addSubview(bright)
        bright.wantsLayer = true
        band.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func field(color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .preferredFont(forTextStyle: .callout)
        field.textColor = color
        field.lineBreakMode = .byTruncatingMiddle
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    override var intrinsicContentSize: NSSize {
        naturalSize
    }

    override func layout() {
        super.layout()
        base.frame = bounds
        bright.frame = bounds
        if bright.layer?.mask !== band { bright.layer?.mask = band }
        guard abs(bounds.width - sweptWidth) > 0.5 || band.animation(forKey: "sweep") == nil else { return }
        sweep()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { sweep() }
    }

    /// One band a third of the text wide, crossing it every 1.8 seconds.
    private func sweep() {
        sweptWidth = bounds.width
        let width = max(bounds.width * 0.36, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.frame = CGRect(x: -width, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = -width / 2
        animation.toValue = bounds.width + width / 2
        animation.duration = 1.8
        animation.repeatCount = .infinity
        band.add(animation, forKey: "sweep")
    }
}
