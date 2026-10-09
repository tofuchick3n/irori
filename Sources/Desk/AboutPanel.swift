import AppKit

/// The standard About panel, with links to the source and Takibi.
enum AboutPanel {
    @MainActor
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    static func credits() -> NSAttributedString {
        let credits = NSMutableAttributedString(string: "An independent side project that works with Takibi Base.\n")
        link("Source code", to: Brand.repository, in: credits)
        credits.append(NSAttributedString(string: "  ·  "))
        link("Takibi Base", to: Brand.takibiSite, in: credits)
        return credits
    }

    private static func link(_ text: String, to address: String, in credits: NSMutableAttributedString) {
        guard let url = URL(string: address) else { return }
        credits.append(NSAttributedString(string: text, attributes: [
            .link: url,
            .foregroundColor: NSColor.linkColor,
        ]))
    }
}
