import AVFoundation
import Foundation
import Testing
@testable import Desk

@Test func dictatedTextJoinsWithSingleSpaces() {
    var text = DictatedText(base: "Hi")
    #expect(text.draft == "Hi")
    text.add(Whistle.Piece(text: " Ask Codex", pending: "and"))
    #expect(text.draft == "Hi Ask Codex and")
    text.add(Whistle.Piece(text: "and Grok", pending: nil))
    #expect(text.draft == "Hi Ask Codex and Grok")

    var afterNewline = DictatedText(base: "List:\n")
    afterNewline.add(Whistle.Piece(text: "one", pending: ""))
    #expect(afterNewline.draft == "List:\none")
}

@Test func theGateSendsSpeechWithALeadInAndDropsTheRest() {
    // The fake detector hears speech wherever a sample is 1.
    var gate = SpeechGate { $0.contains(1) ? 0.9 : 0.01 }
    let quiet = [Float](repeating: 0.5, count: 16_000)
    let speech = [Float](repeating: 1, count: 16_000)
    #expect(gate.admit(quiet).isEmpty)
    let first = gate.admit(speech)
    #expect(first.count == SpeechGate.leadIn + speech.count)
    #expect(first.prefix(SpeechGate.leadIn).allSatisfy { $0 == 0.5 })
    // The second after speech is judged with the speech before it, so word endings go through.
    #expect(gate.admit(quiet) == quiet)
    #expect(gate.admit(quiet).isEmpty)
    #expect(gate.admit([]).isEmpty)
}

@Test func quietSpeechKeepsGoingButDoesNotStart() {
    // Judged on the newest sample alone, so context doesn't carry the loud second along.
    var gate = SpeechGate { [0.9, 0.15, 0.06][[1, 0.2, 0.05].firstIndex(of: $0.last ?? 0) ?? 2] }
    let whisper = [Float](repeating: 0.2, count: 16_000)
    let dip = [Float](repeating: 0.05, count: 16_000)
    #expect(gate.admit(whisper).isEmpty)
    #expect(gate.admit([Float](repeating: 1, count: 16_000)).count == SpeechGate.leadIn + 16_000)
    #expect(gate.admit(whisper) == whisper)
    // One dip doesn't end it: the whisper after it still keeps going.
    #expect(gate.admit(dip).isEmpty)
    #expect(gate.admit(whisper).count == SpeechGate.leadIn + 16_000)
    // Two misses in a row do.
    #expect(gate.admit(dip).isEmpty)
    #expect(gate.admit(dip).isEmpty)
    #expect(gate.admit(whisper).isEmpty)
}

@Test func paddingCoversTheLastSample() {
    #expect(SpeechDetector.paddedLength(100) == 16_000)
    #expect(SpeechDetector.paddedLength(16_000) == 16_000)
    #expect(SpeechDetector.paddedLength(16_001) == 24_000)
    #expect(SpeechDetector.paddedLength(16_000 + 4_800) == 24_000)
    #expect(SpeechDetector.paddedLength(24_001) == 32_000)
}

@Test func theLeadInIsOnlyAudioThatWasNotSent() {
    var gate = SpeechGate { $0.last == 1 ? 0.9 : 0.01 }
    let speech = [Float](repeating: 1, count: 16_000)
    #expect(gate.admit(speech) == speech)
    // A short dropped piece, then speech: the lead-in is that piece, not the end of the speech before.
    let gap = [Float](repeating: 0.5, count: 2_000)
    #expect(gate.admit(gap).isEmpty)
    #expect(gate.admit(gap).isEmpty)
    #expect(gate.admit(speech) == gap + gap + speech)
}

@Test func roomNoiseIsNotSpeech() {
    for noise in [brownNoise(seconds: 2, level: 0.01), brownNoise(seconds: 2, level: 0.05), [Float](repeating: 0, count: 8_000)] {
        #expect(SpeechDetector.confidence(noise) < SpeechGate.threshold)
    }
}

/// Like a quiet room: the noise Whistle turns into "Thank you." when nothing gates it.
private func brownNoise(seconds: Int, level: Float) -> [Float] {
    var generator = SystemRandomNumberGenerator()
    var value: Float = 0
    return (0..<(16_000 * seconds)).map { _ in
        value = 0.98 * value + Float.random(in: -1...1, using: &generator) * 0.1
        return value * level
    }
}

private let fetchedWhistleWeights: URL? = {
    let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".build/whistle/whistle.cact")
    return FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) ? file : nil
}()

/// Runs the real model on speech from `say`, so it's opt-in like the other live tests:
/// `DESK_LIVE=1 swift test --disable-sandbox --filter Whistle`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DESK_LIVE"] == "1" && fetchedWhistleWeights != nil))
struct WhistleTests {
    static let weights = fetchedWhistleWeights

    static let sentence = "Grok, can you check what Muse said about Takibi?"

    @Test func transcribesAClip() async throws {
        let samples = try await Self.speech(Self.sentence)
        try await Whistle.shared.load(try #require(Self.weights))
        let text = try await Whistle.shared.transcribe(samples)
        #expect(Self.words(text).contains("grok"))
        #expect(Self.words(text).contains("takibi"))
    }

    @Test func streamsAboutASecondAtATime() async throws {
        let samples = try await Self.speech(Self.sentence)
        try await Whistle.shared.load(try #require(Self.weights))
        _ = try? await Whistle.shared.finishStream()
        var text = DictatedText(base: "")
        for start in stride(from: 0, to: samples.count, by: 16_000) {
            text.add(try await Whistle.shared.stream(Array(samples[start..<min(start + 16_000, samples.count)])))
        }
        text.add(try await Whistle.shared.finishStream())
        #expect(text.pending.isEmpty)
        #expect(Self.words(text.draft).contains("muse"))
        #expect(Self.words(text.draft).contains("takibi"))
    }

    /// "Yes" said just before stopping, after a quiet second.
    @Test func aShortWordAfterQuietIsHeard() async throws {
        let word = try await Self.speech("Yes.")
        let start = try #require(word.firstIndex { abs($0) > 0.01 })
        let tail = Array(word[start..<min(start + 4_800, word.count)])
        #expect(SpeechDetector.confidence(brownNoise(seconds: 1, level: 0.01) + tail) >= SpeechGate.threshold)
    }

    @Test func roomNoiseWritesNothing() async throws {
        try await Whistle.shared.load(try #require(Self.weights))
        // Ungated, noise like this usually comes back as "Thank you."
        #expect(try await Self.dictate(brownNoise(seconds: 4, level: 0.01)) == "")
    }

    @Test func speechBetweenNoiseComesThrough() async throws {
        try await Whistle.shared.load(try #require(Self.weights))
        let speech = try await Self.speech(Self.sentence)
        let text = try await Self.dictate(brownNoise(seconds: 2, level: 0.01) + speech + brownNoise(seconds: 2, level: 0.01))
        #expect(Self.words(text).contains("muse"))
        #expect(Self.words(text).contains("takibi"))
        #expect(!Self.words(text).contains("thank"))
    }

    /// What dictation does with a recording: gated one-second passes, then the end of the stream.
    private static func dictate(_ samples: [Float]) async throws -> String {
        _ = try? await Whistle.shared.finishStream()
        var gate = SpeechGate()
        var text = DictatedText(base: "")
        for start in stride(from: 0, to: samples.count, by: 16_000) {
            let admitted = gate.admit(Array(samples[start..<min(start + 16_000, samples.count)]))
            if !admitted.isEmpty {
                text.add(try await Whistle.shared.stream(admitted))
            }
        }
        text.add(try await Whistle.shared.finishStream())
        return text.draft
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init)
    }

    /// 16 kHz mono samples of `sentence` spoken by the system voice.
    private static func speech(_ sentence: String) async throws -> [Float] {
        let file = FileManager.default.temporaryDirectory.appending(path: "whistle-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path(percentEncoded: false), "--data-format=LEF32@16000", sentence]
        try say.run()
        while say.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        let audio = try AVAudioFile(forReading: file)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
