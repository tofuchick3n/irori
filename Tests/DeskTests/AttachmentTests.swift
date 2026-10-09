import Foundation
import Synchronization
import Testing
@testable import Desk

private typealias DeskThread = Desk.Thread

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "desk-attach-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ name: String, _ bytes: Int = 4, in folder: URL) throws -> URL {
    let url = folder.appending(path: name, directoryHint: .notDirectory)
    try Data(repeating: 7, count: bytes).write(to: url)
    return url
}

@Test func copyKeepsNamesAndNumbersCollisions() throws {
    let source = try temporaryFolder()
    let workspace = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: workspace) }
    let plan = try write("plan.pdf", in: source)
    let other = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: other) }
    let samePlan = try write("plan.pdf", in: other)
    let noExtension = try write("notes", in: source)

    let first = Attachments.copy([plan, samePlan, noExtension], into: workspace)
    #expect(first.paths == ["attachments/plan.pdf", "attachments/plan 2.pdf", "attachments/notes"])
    #expect(first.failed.isEmpty)
    let second = Attachments.copy([plan, noExtension], into: workspace)
    #expect(second.paths == ["attachments/plan 3.pdf", "attachments/notes 2"])
    let missing = Attachments.copy([source.appending(path: "gone.txt")], into: workspace)
    #expect(missing.paths.isEmpty)
    #expect(missing.failed == ["gone.txt"])
}

@Test func imagesAreRecognisedByType() {
    #expect(Attachments.isImage("attachments/shot.PNG"))
    #expect(Attachments.isImage("a/b.heic"))
    #expect(!Attachments.isImage("attachments/plan.pdf"))
    #expect(!Attachments.isImage("attachments/notes"))
    #expect(Attachments.claudeMediaType("x.JPG") == "image/jpeg")
    #expect(Attachments.claudeMediaType("x.heic") == nil)
}

@Test func imagesGoOnTheTurnTheMessageIsFirstDelivered() {
    let workspace = URL(filePath: "/w")
    var first = Message(author: .user, body: "look")
    first.attachments = ["attachments/a.png", "attachments/plan.pdf"]
    var second = Message(author: .user, body: "and")
    second.attachments = ["attachments/b.jpg"]
    var agentImage = Message(author: .agent(.claude), body: "ok")
    agentImage.attachments = ["attachments/ignored.png"]
    let messages = [first, agentImage, second]

    #expect(Attachments.newImages(in: messages, seenThrough: nil, workspace: workspace).map(\.path) == ["/w/attachments/a.png", "/w/attachments/b.jpg"])
    #expect(Attachments.newImages(in: messages, seenThrough: 0, workspace: workspace).map(\.path) == ["/w/attachments/b.jpg"])
    #expect(Attachments.newImages(in: messages, seenThrough: 2, workspace: workspace).isEmpty)
}

@Test func promptListsAttachmentsByRelativePath() {
    var message = Message(author: .user, body: "see this")
    message.attachments = ["attachments/plan.pdf", "attachments/a.png"]
    #expect(Turn.prompt(messages: [message], seenThrough: nil) == "User: see this\nAttached: attachments/plan.pdf, attachments/a.png")
    #expect(Attachments.promptLine([]) == nil)
}

@Test func oldMessagesDecodeWithoutAttachments() throws {
    let json = #"{"id":"\#(UUID().uuidString)","author":{"user":{}},"body":"hi","createdAt":0}"#
    let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
    #expect(message.attachments.isEmpty)
    var withFiles = message
    withFiles.attachments = ["attachments/a.png"]
    let round = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(withFiles))
    #expect(round.attachments == ["attachments/a.png"])
}

@Test func claudeContentIsATextBlockThenBase64Images() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let png = try write("a.png", 3, in: folder)
    let big = try write("big.png", Attachments.claudeImageLimit + 1, in: folder)
    let heic = try write("c.heic", in: folder)

    let plain = Attachments.claudeContent(prompt: "hi", images: [])
    #expect(plain.content as? String == "hi")

    let result = Attachments.claudeContent(prompt: "hi", images: [png, big, heic])
    #expect(result.skipped == ["big.png", "c.heic"])
    let blocks = try #require(result.content as? [[String: Any]])
    #expect(blocks.count == 2)
    #expect(blocks[0]["type"] as? String == "text")
    #expect(blocks[0]["text"] as? String == "hi")
    let source = try #require(blocks[1]["source"] as? [String: Any])
    #expect(blocks[1]["type"] as? String == "image")
    #expect(source["type"] as? String == "base64")
    #expect(source["media_type"] as? String == "image/png")
    #expect(source["data"] as? String == Data(repeating: 7, count: 3).base64EncodedString())
}

@Test func claudeUserMessageKeepsStringContentWithoutImages() throws {
    let line = ClaudeCommand.userMessage("hello").line
    let object = try #require(jsonObject(from: line))
    let message = try #require(object["message"] as? [String: Any])
    #expect(message["content"] as? String == "hello")
}

@Test func claudeSessionNamesSkippedImagesOnce() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let big = try write("big.png", Attachments.claudeImageLimit + 1, in: folder)
    let stdin = AgentStdin()
    var session = ClaudeSession(stdin: stdin, prompt: "hi", images: [big]) { _ in .deny }
    session.sessionStarted()
    #expect(try session.events(from: #"{"type":"control_response"}"#) == [.notice(Attachments.skippedNotice(["big.png"]))])
    #expect(try session.events(from: #"{"type":"control_response"}"#).isEmpty)
}

@Test func codexTurnInputGainsLocalImageItems() throws {
    let params = CodexCommand.turnStartParams(threadID: "t", prompt: "p", model: nil, images: [URL(filePath: "/w/attachments/a.png")])
    let input = try #require(params["input"] as? [[String: Any]])
    #expect(input.count == 2)
    #expect(input[0]["type"] as? String == "text")
    #expect(input[1]["type"] as? String == "localImage")
    #expect(input[1]["path"] as? String == "/w/attachments/a.png")
    let none = CodexCommand.turnStartParams(threadID: "t", prompt: "p", model: nil)
    #expect((none["input"] as? [[String: Any]])?.count == 1)
}

@Test func museGetsImageFlagBeforeThePrompt() {
    let args = MuseCommand.arguments(
        prompt: "hi", session: "s", workspace: URL(filePath: "/w"),
        images: [URL(filePath: "/w/attachments/a.png"), URL(filePath: "/w/attachments/b.jpg")]
    )
    #expect(args.suffix(5) == ["--image", "/w/attachments/a.png", "--image", "/w/attachments/b.jpg", "hi"])
    #expect(!MuseCommand.arguments(prompt: "hi", session: "s", workspace: URL(filePath: "/w")).contains("--image"))
}

@MainActor
@Suite struct AttachmentSendTests {
    private final class Recorder: AgentRunner, Sendable {
        let calls = Mutex<[(prompt: String, images: [URL])]>([])
        func run(agent _: AgentID, prompt: String, session _: String?, workspace _: URL, model _: String?, effort _: String?, permissions: AgentPermissions, executable _: URL?, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
            calls.withLock { $0.append((prompt, permissions.images)) }
            return AsyncThrowingStream { continuation in
                continuation.yield(.text("ok"))
                continuation.finish()
            }
        }
    }

    private func make(_ runner: Recorder) throws -> (DeskModel, URL) {
        let directory = try temporaryFolder()
        let model = DeskModel(
            store: ThreadStore(directory: directory),
            runner: runner,
            defaults: UserDefaults(suiteName: "desk-attach-\(UUID().uuidString)")!,
            notifier: NoTurnNotifier(),
            isAppActive: { true }
        )
        return (model, directory)
    }

    private func settle(_ model: DeskModel) async throws {
        for _ in 0..<300 where model.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isRunning)
    }

    @Test func sendCopiesAttachmentsAndDeliversImagesOnce() async throws {
        let runner = Recorder()
        let (model, directory) = try make(runner)
        let source = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: source) }
        model.newThread()
        let threadID = try #require(model.selection)
        let image = try write("a.png", in: source)
        let pdf = try write("plan.pdf", in: source)
        model.addAttachments([image, pdf, source, image])
        #expect(model.attachments == [image, pdf])

        model.draft = "@claude look"
        model.send()
        #expect(model.attachments.isEmpty)
        try await settle(model)

        let message = try #require(model.selectedThread?.messages.first)
        #expect(message.attachments == ["attachments/a.png", "attachments/plan.pdf"])
        let workspace = model.workspaceURL(for: threadID)
        #expect(FileManager.default.fileExists(atPath: workspace.appending(path: "attachments/a.png").path(percentEncoded: false)))
        let reply = try #require(model.selectedThread?.messages.last)
        #expect(!reply.files.contains { $0.hasPrefix("attachments/") })

        model.draft = "@claude again"
        model.send()
        try await settle(model)
        let calls = runner.calls.withLock { $0 }
        #expect(calls.count == 2)
        #expect(calls[0].prompt.contains("Attached: attachments/a.png, attachments/plan.pdf"))
        #expect(calls[0].images.map(\.lastPathComponent) == ["a.png"])
        #expect(calls[1].images.isEmpty)
    }

    @Test func attachmentsAreKeptPerThreadAndSendableWithoutText() async throws {
        let runner = Recorder()
        let (model, directory) = try make(runner)
        let source = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: source) }
        model.newThread()
        let first = try #require(model.selection)
        let file = try write("notes.txt", in: source)
        model.addAttachments([file])
        model.threads.append(DeskThread())
        model.selection = model.threads.last?.id
        #expect(model.attachments.isEmpty)
        model.selection = first
        #expect(model.attachments == [file])
        model.removeAttachment(file)
        #expect(model.attachments.isEmpty)

        model.addAttachments([file])
        model.draft = ""
        model.send()
        try await settle(model)
        #expect(model.selectedThread?.messages.first?.attachments == ["attachments/notes.txt"])
    }
}
