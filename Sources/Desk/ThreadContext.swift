/// The thread's tags, told to every agent so a thread tagged "Lumen Bikes" gets Lumen Bikes material
/// looked up without the user naming it each time.
enum ThreadContext {
    static func tagLine(_ tags: [String]) -> String? {
        var names: [String] = []
        var seen = Set<String>()
        for tag in tags {
            // One line, whatever was typed into the tag's name.
            let name = tag.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(TagLibrary.slug(name)).inserted else { continue }
            names.append("\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"")
        }
        guard let last = names.last else { return nil }
        let list = names.count == 1 ? last
            : names.count == 2 ? "\(names[0]) and \(last)"
            : names.dropLast().joined(separator: ", ") + ", and " + last
        let noun = names.count == 1 ? "tag" : "tags"
        return "Context: the user tagged this thread \(list). Unless they say otherwise, treat the \(noun) as the thread's topic, and when looking things up, start with material about \(names.count == 1 ? "it" : "them")."
    }
}
