import Foundation

/// Redirections that only drop a stream or swap stdout and stderr.
/// A digit is a file descriptor when it is its own token (`ls 2>/dev/null`).
/// Glued to the previous word (`ls2>/dev/null`), it is part of that word and the program is `ls2`.
enum ShellCommand {
    static func maskingHarmlessRedirections(_ command: String) -> String {
        var chars = Array(command)
        var index = 0
        while index < chars.count {
            if chars[index] == ">", let range = harmlessRange(in: chars, at: index) {
                for cursor in range {
                    chars[cursor] = " "
                }
                index = range.upperBound
            } else {
                index += 1
            }
        }
        return String(chars)
    }

    /// The span of a harmless redirection whose `>` is at `gt`, including its file descriptor.
    private static func harmlessRange(in chars: [Character], at gt: Int) -> Range<Int>? {
        if gt + 1 < chars.count, chars[gt + 1] == ">" { return nil }
        if gt > 0, chars[gt - 1] == ">" { return nil }

        let start = operatorStart(chars, gt)

        if gt + 1 < chars.count, chars[gt + 1] == "&" {
            let source = String(chars[start..<gt])
            let dest = digits(chars, from: gt + 2)
            guard !dest.isEmpty else { return nil }
            let destText = String(dest)
            let harmless = (source == "2" && destText == "1")
                || (source == "1" && destText == "2")
                || (source.isEmpty && destText == "2")
            guard harmless else { return nil }
            return start..<(gt + 2 + dest.count)
        }

        // `&>/dev/null` redirects both streams. `&&>/dev/null` is `&&` followed by `>/dev/null`.
        if gt > 0, chars[gt - 1] == "&", !(gt > 1 && chars[gt - 2] == "&"),
           let end = devNullEnd(chars, from: gt + 1) {
            return (gt - 1)..<end
        }

        let source = String(chars[start..<gt])
        guard source.isEmpty || source == "1" || source == "2" else { return nil }
        guard let end = devNullEnd(chars, from: gt + 1) else { return nil }
        return start..<end
    }

    /// Where the redirection operator starts. Digits count only as a file descriptor when they stand alone.
    private static func operatorStart(_ chars: [Character], _ gt: Int) -> Int {
        var start = gt
        while start > 0, chars[start - 1].isNumber {
            start -= 1
        }
        guard start < gt else { return gt }
        if start == 0 || isSeparator(chars[start - 1]) { return start }
        return gt
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || ";|&()".contains(character)
    }

    private static func digits(_ chars: [Character], from index: Int) -> ArraySlice<Character> {
        var end = index
        while end < chars.count, chars[end].isNumber {
            end += 1
        }
        return chars[index..<end]
    }

    private static let devNull = Array("/dev/null")

    private static func devNullEnd(_ chars: [Character], from index: Int) -> Int? {
        var cursor = index
        while cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\t" {
            cursor += 1
        }
        let end = cursor + devNull.count
        guard end <= chars.count, Array(chars[cursor..<end]) == devNull else { return nil }
        if end < chars.count, isPathCharacter(chars[end]) { return nil }
        return end
    }

    private static func isPathCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "/._-".contains(character)
    }
}
