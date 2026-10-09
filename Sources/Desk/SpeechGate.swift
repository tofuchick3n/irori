import AVFoundation
import SoundAnalysis
import Synchronization

/// Lets audio through to Whistle only around speech. Given room noise and no words, Whistle
/// writes "Thank you." with high confidence, so chunks without speech never reach it.
struct SpeechGate: Sendable {
    /// How sure the detector must be to start letting audio through. Speech scores about 0.9 even
    /// when quiet, noise about 0.01, and a whisper can dip to 0.05.
    static let threshold = 0.25
    /// Once speech is going, a quiet second only has to beat this to keep it going, and it stays
    /// going until this many pieces in a row have missed.
    static let keepGoing = 0.1
    static let missesToStop = 2
    /// Audio before the chunk, which judges it with context and gives a word that starts at the
    /// chunk's edge its beginning.
    static let contextLength = Int(Whistle.sampleRate)
    static let leadIn = Int(Whistle.sampleRate / 2)

    let speechConfidence: @Sendable ([Float]) -> Double
    private var context: [Float] = []
    private var lastWasSent = false
    private var misses = Self.missesToStop
    /// The end of the audio dropped since the last that was sent.
    private var dropped: [Float] = []

    init(speechConfidence: @escaping @Sendable ([Float]) -> Double = SpeechDetector.confidence) {
        self.speechConfidence = speechConfidence
    }

    /// The samples to send for this chunk: none without speech, with a lead-in after a gap.
    mutating func admit(_ chunk: [Float]) -> [Float] {
        guard !chunk.isEmpty else { return [] }
        let speaking = misses < Self.missesToStop
        let heard = speechConfidence(context + chunk) >= (speaking ? Self.keepGoing : Self.threshold)
        context = Array((context + chunk).suffix(Self.contextLength))
        lastWasSent = heard
        misses = heard ? 0 : misses + 1
        guard heard else {
            dropped = Array((dropped + chunk).suffix(Self.leadIn))
            return []
        }
        defer { dropped = [] }
        return dropped + chunk
    }
}

/// Apple's on-device sound classifier, asked how likely a stretch of 16 kHz mono audio holds speech.
enum SpeechDetector {
    static let window = Int(Whistle.sampleRate)
    static let hop = window / 2

    /// The classifier judges one-second windows every half second and skips a partial one at the
    /// end, so audio is padded with silence until a window covers its last sample. Without that, a
    /// short word after a second of context was never judged.
    static func paddedLength(_ count: Int) -> Int {
        guard count > window else { return window }
        let hops = (count - window + hop - 1) / hop
        return window + hops * hop
    }

    static func confidence(_ samples: [Float]) -> Double {
        let samples = samples + [Float](repeating: 0, count: paddedLength(samples.count) - samples.count)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Whistle.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1)
        else { return 1 }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        request.windowDuration = CMTime(seconds: 1, preferredTimescale: 16_000)
        request.overlapFactor = 0.5
        let observer = SpeechObserver()
        let analyzer = SNAudioStreamAnalyzer(format: format)
        guard (try? analyzer.add(request, withObserver: observer)) != nil else { return 1 }
        analyzer.analyze(buffer, atAudioFramePosition: 0)
        analyzer.completeAnalysis()
        return observer.highest.withLock { $0 } ?? 0
    }
}

private final class SpeechObserver: NSObject, SNResultsObserving, Sendable {
    let highest = Mutex<Double?>(nil)

    func request(_: any SNRequest, didProduce result: any SNResult) {
        guard let confidence = (result as? SNClassificationResult)?.classification(forIdentifier: "speech")?.confidence else { return }
        highest.withLock { $0 = max($0 ?? 0, confidence) }
    }
}
