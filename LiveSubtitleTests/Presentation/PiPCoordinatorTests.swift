import CoreGraphics
import Foundation
#if !TASK11_HOST_CHECK
import Testing
@testable import LiveSubtitle
#endif

@MainActor
final class Task11PiPSystem: PiPSystemAdapting {
    var supported = true
    var possible = true
    var suspended = false
    private(set) var supportReadCount = 0
    private(set) var possibleReadCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var eventHandler: ((PiPSystemEvent) -> Void)?

    var isSupported: Bool {
        supportReadCount += 1
        return supported
    }

    var isPossible: Bool {
        possibleReadCount += 1
        return possible
    }

    var isSuspended: Bool { suspended }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func emit(_ event: PiPSystemEvent) { eventHandler?(event) }
}

@MainActor
private func task11NextPiPEvent(_ stream: AsyncStream<PiPEvent>) async throws -> PiPEvent {
    var iterator = stream.makeAsyncIterator()
    let event = await iterator.next()
    return try task11Value(event)
}

@MainActor
private func task11RequirePiPStreamEnded(
    _ stream: AsyncStream<PiPEvent>,
    _ message: String
) async throws {
    var iterator = stream.makeAsyncIterator()
    let event = await iterator.next()
    try task11Require(event == nil, message)
}

@MainActor
private func task11Coordinator(
    renderer: SubtitleRenderer,
    systems: [Task11PiPSystem]
) -> PiPCoordinator {
    var index = 0
    return PiPCoordinator(renderer: renderer, systemFactory: { _ in
        let system = systems[index]
        index += 1
        return system
    })
}

@MainActor
private func checkCloseRestoreAndReplacementDiffer() async throws {
    let clock = Task11Clock()
    let output = Task11FrameOutput()
    let renderer = SubtitleRenderer(output: output, clock: clock)
    let systems = [Task11PiPSystem(), Task11PiPSystem(), Task11PiPSystem()]
    let coordinator = task11Coordinator(renderer: renderer, systems: systems)

    let firstID = UUID()
    let firstStream = try await coordinator.start(sessionID: firstID)
    renderer.present(task11Snapshot(segments: [task11Segment(source: "source", translation: "译文")]))
    clock.advance(toMilliseconds: 100)
    await task11WaitUntil { output.visibleFrame != nil }
    systems[0].emit(.started)
    if case .started(let id) = try await task11NextPiPEvent(firstStream) {
        try task11Require(id == firstID, "started carried the wrong sessionID")
    } else {
        throw Task11CheckFailure(message: "PiP did not emit started")
    }

    var restoreCompleted = false
    systems[0].emit(.restoreRequested { restoreCompleted = $0 })
    if case .restoringInterface(let id) = try await task11NextPiPEvent(firstStream) {
        try task11Require(id == firstID && restoreCompleted, "restore did not complete the system handshake")
    } else {
        throw Task11CheckFailure(message: "restore button emitted a close instead of restoringInterface")
    }
    systems[0].emit(.stopped)
    if case .restoredInterface(let id) = try await task11NextPiPEvent(firstStream) {
        try task11Require(id == firstID, "restoredInterface carried the wrong sessionID")
    } else {
        throw Task11CheckFailure(message: "restoring stop did not emit restoredInterface")
    }
    try task11Require(output.visibleFrame != nil, "restoring the App cleared the live subtitles")

    systems[0].emit(.stopped)
    if case .closed(let id) = try await task11NextPiPEvent(firstStream) {
        try task11Require(id == firstID, "closed carried the wrong sessionID")
    } else {
        throw Task11CheckFailure(message: "explicit close did not emit closed")
    }
    await renderer.waitForClear()
    try task11Require(output.visibleFrame == nil, "closing PiP left subtitle frames visible")
    try await task11RequirePiPStreamEnded(firstStream, "terminal close did not finish the event stream")

    let secondID = UUID()
    let secondStream = try await coordinator.start(sessionID: secondID)
    systems[1].suspended = true
    systems[1].emit(.stopped)
    if case .replaced(let id) = try await task11NextPiPEvent(secondStream) {
        try task11Require(id == secondID, "replacement carried the wrong sessionID")
    } else {
        throw Task11CheckFailure(message: "a suspended subtitle PiP was not reported as replaced")
    }

    let thirdID = UUID()
    let thirdStream = try await coordinator.start(sessionID: thirdID)
    systems[1].suspended = false
    systems[1].emit(.stopped)
    systems[1].emit(.failed)
    await coordinator.stop(sessionID: secondID)
    try task11Require(systems[2].stopCount == 0, "an old session stopped the replacement session")
    systems[2].emit(.started)
    if case .started(let id) = try await task11NextPiPEvent(thirdStream) {
        try task11Require(id == thirdID, "an old callback contaminated the new session")
    } else {
        throw Task11CheckFailure(message: "new session did not receive its own started event")
    }
    await coordinator.stop(sessionID: thirdID)
    try task11Require(systems[2].stopCount == 1, "the current session did not stop its own PiP")
    try await task11RequirePiPStreamEnded(thirdStream, "stop left the event stream active")
}

@MainActor
private func checkUnsupportedOrImpossiblePiPFails() async throws {
    let clock = Task11Clock()
    let output = Task11FrameOutput()
    let renderer = SubtitleRenderer(output: output, clock: clock)
    let systems = [Task11PiPSystem(), Task11PiPSystem(), Task11PiPSystem()]
    systems[0].supported = false
    systems[1].possible = false
    let coordinator = task11Coordinator(renderer: renderer, systems: systems)

    for (index, sessionID) in [UUID(), UUID()].enumerated() {
        renderer.present(task11Snapshot(segments: [task11Segment(source: "source", translation: "译文")]))
        do {
            _ = try await coordinator.start(sessionID: sessionID)
            throw Task11CheckFailure(message: "unsupported or impossible PiP started successfully")
        } catch let code as FailureCode {
            try task11Require(code == .pipFailed, "PiP capability failure used the wrong error")
        }
        try task11Require(systems[index].startCount == 0, "start was called despite a failed capability check")
        await renderer.waitForClear()
        try task11Require(output.visibleFrame == nil, "failed start left a subtitle frame without PiP")
    }
    try task11Require(systems[0].possibleReadCount == 0, "support and possibility were not checked separately")
    try task11Require(systems[1].possibleReadCount == 1, "possible was not checked on a supported device")

    let sessionID = UUID()
    renderer.present(task11Snapshot(segments: [task11Segment(source: "source", translation: "译文")]))
    let stream = try await coordinator.start(sessionID: sessionID)
    systems[2].emit(.failed)
    if case .failed(let id, let reason) = try await task11NextPiPEvent(stream) {
        try task11Require(id == sessionID && reason == .pipFailed, "async start failure lost its scope or reason")
    } else {
        throw Task11CheckFailure(message: "async PiP failure did not emit failed")
    }
    await renderer.waitForClear()
    try task11Require(output.visibleFrame == nil, "async PiP failure left frames visible")
    try task11Require(systems[2].stopCount == 1, "failed PiP was not stopped")
    try await task11RequirePiPStreamEnded(stream, "failed PiP did not finish its stream")
}

@MainActor
private func checkPiPEventsSurviveSlowConsumer() async throws {
    let output = Task11FrameOutput()
    let renderer = SubtitleRenderer(output: output, clock: Task11Clock())
    let system = Task11PiPSystem()
    let coordinator = task11Coordinator(renderer: renderer, systems: [system])
    let sessionID = UUID()
    let stream = try await coordinator.start(sessionID: sessionID)

    system.emit(.started)
    system.emit(.restoreRequested { _ in })
    system.emit(.stopped)
    system.emit(.stopped)
    var events: [PiPEvent] = []
    for _ in 0..<4 { events.append(try await task11NextPiPEvent(stream)) }
    guard case .started = events[0],
          case .restoringInterface = events[1],
          case .restoredInterface = events[2],
          case .closed = events[3] else {
        throw Task11CheckFailure(message: "a slow consumer lost or reordered bounded PiP control events")
    }
    try await task11RequirePiPStreamEnded(stream, "backpressured terminal event did not finish after draining")
}

@MainActor
private func checkSameSessionRestartPreservesRenderer() async throws {
    let clock = Task11Clock()
    let output = Task11FrameOutput()
    let renderer = SubtitleRenderer(output: output, clock: clock)
    let systems = [Task11PiPSystem(), Task11PiPSystem()]
    let coordinator = task11Coordinator(renderer: renderer, systems: systems)
    let sessionID = UUID()
    let firstStream = try await coordinator.start(sessionID: sessionID)
    renderer.present(task11Snapshot(
        segments: [task11Segment(source: "source", translation: "译文")],
        identity: task11Identity(sessionID: sessionID)
    ))
    clock.advance(toMilliseconds: 100)
    await task11WaitUntil { output.visibleFrame != nil }

    systems[0].emit(.restoreRequested { _ in })
    if case .restoringInterface = try await task11NextPiPEvent(firstStream) {
        // Consume the restoration request before the matching stopped callback.
    } else {
        throw Task11CheckFailure(message: "same-session restart lost restoringInterface")
    }
    systems[0].emit(.stopped)
    if case .restoredInterface = try await task11NextPiPEvent(firstStream) {
        // The same session may present PiP again after returning to the App.
    } else {
        throw Task11CheckFailure(message: "same-session restart did not reach restored state")
    }
    let secondStream = try await coordinator.start(sessionID: sessionID)
    try task11Require(systems[0].stopCount == 1, "old PiP adapter was not stopped during same-session restart")
    try task11Require(output.visibleFrame != nil, "same-session restart cleared existing captions")
    try await task11RequirePiPStreamEnded(firstStream, "old event stream remained active after restart")

    systems[1].emit(.started)
    if case .started(let id) = try await task11NextPiPEvent(secondStream) {
        try task11Require(id == sessionID, "same-session restart changed the sessionID")
    } else {
        throw Task11CheckFailure(message: "restarted PiP did not start")
    }
    systems[1].emit(.renderSize(CGSize(width: 320, height: 180)))
    clock.advance(toMilliseconds: 200)
    await task11WaitUntil { output.visibleFrame?.layout.size == CGSize(width: 320, height: 180) }
    try task11Require(output.visibleFrame?.layout.size == CGSize(width: 320, height: 180),
                      "PiP render-size callback did not relayout the current snapshot")
    try task11Require(systems[1].startCount == 1, "render-size change restarted PiP")
    await coordinator.stop(sessionID: sessionID)
}

func runPiPCoordinatorChecks() async throws {
    try await checkCloseRestoreAndReplacementDiffer()
    try await checkUnsupportedOrImpossiblePiPFails()
    try await checkPiPEventsSurviveSlowConsumer()
    try await checkSameSessionRestartPreservesRenderer()
}

#if !TASK11_HOST_CHECK
struct PiPCoordinatorTests {
    @Test @MainActor func testCloseRestoreAndReplacementDiffer() async throws {
        try await checkCloseRestoreAndReplacementDiffer()
    }
    @Test @MainActor func testUnsupportedOrImpossiblePiPFails() async throws {
        try await checkUnsupportedOrImpossiblePiPFails()
    }
    @Test @MainActor func testPiPEventsSurviveSlowConsumer() async throws {
        try await checkPiPEventsSurviveSlowConsumer()
    }
    @Test @MainActor func testSameSessionRestartPreservesRenderer() async throws {
        try await checkSameSessionRestartPreservesRenderer()
    }
}
#endif
