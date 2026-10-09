import AVFoundation
import Synchronization

/// The draft while dictating: what was typed before, the words Whistle has settled, then the
/// tail it may still revise.
struct DictatedText: Equatable {
    var base: String
    var settled = ""
    var pending = ""

    mutating func add(_ piece: Whistle.Piece) {
        settled = Self.joined(settled, piece.text)
        pending = piece.pending ?? ""
    }

    var draft: String {
        Self.joined(Self.joined(base, settled), pending)
    }

    static func joined(_ head: String, _ tail: String) -> String {
        let tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return head }
        guard let last = head.last, !last.isWhitespace else { return head + tail }
        return head + " " + tail
    }
}

/// Voice input into the composer: records the microphone and streams it through Whistle about
/// once a second, so words appear while you talk.
@MainActor
@Observable
final class Dictation {
    enum State: Equatable {
        case idle, starting, listening, finishing
    }

    private(set) var state = State.idle
    /// Why the last attempt couldn't start, until the next one.
    private(set) var problem: String?
    private(set) var needsMicrophoneAccess = false
    /// The thread whose draft is being dictated into.
    private(set) var threadID: Thread.ID?

    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var sink: SampleSink?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Closing the engine's stream after a cancel; the next start waits for it.
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private var deviceChange: (any NSObjectProtocol)?
    @ObservationIgnored private var gate = SpeechGate()
    @ObservationIgnored private var text = DictatedText(base: "")
    @ObservationIgnored private var written = ""
    @ObservationIgnored private var read: () -> String = { "" }
    @ObservationIgnored private var write: (String) -> Void = { _ in }

    /// Only in the packaged app: without a usage description, macOS ends the process at the
    /// microphone prompt.
    var isAvailable: Bool {
        Whistle.weights != nil && Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
    }
    var isActive: Bool { state != .idle }

    func start(threadID: Thread.ID, read: @escaping () -> String, write: @escaping (String) -> Void) async {
        guard state == .idle, let weights = Whistle.weights else { return }
        attempt += 1
        let current = attempt
        state = .starting
        self.threadID = threadID
        problem = nil
        needsMicrophoneAccess = false
        // Stop, or a newer start, can come in during any wait below.
        let superseded = { [unowned self] in state != .starting || attempt != current }
        let allowed = await Self.microphoneAllowed()
        guard !superseded() else { return }
        guard allowed else {
            fail("Allow \(Brand.name) to use the microphone in System Settings.", needsAccess: true)
            return
        }
        await closing?.value
        let engine = AVAudioEngine()
        do {
            try await Whistle.shared.load(weights)
            // A stream left open by an earlier session would run on into this one.
            _ = try? await Whistle.shared.finishStream()
            guard !superseded() else { return }
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0, let sink = SampleSink(from: format) else {
                fail("No microphone is available.")
                return
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(into: sink))
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.sink = sink
            // A new input or output device stops the engine, so take the words so far and end.
            deviceChange = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.finish() }
                }
            }
        } catch {
            // An engine released with its tap still installed crashes on the audio thread.
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            if !superseded() {
                fail((error as? Whistle.Failure)?.message ?? "Couldn't start the microphone.")
            }
            return
        }
        self.read = read
        self.write = write
        gate = SpeechGate()
        text = DictatedText(base: read())
        written = text.draft
        state = .listening
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.state == .listening else { return }
                await self.pass(final: false)
            }
        }
    }

    /// Stops recording and writes the last words, which takes a moment.
    func finish() async {
        guard state == .listening else {
            if state == .starting { reset() }
            return
        }
        state = .finishing
        loop?.cancel()
        await loop?.value
        stopRecording()
        // What the microphone caught since the last pass is still in the sink.
        await pass(final: true)
        reset()
    }

    /// Stops at once and leaves the draft as it is.
    func cancel() {
        guard state != .idle else { return }
        loop?.cancel()
        stopRecording()
        closing = Task { _ = try? await Whistle.shared.finishStream() }
        reset()
    }

    private func pass(final: Bool) async {
        let session = attempt
        let samples = await admitted(sink?.drain() ?? [])
        // A cancel, and maybe a new start, came in while the classifier ran; this pass is over.
        guard attempt == session, state == .listening || state == .finishing else { return }
        do {
            // A slow pass leaves more than a second waiting; the engine takes at most 30 seconds a call.
            for start in stride(from: 0, to: samples.count, by: Self.longestPass) {
                text.add(try await Whistle.shared.stream(Array(samples[start..<min(start + Self.longestPass, samples.count)])))
            }
        } catch {
            problem = (error as? Whistle.Failure)?.message ?? "Couldn't transcribe."
            if !final {
                cancel()
                return
            }
        }
        if final {
            do {
                text.add(try await Whistle.shared.finishStream())
            } catch {
                problem = (error as? Whistle.Failure)?.message ?? "Couldn't transcribe."
            }
        }
        // Typing while dictating takes over the draft.
        guard read() == written else {
            if !final { cancel() }
            return
        }
        written = text.draft
        write(written)
    }

    /// Judged a second at a time even when a slow pass left more waiting, so one word doesn't
    /// carry the silence around it. The classifier runs off the main actor.
    private func admitted(_ drained: [Float]) async -> [Float] {
        let gate = gate
        let session = attempt
        let (judged, samples) = await Task.detached(priority: .userInitiated) {
            var gate = gate
            let second = Int(Whistle.sampleRate)
            let samples = stride(from: 0, to: drained.count, by: second).flatMap { start in
                gate.admit(Array(drained[start..<min(start + second, drained.count)]))
            }
            return (gate, samples)
        }.value
        // A cancel and a new start during the wait make this a different session.
        guard attempt == session, state == .listening || state == .finishing else { return [] }
        self.gate = judged
        return samples
    }

    private static let longestPass = Int(Whistle.sampleRate) * 20

    private func stopRecording() {
        if let deviceChange {
            NotificationCenter.default.removeObserver(deviceChange)
        }
        deviceChange = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func reset() {
        sink = nil
        loop = nil
        threadID = nil
        read = { "" }
        write = { _ in }
        state = .idle
    }

    private func fail(_ message: String, needsAccess: Bool = false) {
        problem = message
        needsMicrophoneAccess = needsAccess
        threadID = nil
        state = .idle
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// Built outside the main actor: the tap runs on the audio thread.
    private nonisolated static func tap(into sink: SampleSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.append(buffer) }
    }
}

/// Converts microphone buffers to 16 kHz mono and keeps them until the next pass. The converter
/// is used only from the audio thread; the samples are behind a lock.
private final class SampleSink: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private let samples = Mutex<[Float]>([])

    init?(from format: AVAudioFormat) {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Whistle.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output)
        else { return nil }
        self.output = output
        self.converter = converter
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        var given = false
        converter.convert(to: converted, error: nil) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard let channel = converted.floatChannelData?[0], converted.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
        samples.withLock { $0.append(contentsOf: chunk) }
    }

    func drain() -> [Float] {
        samples.withLock { samples in
            defer { samples.removeAll(keepingCapacity: true) }
            return samples
        }
    }
}
