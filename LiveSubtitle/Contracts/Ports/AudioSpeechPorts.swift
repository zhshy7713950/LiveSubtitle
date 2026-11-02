import Foundation

/// UI authorization stays on MainActor. Callback ownership/buffering is internal.
@MainActor
protocol AudioSource: AnyObject {
    func start(config: CaptureConfig) async throws -> AsyncStream<AudioSourceEvent>
    func stop() async
}

protocol AudioProcessing: Sendable {
    func process(_ input: AsyncStream<AudioSourceEvent>, target: AudioFormat) async -> AsyncStream<AudioSourceEvent>
    func stop() async
}

protocol SpeechRecognizing: Sendable {
    func inputFormat(source: LanguageIdentifier) async throws -> AudioFormat
    func start(input: AsyncStream<AudioSourceEvent>, source: LanguageIdentifier) async throws -> AsyncStream<SpeechEvent>
    func finish() async
    func cancelAndFinish() async
}

protocol CaptionSegmenting: Sendable {
    /// Output may be emitted by a timer even when no new speech event arrives.
    func start(input: AsyncStream<SpeechEvent>) async -> AsyncStream<SegmentEvent>
    /// Cancels input consumption, timers and the output stream; clears all text.
    func reset() async
}
