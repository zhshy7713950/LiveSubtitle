import CoreMedia
import Foundation

/// Keeps recognition PCM contiguous even when the capture clock drifts slightly.
struct AudioTimeMapper {
    private var previousSourceEnd: CMTime?
    private var nextOutputFrame: Int64 = 0

    func requiresDiscontinuity(
        capturePTS: AudioTimestamp,
        sourceFrameCount: Int,
        sourceSampleRate: Double
    ) throws -> Bool {
        try Self.validateSource(capturePTS: capturePTS, frameCount: sourceFrameCount, sampleRate: sourceSampleRate)
        guard let previousSourceEnd else { return false }
        let current = CMTime(value: capturePTS.value, timescale: capturePTS.timescale)
        let tolerance = CMTime(value: 1, timescale: Int32(sourceSampleRate))
        return CMTimeCompare(current, CMTimeAdd(previousSourceEnd, tolerance)) > 0
            || CMTimeCompare(current, CMTimeSubtract(previousSourceEnd, tolerance)) < 0
    }

    mutating func map(
        capturePTS: AudioTimestamp,
        sourceFrameCount: Int,
        sourceSampleRate: Double,
        outputFrameCount: Int,
        outputSampleRate: Double,
        reset: Bool
    ) throws -> AudioTimestamp {
        try Self.validateSource(capturePTS: capturePTS, frameCount: sourceFrameCount, sampleRate: sourceSampleRate)
        guard outputFrameCount >= 0, Self.isIntegerRate(outputSampleRate) else {
            throw FailureCode.captureFailed
        }
        let current = CMTime(value: capturePTS.value, timescale: capturePTS.timescale)
        let newSourceEnd = CMTimeAdd(
            current,
            CMTime(value: Int64(sourceFrameCount), timescale: Int32(sourceSampleRate))
        )
        guard newSourceEnd.isNumeric else { throw FailureCode.captureFailed }
        let (advanced, overflow) = nextOutputFrame.addingReportingOverflow(Int64(outputFrameCount))
        guard !overflow else { throw FailureCode.captureFailed }

        if reset { nextOutputFrame = 0 }
        let mapped = AudioTimestamp(value: nextOutputFrame, timescale: Int32(outputSampleRate))
        nextOutputFrame = reset ? Int64(outputFrameCount) : advanced
        previousSourceEnd = newSourceEnd
        return mapped
    }

    mutating func mapDrainedOutput(frameCount: Int, sampleRate: Double) throws -> AudioTimestamp {
        guard frameCount > 0, Self.isIntegerRate(sampleRate) else { throw FailureCode.captureFailed }
        let mapped = AudioTimestamp(value: nextOutputFrame, timescale: Int32(sampleRate))
        let (advanced, overflow) = nextOutputFrame.addingReportingOverflow(Int64(frameCount))
        guard !overflow else { throw FailureCode.captureFailed }
        nextOutputFrame = advanced
        return mapped
    }

    private static func validateSource(
        capturePTS: AudioTimestamp,
        frameCount: Int,
        sampleRate: Double
    ) throws {
        let time = CMTime(value: capturePTS.value, timescale: capturePTS.timescale)
        guard capturePTS.value >= 0, time.isNumeric, frameCount > 0, isIntegerRate(sampleRate) else {
            throw FailureCode.captureFailed
        }
    }

    private static func isIntegerRate(_ sampleRate: Double) -> Bool {
        sampleRate.isFinite && sampleRate > 0 && sampleRate <= Double(Int32.max)
            && sampleRate.rounded() == sampleRate
    }
}
