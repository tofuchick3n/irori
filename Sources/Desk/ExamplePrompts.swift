enum ExamplePrompts {
    /// Three starters that fill the draft; each ends where the user keeps typing.
    static func make(active: [AgentID]) -> [String] {
        guard let first = active.first else { return [] }
        guard active.count >= 2, let last = active.last else {
            return [
                "@\(first.rawValue) Poke holes in this idea: ",
                "@\(first.rawValue) Compare two ways to ",
                "@\(first.rawValue) Argue the opposite of ",
            ]
        }
        return [
            "@all Poke holes in this idea: ",
            "@\(first.rawValue) @\(active[1].rawValue) Compare two ways to ",
            "@\(last.rawValue) Argue the opposite of ",
        ]
    }
}
