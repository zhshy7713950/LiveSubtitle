import Foundation
@testable import LiveSubtitle

@MainActor
final class IntegrationAudioSource: AudioSource {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var buffer = BoundedAudioEventBuffer()
    var bufferedDuration: Double { buffer.snapshot().bufferedDuration }

    func start(config: CaptureConfig) async throws -> AsyncStream<AudioSourceEvent> {
        startCount += 1
        let buffer = BoundedAudioEventBuffer()
        self.buffer = buffer
        return AsyncStream(unfolding: { await buffer.next() }, onCancel: { buffer.close() })
    }
    func stop() async { stopCount += 1; buffer.close() }
    func feedPCM() {
        let samples = [Float](repeating: 0.25, count: 160)
        let data = samples.withUnsafeBytes { Data($0) }
        buffer.push(AudioChunk(sequence: 0, capturePTS: .init(value: 0, timescale: 16_000),
            frameCount: 160, sampleRate: 16_000, channels: 1,
            format: .init(sampleFormat: .float32, isInterleaved: true, isBigEndian: false, bytesPerFrame: 4),
            ownedPCM: [data], discontinuity: false))
    }
    func revoke() { buffer.finish(.failed(.captureFailed)) }
}

/// Owns one synthetic speech input consumer; backend transcription remains a test seam.
actor IntegrationSpeech: SpeechRecognizing {
    private var generation: UInt64 = 0
    private var consumer: Task<Void, Never>?
    private let events = SessionStreamBox<SpeechEvent>()
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var receivedFrames = 0
    private(set) var retainedPCM: [Data] = []

    func inputFormat(source: LanguageIdentifier) async throws -> AudioFormat {
        AudioFormat(sampleRate: 16_000, channels: 1,
            pcm: .init(sampleFormat: .float32, isInterleaved: true, isBigEndian: false, bytesPerFrame: 4))
    }
    func start(input: AsyncStream<AudioSourceEvent>, source: LanguageIdentifier) async throws -> AsyncStream<SpeechEvent> {
        generation &+= 1
        let token = generation
        let streamIndex = startCount
        startCount += 1
        let stream = events.makeStream()
        consumer = Task {
            for await event in input {
                guard !Task.isCancelled, token == self.generation else { return }
                switch event {
                case .chunk(let chunk):
                    self.receivedFrames += chunk.frameCount
                    self.retainedPCM = chunk.ownedPCM
                case .ended: self.events.emit(.ended, at: streamIndex); return
                case .failed(let failure): self.events.emit(.failed(failure), at: streamIndex); return
                }
            }
        }
        return stream
    }
    func emit(_ event: SpeechEvent, at index: Int = 0) { events.emit(event, at: index) }
    func finish() async { await cancelAndFinish() }
    func cancelAndFinish() async {
        cancelCount += 1
        generation &+= 1
        let task = consumer
        consumer = nil
        task?.cancel()
        await task?.value
        retainedPCM.removeAll()
    }
}
