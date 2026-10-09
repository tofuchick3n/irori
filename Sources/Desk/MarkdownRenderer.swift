import AppKit

extension NSAttributedString.Key {
    /// Block kinds the text view draws behind or beside the text.
    static let markdownCodeBlock = NSAttributedString.Key("desk.markdown.codeBlock")
    static let markdownQuote = NSAttributedString.Key("desk.markdown.quote")
    static let markdownRule = NSAttributedString.Key("desk.markdown.rule")
    /// A code block's whole text, for copying, even when only part of it is shown. It sits on the
    /// block's last character, so a streaming block's growing text leaves its earlier lines alone.
    static let markdownCodeText = NSAttributedString.Key("desk.markdown.codeText")
    /// The title of the button that opens or folds a long code block, on the empty line it sits on.
    /// The block it belongs to is the line's `markdownCodeBlock` value.
    static let markdownCodeToggle = NSAttributedString.Key("desk.markdown.codeToggle")
}

extension NSColor {
    /// The label color at `alpha`, still following light and dark. `withAlphaComponent` on its own
    /// keeps the label color of the appearance it was made in.
    static func label(alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { _ in NSColor.labelColor.withAlphaComponent(alpha) }
    }
}

/// Markdown to a styled string for a plain AppKit text view: headings, paragraphs, nested lists,
/// code blocks, quotes, rules, and tables, with bold, italic, code, strikethrough, and links inline.
enum MarkdownRenderer {
    static let bodySize: CGFloat = 14
    private static let headingScales: [CGFloat] = [1.35, 1.2, 1.1, 1, 1, 1]
    private static let blockGap: CGFloat = 12
    private static let listGap: CGFloat = 4
    private static let listIndent: CGFloat = 18
    static let codeInset: CGFloat = 12
    /// Code blocks longer than this fold to their first `foldedLines` until opened.
    private static let foldLimit = 12
    private static let foldedLines = 6

    /// How the text view shows code blocks: long ones folded unless opened, and while a reply
    /// streams, a block still being written as a line count instead of its growing text.
    struct CodeFolding: Equatable {
        var streaming = false
        var expanded: Set<Int> = []
    }

    /// Without `folding`, every code block renders in full, as find and copy expect.
    static func render(_ markdown: String, folding: CodeFolding? = nil) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: bracketingPathLinks(markdown), options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: NSColor.labelColor])
        }
        var builder = Builder()
        builder.folding = folding
        builder.writingLast = folding?.streaming == true && endsInOpenFence(markdown)
        for run in parsed.runs {
            builder.append(String(parsed[run.range].characters), run: run)
        }
        return builder.finish()
    }

    /// Agents link local files by path, often with spaces (Application Support), which markdown
    /// only accepts inside angle brackets. Code blocks are left alone.
    static func bracketingPathLinks(_ markdown: String) -> String {
        guard markdown.contains("](/") || markdown.contains("](~/") else { return markdown }
        var inFence = false
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            guard !inFence else { return String(line) }
            return String(line).replacing(pathLink) { match in "](<\(match.output.1)>)" }
        }
        return lines.joined(separator: "\n")
    }

    nonisolated(unsafe) private static let pathLink = /\]\(((?:\/|~\/)[^()<>"\n]* [^()<>"\n]*)\)/

    /// Whether the text stops inside a code block, its closing fence not written yet.
    /// A fence closes only on a bare run of its own mark at least as long, so a ```` block can
    /// hold ``` lines.
    static func endsInOpenFence(_ markdown: String) -> Bool {
        var open: (mark: Character, length: Int)?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let mark = trimmed.first, mark == "`" || mark == "~" else { continue }
            let length = trimmed.prefix { $0 == mark }.count
            guard length >= 3 else { continue }
            if let fence = open {
                if mark == fence.mark, length >= fence.length, trimmed.dropFirst(length).allSatisfy(\.isWhitespace) {
                    open = nil
                }
            } else {
                open = (mark, length)
            }
        }
        return open != nil
    }

    static func lineCount(_ count: Int) -> String {
        count == 1 ? "1 line" : "\(count) lines"
    }

    /// Height of the line a code block's fold button sits on.
    static let codeToggleHeight: CGFloat = 30

    /// A bare path link becomes a file URL, so clicking it opens the file.
    static func fileURL(for link: URL) -> URL {
        guard link.scheme == nil else { return link }
        let path = link.path(percentEncoded: false)
        if path.hasPrefix("/") { return URL(filePath: path) }
        if path.hasPrefix("~/") { return URL(filePath: (path as NSString).expandingTildeInPath) }
        return link
    }

    /// One block being built: where it starts in the output and how it's laid out.
    struct Block {
        var id: Int
        var start: Int
        var kind: Kind
        var depth = 0
        var spacingBefore: CGFloat
        var cell: NSTextTableBlock?
        var code = ""

        enum Kind: Equatable {
            case paragraph, heading(Int), listItem, code, quote, rule
            case tableCell(header: Bool)
        }
    }

    private struct Builder {
        let output = NSMutableAttributedString()
        private var block: Block?
        private var lastListItem: Int?
        private var lastList: Int?
        private var previousKind: Block.Kind?
        private var tables: [Int: NSTextTable] = [:]
        /// The table row being filled, and the next column it has a cell for.
        private var openRow: (identity: Int, index: Int, table: NSTextTable, next: Int)?
        private var tableMargin: CGFloat = 0
        var folding: CodeFolding?
        /// The last block is a code block whose closing fence hasn't streamed in yet.
        var writingLast = false
        private var finishing = false

        mutating func append(_ rawText: String, run: AttributedString.Runs.Run) {
            let components = run.presentationIntent?.components ?? []
            let cell = components.first { if case .tableCell = $0.kind { true } else { false } }
            let row = components.first {
                switch $0.kind {
                case .tableRow, .tableHeaderRow: true
                default: false
                }
            }
            let blockID = components.first?.identity ?? -1

            if blockID != block?.id {
                startBlock(id: blockID, components: components, cell: cell, row: row)
            }

            var text = rawText
            let inline = run.inlinePresentationIntent
            if inline?.contains(.softBreak) == true { text = " " }
            if inline?.contains(.lineBreak) == true { text = "\u{2028}" }
            guard let kind = block?.kind else { return }
            if kind == .code {
                block?.code += text
                return
            }
            if kind == .rule { text = " " }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: kind == .rule ? NSFont.systemFont(ofSize: 4) : MarkdownRenderer.font(for: kind, inline: inline),
                .foregroundColor: kind == .quote ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
            if inline?.contains(.code) == true, kind != .code {
                attributes[.backgroundColor] = NSColor.quaternarySystemFill
            }
            if inline?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = MarkdownRenderer.fileURL(for: link)
            }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }

        private mutating func startBlock(
            id: Int,
            components: [PresentationIntent.IntentType],
            cell: PresentationIntent.IntentType?,
            row: PresentationIntent.IntentType?
        ) {
            finishBlock(addNewline: true)
            var kind = Block.Kind.paragraph
            var depth = 0
            var list: Int?
            var listItem: (identity: Int, ordinal: Int)?
            var ordered = false
            var tableCell: NSTextTableBlock?
            for component in components {
                switch component.kind {
                case .header(let level): kind = .heading(level)
                case .codeBlock: kind = .code
                case .thematicBreak: kind = .rule
                case .blockQuote where kind == .paragraph: kind = .quote
                case .listItem(let ordinal):
                    if listItem == nil { listItem = (component.identity, ordinal) }
                    if kind == .paragraph { kind = .listItem }
                case .orderedList, .unorderedList:
                    depth += 1
                    if list == nil {
                        list = component.identity
                        if case .orderedList = component.kind { ordered = true }
                    }
                case .table(let columns):
                    let header = row.map { if case .tableHeaderRow = $0.kind { true } else { false } } ?? false
                    kind = .tableCell(header: header)
                    tableCell = cellBlock(table: component.identity, columns: columns.count, cell: cell, row: row)
                default: break
                }
            }
            if tableCell == nil { closeRow() }

            let first = output.length == 0
            var spacing = first ? 0 : MarkdownRenderer.blockGap
            switch (previousKind, kind) {
            case (.listItem?, .listItem): spacing = MarkdownRenderer.listGap
            case (_, .tableCell): spacing = 0
            case (.heading?, _): spacing = 4
            default: break
            }
            if case .heading(let level) = kind, !first {
                spacing = MarkdownRenderer.bodySize * MarkdownRenderer.headingScales[min(level, 6) - 1] * 1.1
            }
            if kind == .code || previousKind == .code, !first { spacing += 6 }
            block = Block(id: id, start: output.length, kind: kind, depth: depth, spacingBefore: spacing, cell: tableCell)

            if let listItem, listItem.identity != lastListItem {
                let marker = ordered ? "\(listItem.ordinal)." : (depth > 1 ? "◦" : "•")
                output.append(NSAttributedString(string: marker + "\t", attributes: [
                    .font: MarkdownRenderer.font(for: .paragraph, inline: nil),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                lastListItem = listItem.identity
            }
            if listItem == nil { lastListItem = nil }
            lastList = list
        }

        /// The table cell a paragraph sits in, making the table on its first cell. Cells markdown
        /// leaves blank get empty ones, since a text table places cells in order, not by column.
        private mutating func cellBlock(
            table identity: Int,
            columns: Int,
            cell: PresentationIntent.IntentType?,
            row: PresentationIntent.IntentType?
        ) -> NSTextTableBlock {
            if tables[identity] == nil {
                closeRow()
                tables[identity] = MarkdownRenderer.makeTable(columns: max(columns, 1))
                tableMargin = output.length == 0 ? 0 : MarkdownRenderer.blockGap
            }
            let table = tables[identity]!
            let rowID = row?.identity ?? -1
            if openRow?.identity != rowID {
                let index = openRow.map { $0.table === table ? $0.index + 1 : 0 } ?? 0
                closeRow()
                openRow = (rowID, index, table, 0)
            }
            let index = if case .tableCell(let index) = cell?.kind { index } else { 0 }
            let column = max(min(index, table.numberOfColumns - 1), openRow?.next ?? 0)
            fillRow(upTo: column)
            openRow?.next = column + 1
            return makeCell(row: openRow?.index ?? 0, column: column, in: table)
        }

        private func makeCell(row: Int, column: Int, in table: NSTextTable) -> NSTextTableBlock {
            let cell = MarkdownRenderer.makeCell(in: table, row: row, column: min(column, table.numberOfColumns - 1))
            if row == 0, tableMargin > 0 {
                cell.setWidth(tableMargin, type: .absoluteValueType, for: .margin, edge: .minY)
            }
            return cell
        }

        /// Empty cells for the open row's columns before `end`; the last one in the text can't end in a newline.
        private mutating func fillRow(upTo end: Int, endsText: Bool = false) {
            guard let row = openRow, row.next < end else { return }
            for column in row.next..<end {
                let cell = makeCell(row: row.index, column: column, in: row.table)
                let filler = Block(id: -1, start: 0, kind: .tableCell(header: false), spacingBefore: 0, cell: cell)
                output.append(NSAttributedString(string: endsText && column == end - 1 ? "\u{200B}" : "\n", attributes: [
                    .font: MarkdownRenderer.font(for: .paragraph, inline: nil),
                    .paragraphStyle: MarkdownRenderer.paragraphStyle(for: filler),
                ]))
            }
            openRow?.next = end
        }

        private mutating func closeRow(endsText: Bool = false) {
            guard let row = openRow else { return }
            fillRow(upTo: row.table.numberOfColumns, endsText: endsText)
            openRow = nil
        }

        private mutating func finishBlock(addNewline: Bool) {
            guard let block else { return }
            if addNewline {
                if block.kind == .code { appendCode(of: block) }
                output.append(NSAttributedString(string: "\n", attributes: [.font: MarkdownRenderer.font(for: block.kind, inline: nil)]))
            }
            let range = NSRange(location: block.start, length: output.length - block.start)
            guard range.length > 0 else { return }
            output.addAttribute(.paragraphStyle, value: MarkdownRenderer.paragraphStyle(for: block), range: range)
            if block.kind == .code {
                // Each code line is its own paragraph, so a line streaming in re-lays out only that
                // line; the gap above the block belongs to its first line alone.
                let first = output.mutableString.paragraphRange(for: NSRange(location: block.start, length: 0))
                let rest = NSRange(location: NSMaxRange(first), length: NSMaxRange(range) - NSMaxRange(first))
                var later = block
                later.spacingBefore = 0
                if rest.length > 0 {
                    output.addAttribute(.paragraphStyle, value: MarkdownRenderer.paragraphStyle(for: later), range: rest)
                }
                output.enumerateAttribute(.markdownCodeToggle, in: range) { value, toggle, _ in
                    guard value != nil else { return }
                    let style = MarkdownRenderer.paragraphStyle(for: later).mutableCopy() as! NSMutableParagraphStyle
                    style.minimumLineHeight = MarkdownRenderer.codeToggleHeight
                    style.maximumLineHeight = MarkdownRenderer.codeToggleHeight
                    output.addAttribute(.paragraphStyle, value: style, range: toggle)
                }
            }
            switch block.kind {
            // Each block's own value, so back-to-back code blocks stay separate runs.
            case .code:
                output.addAttribute(.markdownCodeBlock, value: block.id, range: range)
                output.addAttribute(.markdownCodeText, value: Self.trimmed(block.code), range: NSRange(location: NSMaxRange(range) - 1, length: 1))
            case .quote: output.addAttribute(.markdownQuote, value: true, range: range)
            case .rule: output.addAttribute(.markdownRule, value: true, range: range)
            default: break
            }
            previousKind = block.kind
            self.block = nil
        }

        private static func trimmed(_ code: String) -> String {
            code.hasSuffix("\n") ? String(code.dropLast()) : code
        }

        /// A code block's text, or as much of it as `folding` shows.
        private mutating func appendCode(of block: Block) {
            let code = Self.trimmed(block.code)
            let font = MarkdownRenderer.font(for: .code, inline: nil)
            let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
            func append(_ text: String, _ attributes: [NSAttributedString.Key: Any]) {
                output.append(NSAttributedString(string: text, attributes: attributes))
            }
            let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            guard let folding else { return append(code, plain) }
            if finishing, writingLast {
                return append("Writing code… " + MarkdownRenderer.lineCount(lines.count), [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            }
            guard lines.count > MarkdownRenderer.foldLimit else { return append(code, plain) }
            let expanded = folding.expanded.contains(block.id)
            if expanded {
                append(code, plain)
            } else {
                // The last lines shown fade out, so the fold reads as more to come.
                let shown = lines.prefix(MarkdownRenderer.foldedLines)
                let fading = [0.55, 0.25]
                for (index, line) in shown.enumerated() {
                    let fromEnd = shown.count - 1 - index
                    var attributes = plain
                    if fromEnd < fading.count {
                        attributes[.foregroundColor] = NSColor.label(alpha: fading[fading.count - 1 - fromEnd])
                    }
                    append((index > 0 ? "\n" : "") + line, attributes)
                }
            }
            // An empty line the text view puts a button over.
            append("\n\u{200B}", [
                .font: font,
                .markdownCodeToggle: expanded ? "Show Less" : "Show All \(lines.count) Lines",
            ])
        }

        mutating func finish() -> NSAttributedString {
            finishing = true
            if block?.kind == .code, let block { appendCode(of: block) }
            if let row = openRow, row.next < row.table.numberOfColumns {
                finishBlock(addNewline: true)
                closeRow(endsText: true)
            } else {
                finishBlock(addNewline: false)
            }
            MarkdownRenderer.sizeColumns(in: output)
            return output
        }
    }

    static func font(for kind: Block.Kind, inline: InlinePresentationIntent?) -> NSFont {
        var size = bodySize
        var weight = NSFont.Weight.regular
        switch kind {
        case .heading(let level):
            size *= headingScales[min(level, 6) - 1]
            weight = .semibold
        case .code:
            return NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
        case .tableCell(let header) where header:
            weight = .semibold
        default:
            break
        }
        if inline?.contains(.code) == true {
            return NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: weight)
        }
        if inline?.contains(.stronglyEmphasized) == true {
            weight = .semibold
        }
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if inline?.contains(.emphasized) == true {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    private static func paragraphStyle(for block: Block) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacingBefore = block.spacingBefore
        if let cell = block.cell {
            style.textBlocks = [cell]
        }
        switch block.kind {
        case .listItem:
            let indent = CGFloat(block.depth) * listIndent
            style.firstLineHeadIndent = indent - listIndent + 2
            style.headIndent = indent
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        case .code:
            style.firstLineHeadIndent = codeInset
            style.headIndent = codeInset
            // Room for the copy button on the first line.
            style.tailIndent = -(codeInset + 24)
            style.lineSpacing = 1
        case .quote:
            style.firstLineHeadIndent = 14
            style.headIndent = 14
        default:
            break
        }
        return style
    }

    static func makeTable(columns: Int) -> NSTextTable {
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        return table
    }

    /// A cell with room around its text and a hairline under it; the first column lines up with the text.
    static func makeCell(in table: NSTextTable, row: Int, column: Int) -> NSTextTableBlock {
        let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        cell.setWidth(column == 0 ? 0 : 8, type: .absoluteValueType, for: .padding, edge: .minX)
        cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
        cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
        cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
        cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        cell.setBorderColor(.separatorColor, for: .maxY)
        cell.verticalAlignment = .topAlignment
        return cell
    }

    /// Gives narrow columns the width they need and shares what's left among the wide ones,
    /// as fractions of a typical reading width so the table still fits a narrower window.
    private static func sizeColumns(in output: NSMutableAttributedString) {
        var cells: [ObjectIdentifier: [(block: NSTextTableBlock, width: CGFloat)]] = [:]
        output.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: output.length)) { value, range, _ in
            guard let cell = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock else { return }
            let text = output.attributedSubstring(from: range)
            let width = ceil(text.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: 100), options: []).width)
                + cell.width(for: .padding, edge: .minX) + cell.width(for: .padding, edge: .maxX) + 6
            cells[ObjectIdentifier(cell.table), default: []].append((cell, width))
        }
        let reference: CGFloat = 680
        for tableCells in cells.values {
            guard let columns = tableCells.first?.block.table.numberOfColumns else { continue }
            var natural = Array(repeating: CGFloat(24), count: columns)
            for (block, width) in tableCells {
                natural[block.startingColumn] = max(natural[block.startingColumn], width)
            }
            var shares = Array(repeating: CGFloat(0), count: columns)
            var open = Set(0..<columns)
            var left = reference
            while !open.isEmpty {
                let fair = left / CGFloat(open.count)
                let fitting = open.filter { natural[$0] <= fair }
                if fitting.isEmpty {
                    for column in open { shares[column] = fair }
                    break
                }
                for column in fitting {
                    shares[column] = natural[column]
                    left -= natural[column]
                    open.remove(column)
                }
            }
            let total = shares.reduce(0, +)
            for (block, _) in tableCells {
                block.setValue(shares[block.startingColumn] / total * 100, type: .percentageValueType, for: .width)
            }
        }
    }

    /// The rendered text for copying, with table cells in a row joined by tabs instead of new lines.
    static func plainText(_ rendered: NSAttributedString) -> String {
        let text = NSMutableString(string: rendered.string)
        rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length), options: .reverse) { value, range, _ in
            guard let cell = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock,
                  cell.startingColumn < cell.table.numberOfColumns - 1,
                  range.length > 0,
                  text.character(at: NSMaxRange(range) - 1) == 0x0A else { return }
            text.replaceCharacters(in: NSRange(location: NSMaxRange(range) - 1, length: 1), with: "\t")
        }
        return (text as String).replacingOccurrences(of: "\u{200B}", with: "")
    }
}
