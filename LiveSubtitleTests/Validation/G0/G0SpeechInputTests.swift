#if DEBUG && !targetEnvironment(simulator)
import AVFoundation
import Speech
import Testing
@testable import LiveSubtitle

/// Synthetic silence only: no microphone, capture, user media, or transcription
/// is logged. Exercise the same SDK converter/analyzer handoff in isolation.
@Suite(.serialized)
struct G0SpeechInputTests {
    @MainActor @Test
    func convertedStereoFixtureCanFinishAnalysis() async throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try audio.setActive(true)
        do {
            try await analyzeFixture(useCaptureClock: false)
            try audio.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    @MainActor @Test
    func capturedRationalTimeFixtureCanFinishAnalysis() async throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try audio.setActive(true)
        do {
            try await analyzeFixture(useCaptureClock: true)
            try await analyzeFixture(useCaptureClock: true, jitter: true)
            try audio.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    private func analyzeFixture(useCaptureClock: Bool, jitter: Bool = false) async throws {
        let locale = try #require(await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")))
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        let existing = await AssetInventory.reservedLocales
        let owns = !existing.contains(locale)
        if owns { _ = try await AssetInventory.reserve(locale: locale) }
        do {
            #expect(await AssetInventory.status(forModules: [module]) == .installed)
            let target = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]))
            let converter = AnalyzerInputConverter(analyzerFormat: target)
            let source = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
            var inputs: [AnalyzerInput] = []
            var timing = G0AudioTiming()
            for index in 0..<5 {
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 768))
                buffer.frameLength = 768
                for plane in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                    if let pointer = plane.mData { memset(pointer, 0, Int(plane.mDataByteSize)) }
                }
                let clockOffset: Int64 = jitter && index >= 2 ? -21_000 : 0
                let capturePTS = AudioTimestamp(value: 1_000_000_000_000 + Int64(index * 16_000_000) + clockOffset, timescale: 1_000_000_000)
                let position = useCaptureClock ? try timing.framePosition(for: capturePTS, frameCount: 768, sampleRate: 48_000) : Int64(index * 768)
                let time = AVAudioTime(sampleTime: position, atRate: 48_000)
                inputs += try converter.convert(buffer, at: time)
            }
            inputs += try converter.flush()
            let analyzer = SpeechAnalyzer(modules: [module])
            let results = Task {
                for try await _ in module.results { /* Discard synthetic output. */ }
            }
            do {
                try await analyzer.prepareToAnalyze(in: target)
                try await analyzer.start(inputSequence: G0FixtureInputs(values: inputs))
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                try await results.value
            } catch {
                results.cancel()
                await analyzer.cancelAndFinishNow()
                _ = try? await results.value
                throw error
            }
            if owns { _ = await AssetInventory.release(reservedLocale: locale) }
        } catch {
            if owns { _ = await AssetInventory.release(reservedLocale: locale) }
            throw error
        }
    }
}

private struct G0FixtureInputs: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let values: [AnalyzerInput]
    struct AsyncIterator: AsyncIteratorProtocol {
        let values: [AnalyzerInput]
        var index = 0
        mutating func next() async -> AnalyzerInput? {
            guard index < values.count else { return nil }
            defer { index += 1 }
            return values[index]
        }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(values: values) }
}
#endif
