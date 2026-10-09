import Foundation
import Testing
@testable import Desk

@Test func promptIncludesEveryMessageAfterTheCursor() {
    let messages = [
        Message(author: .user, body: "@grok @claude hi"),
        Message(author: .agent(.grok), body: "**Grok** heard: @grok @claude hi"),
        Message(author: .agent(.claude), body: "**Claude** heard: @grok @claude hi"),
        Message(author: .user, body: "next"),
    ]

    #expect(Turn.prompt(messages: messages, seenThrough: nil) == """
    User: @grok @claude hi
    Grok: **Grok** heard: @grok @claude hi
    Claude: **Claude** heard: @grok @claude hi
    User: next
    """)
    #expect(Turn.prompt(messages: messages, seenThrough: 1) == """
    Claude: **Claude** heard: @grok @claude hi
    User: next
    """)
    #expect(Turn.prompt(messages: messages, seenThrough: 2) == "User: next")
    #expect(Turn.prompt(messages: messages, seenThrough: 3) == "")
}

@Test func promptKeepsLaterLinesOfAMultilineMessage() {
    let messages = [
        Message(author: .user, body: "line one\nline two"),
        Message(author: .notice, body: "denied rm"),
    ]
    #expect(Turn.prompt(messages: messages, seenThrough: nil) == """
    User: line one
    line two
    Notice: denied rm
    """)
}

@Test func lastUserLineIsTheLastLineOfTheLastUserMessage() {
    #expect(Turn.lastUserLine(in: "User: @grok @claude hi") == "@grok @claude hi")
    #expect(Turn.lastUserLine(in: """
    User: @grok @claude hi
    Grok: **Grok** heard: @grok @claude hi
    """) == "@grok @claude hi")
    #expect(Turn.lastUserLine(in: """
    User: hello
    there
    Grok: seen
    User: final line
    """) == "final line")
    #expect(Turn.lastUserLine(in: "Grok: only") == "")
}
