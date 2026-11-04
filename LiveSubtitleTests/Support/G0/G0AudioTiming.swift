#if DEBUG
#if !G0_HOST_CHECK
@testable import LiveSubtitle
#endif
import Foundation
import CoreMedia

/// Anchor capture PTS while advancing the analyzer's sample clock by actual
/// PCM frame counts. Capture-clock drift must not make contiguous PCM overlap.
struct G0AudioTiming {
    private var origin: CMTime?
    private var rate: Double?
    private var nextFrame: Int64 = 0
    private(set) var captureFramePosition: Int64 = 0
    private(set) var maximumClockOffsetFrames: Int64 = 0

    mutating func framePosition(for timestamp: AudioTimestamp, frameCount: Int, sampleRate: Double) throws -> Int64 {
        guard timestamp.timescale > 0, frameCount > 0, sampleRate.isFinite, sampleRate > 0,
              sampleRate <= Double(Int32.max), sampleRate.rounded() == sampleRate else {
            throw FailureCode.captureFailed
        }
        if let rate, rate != sampleRate { throw FailureCode.captureFailed }
        let current = CMTime(value: timestamp.value, timescale: timestamp.timescale)
        if origin == nil { origin = current }
        guard let origin else { throw FailureCode.captureFailed }
        let relative = CMTimeSubtract(current, origin)
        let frames = CMTimeConvertScale(relative, timescale: Int32(sampleRate), method: .roundHalfAwayFromZero)
        guard relative.isNumeric, frames.isNumeric, frames.value >= 0 else { throw FailureCode.captureFailed }
        let position = nextFrame
        let (advanced, overflow) = nextFrame.addingReportingOverflow(Int64(frameCount))
        guard !overflow else { throw FailureCode.captureFailed }
        captureFramePosition = frames.value
        maximumClockOffsetFrames = max(maximumClockOffsetFrames, abs(frames.value - position))
        nextFrame = advanced
        rate = sampleRate
        return position
    }
}
#endif
