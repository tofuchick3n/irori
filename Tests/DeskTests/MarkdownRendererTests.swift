import AppKit
import Testing
@testable import Desk

@MainActor
struct MarkdownRendererTests {
    private func render(_ markdown: String) -> NSAttributedString {
        MarkdownRenderer.render(markdown)
    }

    @Test func blocksBecomeParagraphs() {
        let text = render("# Plan\n\nFirst *point* and **bold**.\n\nSecond paragraph.").string
        #expect(text == "Plan\nFirst point and bold.\nSecond paragraph.")
    }

    @Test func headingsAreLargerAndSemibold() {
        let out = render("## Findings\n\nBody")
        let heading = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let body = out.attribute(.font, at: out.length - 1, effectiveRange: nil) as? NSFont
        #expect((heading?.pointSize ?? 0) > (body?.pointSize ?? 0))
    }

    @Test func listsGetMarkersOncePerItem() {
        #expect(render("- one\n- two\n  - nested").string == "•\tone\n•\ttwo\n◦\tnested")
        #expect(render("1. first\n2. second").string == "1.\tfirst\n2.\tsecond")
    }

    @Test func codeBlockIsOneMonospacedBlock() {
        let out = render("Run:\n\n```sh\ntakibi version\ntakibi tasks list\n```\n\nDone.")
        #expect(out.string == "Run:\ntakibi version\ntakibi tasks list\nDone.")
        let start = (out.string as NSString).range(of: "takibi version").location
        let font = out.attribute(.font, at: start, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
        #expect(out.attribute(.markdownCodeBlock, at: start, effectiveRange: nil) != nil)
        var block = NSRange()
        _ = out.attribute(.markdownCodeBlock, at: start, longestEffectiveRange: &block, in: NSRange(location: 0, length: out.length))
        #expect((out.string as NSString).substring(with: block) == "takibi version\ntakibi tasks list\n")
        let second = (out.string as NSString).range(of: "takibi tasks").location
        let gap = { (index: Int) in (out.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore ?? -1 }
        #expect(gap(start) > 0)
        #expect(gap(second) == 0)
    }

    @Test func tablesAreCellsInATextTable() {
        let out = render("| Page | Clicks |\n|---|---|\n| /blog/a | 120 |\n| /blog/b | 4 |")
        #expect(out.string == "Page\nClicks\n/blog/a\n120\n/blog/b\n4")
        let last = out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil) as? NSParagraphStyle
        let cell = last?.textBlocks.first as? NSTextTableBlock
        #expect(cell?.table.numberOfColumns == 2)
        #expect(cell?.startingRow == 2)
        #expect(cell?.startingColumn == 1)
        let header = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(header?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(MarkdownRenderer.plainText(out) == "Page\tClicks\n/blog/a\t120\n/blog/b\t4")
    }

    @Test func blankTableCellsKeepTheirColumn() {
        let out = render("| a | b | c |\n|---|---|---|\n| | mid | |\n| left | | right |\n\nAfter")
        let text = out.string as NSString
        let column = { (word: String) in
            let style = out.attribute(.paragraphStyle, at: text.range(of: word).location, effectiveRange: nil) as? NSParagraphStyle
            return (style?.textBlocks.first as? NSTextTableBlock)?.startingColumn
        }
        #expect(column("mid") == 1)
        #expect(column("right") == 2)
        #expect(MarkdownRenderer.plainText(out) == "a\tb\tc\n\tmid\t\nleft\t\tright\nAfter")
        #expect(MarkdownRenderer.plainText(render("| x | y |\n|---|---|\n| Ada | |")) == "x\ty\nAda\t")
    }

    @Test func backToBackCodeBlocksStaySeparate() {
        let out = render("```\none\n```\n```\ntwo\n```")
        var blocks = 0
        out.enumerateAttribute(.markdownCodeBlock, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if value != nil { blocks += 1 }
        }
        #expect(blocks == 2)
    }

    @Test func linksInlineCodeAndQuotes() {
        let out = render("See [Takibi](https://takibibase.com) and `takibi ask`.\n\n> quoted")
        let link = (out.string as NSString).range(of: "Takibi")
        #expect(out.attribute(.link, at: link.location, effectiveRange: nil) as? URL == URL(string: "https://takibibase.com"))
        let code = (out.string as NSString).range(of: "takibi ask")
        #expect((out.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont)?.isFixedPitch == true)
        let quote = (out.string as NSString).range(of: "quoted")
        #expect(out.attribute(.markdownQuote, at: quote.location, effectiveRange: nil) != nil)
    }

    @Test func partialMarkdownWhileStreamingStillRenders() {
        #expect(render("Here is **bo").string.hasPrefix("Here is"))
        #expect(render("```sh\ntakibi ver").string.contains("takibi ver"))
    }

    @Test func pathLinksWithSpacesBecomeFileLinks() {
        let out = render("Done: [draft.md](/Users/me/Library/Application Support/Desk/draft.md)")
        #expect(out.string == "Done: draft.md")
        let link = out.attribute(.link, at: 7, effectiveRange: nil) as? URL
        #expect(link == URL(filePath: "/Users/me/Library/Application Support/Desk/draft.md"))
    }

    @Test func pathLinksInCodeBlocksStayAsWritten() {
        let out = render("```\n[a](/x y/z.md)\n```")
        #expect(out.string == "[a](/x y/z.md)")
    }

    @Test func webLinksAndTitlesAreUntouched() {
        let out = render("[site](https://takibibase.com \"Takibi\")")
        #expect(out.attribute(.link, at: 0, effectiveRange: nil) as? URL == URL(string: "https://takibibase.com"))
    }

    @Test func streamingOnlyChangesTheTail() {
        let earlier = render("Intro.\n\n```swift\nlet a = 1\nlet b")
        let later = render("Intro.\n\n```swift\nlet a = 1\nlet b = 2\n```")
        #expect(earlier.firstDifference(from: later) >= (earlier.string as NSString).range(of: "let b").location)
        #expect(later.firstDifference(from: later) == later.length)
        let restyled = render("Intro.\n===")
        #expect(render("Intro.").firstDifference(from: restyled) == 0)
    }

    @Test func codeStillBeingWrittenShowsALineCount() {
        let streaming = MarkdownRenderer.CodeFolding(streaming: true)
        let out = MarkdownRenderer.render("Here:\n\n```swift\nlet a = 1\nlet b = 2\n", folding: streaming)
        #expect(out.string == "Here:\nWriting code… 2 lines")
        let closed = MarkdownRenderer.render("Here:\n\n```swift\nlet a = 1\n```", folding: streaming)
        #expect(closed.string == "Here:\nlet a = 1")
    }

    @Test func longCodeFoldsUntilOpenedAndCopiesInFull() {
        let code = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let markdown = "```\n\(code)\n```\n\nAfter."
        let folded = MarkdownRenderer.render(markdown, folding: .init())
        #expect(folded.string.hasPrefix("line 1\nline 2"))
        #expect(!folded.string.contains("line 7"))
        let toggle = (folded.string as NSString).range(of: "\u{200B}").location
        #expect(folded.attribute(.markdownCodeToggle, at: toggle, effectiveRange: nil) as? String == "Show All 20 Lines")
        var block = NSRange()
        _ = folded.attribute(.markdownCodeBlock, at: 0, longestEffectiveRange: &block, in: NSRange(location: 0, length: folded.length))
        #expect(folded.attribute(.markdownCodeText, at: NSMaxRange(block) - 1, effectiveRange: nil) as? String == code)
        let id = folded.attribute(.markdownCodeBlock, at: toggle, effectiveRange: nil) as? Int
        #expect(id != nil)
        func alpha(_ text: String, in rendered: NSAttributedString) -> CGFloat? {
            let at = (rendered.string as NSString).range(of: text).location
            return (rendered.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor)?.alphaComponent
        }
        #expect(alpha("line 4", in: folded) == NSColor.labelColor.alphaComponent)
        #expect(alpha("line 5", in: folded) == 0.55)
        #expect(alpha("line 6", in: folded) == 0.25)
        // The faded lines follow light and dark like the rest of the text.
        let faded = folded.attribute(.foregroundColor, at: (folded.string as NSString).range(of: "line 6").location, effectiveRange: nil) as? NSColor
        var darkRed: CGFloat?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            darkRed = faded?.usingColorSpace(.sRGB)?.redComponent
        }
        #expect(darkRed == 1)

        let opened = MarkdownRenderer.render(markdown, folding: .init(expanded: [id ?? -1]))
        #expect(opened.string.contains("line 20\n\u{200B}\nAfter."))
        let shown = (opened.string as NSString).range(of: "\u{200B}").location
        #expect(opened.attribute(.markdownCodeToggle, at: shown, effectiveRange: nil) as? String == "Show Less")
        #expect(alpha("line 6", in: opened) == NSColor.labelColor.alphaComponent)
        #expect(render(markdown).string == code + "\nAfter.")
    }

    @Test func onlyAMatchingFenceClosesABlock() {
        #expect(MarkdownRenderer.endsInOpenFence("```swift\nlet a = 1"))
        #expect(!MarkdownRenderer.endsInOpenFence("```swift\nlet a = 1\n```"))
        #expect(MarkdownRenderer.endsInOpenFence("````md\n```swift\ncode\n```"))
        #expect(!MarkdownRenderer.endsInOpenFence("````md\n```swift\ncode\n```\n````"))
        #expect(MarkdownRenderer.endsInOpenFence("~~~\n```\n"))
    }
}
