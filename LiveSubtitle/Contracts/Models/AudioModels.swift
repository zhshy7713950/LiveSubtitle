import Foundation

/// Rational media time; an adapter must map it to host uptime explicitly.
struct AudioTimestamp: Sendable, Hashable {
    let value: Int64
    let timescale: Int32
}

struct AudioRange: Sendable, Equatable {
    let start: AudioTimestamp
    let end: AudioTimestamp
}

enum PCMSampleFormat: Sendable {
    case float32, float64, signedInt16, signedInt32
}

struct PCMFormat: Sendable {
    let sampleFormat: PCMSampleFormat
    let isInterleaved: Bool
    let isBigEndian: Bool
    let bytesPerFrame: Int
}

struct AudioFormat: Sendable {
    let sampleRate: Double
    let channels: Int
    let pcm: PCMFormat
}

struct AudioChunk: Sendable {
    let sequence: UInt64
    let capturePTS: AudioTimestamp
    let frameCount: Int
    let sampleRate: Double
    let channels: Int
    let format: PCMFormat
    /// Owned copies. One plane for interleaved PCM, one per channel otherwise.
    let ownedPCM: [Data]
    let discontinuity: Bool
}

struct CaptureConfig: Sendable {
    let identity: SessionIdentity
    let sourceLanguage: LanguageIdentifier
}

enum AudioSourceEvent: Sendable {
    case chunk(AudioChunk)
    case ended
    case failed(FailureCode)
}

/// Word/character timing from the SDK, indexed in grapheme clusters within text.
struct TranscriptSpan: Sendable {
    let characterRange: Range<Int>
    let audioRange: AudioRange
}

struct TranscriptEvent: Sendable {
    let utteranceID: UUID
    let audioRange: AudioRange
    let revision: UInt64
    let text: String
    let spans: [TranscriptSpan]
    let isFinal: Bool
    let receivedAt: MonotonicInstant
}

enum SpeechEvent: Sendable {
    case transcript(TranscriptEvent)
    case discontinuity(AudioTimestamp)
    case ended
    case failed(FailureCode)
}
