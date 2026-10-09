import Testing
@testable import Desk

@Test func mentionsKeepWrittenOrderAndCollapseDuplicates() {
    #expect(Turn.mentionedAgents(in: "@grok @claude @grok") == [.grok, .claude])
    #expect(Turn.mentionedAgents(in: "@MUSE, then @Codex") == [.muse, .codex])
}

@Test func mentionsAreCaseInsensitiveAndWordBounded() {
    #expect(Turn.mentionedAgents(in: "email me@claude.com") == [])
    #expect(Turn.mentionedAgents(in: "@claudeextra") == [])
    #expect(Turn.mentionedAgents(in: "@allstars") == [])
    #expect(Turn.mentionedAgents(in: "(@Grok)") == [.grok])
    #expect(Turn.mentionedAgents(in: "start @codex.") == [.codex])
    #expect(Turn.mentionedAgents(in: "no mentions here") == [])
    #expect(Turn.mentionedAgents(in: "@") == [])
}

@Test func allMentionExpandsInAgentOrder() {
    #expect(AgentID.allCases == [.claude, .codex, .grok, .muse])
    #expect(Turn.mentionedAgents(in: "@all") == [.claude, .codex, .grok, .muse])
    #expect(Turn.mentionedAgents(in: "@ALL") == [.claude, .codex, .grok, .muse])
    #expect(Turn.mentionedAgents(in: "@grok @all") == [.grok, .claude, .codex, .muse])
    #expect(Turn.mentionedAgents(in: "@all @muse") == [.claude, .codex, .grok, .muse])
}

@Test func mentionQueryAtTheStartNoLettersAndAfterASpace() {
    #expect(Mention.query(in: "@", caret: 1) == Mention.Query(start: 0, end: 1, letters: ""))
    #expect(Mention.query(in: "@mu", caret: 3) == Mention.Query(start: 0, end: 3, letters: "mu"))
    #expect(Mention.query(in: "hi @", caret: 4) == Mention.Query(start: 3, end: 4, letters: ""))
    #expect(Mention.query(in: "hi @cod", caret: 7) == Mention.Query(start: 3, end: 7, letters: "cod"))
    #expect(Mention.query(in: "(@g", caret: 3) == Mention.Query(start: 1, end: 3, letters: "g"))
}

@Test func mentionQueryIgnoresAMidWordAtSign() {
    #expect(Mention.query(in: "a@b", caret: 3) == nil)
    #expect(Mention.query(in: "a@b", caret: 2) == nil)
    #expect(Mention.query(in: "foo_@bar", caret: 8) == nil)
}

@Test func mentionQueryRequiresTheCaretAtTheTokenEnd() {
    #expect(Mention.query(in: "@claude", caret: 4) == nil)
    #expect(Mention.query(in: "@claude", caret: 0) == nil)
    #expect(Mention.query(in: "hi @claude there", caret: 16) == nil)
    #expect(Mention.query(in: "@claude", caret: 7) == Mention.Query(start: 0, end: 7, letters: "claude"))
}

@Test func mentionChoicesMatchACaseInsensitivePrefix() {
    let everyone = Array(AgentID.allCases)
    #expect(Mention.choices(matching: "", among: everyone) == Mention.Choice.allCases)
    #expect(Mention.choices(matching: "c", among: everyone) == [.claude, .codex])
    #expect(Mention.choices(matching: "G", among: everyone) == [.grok])
    #expect(Mention.choices(matching: "al", among: everyone) == [.all])
    #expect(Mention.choices(matching: "z", among: everyone).isEmpty)
    #expect(Mention.choices(matching: "", among: [.claude]) == [.claude])
    #expect(Mention.choices(matching: "al", among: [.claude]).isEmpty)
    #expect(Mention.choices(matching: "", among: [.muse, .claude]) == [.muse, .claude, .all])
    #expect(Mention.choices(matching: "", among: []).isEmpty)
    #expect(Mention.Choice.all.symbolName == "person.3")
}

@Test func applyingAMentionReplacesThePartialToken() throws {
    let partial = try #require(Mention.query(in: "hi @cl there", caret: 6))
    let applied = Mention.apply(.claude, to: "hi @cl there", query: partial)
    #expect(applied.text == "hi @claude  there")
    #expect(applied.caret == 11)

    let atStart = Mention.apply(.all, to: "@", query: Mention.Query(start: 0, end: 1, letters: ""))
    #expect(atStart.text == "@all ")
    #expect(atStart.caret == 5)

    let atEnd = Mention.apply(.muse, to: "ask @m", query: Mention.Query(start: 4, end: 6, letters: "m"))
    #expect(atEnd.text == "ask @muse ")
    #expect(atEnd.caret == 10)
}

@Test func agentDisplayNames() {
    #expect(AgentID.claude.displayName == "Claude")
    #expect(AgentID.codex.displayName == "Codex")
    #expect(AgentID.grok.displayName == "Grok")
    #expect(AgentID.muse.displayName == "Muse")
}
