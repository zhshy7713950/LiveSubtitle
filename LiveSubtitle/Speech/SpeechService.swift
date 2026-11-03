import Foundation
import AVFoundation
import CoreMedia
import Speech

struct SpeechRawResult: Sendable {
    let audioRange: AudioRange
    let text: String
    let spans: [TranscriptSpan]
    let isFinal: Bool
}

enum SpeechRawEvent: Sendable {
    case result(SpeechRawResult)
    case discontinuity(AudioTimestamp)
    case ended
    case failed(FailureCode)
}

protocol SpeechBackendDriving: Sendable {
    func inputFormat(source: LanguageIdentifier) async throws -> AudioFormat
    func start(
        input: AsyncStream<AudioSourceEvent>,
        source: LanguageIdentifier
    ) async throws -> AsyncStream<SpeechRawEvent>
    func reset() async throws
    func finish() async
    func cancelAndFinish() async
}

protocol SpeechBackendFactory: Sendable {
    func makeBackend() -> any SpeechBackendDriving
}

struct SystemSpeechBackendFactory: SpeechBackendFactory {
    func makeBackend() -> any SpeechBackendDriving { SystemSpeechBackend() }
}

struct SpeechSystemClock: MonotonicClock {
    func now() -> MonotonicInstant {
        MonotonicInstant(uptimeNanoseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
    }

    func sleep(until deadline: MonotonicInstant) async throws {
        let current = now().uptimeNanoseconds
        guard deadline.uptimeNanoseconds > current else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(nanoseconds: deadline.uptimeNanoseconds - current)
    }
}

actor SpeechService: SpeechRecognizing {
    private let backendFactory: any SpeechBackendFactory
    private let clock: any MonotonicClock
    private var backend: (any SpeechBackendDriving)?
    private var resultTask: Task<Void, Never>?
    private var channel: BoundedEventChannel<SpeechEvent>?
    private var normalizer = SpeechResultNormalizer()
    private var isActive = false

    init() {
        self.backendFactory = SystemSpeechBackendFactory()
        self.clock = SpeechSystemClock()
    }

    init(backendFactory: any SpeechBackendFactory, clock: any MonotonicClock) {
        self.backendFactory = backendFactory
        self.clock = clock
    }

    func inputFormat(source: LanguageIdentifier) async throws -> AudioFormat {
        try await backendFactory.makeBackend().inputFormat(source: source)
    }

    func start(
        input: AsyncStream<AudioSourceEvent>,
        source: LanguageIdentifier
    ) async throws -> AsyncStream<SpeechEvent> {
        guard !isActive else { throw FailureCode.unavailable }
        let backend = backendFactory.makeBackend()
        let rawStream = try await backend.start(input: input, source: source)
        let channel = BoundedEventChannel<SpeechEvent>()
        self.backend = backend
        self.channel = channel
        normalizer.reset()
        isActive = true
        resultTask = Task { [weak self] in
            guard let self else { return }
            for await event in rawStream {
                await self.receive(event)
            }
            await self.rawStreamEnded()
        }
        return channel.makeStream { [weak self] in
            Task { await self?.outputTerminated() }
        }
    }

    func finish() async {
        guard isActive, let backend else { return }
        await backend.finish()
        await resultTask?.value
        resultTask = nil
        self.backend = nil
        channel = nil
    }

    func cancelAndFinish() async {
        guard isActive else { return }
        isActive = false
        normalizer.reset()
        resultTask?.cancel()
        await backend?.cancelAndFinish()
        resultTask = nil
        backend = nil
        await channel?.cancel()
        channel = nil
    }

    private func receive(_ event: SpeechRawEvent) async {
        guard isActive else { return }
        switch event {
        case .result(let raw):
            await receive(raw)
        case .discontinuity(let timestamp):
            normalizer.reset()
            await channel?.send(.discontinuity(timestamp))
        case .ended:
            isActive = false
            normalizer.reset()
            await channel?.send(.ended)
            await channel?.finish()
        case .failed(let code):
            isActive = false
            normalizer.reset()
            await channel?.send(.failed(code))
            await channel?.finish()
        }
    }

    private func receive(_ raw: SpeechRawResult) async {
        guard !raw.text.isEmpty else { return }
        if raw.exceedsWindow && !raw.hasCompleteTiming {
            normalizer.reset()
            await channel?.send(.discontinuity(raw.audioRange.start))
            do {
                try await backend?.reset()
            } catch {
                isActive = false
                await channel?.send(.failed((error as? FailureCode) ?? .speechFailed))
                await channel?.finish()
            }
            return
        }
        let bounded = raw.boundedToWindow()
        guard let transcript = normalizer.normalize(
            raw: bounded,
            receivedAt: clock.now()
        ) else { return }
        await channel?.send(.transcript(transcript))
    }

    private func rawStreamEnded() async {
        guard isActive else { return }
        isActive = false
        normalizer.reset()
        await channel?.send(.failed(.speechFailed))
        await channel?.finish()
    }

    private func outputTerminated() async {
        guard isActive else { return }
        await cancelAndFinish()
    }
}

private struct SpeechResultNormalizer {
    private var utteranceID: UUID?
    private var previousRange: AudioRange?
    private var revision: UInt64 = 0
    private var previousWasFinal = false

    mutating func reset() {
        utteranceID = nil
        previousRange = nil
        revision = 0
        previousWasFinal = false
    }

    mutating func normalize(
        raw: SpeechRawResult,
        receivedAt: MonotonicInstant
    ) -> TranscriptEvent? {
        let startsNewUtterance = utteranceID == nil ||
            (previousWasFinal && !rangesOverlap(previousRange, raw.audioRange))
        if startsNewUtterance {
            utteranceID = UUID()
            revision = 0
        } else if revision < UInt64.max {
            revision += 1
        }
        previousRange = raw.audioRange
        previousWasFinal = raw.isFinal
        guard let utteranceID else { return nil }
        return TranscriptEvent(
            utteranceID: utteranceID,
            audioRange: raw.audioRange,
            revision: revision,
            text: raw.text,
            spans: raw.spans,
            isFinal: raw.isFinal,
            receivedAt: receivedAt
        )
    }
}

private func rangesOverlap(_ lhs: AudioRange?, _ rhs: AudioRange) -> Bool {
    guard let lhs else { return false }
    return seconds(lhs.start) < seconds(rhs.end) && seconds(rhs.start) < seconds(lhs.end)
}

private func seconds(_ timestamp: AudioTimestamp) -> Double {
    guard timestamp.timescale > 0 else { return 0 }
    return Double(timestamp.value) / Double(timestamp.timescale)
}

private extension SpeechRawResult {
    var exceedsWindow: Bool {
        text.count >= RuntimePolicy.transcriptWindowCharacterLimit ||
            seconds(audioRange.end) - seconds(audioRange.start) >=
            Double(RuntimePolicy.transcriptWindowDuration.components.seconds)
    }

    var hasCompleteTiming: Bool {
        guard let first = spans.first, let last = spans.last else { return false }
        return first.characterRange.lowerBound == 0 && last.characterRange.upperBound == text.count
    }

    func boundedToWindow() -> SpeechRawResult {
        var startIndex = text.startIndex
        if text.count > RuntimePolicy.transcriptWindowCharacterLimit {
            startIndex = text.index(
                text.endIndex,
                offsetBy: -RuntimePolicy.transcriptWindowCharacterLimit
            )
        }
        let cutoff = seconds(audioRange.end) - Double(RuntimePolicy.transcriptWindowDuration.components.seconds)
        if seconds(audioRange.start) < cutoff,
           let firstRetained = spans.first(where: { seconds($0.audioRange.end) > cutoff }) {
            let index = text.index(text.startIndex, offsetBy: firstRetained.characterRange.lowerBound)
            startIndex = max(startIndex, index)
        }
        let offset = text.distance(from: text.startIndex, to: startIndex)
        guard offset > 0 else { return self }
        let retainedText = String(text[startIndex...])
        let retainedSpans = spans.compactMap { span -> TranscriptSpan? in
            let upper = min(span.characterRange.upperBound - offset, retainedText.count)
            let lower = max(span.characterRange.lowerBound - offset, 0)
            guard lower < upper else { return nil }
            return TranscriptSpan(characterRange: lower..<upper, audioRange: span.audioRange)
        }
        let retainedStart = retainedSpans.first?.audioRange.start ?? audioRange.start
        return SpeechRawResult(
            audioRange: AudioRange(start: retainedStart, end: audioRange.end),
            text: retainedText,
            spans: retainedSpans,
            isFinal: isFinal
        )
    }
}

private actor BoundedEventChannel<Event: Sendable> {
    private let eventLimit = 32
    private var events: [Event] = []
    private var waiters: [UUID: CheckedContinuation<Event?, Never>] = [:]
    private var waiterOrder: [UUID] = []
    private var spaceWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminated = false
    private var cancelled = false

    nonisolated func makeStream(
        onTermination: @escaping @Sendable () -> Void
    ) -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let forwardingTask = Task { [self] in
            while let event = await self.next() {
                if case .dropped(let dropped) = continuation.yield(event) {
                    await self.requeue(dropped)
                    await Task.yield()
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            forwardingTask.cancel()
            onTermination()
        }
        return stream
    }

    private func requeue(_ event: Event) {
        guard !cancelled else { return }
        events.insert(event, at: 0)
        drainWaiters()
    }

    func send(_ event: Event) async {
        while events.count >= eventLimit && !terminated {
            await withCheckedContinuation { continuation in
                spaceWaiters.append(continuation)
            }
        }
        guard !terminated else { return }
        events.append(event)
        drainWaiters()
    }

    func finish() {
        terminated = true
        drainWaiters()
        resumeSpaceWaiters()
    }

    func cancel() {
        terminated = true
        cancelled = true
        events.removeAll()
        let continuations = waiters.values
        waiters.removeAll()
        waiterOrder.removeAll()
        for continuation in continuations { continuation.resume(returning: nil) }
        resumeSpaceWaiters()
    }

    private func next() async -> Event? {
        if let event = takeEvent() { return event }
        if terminated { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
                waiterOrder.append(id)
                drainWaiters()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func takeEvent() -> Event? {
        guard !events.isEmpty else { return nil }
        let event = events.removeFirst()
        if !spaceWaiters.isEmpty {
            spaceWaiters.removeFirst().resume()
        }
        return event
    }

    private func drainWaiters() {
        while !waiterOrder.isEmpty, let event = takeEvent() {
            let id = waiterOrder.removeFirst()
            waiters.removeValue(forKey: id)?.resume(returning: event)
        }
        if terminated && events.isEmpty {
            let continuations = waiters.values
            waiters.removeAll()
            waiterOrder.removeAll()
            for continuation in continuations { continuation.resume(returning: nil) }
        }
    }

    private func cancelWaiter(id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: nil)
        waiterOrder.removeAll { $0 == id }
    }

    private func resumeSpaceWaiters() {
        let continuations = spaceWaiters
        spaceWaiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private actor SystemSpeechBackend: SpeechBackendDriving {
    private var transcriber: SpeechTranscriber?
    private var dictation: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var format: AVAudioFormat?
    private var source: LanguageIdentifier?
    private var input: AsyncStream<AudioSourceEvent>?
    private var resultTask: Task<Void, Never>?
    private var channel: BoundedEventChannel<SpeechRawEvent>?
    private var generation = 0
    private var samplePosition: Int64 = 0
    private var isActive = false
    private var isFinishing = false

    private var modules: [any SpeechModule] {
        if let transcriber { return [transcriber] }
        if let dictation { return [dictation] }
        return []
    }

    func inputFormat(source: LanguageIdentifier) async throws -> AudioFormat {
        let format = try await prepare(source: source)
        return try SpeechPCMConverter.contractFormat(format)
    }

    func start(
        input: AsyncStream<AudioSourceEvent>,
        source: LanguageIdentifier
    ) async throws -> AsyncStream<SpeechRawEvent> {
        guard !isActive else { throw FailureCode.unavailable }
        let format = try await prepare(source: source)
        let analyzer = SpeechAnalyzer(modules: modules)
        let channel = BoundedEventChannel<SpeechRawEvent>()
        self.analyzer = analyzer
        self.format = format
        self.channel = channel
        self.input = input
        generation += 1
        samplePosition = 0
        isFinishing = false
        isActive = true
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(
                inputSequence: SystemAnalyzerInputs(
                    backend: self,
                    generation: generation,
                    input: input
                )
            )
            startResults(generation: generation)
            return channel.makeStream { [weak self] in
                Task { await self?.cancelAndFinish() }
            }
        } catch {
            await cancelAndFinish()
            throw error
        }
    }

    func reset() async throws {
        guard isActive, let source, let input else { return }
        generation += 1
        let nextGeneration = generation
        resultTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        await resultTask?.value
        resultTask = nil
        analyzer = nil
        transcriber = nil
        dictation = nil
        do {
            let format = try await prepare(source: source)
            let analyzer = SpeechAnalyzer(modules: modules)
            self.format = format
            self.analyzer = analyzer
            samplePosition = 0
            isFinishing = false
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(
                inputSequence: SystemAnalyzerInputs(
                    backend: self,
                    generation: nextGeneration,
                    input: input
                )
            )
            startResults(generation: nextGeneration)
        } catch {
            isActive = false
            await channel?.send(.failed((error as? FailureCode) ?? .speechFailed))
            await channel?.finish()
            throw error
        }
    }

    func finish() async {
        guard isActive, let analyzer else { return }
        isFinishing = true
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await resultTask?.value
        } catch {
            if isActive {
                isActive = false
                await channel?.send(.failed(.speechFailed))
                await channel?.finish()
            }
            resultTask?.cancel()
        }
        isActive = false
        resultTask = nil
        self.analyzer = nil
        input = nil
        channel = nil
    }

    func cancelAndFinish() async {
        guard isActive || analyzer != nil else { return }
        isActive = false
        isFinishing = false
        generation += 1
        resultTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        await resultTask?.value
        resultTask = nil
        analyzer = nil
        input = nil
        await channel?.cancel()
        channel = nil
    }

    private func prepare(source: LanguageIdentifier) async throws -> AVAudioFormat {
        if self.source != source || modules.isEmpty {
            guard let module = await SpeechModuleFactory.makeModule(source: source) else {
                throw FailureCode.unsupportedLanguage
            }
            if let transcriber = module as? SpeechTranscriber {
                self.transcriber = transcriber
                dictation = nil
            } else if let dictation = module as? DictationTranscriber {
                self.dictation = dictation
                transcriber = nil
            } else {
                throw FailureCode.unsupportedLanguage
            }
            self.source = source
        }
        guard await AssetInventory.status(forModules: modules) == .installed else {
            throw FailureCode.assetsMissing
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw FailureCode.unavailable
        }
        return format
    }

    private func startResults(generation: Int) {
        guard let channel else { return }
        if let transcriber {
            resultTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self, await self.isCurrent(generation), !Task.isCancelled else { return }
                        await channel.send(.result(SpeechRawResultFactory.make(
                            range: result.range,
                            text: result.text,
                            isFinal: result.isFinal
                        )))
                    }
                    await self?.finishResults(generation: generation, channel: channel)
                } catch {
                    await self?.failResults(generation: generation, channel: channel)
                }
            }
        } else if let dictation {
            resultTask = Task { [weak self] in
                do {
                    for try await result in dictation.results {
                        guard let self, await self.isCurrent(generation), !Task.isCancelled else { return }
                        await channel.send(.result(SpeechRawResultFactory.make(
                            range: result.range,
                            text: result.text,
                            isFinal: result.isFinal
                        )))
                    }
                    await self?.finishResults(generation: generation, channel: channel)
                } catch {
                    await self?.failResults(generation: generation, channel: channel)
                }
            }
        }
    }

    fileprivate func isCurrent(_ generation: Int) -> Bool {
        isActive && self.generation == generation
    }

    private func finishResults(
        generation: Int,
        channel: BoundedEventChannel<SpeechRawEvent>
    ) async {
        guard isCurrent(generation), !Task.isCancelled else { return }
        isActive = false
        await channel.send(isFinishing ? .ended : .failed(.speechFailed))
        await channel.finish()
    }

    private func failResults(
        generation: Int,
        channel: BoundedEventChannel<SpeechRawEvent>
    ) async {
        guard isCurrent(generation), !Task.isCancelled else { return }
        isActive = false
        await channel.send(.failed(.speechFailed))
        await channel.finish()
    }

    fileprivate func nextInput(
        _ event: AudioSourceEvent,
        generation: Int
    ) async -> AnalyzerInput? {
        guard isCurrent(generation), !Task.isCancelled else { return nil }
        switch event {
        case .chunk(let chunk):
            if chunk.discontinuity {
                await channel?.send(.discontinuity(chunk.capturePTS))
                Task { [weak self] in
                    do { try await self?.reset() }
                    catch { /* reset has already emitted a scoped failure */ }
                }
                return nil
            }
            do {
                let input = try SpeechPCMConverter.makeInput(
                    chunk: chunk,
                    samplePosition: samplePosition
                )
                let (newPosition, overflow) = samplePosition.addingReportingOverflow(Int64(chunk.frameCount))
                guard !overflow else { throw FailureCode.speechFailed }
                samplePosition = newPosition
                await trimAnalysis(chunk: chunk)
                return input
            } catch {
                isActive = false
                await channel?.send(.failed(.speechFailed))
                await channel?.finish()
                return nil
            }
        case .ended:
            isFinishing = true
            Task { [weak self] in await self?.finish() }
            return nil
        case .failed(let code):
            isActive = false
            await channel?.send(.failed(code))
            await channel?.finish()
            return nil
        }
    }

    private func trimAnalysis(chunk: AudioChunk) async {
        let windowSeconds = Double(RuntimePolicy.transcriptWindowDuration.components.seconds)
        let positionSeconds = Double(samplePosition) / chunk.sampleRate
        guard positionSeconds > windowSeconds else { return }
        let cutoff = positionSeconds - windowSeconds
        await analyzer?.cancelAnalysis(
            before: CMTime(seconds: cutoff, preferredTimescale: 1_000_000)
        )
    }
}

private struct SystemAnalyzerInputs: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let backend: SystemSpeechBackend
    let generation: Int
    let input: AsyncStream<AudioSourceEvent>

    struct AsyncIterator: AsyncIteratorProtocol {
        let backend: SystemSpeechBackend
        let generation: Int
        var iterator: AsyncStream<AudioSourceEvent>.Iterator

        mutating func next() async -> AnalyzerInput? {
            guard await backend.isCurrent(generation), !Task.isCancelled,
                  let event = await iterator.next() else { return nil }
            return await backend.nextInput(event, generation: generation)
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(backend: backend, generation: generation, iterator: input.makeAsyncIterator())
    }
}

private enum SpeechRawResultFactory {
    static func make(
        range: CMTimeRange,
        text: AttributedString,
        isFinal: Bool
    ) -> SpeechRawResult {
        let sourceText = String(text.characters)
        var spans: [TranscriptSpan] = []
        for run in text.runs {
            guard let timeRange = run[keyPath: \.audioTimeRange] else { continue }
            let lower = text.characters.distance(from: text.characters.startIndex, to: run.range.lowerBound)
            let upper = text.characters.distance(from: text.characters.startIndex, to: run.range.upperBound)
            spans.append(TranscriptSpan(
                characterRange: lower..<upper,
                audioRange: audioRange(timeRange)
            ))
        }
        return SpeechRawResult(
            audioRange: audioRange(range),
            text: sourceText,
            spans: spans,
            isFinal: isFinal
        )
    }

    private static func audioRange(_ range: CMTimeRange) -> AudioRange {
        AudioRange(
            start: AudioTimestamp(value: range.start.value, timescale: range.start.timescale),
            end: AudioTimestamp(value: range.end.value, timescale: range.end.timescale)
        )
    }
}

enum SpeechPCMConverter {
    static func contractFormat(_ format: AVAudioFormat) throws -> AudioFormat {
        let description = format.streamDescription.pointee
        let sampleFormat: PCMSampleFormat
        switch format.commonFormat {
        case .pcmFormatFloat32: sampleFormat = .float32
        case .pcmFormatFloat64: sampleFormat = .float64
        case .pcmFormatInt16: sampleFormat = .signedInt16
        case .pcmFormatInt32: sampleFormat = .signedInt32
        default: throw FailureCode.unavailable
        }
        let bytesPerFrame = Int(description.mBytesPerFrame)
        guard format.sampleRate > 0, format.channelCount > 0, bytesPerFrame > 0 else {
            throw FailureCode.unavailable
        }
        return AudioFormat(
            sampleRate: format.sampleRate,
            channels: Int(format.channelCount),
            pcm: PCMFormat(
                sampleFormat: sampleFormat,
                isInterleaved: description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                isBigEndian: description.mFormatFlags & kAudioFormatFlagIsBigEndian != 0,
                bytesPerFrame: bytesPerFrame
            )
        )
    }

    static func makeInput(chunk: AudioChunk, samplePosition: Int64) throws -> AnalyzerInput {
        guard chunk.frameCount >= 0,
              chunk.frameCount <= Int(UInt32.max),
              chunk.channels > 0,
              chunk.channels <= Int(UInt32.max),
              chunk.sampleRate > 0,
              chunk.sampleRate <= Double(Int32.max),
              chunk.sampleRate.rounded() == chunk.sampleRate,
              !chunk.format.isBigEndian,
              samplePosition >= 0 else {
            throw FailureCode.speechFailed
        }
        let commonFormat: AVAudioCommonFormat
        switch chunk.format.sampleFormat {
        case .float32: commonFormat = .pcmFormatFloat32
        case .float64: commonFormat = .pcmFormatFloat64
        case .signedInt16: commonFormat = .pcmFormatInt16
        case .signedInt32: commonFormat = .pcmFormatInt32
        }
        guard let format = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: chunk.sampleRate,
            channels: AVAudioChannelCount(chunk.channels),
            interleaved: chunk.format.isInterleaved
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(chunk.frameCount)
        ) else {
            throw FailureCode.speechFailed
        }
        buffer.frameLength = AVAudioFrameCount(chunk.frameCount)
        let planes = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard planes.count == chunk.ownedPCM.count else { throw FailureCode.speechFailed }
        for (index, plane) in planes.enumerated() {
            let data = chunk.ownedPCM[index]
            guard let target = plane.mData, data.count == Int(plane.mDataByteSize) else {
                throw FailureCode.speechFailed
            }
            data.withUnsafeBytes { bytes in
                if let source = bytes.baseAddress {
                    target.copyMemory(from: source, byteCount: data.count)
                }
            }
        }
        let start = CMTime(
            value: samplePosition,
            timescale: Int32(chunk.sampleRate)
        )
        return AnalyzerInput(buffer: buffer, bufferStartTime: start)
    }
}
