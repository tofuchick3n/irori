import Foundation
import Needle

/// On-device speech to text with Cactus Compute's Whistle model. The engine holds one model per
/// process and isn't thread-safe, so every call goes through this actor.
actor Whistle {
    static let shared = Whistle()

    /// What one pass returned: `text` is settled, `pending` may still change on the next pass.
    struct Piece: Decodable, Equatable, Sendable {
        var text: String
        var pending: String?
    }

    struct Failure: Error, Equatable {
        var message: String
    }

    /// 16 kHz mono, the only format the engine takes.
    static let sampleRate = 16_000.0
    /// Names a general model mishears, so the search favours them.
    static let keywords = (AgentID.allCases.map(\.displayName) + [Brand.name, "Takibi"]).joined(separator: "\n")

    /// Bundled by `scripts/make-app`.
    static let weights = Bundle.main.url(forResource: "whistle", withExtension: "cact")

    /// The weights, which the engine may keep reading after loading, so they're never freed.
    private var model: UnsafeMutableRawBufferPointer?

    func load(_ weights: URL) throws {
        guard model == nil else { return }
        let data = try Data(contentsOf: weights)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: data.count, alignment: 64)
        buffer.copyBytes(from: data)
        guard needle_load(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt64(buffer.count)) >= 0 else {
            buffer.deallocate()
            throw Self.lastError()
        }
        model = buffer
    }

    /// One clip of at most 30 seconds.
    func transcribe(_ samples: [Float]) throws -> String {
        try call { out, capacity in
            needle_transcribe(samples, Int32(samples.count), nil, Self.keywords, 0, out, capacity)
        }.text
    }

    /// Adds about a second of audio to the live stream and returns the words it settled.
    func stream(_ samples: [Float]) throws -> Piece {
        try call { out, capacity in
            needle_stream_transcribe_process(samples, Int32(samples.count), nil, Self.keywords, out, capacity)
        }
    }

    /// Ends the live stream; the unsettled tail becomes `text`.
    func finishStream() throws -> Piece {
        try call { out, capacity in
            needle_stream_transcribe_stop(out, capacity)
        }
    }

    private func call(_ body: (UnsafeMutablePointer<CChar>, Int32) -> Int32) throws -> Piece {
        guard model != nil else { throw Failure(message: "The speech model isn't loaded.") }
        var out = [CChar](repeating: 0, count: 64 * 1024)
        let result = out.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!, Int32(buffer.count))
        }
        guard result >= 0 else { throw Self.lastError() }
        let json = out.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        do {
            return try JSONDecoder().decode(Piece.self, from: Data(json.utf8))
        } catch {
            throw Failure(message: "The speech model returned something unreadable.")
        }
    }

    private static func lastError() -> Failure {
        guard let message = needle_last_error() else { return Failure(message: "The speech model failed.") }
        return Failure(message: String(cString: message))
    }
}
