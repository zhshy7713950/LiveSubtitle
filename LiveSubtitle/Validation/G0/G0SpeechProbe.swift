#if DEBUG && !targetEnvironment(simulator)
import AVFoundation
import Speech
import OSLog

struct G0SpeechMetrics: Sendable {
    var consumed = 0
    var nonSilent = 0
    var results = 0
    var inputDrops = 0
    var inputRate = 0.0
    var analyzerRate = 0.0
    var channels = 0
    var discontinuities = 0
    var failure = ""
    var maximumClockOffsetFrames: Int64 = 0
}

/// SDK objects and conversion stay inside this actor. G0 only, not SpeechServicing.
actor G0SpeechProbe {
    private var transcriber: SpeechTranscriber?
    private var dictation: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var converter: AnalyzerInputConverter?
    private var format: AVAudioFormat?
    private var reservedLocale: Locale?
    private var ownsReservation = false
    private var converted: [AnalyzerInput] = []
    private var heldSeconds = 0.0
    private var firstPTS: Double?
    private var previousEnd: Double?
    private var audioTiming = G0AudioTiming()
    private var failureCallback: (@Sendable (SessionIdentity, FailureCode) async -> Void)?
    private var resultTask: Task<Void, Never>?
    private var identity: SessionIdentity?
    private var metrics = G0SpeechMetrics()
    private var inputStage = "idle"
    private var lastInputEnd: CMTime?

    func prepare(progress: @escaping @Sendable (String) async -> Void) async throws -> String {
        do { return try await prepareResources(progress: progress) }
        catch {
            await release() // Cleanup is part of the tracked preparation task.
            throw error
        }
    }

    private func prepareResources(progress: @Sendable (String) async -> Void) async throws -> String {
        try Task.checkCancellation()
        await progress("识别：正在检查英文识别能力与语种")
        let requested = Locale(identifier: "en-US")
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
            try await install(locale: locale, progress: progress)
            return "SpeechTranscriber"
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) else {
            throw FailureCode.unsupportedLanguage
        }
        dictation = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [],
                                         reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        try await install(locale: locale, progress: progress)
        return "DictationTranscriber"
    }

    private var modules: [any SpeechModule] {
        if let transcriber { return [transcriber] }
        if let dictation { return [dictation] }
        return []
    }

    private func install(locale: Locale, progress: @Sendable (String) async -> Void) async throws {
        await progress("识别：正在预留英文模型资源")
        let existing = await AssetInventory.reservedLocales
        ownsReservation = !existing.contains(locale)
        if ownsReservation { _ = try await AssetInventory.reserve(locale: locale) }
        reservedLocale = locale
        try Task.checkCancellation()
        await progress("识别：正在查询模型安装请求")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            await progress("识别：正在下载 / 安装英文模型，请保持前台联网")
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        await progress("识别：正在核对安装状态与输入格式")
        guard await AssetInventory.status(forModules: modules) == .installed,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw FailureCode.assetsMissing
        }
        self.format = format
    }

    func start(identity: SessionIdentity, inbox: G0AudioInbox,
               onTranscript: @escaping @Sendable (G0Transcript) async -> Void,
               onFailure: @escaping @Sendable (SessionIdentity, FailureCode) async -> Void) async throws {
        guard let format, !modules.isEmpty else { throw FailureCode.assetsMissing }
        self.identity = identity
        metrics = G0SpeechMetrics()
        metrics.analyzerRate = format.sampleRate
        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer
        converter = AnalyzerInputConverter(analyzerFormat: format)
        converted = []
        heldSeconds = 0
        firstPTS = nil
        previousEnd = nil
        audioTiming = G0AudioTiming()
        lastInputEnd = nil
        failureCallback = onFailure
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        try await analyzer.start(inputSequence: G0AnalyzerInputs(probe: self, identity: identity, inbox: inbox))
        try Task.checkCancellation()
        if let transcriber {
            resultTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self, await self.isCurrent(identity), !Task.isCancelled else { return }
                        try await self.publish(identity, range: result.range, text: result.text, final: result.isFinal, callback: onTranscript)
                    }
                    if let self, await self.isCurrent(identity), !Task.isCancelled {
                        Logger(subsystem: "com.zhshy7713950.LiveSubtitle", category: "G0Speech").error("speech_stage=results_ended")
                        await onFailure(identity, .speechFailed)
                    }
                } catch {
                    if let self, await self.isCurrent(identity), !Task.isCancelled {
                        await self.recordFailure(error, stage: "results")
                        await onFailure(identity, .speechFailed)
                    }
                }
            }
        } else if let dictation {
            resultTask = Task { [weak self] in
                do {
                    for try await result in dictation.results {
                        guard let self, await self.isCurrent(identity), !Task.isCancelled else { return }
                        try await self.publish(identity, range: result.range, text: result.text, final: result.isFinal, callback: onTranscript)
                    }
                    if let self, await self.isCurrent(identity), !Task.isCancelled { await onFailure(identity, .speechFailed) }
                } catch {
                    if let self, await self.isCurrent(identity), !Task.isCancelled { await onFailure(identity, .speechFailed) }
                }
            }
        }
    }

    func nextInput(identity token: SessionIdentity, inbox: G0AudioInbox) async throws -> AnalyzerInput? {
        guard identity == token, !Task.isCancelled else { return nil }
        if !converted.isEmpty { return popConverted() }
        if heldSeconds > 0 {
            inbox.consumed(token, seconds: heldSeconds)
            heldSeconds = 0
        }
        do {
            while identity == token, inbox.accepts(token), !Task.isCancelled {
                if let failure = inbox.failure(token) { throw failure }
                guard let packet = inbox.pop(token) else {
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                }
                let pts = Double(packet.chunk.capturePTS.value) / Double(packet.chunk.capturePTS.timescale)
                if firstPTS == nil { firstPTS = pts }
                let duration = Double(packet.chunk.frameCount) / packet.chunk.sampleRate
                heldSeconds += duration
                if let end = previousEnd, abs(pts - end) > 0.1 {
                    metrics.discontinuities += 1
                    throw FailureCode.speechFailed
                }
                previousEnd = pts + duration
                try await consume(packet.chunk, relativePTS: pts - (firstPTS ?? pts))
                guard identity == token, !Task.isCancelled else { return nil }
                if !converted.isEmpty { return popConverted() }
            }
            return nil
        } catch {
            if identity == token, !Task.isCancelled {
                recordFailure(error, stage: inputStage)
                await failureCallback?(token, (error as? FailureCode) ?? .speechFailed)
            }
            throw error
        }
    }

    private func isCurrent(_ token: SessionIdentity) -> Bool { identity == token }

    private func popConverted() -> AnalyzerInput {
        let input = converted.removeFirst()
        if let start = input.bufferStartTime {
            let overlap = lastInputEnd.map { CMTimeCompare(start, $0) < 0 } ?? false
            if metrics.consumed <= 8 || overlap {
                let previous = lastInputEnd ?? .zero
                Logger(subsystem: "com.zhshy7713950.LiveSubtitle", category: "G0Speech").notice("speech_stage=input_time start=\(start.value)/\(start.timescale) duration=\(input.bufferDuration.value)/\(input.bufferDuration.timescale) previous_end=\(previous.value)/\(previous.timescale) overlap=\(overlap) rate=\(input.bufferFormat.sampleRate) channels=\(input.bufferFormat.channelCount)")
            }
            lastInputEnd = CMTimeAdd(start, input.bufferDuration)
        }
        return input
    }

    private func recordFailure(_ error: any Error, stage: String) {
        let native = error as NSError
        // Error-domain identifiers and numeric codes are metadata; never log
        // localizedDescription, userInfo, audio, or recognition output.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        let domain = native.domain.count <= 128 && native.domain.unicodeScalars.allSatisfy(allowed.contains) ? native.domain : "other"
        let audioSystem = native.domain == SFSpeechErrorDomain && native.code == SFSpeechError.Code.cannotConfigureAudioSystem.rawValue
        metrics.failure = "\(stage): \(domain)#\(native.code) audioSystem=\(audioSystem)"
        let diagnostic = metrics.failure
        Logger(subsystem: "com.zhshy7713950.LiveSubtitle", category: "G0Speech").error("speech_stage=\(diagnostic, privacy: .public)")
    }

    private func publish(_ token: SessionIdentity, range: CMTimeRange, text: AttributedString, final: Bool,
                         callback: @Sendable (G0Transcript) async -> Void) async throws {
        guard identity == token else { return }
        guard text.characters.count <= RuntimePolicy.transcriptWindowCharacterLimit else { throw FailureCode.speechFailed }
        let source = String(text.characters.suffix(RuntimePolicy.sourceCharacterLimit))
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        metrics.results += 1
        let key = CMTimeConvertScale(range.start, timescale: 1_000, method: .default).value
        let end = CMTimeConvertScale(CMTimeRangeGetEnd(range), timescale: 1_000, method: .default).value
        await callback(G0Transcript(identity: token, key: key, text: source, isFinal: final, end: end))
    }

    private func consume(_ chunk: AudioChunk, relativePTS: Double) async throws {
        inputStage = "pcm_format"
        guard let converter else { throw FailureCode.speechFailed }
        let common: AVAudioCommonFormat
        switch chunk.format.sampleFormat {
        case .float32: common = .pcmFormatFloat32
        case .float64: common = .pcmFormatFloat64
        case .signedInt16: common = .pcmFormatInt16
        case .signedInt32: common = .pcmFormatInt32
        }
        guard !chunk.format.isBigEndian,
              let inputFormat = AVAudioFormat(commonFormat: common, sampleRate: chunk.sampleRate,
                                               channels: AVAudioChannelCount(chunk.channels), interleaved: chunk.format.isInterleaved),
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(chunk.frameCount)) else {
            throw FailureCode.speechFailed
        }
        buffer.frameLength = AVAudioFrameCount(chunk.frameCount)
        let planes = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        inputStage = "pcm_ownership"
        guard planes.count == chunk.ownedPCM.count else { throw FailureCode.speechFailed }
        var peak = 0.0
        for (index, plane) in planes.enumerated() {
            let data = chunk.ownedPCM[index]
            guard let target = plane.mData, data.count == Int(plane.mDataByteSize) else { throw FailureCode.speechFailed }
            data.withUnsafeBytes { bytes in
                if let source = bytes.baseAddress { target.copyMemory(from: source, byteCount: data.count) }
            }
            switch common {
            case .pcmFormatFloat32:
                peak = max(peak, Double(UnsafeBufferPointer(start: target.assumingMemoryBound(to: Float.self), count: data.count / 4).map { abs($0) }.max() ?? 0))
            case .pcmFormatInt16:
                peak = max(peak, UnsafeBufferPointer(start: target.assumingMemoryBound(to: Int16.self), count: data.count / 2).map { abs(Double($0)) / 32768 }.max() ?? 0)
            case .pcmFormatFloat64:
                peak = max(peak, UnsafeBufferPointer(start: target.assumingMemoryBound(to: Double.self), count: data.count / 8).map { abs($0) }.max() ?? 0)
            case .pcmFormatInt32:
                peak = max(peak, UnsafeBufferPointer(start: target.assumingMemoryBound(to: Int32.self), count: data.count / 4).map { abs(Double($0)) / 2147483648 }.max() ?? 0)
            default: break
            }
        }
        metrics.consumed += 1
        if peak > 0.0001 { metrics.nonSilent += 1 }
        metrics.inputRate = chunk.sampleRate
        metrics.channels = chunk.channels
        inputStage = "sample_clock"
        let position = try audioTiming.framePosition(for: chunk.capturePTS, frameCount: chunk.frameCount, sampleRate: chunk.sampleRate)
        metrics.maximumClockOffsetFrames = audioTiming.maximumClockOffsetFrames
        if metrics.consumed <= 8 {
            Logger(subsystem: "com.zhshy7713950.LiveSubtitle", category: "G0Speech").notice("speech_stage=capture_time sequence=\(chunk.sequence) frames=\(chunk.frameCount) sample_position=\(position) capture_position=\(self.audioTiming.captureFramePosition) rate=\(chunk.sampleRate)")
        }
        let time = AVAudioTime(sampleTime: position, atRate: chunk.sampleRate)
        inputStage = "conversion"
        converted = try converter.convert(buffer, at: time)
        inputStage = "analysis_window"
        // Explicitly trim old analysis audio; never retain an unbounded transcript window.
        if relativePTS > Double(RuntimePolicy.transcriptWindowDuration.components.seconds) {
            await analyzer?.cancelAnalysis(before: CMTime(seconds: relativePTS - Double(RuntimePolicy.transcriptWindowDuration.components.seconds), preferredTimescale: 1_000))
        }
    }

    func snapshot() -> G0SpeechMetrics { metrics }

    func stop() async {
        identity = nil
        resultTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        await resultTask?.value
        resultTask = nil
        converted = []
        heldSeconds = 0
        failureCallback = nil
        converter = nil
        analyzer = nil
    }

    func release() async {
        await stop()
        transcriber = nil
        dictation = nil
        format = nil
        let reservation = ownsReservation ? reservedLocale : nil
        reservedLocale = nil
        ownsReservation = false
        if let reservation { _ = await AssetInventory.release(reservedLocale: reservation) }
    }
}

/// Pull-based input: no extra AsyncStream queue and no per-buffer tasks.
private struct G0AnalyzerInputs: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let probe: G0SpeechProbe
    let identity: SessionIdentity
    let inbox: G0AudioInbox
    struct AsyncIterator: AsyncIteratorProtocol {
        let source: G0AnalyzerInputs
        mutating func next() async throws -> AnalyzerInput? {
            try await source.probe.nextInput(identity: source.identity, inbox: source.inbox)
        }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(source: self) }
}
#endif
