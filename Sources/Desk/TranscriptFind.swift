import Foundation

/// One occurrence of the find text, as a range in a message's rendered text.
struct FindMatch: Equatable, Sendable {
    let messageID: Message.ID
    let range: NSRange
}

enum TranscriptFind {
    /// Every non-overlapping occurrence, ignoring case and diacritics.
    static func ranges(of query: String, in text: String) -> [NSRange] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let haystack = text as NSString
        var found: [NSRange] = []
        var start = 0
        while start < haystack.length {
            let range = haystack.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: NSRange(location: start, length: haystack.length - start)
            )
            guard range.location != NSNotFound else { break }
            found.append(range)
            start = NSMaxRange(range)
        }
        return found
    }

    /// Matches in the text people read: user messages and replies, as rendered, in thread order.
    @MainActor static func matches(in messages: [Message], query: String) -> [FindMatch] {
        messages.flatMap { message -> [FindMatch] in
            guard message.author != .notice, !message.body.isEmpty else { return [] }
            return ranges(of: query, in: plainText(message.body)).map { FindMatch(messageID: message.id, range: $0) }
        }
    }

    @MainActor private static var plainCache: [String: String] = [:]

    @MainActor private static func plainText(_ markdown: String) -> String {
        if let cached = plainCache[markdown] { return cached }
        if plainCache.count > 1_000 { plainCache.removeAll() }
        let text = MarkdownRenderer.render(markdown).string
        plainCache[markdown] = text
        return text
    }
}
