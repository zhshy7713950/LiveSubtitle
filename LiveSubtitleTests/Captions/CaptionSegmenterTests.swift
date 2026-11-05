import Foundation
import Synchronization
#if !TASK06_HOST_CHECK
import Testing
@testable import LiveSubtitle
#endif

private final class Task06Clock: MonotonicClock, Sendable {
    private let ticks = Mutex<UInt64>(0)

    func now() -> MonotonicInstant {
        MonotonicInstant(uptimeNanoseconds: ticks.withLock { $0 })
    }

    func advance(toMilliseconds milliseconds: UInt64) {
        ticks.withLock { $0 = milliseconds * 1_000_000 }
    }

    func sleep(until deadline: MonotonicInstant) async throws {
        while now().uptimeNanoseconds < deadline.uptimeNanoseconds {
            try Task.checkCancellation()
            await Task.yield()
        }
        try Task.checkCancellation()
    }
}

private actor Task06SpeechBuffer {
    private var events: [SpeechEvent] = []
    private var waiter: CheckedContinuation<SpeechEvent?, Never>?
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false

    func push(_ event: SpeechEvent) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: event)
        } else {
            events.append(event)
        }
    }

    func next() async -> SpeechEvent? {
        if !events.isEmpty { return events.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            for readWaiter in readWaiters { readWaiter.resume() }
            readWaiters.removeAll()
        }
    }

    func waitForNextRead() async {
        if waiter != nil || closed { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    func close() {
        closed = true
        waiter?.resume(returning: nil)
        waiter = nil
        for readWaiter in readWaiters { readWaiter.resume() }
        readWaiters.removeAll()
    }
}

private func task06WaitForInput(_ buffer: Task06SpeechBuffer) async throws {
    await buffer.waitForNextRead()
}

private func task06Flush() async {
    for _ in 0..<12 { await Task.yield() }
}

func task06CharacterSpans(text: String, range: AudioRange) -> [TranscriptSpan] {
    let count = max(text.count, 1)
    let duration = range.end.value - range.start.value
    return (0..<text.count).map { index in
        let start = range.start.value + duration * Int64(index) / Int64(count)
        let end = range.start.value + duration * Int64(index + 1) / Int64(count)
        return TranscriptSpan(characterRange: index..<(index + 1),
                              audioRange: AudioRange(start: AudioTimestamp(value: start, timescale: range.start.timescale),
                                                     end: AudioTimestamp(value: end, timescale: range.start.timescale)))
    }
}

private func checkRevisionReplacesSameSegment() async throws {
    let clock = Task06Clock()
    let segmenter = CaptionSegmenter(clock: clock)
    let (input, continuation) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
    let output = await segmenter.start(input: input)
    var iterator = output.makeAsyncIterator()
    let id = UUID()

    continuation.yield(.transcript(task06Event(utteranceID: id, text: "Draft draft", range: task06Range(0, 1_000),
                                               receivedAt: task06Instant(0))))
    await task06Flush()
    clock.advance(toMilliseconds: 300)
    continuation.yield(.transcript(task06Event(utteranceID: id, revision: 1, text: "Draft",
                                               range: task06Range(0, 1_000), receivedAt: task06Instant(300))))
    guard case .upsert(let first)? = await iterator.next() else {
        throw Task06CheckFailure(message: "stable shortened text did not produce a caption")
    }
    clock.advance(toMilliseconds: 400)
    continuation.yield(.transcript(task06Event(utteranceID: id, revision: 2, text: "Draft revised",
                                               range: task06Range(0, 1_400), receivedAt: task06Instant(400))))
    guard case .upsert(let revised)? = await iterator.next() else {
        throw Task06CheckFailure(message: "a revised emitted segment did not update")
    }
    clock.advance(toMilliseconds: 500)
    continuation.yield(.transcript(task06Event(utteranceID: id, revision: 3, text: "Draft revised.",
                                               range: task06Range(0, 1_500), isFinal: true,
                                               receivedAt: task06Instant(500))))
    guard case .upsert(let final)? = await iterator.next() else {
        throw Task06CheckFailure(message: "final punctuation did not update the same segment")
    }
    try task06Require(first.segmentID == revised.segmentID && revised.segmentID == final.segmentID,
                      "revisions must retain segment identity")
    try task06Require(first.sourceText == "Draft" && revised.sourceText == "Draft revised" && final.sourceText == "Draft revised.",
                      "shortening, duplicate words and final punctuation must replace rather than append")
    try task06Require(first.sourceRevision < revised.sourceRevision && revised.sourceRevision < final.sourceRevision,
                      "every emitted source revision must increase")
    try task06Require(final.stability == .final && final.audioRange.end == task06Time(1_500),
                      "final must merge the revised audio range")
    await segmenter.reset()
    continuation.finish()
}

private func checkTimedSegmentation() async throws {
    do {
        let clock = Task06Clock()
        let segmenter = CaptionSegmenter(clock: clock)
        let (input, continuation) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let output = await segmenter.start(input: input)
        var iterator = output.makeAsyncIterator()
        let id = UUID()
        continuation.yield(.transcript(task06Event(utteranceID: id, text: "pause", range: task06Range(0, 400),
                                                   receivedAt: task06Instant(0))))
        await task06Flush()
        clock.advance(toMilliseconds: 450)
        guard case .upsert(let paused)? = await iterator.next() else {
            throw Task06CheckFailure(message: "pause deadline did not close the caption")
        }
        clock.advance(toMilliseconds: 500)
        let spans = [
            TranscriptSpan(characterRange: 0..<5, audioRange: task06Range(0, 400)),
            TranscriptSpan(characterRange: 5..<10, audioRange: task06Range(500, 900))
        ]
        continuation.yield(.transcript(task06Event(utteranceID: id, revision: 1, text: "pause next",
                                                   range: task06Range(0, 900), spans: spans,
                                                   receivedAt: task06Instant(500))))
        await task06Flush()
        clock.advance(toMilliseconds: 600)
        continuation.yield(.transcript(task06Event(utteranceID: id, revision: 2, text: "pause next",
                                                   range: task06Range(0, 900), spans: spans, isFinal: false,
                                                   receivedAt: task06Instant(600))))
        await task06Flush()
        clock.advance(toMilliseconds: 950)
        guard case .upsert(let next)? = await iterator.next() else {
            throw Task06CheckFailure(message: "post-pause text did not produce a new caption")
        }
        try task06Require(next.segmentID != paused.segmentID && next.sourceText == "next",
                          "text consumed at a pause must not be appended to the next caption; actual=\(next.sourceText.debugDescription), sameID=\(next.segmentID == paused.segmentID)")
        try task06Require(next.audioRange.start == task06Time(500),
                          "the retained caption must use the first retained span's audio start")
        await segmenter.reset()
        continuation.finish()
    }

    do {
        let clock = Task06Clock()
        let segmenter = CaptionSegmenter(clock: clock)
        let (input, continuation) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let output = await segmenter.start(input: input)
        var iterator = output.makeAsyncIterator()
        let id = UUID()
        continuation.yield(.transcript(task06Event(utteranceID: id, text: "two", range: task06Range(0, 1_000),
                                                   receivedAt: task06Instant(0))))
        await task06Flush()
        clock.advance(toMilliseconds: 300)
        continuation.yield(.transcript(task06Event(utteranceID: id, revision: 1, text: "two seconds",
                                                   range: task06Range(0, 1_800), receivedAt: task06Instant(300))))
        _ = await iterator.next()
        for (index, time) in [700, 1_100, 1_500, 1_900].enumerated() {
            clock.advance(toMilliseconds: UInt64(time))
            continuation.yield(.transcript(task06Event(utteranceID: id, revision: UInt64(index + 2), text: "two seconds",
                                                       range: task06Range(0, 1_800), receivedAt: task06Instant(UInt64(time)))))
            await task06Flush()
            if time == 700 { _ = await iterator.next() }
        }
        clock.advance(toMilliseconds: 2_000)
        await task06Flush()
        clock.advance(toMilliseconds: 2_100)
        let finalSpans = [
            TranscriptSpan(characterRange: 0..<11, audioRange: task06Range(0, 1_800)),
            TranscriptSpan(characterRange: 11..<16, audioRange: task06Range(1_900, 2_100))
        ]
        continuation.yield(.transcript(task06Event(utteranceID: id, revision: 6, text: "two seconds next",
                                                   range: task06Range(0, 2_100), spans: finalSpans, isFinal: false,
                                                   receivedAt: task06Instant(2_100))))
        await task06Flush()
        clock.advance(toMilliseconds: 2_550)
        guard case .upsert(let next)? = await iterator.next() else {
            throw Task06CheckFailure(message: "preferred-duration boundary did not close the old segment")
        }
        try task06Require(next.sourceText == "next", "two-second candidate did not create a fresh segment for later text; actual=\(next.sourceText.debugDescription)")
        await segmenter.reset()
        continuation.finish()
    }

    do {
        let clock = Task06Clock()
        let segmenter = CaptionSegmenter(clock: clock)
        let (input, continuation) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let output = await segmenter.start(input: input)
        var iterator = output.makeAsyncIterator()
        let text = String(repeating: "x", count: 81)
        continuation.yield(.transcript(task06Event(text: text, range: task06Range(0, 8_100),
                                                   spans: task06CharacterSpans(text: text, range: task06Range(0, 8_100)),
                                                   receivedAt: task06Instant(0))))
        guard case .upsert(let segment)? = await iterator.next() else {
            throw Task06CheckFailure(message: "eighty-character candidate did not emit")
        }
        try task06Require(segment.sourceText.count == 80, "character-based segmentation must use a bounded short prefix")
        await segmenter.reset()
        continuation.finish()
    }

    do {
        let clock = Task06Clock()
        let segmenter = CaptionSegmenter(clock: clock)
        let buffer = Task06SpeechBuffer()
        let input = AsyncStream<SpeechEvent>(unfolding: { await buffer.next() })
        let output = await segmenter.start(input: input)
        var iterator = output.makeAsyncIterator()
        let id = UUID()
        let updates = [(0, "a"), (400, "b"), (800, "c"), (1_200, "d"), (1_600, "e"), (2_000, "f"), (2_400, "g"), (2_800, "h")]
        for (index, update) in updates.enumerated() {
            clock.advance(toMilliseconds: UInt64(update.0))
            await buffer.push(.transcript(task06Event(utteranceID: id, revision: UInt64(index), text: update.1,
                                                range: task06Range(Int64(update.0), Int64(update.0) + 300),
                                                receivedAt: task06Instant(UInt64(update.0)))))
            try await task06WaitForInput(buffer)
        }
        clock.advance(toMilliseconds: 3_000)
        guard case .upsert(let provisional)? = await iterator.next() else {
            throw Task06CheckFailure(message: "three-second provisional deadline did not emit changing text")
        }
        try task06Require(provisional.sourceText == "h" && provisional.stability == .provisional,
                          "provisional deadline must use current text without inventing final stability; actual=\(provisional.sourceText.debugDescription), stability=\(provisional.stability)")
        await segmenter.reset()
        await buffer.close()
    }
}

private func checkNoNextSpeechCallbackStillEmits() async throws {
    let clock = Task06Clock()
    let segmenter = CaptionSegmenter(clock: clock)
    let (input, continuation) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
    let output = await segmenter.start(input: input)
    var iterator = output.makeAsyncIterator()
    continuation.yield(.transcript(task06Event(text: "last callback", range: task06Range(0, 300),
                                               receivedAt: task06Instant(0))))
    await task06Flush()
    clock.advance(toMilliseconds: 450)
    guard case .upsert = await iterator.next() else {
        throw Task06CheckFailure(message: "timer emission incorrectly depended on another speech callback")
    }
    await segmenter.reset()
    clock.advance(toMilliseconds: 10_000)
    await task06Flush()
    let afterReset = await iterator.next()
    try task06Require(afterReset == nil, "reset must cancel delayed captions and finish the output")
    continuation.finish()
}

private func checkNoTextNeverCreatesTimerCaption() async throws {
    let clock = Task06Clock()
    let segmenter = CaptionSegmenter(clock: clock)
    let (input, continuation) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
    let output = await segmenter.start(input: input)
    var iterator = output.makeAsyncIterator()
    continuation.yield(.transcript(task06Event(text: "", range: task06Range(0, 300), receivedAt: task06Instant(0))))
    await task06Flush()
    clock.advance(toMilliseconds: 3_000)
    await segmenter.reset()
    let event = await iterator.next()
    try task06Require(event == nil, "timers must not manufacture captions from empty text")
    continuation.finish()
}

private func checkTenMinutesVolatileRemainBounded() async throws {
    var normalizer = TranscriptNormalizer()
    let id = UUID()
    var text = ""
    var spans: [TranscriptSpan] = []
    for second in 0..<600 {
        text += second == 0 ? "word" : " word"
        let wordStart = text.count - 4
        spans.append(TranscriptSpan(characterRange: wordStart..<text.count,
                                    audioRange: task06Range(Int64(second) * 1_000, Int64(second + 1) * 1_000)))
        let event = task06Event(utteranceID: id, revision: UInt64(second), text: text,
                                range: task06Range(0, Int64(second + 1) * 1_000), spans: spans,
                                receivedAt: task06Instant(UInt64(second) * 1_000))
        _ = normalizer.normalize(event)
        let retainedCharacters = normalizer.events.reduce(0) { $0 + $1.text.count }
        try task06Require(retainedCharacters <= 2_000, "volatile transcript characters grew beyond the fixed window")
        if let first = normalizer.events.first, let last = normalizer.events.last {
            let duration = captionSeconds(last.audioRange.end) - captionSeconds(first.audioRange.start)
            try task06Require(duration <= 30, "volatile transcript audio range grew beyond thirty seconds")
        }
    }
    let retainedCharacters = normalizer.events.reduce(0) { $0 + $1.text.count }
    try task06Require(retainedCharacters > 0 && retainedCharacters <= 2_000,
                      "ten-minute volatile input must remain nonempty and within the character bound")
    try task06Require(normalizer.events.first?.audioRange.start == task06Time(570_000),
                      "the ten-minute window must discard audio older than thirty seconds")
}

private func checkFinalCoordinatesClosedProvisional() async throws {
    for finalText in ["hello", "hello."] {
        let clock = Task06Clock()
        let segmenter = CaptionSegmenter(clock: clock)
        let (input, continuation) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let output = await segmenter.start(input: input)
        var iterator = output.makeAsyncIterator()
        let id = UUID()
        continuation.yield(.transcript(task06Event(utteranceID: id, text: "hello", range: task06Range(0, 400),
                                                   receivedAt: task06Instant(0))))
        await task06Flush()
        clock.advance(toMilliseconds: 450)
        guard case .upsert(let provisional)? = await iterator.next() else {
            throw Task06CheckFailure(message: "provisional fixture did not close at pause")
        }
        clock.advance(toMilliseconds: 500)
        continuation.yield(.transcript(task06Event(utteranceID: id, revision: 1, text: finalText,
                                                   range: task06Range(0, 400), isFinal: true,
                                                   receivedAt: task06Instant(500))))
        guard case .upsert(let final)? = await iterator.next() else {
            throw Task06CheckFailure(message: "final did not coordinate with the closed provisional")
        }
        try task06Require(final.segmentID == provisional.segmentID && final.sourceText == finalText && final.stability == .final,
                          "same-range final must revise the original segment, including punctuation-only additions")
        try task06Require(final.sourceRevision > provisional.sourceRevision, "final coordination must advance sourceRevision")
        await segmenter.reset()
        continuation.finish()
    }
}

private func checkLongFinalIsSplitBelowSourceLimit() async throws {
    let segmenter = CaptionSegmenter(clock: Task06Clock())
    let (input, continuation) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
    let output = await segmenter.start(input: input)
    var iterator = output.makeAsyncIterator()
    let text = String(repeating: "x", count: 250)
    continuation.yield(.transcript(task06Event(text: text, range: task06Range(0, 25_000),
                                               spans: task06CharacterSpans(text: text, range: task06Range(0, 25_000)),
                                               isFinal: true, receivedAt: task06Instant(0))))
    var lengths: [Int] = []
    var stabilities: [CaptionStability] = []
    for _ in 0..<4 {
        guard case .upsert(let segment)? = await iterator.next() else {
            throw Task06CheckFailure(message: "250-character final did not split into four short segments")
        }
        lengths.append(segment.sourceText.count)
        stabilities.append(segment.stability)
    }
    try task06Require(lengths == [80, 80, 80, 10], "long final remainder must be split repeatedly, not emitted as 170 characters")
    try task06Require(lengths.allSatisfy { $0 <= RuntimePolicy.sourceCharacterLimit }, "a segment exceeded the source limit")
    if case .final? = stabilities.last {
        // Only the last short segment carries the final recognition stability.
    } else {
        throw Task06CheckFailure(message: "long final lost final stability on its last segment")
    }
    await segmenter.reset()
    continuation.finish()
}

private func checkStableGrowingPrefixRestartsAge() async throws {
    let clock = Task06Clock()
    let segmenter = CaptionSegmenter(clock: clock)
    let buffer = Task06SpeechBuffer()
    let input = AsyncStream<SpeechEvent>(unfolding: { await buffer.next() })
    let output = await segmenter.start(input: input)
    var iterator = output.makeAsyncIterator()
    let id = UUID()
    for (index, update) in [(0, "abc"), (100, "abcx"), (200, "abcxyz")].enumerated() {
        clock.advance(toMilliseconds: UInt64(update.0))
        await buffer.push(.transcript(task06Event(utteranceID: id, revision: UInt64(index), text: update.1,
                                                  range: task06Range(0, 300), receivedAt: task06Instant(UInt64(update.0)))))
        try await task06WaitForInput(buffer)
    }
    clock.advance(toMilliseconds: 300)
    await task06Flush()
    await segmenter.reset()
    let early = await iterator.next()
    try task06Require(early == nil, "a growing prefix inherited the old candidate age and emitted before its own 300 ms")
    await buffer.close()
}

private func checkStablePrefixPreservesLeadingWhitespace() async throws {
    let clock = Task06Clock()
    let segmenter = CaptionSegmenter(clock: clock)
    let (input, continuation) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
    let output = await segmenter.start(input: input)
    var iterator = output.makeAsyncIterator()
    let id = UUID()
    continuation.yield(.transcript(task06Event(utteranceID: id, text: " hello", range: task06Range(0, 400),
                                               receivedAt: task06Instant(0))))
    await task06Flush()
    clock.advance(toMilliseconds: 300)
    continuation.yield(.transcript(task06Event(utteranceID: id, revision: 1, text: " hello world",
                                               range: task06Range(0, 800), receivedAt: task06Instant(300))))
    guard case .upsert(let segment)? = await iterator.next() else {
        throw Task06CheckFailure(message: "leading-whitespace stable prefix did not emit")
    }
    try task06Require(segment.sourceText == " hello", "trimming must not slice the original prefix at the wrong character offset")
    await segmenter.reset()
    continuation.finish()
}

private func checkCoarseCharacterSplitRequestsDiscontinuity() async throws {
    let segmenter = CaptionSegmenter(clock: Task06Clock())
    let (input, continuation) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
    let output = await segmenter.start(input: input)
    var iterator = output.makeAsyncIterator()
    let text = String(repeating: "x", count: 81)
    continuation.yield(.transcript(task06Event(text: text, range: task06Range(0, 8_100),
                                               spans: [TranscriptSpan(characterRange: 0..<81, audioRange: task06Range(0, 8_100))],
                                               receivedAt: task06Instant(0))))
    let event = await iterator.next()
    guard case .discontinuity = event else {
        throw Task06CheckFailure(message: "a character split through a coarse span must not consume the whole remainder")
    }
    await segmenter.reset()
    continuation.finish()
}

private func checkResetDuringBackpressureIsolatesNewGeneration() async throws {
    for _ in 0..<10 {
        let clock = Task06Clock()
        let segmenter = CaptionSegmenter(clock: clock)
        let (oldInput, oldContinuation) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        _ = await segmenter.start(input: oldInput)
        for index in 0..<40 {
            oldContinuation.yield(.transcript(task06Event(text: "old", range: task06Range(Int64(index) * 1_000, Int64(index) * 1_000 + 400),
                                                          isFinal: true, receivedAt: task06Instant(UInt64(index)))))
        }
        await task06Flush()
        await segmenter.reset()
        oldContinuation.finish()

        let (newInput, newContinuation) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let newOutput = await segmenter.start(input: newInput)
        var iterator = newOutput.makeAsyncIterator()
        newContinuation.yield(.transcript(task06Event(text: "new", range: task06Range(50_000, 50_400),
                                                      isFinal: true, receivedAt: task06Instant(50_000))))
        guard case .upsert(let segment)? = await iterator.next() else {
            throw Task06CheckFailure(message: "new generation did not emit after backpressured reset")
        }
        try task06Require(segment.sourceText == "new", "an old suspended receiver contaminated the restarted generation")
        await segmenter.reset()
        newContinuation.finish()
    }
}

private func checkNormalizerDiscontinuityClearsClosedSegments() async throws {
    let clock = Task06Clock()
    let segmenter = CaptionSegmenter(clock: clock)
    let (input, continuation) = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
    let output = await segmenter.start(input: input)
    var iterator = output.makeAsyncIterator()
    let id = UUID()
    continuation.yield(.transcript(task06Event(utteranceID: id, text: "hello", range: task06Range(0, 400),
                                               receivedAt: task06Instant(0))))
    await task06Flush()
    clock.advance(toMilliseconds: 450)
    guard case .upsert(let provisional)? = await iterator.next() else {
        throw Task06CheckFailure(message: "provisional fixture did not close before discontinuity")
    }
    continuation.yield(.transcript(task06Event(text: String(repeating: "x", count: 2_001),
                                               range: task06Range(450, 500), spans: [],
                                               receivedAt: task06Instant(500))))
    guard case .discontinuity = await iterator.next() else {
        throw Task06CheckFailure(message: "unmapped window overflow did not request discontinuity")
    }
    clock.advance(toMilliseconds: 600)
    continuation.yield(.transcript(task06Event(utteranceID: id, revision: 1, text: "hello",
                                               range: task06Range(0, 400), isFinal: true,
                                               receivedAt: task06Instant(600))))
    await task06Flush()
    await segmenter.reset()
    let stale = await iterator.next()
    if case .upsert(let segment) = stale {
        try task06Require(segment.segmentID != provisional.segmentID,
                          "a final coordinated a provisional from before the discontinuity")
    }
    continuation.finish()
}

private func checkCheckpointRolloverEmitsEveryFinal() async throws {
    let segmenter = CaptionSegmenter(clock: Task06Clock())
    let pair = AsyncStream<SpeechEvent>.makeStream(bufferingPolicy: .bufferingOldest(32))
    let output = await segmenter.start(input: pair.stream)
    for index in 0..<25 {
        pair.continuation.yield(.transcript(task06Event(text: "Sentence \(index).",
            range: task06Range(Int64(index) * 1_000, Int64(index + 1) * 1_000),
            isFinal: true, receivedAt: task06Instant(UInt64(index) * 1_000))))
    }
    pair.continuation.finish()
    var texts: [String] = []
    for await event in output {
        if case .upsert(let segment) = event { texts.append(segment.sourceText) }
    }
    try task06Require(texts == (0..<25).map { "Sentence \($0)." },
                      "checkpoint rollover lost or duplicated a valid final sentence")
    await segmenter.reset()
}

func runCaptionSegmenterChecks() async throws {
    try await checkCheckpointRolloverEmitsEveryFinal()
    try await checkRevisionReplacesSameSegment()
    try await checkTimedSegmentation()
    try await checkNoNextSpeechCallbackStillEmits()
    try await checkNoTextNeverCreatesTimerCaption()
    try await checkTenMinutesVolatileRemainBounded()
    try await checkFinalCoordinatesClosedProvisional()
    try await checkLongFinalIsSplitBelowSourceLimit()
    try await checkStableGrowingPrefixRestartsAge()
    try await checkStablePrefixPreservesLeadingWhitespace()
    try await checkCoarseCharacterSplitRequestsDiscontinuity()
    try await checkResetDuringBackpressureIsolatesNewGeneration()
    try await checkNormalizerDiscontinuityClearsClosedSegments()
}

#if !TASK06_HOST_CHECK
struct CaptionSegmenterTests {
    @Test func testCheckpointRolloverEmitsEveryFinal() async throws { try await checkCheckpointRolloverEmitsEveryFinal() }
    @Test func testRevisionReplacesSameSegment() async throws { try await checkRevisionReplacesSameSegment() }
    @Test func testTimedSegmentation() async throws { try await checkTimedSegmentation() }
    @Test func testNoNextSpeechCallbackStillEmits() async throws { try await checkNoNextSpeechCallbackStillEmits() }
    @Test func testNoTextNeverCreatesTimerCaption() async throws { try await checkNoTextNeverCreatesTimerCaption() }
    @Test func testTenMinutesVolatileRemainBounded() async throws { try await checkTenMinutesVolatileRemainBounded() }
    @Test func testFinalCoordinatesClosedProvisional() async throws { try await checkFinalCoordinatesClosedProvisional() }
    @Test func testLongFinalIsSplitBelowSourceLimit() async throws { try await checkLongFinalIsSplitBelowSourceLimit() }
    @Test func testStableGrowingPrefixRestartsAge() async throws { try await checkStableGrowingPrefixRestartsAge() }
    @Test func testStablePrefixPreservesLeadingWhitespace() async throws { try await checkStablePrefixPreservesLeadingWhitespace() }
    @Test func testCoarseCharacterSplitRequestsDiscontinuity() async throws { try await checkCoarseCharacterSplitRequestsDiscontinuity() }
    @Test func testResetDuringBackpressureIsolatesNewGeneration() async throws { try await checkResetDuringBackpressureIsolatesNewGeneration() }
    @Test func testNormalizerDiscontinuityClearsClosedSegments() async throws { try await checkNormalizerDiscontinuityClearsClosedSegments() }
}
#endif
