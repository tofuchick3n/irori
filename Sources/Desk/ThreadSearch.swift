import Foundation

enum ThreadSearch {
    /// True when the title or message bodies together contain every word of the query,
    /// ignoring case and diacritics. A blank query matches everything.
    static func matches(_ thread: Thread, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = ([thread.title] + thread.messages.map(\.body)).joined(separator: "\n")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
