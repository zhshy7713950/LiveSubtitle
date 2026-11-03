import Foundation
#if !TASK06_HOST_CHECK
import Testing
@testable import LiveSubtitle
#endif

struct Task06CheckFailure: Error {
    let message: String
}

func task06Require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Task06CheckFailure(message: message) }
}

func task06Value<T>(_ optional: T?) throws -> T {
    guard let optional else { throw Task06CheckFailure(message: "expected a value") }
    return optional
}

func task06Time(_ milliseconds: Int64) -> AudioTimestamp {
    AudioTimestamp(value: milliseconds, timescale: 1_000)
}

func task06Range(_ start: Int64, _ end: Int64) -> AudioRange {
    AudioRange(start: task06Time(start), end: task06Time(end))
}

func task06Instant(_ milliseconds: UInt64) -> MonotonicInstant {
    MonotonicInstant(uptimeNanoseconds: milliseconds * 1_000_000)
}

func task06Event(
    utteranceID: UUID = UUID(),
    revision: UInt64 = 0,
    text: String,
    range: AudioRange,
    spans: [TranscriptSpan]? = nil,
    isFinal: Bool = false,
    receivedAt: MonotonicInstant
) -> TranscriptEvent {
    TranscriptEvent(
        utteranceID: utteranceID,
        audioRange: range,
        revision: revision,
        text: text,
        spans: spans ?? task06CharacterSpans(text: text, range: range),
        isFinal: isFinal,
        receivedAt: receivedAt
    )
}

private func checkTranscriptWindowUsesGraphemeCharacterLimit() throws {
    var normalizer = TranscriptNormalizer()
    let text = String(repeating: "e\u{301}", count: 1_999) + "中👩\u{200d}💻"
    let event = task06Event(text: text, range: task06Range(0, 29_000), receivedAt: task06Instant(0))
    let normalized = try task06Value(normalizer.normalize(event))
    try task06Require(normalized.text.count == 2_000, "window must count grapheme clusters, not UTF-8 bytes")
    try task06Require(normalized.text.first == "e\u{301}", "a combining sequence must not be split")
    try task06Require(normalized.text.last == "👩\u{200d}💻", "an emoji sequence must not be split")
    try task06Require(normalized.spans.count == 2_000 && normalized.spans.first?.characterRange == 0..<1 &&
                        normalized.spans.last?.characterRange == 1_999..<2_000,
                      "span indexes must shift with the retained text")
}

private func checkTranscriptWindowDropsExpiredEvents() throws {
    var normalizer = TranscriptNormalizer()
    let oldID = UUID()
    _ = normalizer.normalize(task06Event(utteranceID: oldID, text: "old", range: task06Range(0, 1_000), receivedAt: task06Instant(0)))
    _ = normalizer.normalize(task06Event(text: "new", range: task06Range(31_000, 32_000), receivedAt: task06Instant(31_000)))
    try task06Require(normalizer.events.count == 1 && normalizer.events.first?.utteranceID != oldID,
                      "audio older than thirty seconds must leave the revision window")
}

private func checkConsumedCheckpointDoesNotReappend() throws {
    var normalizer = TranscriptNormalizer()
    let id = UUID()
    let initialSpans = (0..<6).map {
        TranscriptSpan(characterRange: $0..<($0 + 1), audioRange: task06Range(Int64($0) * 1_000, Int64($0 + 1) * 1_000))
    }
    _ = normalizer.normalize(task06Event(utteranceID: id, text: "abcdef", range: task06Range(0, 6_000),
                                        spans: initialSpans, receivedAt: task06Instant(0)))
    normalizer.consume(utteranceID: id, through: task06Time(2_000))
    let revisedSpans = initialSpans + [
        TranscriptSpan(characterRange: 6..<7, audioRange: task06Range(6_000, 7_000)),
        TranscriptSpan(characterRange: 7..<8, audioRange: task06Range(7_000, 8_000))
    ]
    let normalized = try task06Value(normalizer.normalize(task06Event(utteranceID: id, revision: 1, text: "abcdefXY",
                                                                   range: task06Range(0, 8_000), spans: revisedSpans,
                                                                   receivedAt: task06Instant(100))))
    try task06Require(normalized.text == "cdefXY", "text before the audio checkpoint must not be appended again")
    try task06Require(normalized.spans.map(\.characterRange) == [0..<1, 1..<2, 2..<3, 3..<4, 4..<5, 5..<6],
                      "checkpoint clipping must rebase every retained span")
}

private func checkFullyConsumedRevisionDoesNotReturnEmptyEvent() throws {
    var normalizer = TranscriptNormalizer()
    let id = UUID()
    let spans = [
        TranscriptSpan(characterRange: 0..<1, audioRange: task06Range(0, 1_000)),
        TranscriptSpan(characterRange: 1..<2, audioRange: task06Range(1_000, 2_000))
    ]
    _ = normalizer.normalize(task06Event(utteranceID: id, text: "ab", range: task06Range(0, 2_000),
                                        spans: spans, receivedAt: task06Instant(0)))
    normalizer.consume(utteranceID: id, through: task06Time(2_000))
    let normalized = normalizer.normalize(task06Event(utteranceID: id, revision: 1, text: "ab",
                                                     range: task06Range(0, 2_000), spans: spans,
                                                     receivedAt: task06Instant(100)))
    try task06Require(normalized == nil && normalizer.events.isEmpty,
                      "a fully consumed cumulative revision must disappear instead of emitting an empty caption")
}

private func checkFinalTextFreezesWithoutExplicitReplacement() throws {
    var normalizer = TranscriptNormalizer()
    let id = UUID()
    _ = normalizer.normalize(task06Event(utteranceID: id, text: "Final", range: task06Range(0, 1_000),
                                        isFinal: true, receivedAt: task06Instant(0)))
    let ignored = normalizer.normalize(task06Event(utteranceID: id, revision: 1, text: "Final changed",
                                                  range: task06Range(0, 1_000), isFinal: true,
                                                  receivedAt: task06Instant(100)))
    try task06Require(ignored == nil && normalizer.events.first?.text == "Final",
                      "a same-range event must not rewrite frozen final text")
    let replacement = try task06Value(normalizer.normalize(task06Event(utteranceID: id, revision: 2, text: "Replacement",
                                                                    range: task06Range(100, 1_100), isFinal: true,
                                                                    receivedAt: task06Instant(200))))
    try task06Require(replacement.text == "Replacement", "an explicit shifted-range replacement needs a new version")
}

private func checkSingleEventIsClippedToThirtySeconds() throws {
    var normalizer = TranscriptNormalizer()
    let spans = (0..<6).map {
        TranscriptSpan(characterRange: $0..<($0 + 1),
                       audioRange: task06Range(Int64($0) * 10_000, Int64($0 + 1) * 10_000))
    }
    let normalized = try task06Value(normalizer.normalize(task06Event(text: "abcdef", range: task06Range(0, 60_000),
                                                                      spans: spans, receivedAt: task06Instant(0))))
    try task06Require(normalized.text == "def", "a single cumulative event must also obey the thirty-second window")
}

private func checkMissingTimingAtWindowLimitRequestsDiscontinuity() throws {
    var normalizer = TranscriptNormalizer()
    let event = task06Event(text: String(repeating: "x", count: 2_001), range: task06Range(0, 29_000),
                            spans: [], receivedAt: task06Instant(0))
    let normalized = normalizer.normalize(event)
    try task06Require(normalized == nil && normalizer.requiresDiscontinuity,
                      "an unmapped cumulative transcript must reset at the bounded-window limit")
}

private func checkCoarseCheckpointRequestsDiscontinuity() throws {
    var normalizer = TranscriptNormalizer()
    let id = UUID()
    let event = task06Event(utteranceID: id, text: "coarse", range: task06Range(0, 10_000),
                            spans: [TranscriptSpan(characterRange: 0..<6, audioRange: task06Range(0, 10_000))],
                            receivedAt: task06Instant(0))
    _ = normalizer.normalize(event)
    normalizer.consume(utteranceID: id, through: task06Time(5_000))
    let revised = normalizer.normalize(task06Event(utteranceID: id, revision: 1, text: "coarse",
                                                  range: task06Range(0, 10_000), receivedAt: task06Instant(100)))
    try task06Require(revised == nil && normalizer.requiresDiscontinuity,
                      "a checkpoint through a coarse span must not return the consumed prefix or guess character timing")
}

private func checkCheckpointIndexRemainsBounded() throws {
    var normalizer = TranscriptNormalizer()
    for index in 0..<100 {
        let id = UUID()
        let event = task06Event(utteranceID: id, text: "x",
                                range: task06Range(Int64(index) * 1_000, Int64(index + 1) * 1_000),
                                isFinal: true, receivedAt: task06Instant(UInt64(index) * 1_000))
        _ = normalizer.normalize(event)
        normalizer.consume(utteranceID: id, through: event.audioRange.end)
        try task06Require(normalizer.checkpointCount <= RuntimePolicy.retainedSegmentLimit,
                          "checkpoint indexes grew with total utterances instead of the retained window")
    }
    try task06Require(normalizer.requiresDiscontinuity,
                      "checkpoint overflow must explicitly request a rebuild instead of silently dropping old-result protection")
}

private func runTranscriptWindowChecks() async throws {
    try checkTranscriptWindowUsesGraphemeCharacterLimit()
    try checkTranscriptWindowDropsExpiredEvents()
    try checkConsumedCheckpointDoesNotReappend()
    try checkFullyConsumedRevisionDoesNotReturnEmptyEvent()
    try checkFinalTextFreezesWithoutExplicitReplacement()
    try checkSingleEventIsClippedToThirtySeconds()
    try checkMissingTimingAtWindowLimitRequestsDiscontinuity()
    try checkCoarseCheckpointRequestsDiscontinuity()
    try checkCheckpointIndexRemainsBounded()
}

#if TASK06_HOST_CHECK
@main
private struct Task06HostChecks {
    static func main() async throws {
        try await runTranscriptWindowChecks()
        try await runCaptionStoreChecks()
        try await runCaptionSegmenterChecks()
        print("28 TASK-06 host checks passed; no SDK/device behavior tested.")
    }
}
#else
struct TranscriptWindowTests {
    @Test func testWindowUsesGraphemeCharacterLimit() throws {
        try checkTranscriptWindowUsesGraphemeCharacterLimit()
    }
    @Test func testWindowDropsExpiredEvents() throws {
        try checkTranscriptWindowDropsExpiredEvents()
    }
    @Test func testConsumedCheckpointDoesNotReappend() throws {
        try checkConsumedCheckpointDoesNotReappend()
    }
    @Test func testFullyConsumedRevisionDoesNotReturnEmptyEvent() throws {
        try checkFullyConsumedRevisionDoesNotReturnEmptyEvent()
    }
    @Test func testFinalTextFreezesWithoutExplicitReplacement() throws {
        try checkFinalTextFreezesWithoutExplicitReplacement()
    }
    @Test func testSingleEventIsClippedToThirtySeconds() throws {
        try checkSingleEventIsClippedToThirtySeconds()
    }
    @Test func testMissingTimingAtWindowLimitRequestsDiscontinuity() throws {
        try checkMissingTimingAtWindowLimitRequestsDiscontinuity()
    }
    @Test func testCoarseCheckpointRequestsDiscontinuity() throws {
        try checkCoarseCheckpointRequestsDiscontinuity()
    }
    @Test func testCheckpointIndexRemainsBounded() throws {
        try checkCheckpointIndexRemainsBounded()
    }
}
#endif
