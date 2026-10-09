import Testing
@testable import Desk

@Test func firstMessageWithoutAMentionGoesToClaude() {
    #expect(Turn.recipients(for: "hello", earlierUserTexts: []) == [.claude])
}

@Test func mentionsOverrideEarlierRecipients() {
    #expect(Turn.recipients(for: "@muse @codex look", earlierUserTexts: ["@grok hi"]) == [.muse, .codex])
}

@Test func noMentionRepeatsThePreviousUserMessageRecipients() {
    #expect(Turn.recipients(for: "follow up", earlierUserTexts: ["@grok @claude hi"]) == [.grok, .claude])
    #expect(Turn.recipients(for: "third", earlierUserTexts: ["@grok hi", "plain follow up"]) == [.grok])
}

@Test func noMentionChainsBackToTheFirstMessageDefault() {
    #expect(Turn.recipients(for: "still", earlierUserTexts: ["hello", "again"]) == [.claude])
}

@Test func allMentionAddressesEveryAgent() {
    #expect(Turn.recipients(for: "@all go", earlierUserTexts: ["@grok only"]) == Array(AgentID.allCases))
}

@Test func titleUsesTheFirstFortyCharacters() {
    #expect(Turn.title(for: "@grok hello") == "@grok hello")
    #expect(Turn.title(for: "hello\nworld") == "hello world")
    let long = String(repeating: "a", count: 50)
    #expect(Turn.title(for: long) == String(repeating: "a", count: 40))
    #expect(Turn.title(for: "   ") == Thread.untitled)
}

@Test func theDefaultAgentAnswersUntilSomeoneIsMentioned() {
    #expect(Turn.recipients(for: "hello", earlierUserTexts: [], fallback: .grok) == [.grok])
    #expect(Turn.recipients(for: "again", earlierUserTexts: ["hello"], fallback: .muse) == [.muse])
    #expect(Turn.recipients(for: "again", earlierUserTexts: ["@codex hi"], fallback: .muse) == [.codex])
}
