import Foundation
import Testing
@testable import LiveSubtitle

struct SpeechServiceTests {
    @Test
    func testVolatileTimingEvents() async throws {
        let firstRange = audioRange(start: 0, end: 1_000)
        let provisional = SpeechRawResult(
            audioRange: firstRange,
            text: "A👨‍👩‍👧‍👦B",
            spans: [
                transcriptSpan(characters: 0..<1, start: 0, end: 200),
                transcriptSpan(characters: 1..<2, start: 200, end: 700),
                transcriptSpan(characters: 2..<3, start: 700, end: 1_000)
            ],
            isFinal: false
        )
        let final = SpeechRawResult(
            audioRange: firstRange,
            text: "A👨‍👩‍👧‍👦B.",
            spans: [
                transcriptSpan(characters: 0..<1, start: 0, end: 200),
                transcriptSpan(characters: 1..<2, start: 200, end: 700),
                transcriptSpan(characters: 2..<4, start: 700, end: 1_000)
            ],
            isFinal: true
        )
        let backend = SpeechBackendStub(events: [.result(provisional), .result(final), .ended])
        let service = SpeechService(
            backendFactory: SpeechBackendFactoryStub(backend: backend),
            clock: SpeechTestClock()
        )
        let input = AsyncStream<AudioSourceEvent>(bufferingPolicy: .bufferingNewest(1)) {
            $0.finish()
        }

        let output = try await service.start(input: input, source: LanguageIdentifier(rawValue: "en"))
        var transcripts: [TranscriptEvent] = []
        for await event in output {
            switch event {
            case .transcript(let transcript): transcripts.append(transcript)
            case .ended: break
            default: Issue.record("识别输出包含意外事件")
            }
        }

        #expect(transcripts.count == 2)
        guard transcripts.count == 2 else { return }
        #expect(transcripts[0].utteranceID == transcripts[1].utteranceID)
        #expect(transcripts[0].revision == 0)
        #expect(transcripts[1].revision == 1)
        #expect(!transcripts[0].isFinal)
        #expect(transcripts[1].isFinal)
        #expect(transcripts[0].text == "A👨‍👩‍👧‍👦B")
        #expect(transcripts[1].text == "A👨‍👩‍👧‍👦B.")
        #expect(transcripts[0].spans[1].characterRange == 1..<2)
        #expect(transcripts[0].spans[1].audioRange.start.value == 200)
        #expect(transcripts[1].spans[2].characterRange == 2..<4)
        #expect(transcripts[0].receivedAt.uptimeNanoseconds == 42)
    }

    @Test
    func testExplicitAnalyzerTermination() async throws {
        let finishBackend = SpeechBackendStub(events: [], emitsAutomatically: false)
        let finishService = SpeechService(
            backendFactory: SpeechBackendFactoryStub(backend: finishBackend),
            clock: SpeechTestClock()
        )
        let finishOutput = try await finishService.start(
            input: emptyAudioInput(),
            source: LanguageIdentifier(rawValue: "en")
        )
        await finishService.finish()
        #expect(await finishBackend.lifecycleCounts().finish == 1)
        var receivedEnded = false
        for await event in finishOutput {
            if case .ended = event { receivedEnded = true }
        }
        #expect(receivedEnded)

        let lateResult = SpeechRawResult(
            audioRange: audioRange(start: 0, end: 1_000),
            text: "late",
            spans: [],
            isFinal: false
        )
        let cancelBackend = SpeechBackendStub(
            events: [],
            emitsAutomatically: false,
            lateResultOnCancel: lateResult
        )
        let cancelService = SpeechService(
            backendFactory: SpeechBackendFactoryStub(backend: cancelBackend),
            clock: SpeechTestClock()
        )
        let cancelOutput = try await cancelService.start(
            input: emptyAudioInput(),
            source: LanguageIdentifier(rawValue: "en")
        )
        await cancelService.cancelAndFinish()
        #expect(await cancelBackend.lifecycleCounts().cancel == 1)
        for await event in cancelOutput {
            if case .transcript = event { Issue.record("cancel 后不得输出晚到转写") }
        }
    }

    @Test
    func testFallbackWithoutTimingResetsAtWindowLimit() async throws {
        let characterOverflow = SpeechRawResult(
            audioRange: audioRange(start: 0, end: 29_000),
            text: String(repeating: "a", count: RuntimePolicy.transcriptWindowCharacterLimit),
            spans: [],
            isFinal: false
        )
        let durationOverflow = SpeechRawResult(
            audioRange: audioRange(start: 0, end: 30_000),
            text: "short",
            spans: [],
            isFinal: false
        )
        let afterReset = SpeechRawResult(
            audioRange: audioRange(start: 31_000, end: 32_000),
            text: "new",
            spans: [],
            isFinal: false
        )
        let backend = SpeechBackendStub(events: [
            .result(characterOverflow),
            .result(durationOverflow),
            .result(afterReset),
            .ended
        ])
        let service = SpeechService(
            backendFactory: SpeechBackendFactoryStub(backend: backend),
            clock: SpeechTestClock()
        )
        let output = try await service.start(
            input: emptyAudioInput(),
            source: LanguageIdentifier(rawValue: "en")
        )
        var discontinuities = 0
        var transcripts: [TranscriptEvent] = []
        for await event in output {
            switch event {
            case .discontinuity: discontinuities += 1
            case .transcript(let transcript): transcripts.append(transcript)
            default: break
            }
        }

        #expect(discontinuities == 2)
        #expect(await backend.lifecycleCounts().reset == 2)
        #expect(transcripts.count == 1)
        #expect(transcripts.first?.text == "new")
    }

    @Test
    func testInvalidPCMRejected() {
        let chunk = AudioChunk(
            sequence: 0,
            capturePTS: AudioTimestamp(value: 0, timescale: 16_000),
            frameCount: 4,
            sampleRate: 16_000,
            channels: 1,
            format: PCMFormat(
                sampleFormat: .signedInt16,
                isInterleaved: true,
                isBigEndian: false,
                bytesPerFrame: 2
            ),
            ownedPCM: [Data(repeating: 0, count: 2)],
            discontinuity: false
        )

        #expect(throws: FailureCode.speechFailed) {
            _ = try SpeechPCMConverter.makeInput(chunk: chunk, samplePosition: 0)
        }
    }

    @Test
    func testAudioDiscontinuityResetsUtterance() async throws {
        let first = SpeechRawResult(
            audioRange: audioRange(start: 0, end: 1_000),
            text: "before",
            spans: [],
            isFinal: false
        )
        let second = SpeechRawResult(
            audioRange: audioRange(start: 2_000, end: 3_000),
            text: "after",
            spans: [],
            isFinal: false
        )
        let backend = SpeechBackendStub(events: [
            .result(first),
            .discontinuity(AudioTimestamp(value: 2_000, timescale: 1_000)),
            .result(second),
            .ended
        ])
        let service = SpeechService(
            backendFactory: SpeechBackendFactoryStub(backend: backend),
            clock: SpeechTestClock()
        )
        let output = try await service.start(input: emptyAudioInput(), source: LanguageIdentifier(rawValue: "en"))
        var transcripts: [TranscriptEvent] = []
        var discontinuities = 0
        for await event in output {
            switch event {
            case .transcript(let transcript): transcripts.append(transcript)
            case .discontinuity: discontinuities += 1
            default: break
            }
        }

        #expect(discontinuities == 1)
        #expect(transcripts.count == 2)
        guard transcripts.count == 2 else { return }
        #expect(transcripts[0].utteranceID != transcripts[1].utteranceID)
        #expect(transcripts.map(\.revision) == [0, 0])
    }

    @Test
    func testBackpressuredProducerCancellation() async {
        let channel = BoundedEventChannel<Int>()
        for value in 0..<32 { await channel.send(value) }
        let probe = SpeechCompletionProbe()
        let producer = Task {
            await channel.send(32)
            await probe.markCompleted()
        }
        producer.cancel()
        for _ in 0..<100 {
            if await probe.isCompleted() { break }
            await Task.yield()
        }
        await channel.cancel()
        #expect(await probe.isCompleted())
    }

    @Test
    func testRestartRejectedUntilOldCancellationCompletes() async throws {
        let backend = SpeechBackendStub(
            events: [],
            emitsAutomatically: false,
            waitsForCancelRelease: true
        )
        let service = SpeechService(
            backendFactory: SpeechBackendFactoryStub(backend: backend),
            clock: SpeechTestClock()
        )
        let firstOutput = try await service.start(input: emptyAudioInput(), source: LanguageIdentifier(rawValue: "en"))
        let cancellation = Task { await service.cancelAndFinish() }
        while await backend.lifecycleCounts().cancel == 0 { await Task.yield() }

        await #expect(throws: FailureCode.unavailable) {
            _ = try await service.start(input: emptyAudioInput(), source: LanguageIdentifier(rawValue: "en"))
        }
        await backend.releaseCancellation()
        await cancellation.value
        for await _ in firstOutput {}
        let secondOutput = try await service.start(input: emptyAudioInput(), source: LanguageIdentifier(rawValue: "en"))
        await service.cancelAndFinish()
        for await _ in secondOutput {}
    }

    @Test
    func testDiscontinuityRestartReplaysChunk() {
        var state = SpeechRestartState()
        let initialGeneration = state.generation
        let chunk = AudioChunk(
            sequence: 99,
            capturePTS: AudioTimestamp(value: 32_000, timescale: 16_000),
            frameCount: 4,
            sampleRate: 16_000,
            channels: 1,
            format: PCMFormat(
                sampleFormat: .signedInt16,
                isInterleaved: true,
                isBigEndian: false,
                bytesPerFrame: 2
            ),
            ownedPCM: [Data(repeating: 0, count: 8)],
            discontinuity: true
        )

        let nextGeneration = state.requestRestart(replaying: chunk)
        #expect(nextGeneration == initialGeneration + 1)
        #expect(state.takePendingChunk()?.sequence == 99)
        #expect(state.takePendingChunk() == nil)
    }

    @Test
    func testEmptyFinalRevisesExistingUtterance() async throws {
        let range = audioRange(start: 0, end: 1_000)
        let provisional = SpeechRawResult(
            audioRange: range,
            text: "temporary",
            spans: [],
            isFinal: false
        )
        let emptyFinal = SpeechRawResult(audioRange: range, text: "", spans: [], isFinal: true)
        let backend = SpeechBackendStub(events: [.result(provisional), .result(emptyFinal), .ended])
        let service = SpeechService(
            backendFactory: SpeechBackendFactoryStub(backend: backend),
            clock: SpeechTestClock()
        )
        let output = try await service.start(input: emptyAudioInput(), source: LanguageIdentifier(rawValue: "en"))
        var transcripts: [TranscriptEvent] = []
        for await event in output {
            if case .transcript(let transcript) = event { transcripts.append(transcript) }
        }

        #expect(transcripts.count == 2)
        guard transcripts.count == 2 else { return }
        #expect(transcripts[0].utteranceID == transcripts[1].utteranceID)
        #expect(transcripts[1].revision == 1)
        #expect(transcripts[1].text.isEmpty)
        #expect(transcripts[1].isFinal)
    }

    @Test
    func testIncompleteTimingResetsAtWindowLimit() async throws {
        let partialTiming = SpeechRawResult(
            audioRange: audioRange(start: 0, end: 29_000),
            text: String(repeating: "a", count: RuntimePolicy.transcriptWindowCharacterLimit),
            spans: [
                transcriptSpan(characters: 0..<1, start: 0, end: 1),
                transcriptSpan(
                    characters: (RuntimePolicy.transcriptWindowCharacterLimit - 1)..<RuntimePolicy.transcriptWindowCharacterLimit,
                    start: 28_999,
                    end: 29_000
                )
            ],
            isFinal: false
        )
        let expiredTiming = SpeechRawResult(
            audioRange: audioRange(start: 0, end: 40_000),
            text: "short",
            spans: [transcriptSpan(characters: 0..<5, start: 0, end: 1_000)],
            isFinal: false
        )
        let backend = SpeechBackendStub(events: [.result(partialTiming), .result(expiredTiming), .ended])
        let service = SpeechService(
            backendFactory: SpeechBackendFactoryStub(backend: backend),
            clock: SpeechTestClock()
        )
        let output = try await service.start(input: emptyAudioInput(), source: LanguageIdentifier(rawValue: "en"))
        var discontinuities = 0
        var transcripts: [TranscriptEvent] = []
        for await event in output {
            switch event {
            case .discontinuity: discontinuities += 1
            case .transcript(let transcript): transcripts.append(transcript)
            default: break
            }
        }

        #expect(discontinuities == 2)
        #expect(transcripts.isEmpty)
    }
}

private actor SpeechCompletionProbe {
    private var completed = false
    func markCompleted() { completed = true }
    func isCompleted() -> Bool { completed }
}

private func emptyAudioInput() -> AsyncStream<AudioSourceEvent> {
    AsyncStream<AudioSourceEvent>(bufferingPolicy: .bufferingNewest(1)) { $0.finish() }
}

private func audioRange(start: Int64, end: Int64) -> AudioRange {
    AudioRange(
        start: AudioTimestamp(value: start, timescale: 1_000),
        end: AudioTimestamp(value: end, timescale: 1_000)
    )
}

private func transcriptSpan(characters: Range<Int>, start: Int64, end: Int64) -> TranscriptSpan {
    TranscriptSpan(characterRange: characters, audioRange: audioRange(start: start, end: end))
}

private struct SpeechTestClock: MonotonicClock {
    func now() -> MonotonicInstant { MonotonicInstant(uptimeNanoseconds: 42) }
    func sleep(until deadline: MonotonicInstant) async throws {}
}

private struct SpeechBackendFactoryStub: SpeechBackendFactory {
    let backend: any SpeechBackendDriving
    func makeBackend() -> any SpeechBackendDriving { backend }
}

private actor SpeechBackendStub: SpeechBackendDriving {
    let events: [SpeechRawEvent]
    let emitsAutomatically: Bool
    let lateResultOnCancel: SpeechRawResult?
    let waitsForCancelRelease: Bool
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var continuation: AsyncStream<SpeechRawEvent>.Continuation?
    private var resetCount = 0
    private var finishCount = 0
    private var cancelCount = 0

    init(
        events: [SpeechRawEvent],
        emitsAutomatically: Bool = true,
        lateResultOnCancel: SpeechRawResult? = nil,
        waitsForCancelRelease: Bool = false
    ) {
        self.events = events
        self.emitsAutomatically = emitsAutomatically
        self.lateResultOnCancel = lateResultOnCancel
        self.waitsForCancelRelease = waitsForCancelRelease
    }

    func inputFormat(source: LanguageIdentifier) async throws -> AudioFormat {
        AudioFormat(
            sampleRate: 16_000,
            channels: 1,
            pcm: PCMFormat(sampleFormat: .signedInt16, isInterleaved: true, isBigEndian: false, bytesPerFrame: 2)
        )
    }

    func start(
        input: AsyncStream<AudioSourceEvent>,
        source: LanguageIdentifier
    ) async throws -> AsyncStream<SpeechRawEvent> {
        let (stream, continuation) = AsyncStream<SpeechRawEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        self.continuation = continuation
        if emitsAutomatically {
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
        return stream
    }

    func reset() async throws { resetCount += 1 }

    func finish() async {
        finishCount += 1
        continuation?.yield(.ended)
        continuation?.finish()
        continuation = nil
    }

    func cancelAndFinish() async {
        cancelCount += 1
        if let lateResultOnCancel { continuation?.yield(.result(lateResultOnCancel)) }
        continuation?.finish()
        continuation = nil
        if waitsForCancelRelease && cancelCount == 1 {
            await withCheckedContinuation { continuation in
                cancellationContinuation = continuation
            }
        }
    }

    func releaseCancellation() {
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }

    func lifecycleCounts() -> (reset: Int, finish: Int, cancel: Int) {
        (resetCount, finishCount, cancelCount)
    }
}
