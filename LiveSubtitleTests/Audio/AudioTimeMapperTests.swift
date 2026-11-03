import Foundation
#if !TASK04_HOST_CHECK
import Testing
@testable import LiveSubtitle
#endif

struct Task04CheckFailure: Error {
    let message: String
}

func task04Require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() {
        throw Task04CheckFailure(message: message)
    }
}

private func testContinuousSampleClockIgnoresCaptureOrigin() throws {
    var mapper = AudioTimeMapper()
    let origin: Int64 = 1_000_000_000_000
    for index in 0..<3 {
        let timestamp = try mapper.map(
            capturePTS: AudioTimestamp(value: origin + Int64(index * 16_000_000), timescale: 1_000_000_000),
            sourceFrameCount: 768,
            sourceSampleRate: 48_000,
            outputFrameCount: 256,
            outputSampleRate: 16_000,
            reset: index == 0
        )
        try task04Require(timestamp == AudioTimestamp(value: Int64(index * 256), timescale: 16_000),
                          "PCM output clock must advance by converted frame counts")
    }
}

private func testCaptureClockOneFrameDriftDoesNotResetTimeline() throws {
    var mapper = AudioTimeMapper()
    let origin: Int64 = 1_000_000_000_000
    _ = try mapper.map(capturePTS: AudioTimestamp(value: origin, timescale: 1_000_000_000),
                       sourceFrameCount: 768, sourceSampleRate: 48_000,
                       outputFrameCount: 256, outputSampleRate: 16_000, reset: true)
    let shifted = AudioTimestamp(value: origin + 16_000_000 - 20_833, timescale: 1_000_000_000)
    let discontinuity = try mapper.requiresDiscontinuity(capturePTS: shifted,
                                                         sourceFrameCount: 768,
                                                         sourceSampleRate: 48_000)
    try task04Require(!discontinuity, "sub-frame capture clock drift must not reset contiguous PCM")
    let timestamp = try mapper.map(capturePTS: shifted, sourceFrameCount: 768, sourceSampleRate: 48_000,
                                   outputFrameCount: 256, outputSampleRate: 16_000, reset: discontinuity)
    try task04Require(timestamp.value == 256, "capture clock drift must not overlap the next PCM frame")
}

private func testRealPTSGapMarksDiscontinuity() throws {
    var mapper = AudioTimeMapper()
    _ = try mapper.map(capturePTS: AudioTimestamp(value: 0, timescale: 48_000),
                       sourceFrameCount: 768, sourceSampleRate: 48_000,
                       outputFrameCount: 256, outputSampleRate: 16_000, reset: true)
    let gap = AudioTimestamp(value: 770, timescale: 48_000)
    let discontinuity = try mapper.requiresDiscontinuity(capturePTS: gap,
                                                         sourceFrameCount: 768,
                                                         sourceSampleRate: 48_000)
    try task04Require(discontinuity, "a gap larger than one source frame is a real discontinuity")
    let timestamp = try mapper.map(capturePTS: gap, sourceFrameCount: 768, sourceSampleRate: 48_000,
                                   outputFrameCount: 256, outputSampleRate: 16_000, reset: discontinuity)
    try task04Require(timestamp.value == 0, "a discontinuity starts a new recognition timeline")
}

private func testRouteResetStartsNewTimeline() throws {
    var mapper = AudioTimeMapper()
    _ = try mapper.map(capturePTS: AudioTimestamp(value: 0, timescale: 48_000),
                       sourceFrameCount: 768, sourceSampleRate: 48_000,
                       outputFrameCount: 256, outputSampleRate: 16_000, reset: true)
    let timestamp = try mapper.map(capturePTS: AudioTimestamp(value: 768, timescale: 48_000),
                                   sourceFrameCount: 768, sourceSampleRate: 48_000,
                                   outputFrameCount: 256, outputSampleRate: 16_000, reset: true)
    try task04Require(timestamp.value == 0, "route changes explicitly reset the sample clock")
}

private func testInvalidTimeMappingSamplesAreRejected() throws {
    let invalid: [(AudioTimestamp, Int, Double, Double)] = [
        (AudioTimestamp(value: 0, timescale: 0), 768, 48_000, 16_000),
        (AudioTimestamp(value: 0, timescale: 48_000), 0, 48_000, 16_000),
        (AudioTimestamp(value: 0, timescale: 48_000), 768, 0, 16_000),
        (AudioTimestamp(value: 0, timescale: 48_000), 768, 48_000.5, 16_000),
        (AudioTimestamp(value: 0, timescale: 48_000), 768, 48_000, 0)
    ]
    for (pts, frames, sourceRate, outputRate) in invalid {
        var mapper = AudioTimeMapper()
        do {
            _ = try mapper.map(capturePTS: pts, sourceFrameCount: frames, sourceSampleRate: sourceRate,
                               outputFrameCount: 256, outputSampleRate: outputRate, reset: true)
            throw Task04CheckFailure(message: "invalid timing input was accepted")
        } catch is FailureCode {
            // Expected safe category; no raw SDK error escapes.
        }
    }
}

func runAudioTimeMapperChecks() async throws {
    try testContinuousSampleClockIgnoresCaptureOrigin()
    try testCaptureClockOneFrameDriftDoesNotResetTimeline()
    try testRealPTSGapMarksDiscontinuity()
    try testRouteResetStartsNewTimeline()
    try testInvalidTimeMappingSamplesAreRejected()
}

#if TASK04_HOST_CHECK
@main
struct Task04HostChecks {
    static func main() async throws {
        let allChecks: [(String, () async throws -> Void)] = [
            ("continuousSampleClock", testContinuousSampleClockIgnoresCaptureOrigin),
            ("oneFrameCaptureDrift", testCaptureClockOneFrameDriftDoesNotResetTimeline),
            ("realPTSGap", testRealPTSGapMarksDiscontinuity),
            ("routeReset", testRouteResetStartsNewTimeline),
            ("invalidTiming", testInvalidTimeMappingSamplesAreRejected),
            ("pcmOwnership", checkPCMOwnershipSurvivesCallbackReturn),
            ("overflow", checkOverflowDropsOldestAndMarksDiscontinuity),
            ("controlEvents", checkControlEventsSurviveOverflow),
            ("consumerCancellation", checkConsumerCancellationClosesUnderlyingStream),
            ("silenceVsNoSamples", checkSilenceAndNoSamplesDiffer),
            ("formatChange", checkFormatChangeRebuildsConverter),
            ("oversizedMetadata", checkOversizedPCMMetadataIsRejected),
            ("pickerCancellation", checkCapturePickerCancellationReturnsCancellationError),
            ("captureLifecycle", checkCaptureSourceDeliversAudioAndStopsDriver),
            ("gracefulEOF", checkGracefulEndDrainsQueuedAudio),
            ("converterDrain", checkConverterEndOfStreamDeliversTail),
            ("oldPipelineCancellation", checkOldOutputCancellationDoesNotStopNewPipeline),
            ("oldCaptureCancellation", checkOldOutputCancellationDoesNotStopNewCapture),
            ("pendingPickerCancellation", checkPendingPickerStartRespondsToCancellation),
            ("explicitCaptureStop", checkExplicitCaptureStopClearsQueuedAudio),
            ("coreEventGeneration", checkCaptureEventGenerationRejectsOldCoreCallbacks)
        ]
        let selected = Set(CommandLine.arguments.dropFirst())
        let checks = allChecks.filter { selected.isEmpty || selected.contains($0.0) }
        for (name, check) in checks {
            try await check()
            print("PASS \(name)")
        }
        print("\(checks.count) TASK-04 host checks passed; no iOS capture/device behavior tested.")
    }
}
#else
struct AudioTimeMapperTests {
    @Test func continuousSampleClock() throws { try testContinuousSampleClockIgnoresCaptureOrigin() }
    @Test func oneFrameCaptureDrift() throws { try testCaptureClockOneFrameDriftDoesNotResetTimeline() }
    @Test func realPTSGap() throws { try testRealPTSGapMarksDiscontinuity() }
    @Test func routeReset() throws { try testRouteResetStartsNewTimeline() }
    @Test func invalidTiming() throws { try testInvalidTimeMappingSamplesAreRejected() }
}
#endif
