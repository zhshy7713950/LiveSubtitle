import CoreGraphics
import CoreMedia
import Foundation
import Synchronization
#if !TASK11_HOST_CHECK
import Testing
@testable import LiveSubtitle
#endif

struct Task11CheckFailure: Error {
    let message: String
}

func task11Require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Task11CheckFailure(message: message) }
}

func task11Identity(sessionID: UUID = UUID()) -> SessionIdentity {
    SessionIdentity(sessionID: sessionID, languageEpoch: 1, engineEpoch: 2, cloudConfigRevision: 3)
}

func task11Segment(
    id: UUID = UUID(),
    source: String,
    translation: String?,
    start: Int64 = 0
) -> CaptionSegment {
    let state: CaptionTranslationState
    if let translation {
        state = .translated(text: translation, isFinal: true, provider: .local)
    } else {
        state = .pending
    }
    return CaptionSegment(
        segmentID: id,
        utteranceID: UUID(),
        audioRange: AudioRange(
            start: AudioTimestamp(value: start, timescale: 1_000),
            end: AudioTimestamp(value: start + 1_000, timescale: 1_000)
        ),
        sourceRevision: 0,
        sourceText: source,
        stability: .final,
        translationState: state
    )
}

func task11Snapshot(
    segments: [CaptionSegment],
    displayCount: Int = 3,
    style: DisplayStyle = .bilingual,
    status: SubtitleStatus = .listening,
    identity: SessionIdentity = task11Identity()
) -> SubtitleSnapshot {
    SubtitleSnapshot(
        identity: identity,
        segments: segments,
        displayCount: displayCount,
        displayStyle: style,
        effectiveMode: .local,
        status: status
    )
}

private func checkNewestReadableLinesWin() throws {
    let oldID = UUID()
    let middleID = UUID()
    let newestID = UUID()
    let newestTranslation = "最新译文🧑🏽‍🤝‍🧑🏻"
    let newestSource = "Latest source"
    let snapshot = task11Snapshot(segments: [
        task11Segment(id: oldID, source: "Old source", translation: "旧段不应挤占新段", start: 0),
        task11Segment(
            id: middleID,
            source: "Middle source",
            translation: String(repeating: "中文长句需要按实际宽度换行🧑🏽‍🤝‍🧑🏻", count: 8),
            start: 1_000
        ),
        task11Segment(id: newestID, source: newestSource, translation: newestTranslation, start: 2_000)
    ])

    let layout = SubtitleLayout(snapshot: snapshot, size: CGSize(width: 280, height: 190))
    try task11Require(layout.lines.contains { $0.segmentID == newestID }, "the newest segment was cropped")
    try task11Require(!layout.lines.contains { $0.segmentID == oldID }, "an old segment consumed space needed by newer captions")
    try task11Require(layout.lines.allSatisfy { $0.fontSize >= 12 }, "layout shrank text below a readable size")

    let newestTranslationLines = layout.lines.filter { $0.segmentID == newestID && $0.role == .translation }
    let newestSourceLines = layout.lines.filter { $0.segmentID == newestID && $0.role == .source }
    try task11Require(!newestTranslationLines.isEmpty && !newestSourceLines.isEmpty, "bilingual layout lost one language")
    try task11Require(newestTranslationLines.map(\.text).joined() == newestTranslation, "translation text or composed emoji was split")
    try task11Require(newestSourceLines.map(\.text).joined() == newestSource, "source text was changed while wrapping")
    try task11Require(
        newestTranslationLines.allSatisfy { translation in
            newestSourceLines.allSatisfy { source in translation.fontSize > source.fontSize }
        },
        "translation is not visually dominant"
    )

    let translationOnly = SubtitleLayout(
        snapshot: task11Snapshot(segments: snapshot.segments, style: .translationOnly),
        size: CGSize(width: 640, height: 360)
    )
    try task11Require(translationOnly.lines.allSatisfy { $0.role != .source }, "translation-only layout leaked source text")

    let longText = String(repeating: "宽度决定换行🧑🏽‍🤝‍🧑🏻", count: 12)
    let longSnapshot = task11Snapshot(
        segments: [task11Segment(source: "not shown", translation: longText)],
        style: .translationOnly
    )
    let wide = SubtitleLayout(snapshot: longSnapshot, size: CGSize(width: 800, height: 2_000))
    let narrow = SubtitleLayout(snapshot: longSnapshot, size: CGSize(width: 180, height: 2_000))
    try task11Require(narrow.lines.count > wide.lines.count, "line wrapping did not respond to actual width")
    try task11Require(narrow.lines.map(\.text).joined() == longText, "narrow wrapping lost or reordered characters")
}

private func checkLayoutHandlesEmptyNewlinesAndZeroSize() throws {
    let text = "第一行\n第二行🧑🏽‍🤝‍🧑🏻"
    let snapshot = task11Snapshot(
        segments: [task11Segment(source: "", translation: text)],
        style: .translationOnly
    )
    let layout = SubtitleLayout(snapshot: snapshot, size: CGSize(width: 400, height: 300))
    try task11Require(layout.lines.contains { $0.text.contains("第一行") }, "text before a newline disappeared")
    try task11Require(layout.lines.contains { $0.text.contains("第二行") }, "text after a newline disappeared")
    try task11Require(layout.lines.map(\.text).joined().contains("🧑🏽‍🤝‍🧑🏻"), "composed emoji was damaged")
    let baselines = layout.lines.map(\.baseline.y)
    try task11Require(Set(baselines).count == baselines.count, "explicit newline produced overlapping lines")

    let zero = SubtitleLayout(snapshot: snapshot, size: .zero)
    try task11Require(zero.lines.isEmpty, "zero-sized output should not create lines")
    let waiting = SubtitleLayout(
        snapshot: task11Snapshot(segments: [], status: .waitingForAudio),
        size: CGSize(width: 320, height: 180)
    )
    try task11Require(waiting.lines.map(\.text) == ["等待声音"], "empty captions lost their status phrase")
}

func runSubtitleLayoutChecks() throws {
    try checkNewestReadableLinesWin()
    try checkLayoutHandlesEmptyNewlinesAndZeroSize()
}

final class Task11Clock: MonotonicClock, Sendable {
    private struct Waiter: Sendable {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State: Sendable {
        var ticks: UInt64 = 0
        var waiters: [UUID: Waiter] = [:]
    }

    private let state = Mutex(State())

    func now() -> MonotonicInstant {
        MonotonicInstant(uptimeNanoseconds: state.withLock { $0.ticks })
    }

    func advance(toMilliseconds milliseconds: UInt64) {
        let resumed = state.withLock { state in
            state.ticks = milliseconds * 1_000_000
            let ready = state.waiters.filter { $0.value.deadline <= state.ticks }
            for id in ready.keys { state.waiters.removeValue(forKey: id) }
            return Array(ready.values.map(\.continuation))
        }
        for continuation in resumed { continuation.resume() }
    }

    func sleep(until deadline: MonotonicInstant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeImmediately = state.withLock { state -> Bool in
                    if Task.isCancelled || state.ticks >= deadline.uptimeNanoseconds { return true }
                    state.waiters[id] = Waiter(deadline: deadline.uptimeNanoseconds, continuation: continuation)
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        } onCancel: {
            let continuation = state.withLock { state in
                state.waiters.removeValue(forKey: id)?.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
        try Task.checkCancellation()
    }
}

@MainActor
final class Task11FrameOutput: SubtitleFrameOutput {
    private(set) var frames: [SubtitleFrame] = []
    private(set) var visibleFrame: SubtitleFrame?
    private(set) var flushCount = 0
    var failNextEnqueue = false

    func enqueue(_ frame: SubtitleFrame) throws {
        if failNextEnqueue {
            failNextEnqueue = false
            throw FailureCode.pipFailed
        }
        frames.append(frame)
        visibleFrame = frame
    }

    func flush() async {
        flushCount += 1
        visibleFrame = nil
    }
}

func task11Yield() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
func task11WaitUntil(_ predicate: @MainActor () -> Bool) async {
    for _ in 0..<100 {
        if predicate() { return }
        await Task.yield()
    }
}

@MainActor
private func checkDisplayChangesDoNotRestartPipeline() async throws {
    let clock = Task11Clock()
    let output = Task11FrameOutput()
    let renderer = SubtitleRenderer(output: output, clock: clock, renderSize: CGSize(width: 480, height: 270))
    let old = task11Segment(source: "Old source", translation: "旧译文", start: 0)
    let newest = task11Segment(source: "New source", translation: "新译文", start: 1_000)
    let identity = task11Identity()
    renderer.present(task11Snapshot(segments: [old, newest], identity: identity))
    try task11Require(output.frames.count == 1, "the first subtitle frame was not generated")

    renderer.present(task11Snapshot(segments: [old, newest], displayCount: 1, style: .translationOnly, identity: identity))
    renderer.updateRenderSize(CGSize(width: 320, height: 180))
    clock.advance(toMilliseconds: 100)
    await task11WaitUntil { output.frames.count == 2 }

    try task11Require(output.flushCount == 0, "a display-only change flushed or restarted the renderer")
    try task11Require(output.frames.count == 2, "a display-only change did not redraw the existing snapshot")
    let visible = try task11Value(output.visibleFrame)
    try task11Require(visible.layout.lines.allSatisfy { $0.role != .source }, "style change required a new source layout")
    try task11Require(visible.layout.lines.allSatisfy { $0.segmentID == newest.segmentID }, "displayCount did not limit visible segments")
    try task11Require(visible.layout.size == CGSize(width: 320, height: 180), "render size change did not reuse the current snapshot")
}

@MainActor
private func checkFrameCoalescingAndPTS() async throws {
    let clock = Task11Clock()
    let output = Task11FrameOutput()
    let renderer = SubtitleRenderer(output: output, clock: clock)
    let first = task11Snapshot(segments: [task11Segment(source: "one", translation: "第一版")])
    renderer.present(first)
    let firstPTS = try task11Value(output.frames.first).presentationTimeStamp

    for index in 2...20 {
        renderer.present(task11Snapshot(
            segments: [task11Segment(source: "source \(index)", translation: "版本 \(index)")],
            identity: first.identity
        ))
    }
    clock.advance(toMilliseconds: 99)
    await task11Yield()
    try task11Require(output.frames.count == 1, "frames were emitted above 10 fps")
    clock.advance(toMilliseconds: 100)
    await task11WaitUntil { output.frames.count == 2 }
    try task11Require(output.frames.count == 2, "coalesced snapshots did not produce exactly one frame")
    let latest = try task11Value(output.frames.last)
    try task11Require(latest.layout.lines.filter { $0.role == .translation }.map(\.text).joined() == "版本 20", "an older pending snapshot won")
    try task11Require(CMTimeCompare(latest.presentationTimeStamp, firstPTS) > 0, "video PTS did not increase monotonically")

    for index in 21...40 {
        renderer.present(task11Snapshot(
            segments: [task11Segment(source: "source \(index)", translation: "版本 \(index)")],
            identity: first.identity
        ))
    }
    clock.advance(toMilliseconds: 200)
    await task11WaitUntil { output.frames.count == 3 }
    try task11Require(output.frames.count == 3, "pending frame work grew with every snapshot")
    try task11Require(output.frames.last?.layout.lines.filter { $0.role == .translation }.map(\.text).joined() == "版本 40", "the latest snapshot was not retained")
}

@MainActor
private func checkUnchangedFramesUseBoundedHeartbeat() async throws {
    let clock = Task11Clock()
    let output = Task11FrameOutput()
    let renderer = SubtitleRenderer(output: output, clock: clock)
    renderer.present(task11Snapshot(segments: [task11Segment(source: "source", translation: "译文")]))
    clock.advance(toMilliseconds: 999)
    await task11Yield()
    try task11Require(output.frames.count == 1, "unchanged text rendered at the maximum frame rate")
    clock.advance(toMilliseconds: 1_000)
    await task11WaitUntil { output.frames.count == 2 }
    try task11Require(output.frames.count == 2, "unchanged text did not receive its one-second heartbeat")
    clock.advance(toMilliseconds: 2_000)
    await task11WaitUntil { output.frames.count == 3 }
    try task11Require(output.frames.count == 3, "heartbeat was not bounded to one frame per second")
    let pts = output.frames.map(\.presentationTimeStamp)
    try task11Require(CMTimeCompare(pts[0], pts[1]) < 0 && CMTimeCompare(pts[1], pts[2]) < 0,
                      "heartbeat reused an old PTS")
}

@MainActor
private func checkClearRemovesFramesAndCancelsOldWork() async throws {
    let clock = Task11Clock()
    let output = Task11FrameOutput()
    let renderer = SubtitleRenderer(output: output, clock: clock)
    let identity = task11Identity()
    renderer.present(task11Snapshot(segments: [task11Segment(source: "old", translation: "旧文字")], identity: identity))
    renderer.present(task11Snapshot(segments: [task11Segment(source: "pending", translation: "待绘旧文字")], identity: identity))
    renderer.clear()
    await renderer.waitForClear()
    try task11Require(output.visibleFrame == nil && output.flushCount == 1, "clear did not remove the displayed frame")
    clock.advance(toMilliseconds: 2_000)
    await task11Yield()
    try task11Require(output.frames.count == 1, "clear left a pending frame or heartbeat alive")

    renderer.present(task11Snapshot(segments: [task11Segment(source: "new", translation: "新文字")]))
    await task11WaitUntil { output.visibleFrame != nil }
    try task11Require(output.visibleFrame?.layout.lines.filter { $0.role == .translation }.map(\.text).joined() == "新文字", "new content could not render after clear")
}

@MainActor
private func checkRenderFailureStopsRetries() async throws {
    let clock = Task11Clock()
    let output = Task11FrameOutput()
    let renderer = SubtitleRenderer(output: output, clock: clock)
    var failures: [FailureCode] = []
    renderer.onFailure = { failures.append($0) }
    output.failNextEnqueue = true
    renderer.present(task11Snapshot(segments: [task11Segment(source: "source", translation: "译文")]))
    try task11Require(failures == [.pipFailed], "frame enqueue failure was not surfaced")
    clock.advance(toMilliseconds: 5_000)
    await task11Yield()
    try task11Require(output.frames.isEmpty && failures.count == 1, "a failed frame caused an unbounded retry loop")
}

@MainActor
private func checkRendererReleasesWhenOwnerDrops() async throws {
    let clock = Task11Clock()
    let output = Task11FrameOutput()
    var renderer: SubtitleRenderer? = SubtitleRenderer(output: output, clock: clock)
    weak let weakRenderer = renderer
    renderer?.present(task11Snapshot(segments: [task11Segment(source: "source", translation: "译文")]))
    renderer = nil
    await task11Yield()
    try task11Require(weakRenderer == nil, "heartbeat task retained the renderer after its owner released it")
}

func runSubtitleRendererChecks() async throws {
    try await checkDisplayChangesDoNotRestartPipeline()
    try await checkFrameCoalescingAndPTS()
    try await checkUnchangedFramesUseBoundedHeartbeat()
    try await checkClearRemovesFramesAndCancelsOldWork()
    try await checkRenderFailureStopsRetries()
    try await checkRendererReleasesWhenOwnerDrops()
}

func task11Value<T>(_ value: T?) throws -> T {
    guard let value else { throw Task11CheckFailure(message: "missing required value") }
    return value
}

#if TASK11_HOST_CHECK
@main
private struct Task11HostChecks {
    static func main() async throws {
        try runSubtitleLayoutChecks()
        try await runSubtitleRendererChecks()
        try await runPiPCoordinatorChecks()
        print("12 TASK-11 host checks passed; no SDK/device behavior tested.")
    }
}
#else
struct SubtitleLayoutTests {
    @Test func testNewestReadableLinesWin() throws { try checkNewestReadableLinesWin() }
    @Test func testLayoutHandlesEmptyNewlinesAndZeroSize() throws { try checkLayoutHandlesEmptyNewlinesAndZeroSize() }
    @Test @MainActor func testDisplayChangesDoNotRestartPipeline() async throws {
        try await checkDisplayChangesDoNotRestartPipeline()
    }
    @Test @MainActor func testFrameCoalescingAndPTS() async throws { try await checkFrameCoalescingAndPTS() }
    @Test @MainActor func testUnchangedFramesUseBoundedHeartbeat() async throws {
        try await checkUnchangedFramesUseBoundedHeartbeat()
    }
    @Test @MainActor func testClearRemovesFramesAndCancelsOldWork() async throws {
        try await checkClearRemovesFramesAndCancelsOldWork()
    }
    @Test @MainActor func testRenderFailureStopsRetries() async throws { try await checkRenderFailureStopsRetries() }
    @Test @MainActor func testRendererReleasesWhenOwnerDrops() async throws {
        try await checkRendererReleasesWhenOwnerDrops()
    }
}
#endif
