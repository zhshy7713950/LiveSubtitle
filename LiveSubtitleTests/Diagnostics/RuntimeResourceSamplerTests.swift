import Foundation
import Synchronization
#if !TASK14_RESOURCE_HOST_CHECK
import Testing
@testable import LiveSubtitle
#endif

private struct ResourceCheckFailure: Error { let message: String }
private func resourceRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw ResourceCheckFailure(message: message) }
}

private final class ResourceClock: MonotonicClock {
    private struct Waiter {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct State {
        var ticks: UInt64 = 0
        var nextID = 0
        var waiters: [Int: Waiter] = [:]
    }
    private let state = Mutex(State())
    func now() -> MonotonicInstant {
        MonotonicInstant(uptimeNanoseconds: state.withLock { $0.ticks })
    }
    var waiterCount: Int { state.withLock { $0.waiters.count } }
    func advance(to ticks: UInt64) {
        let ready = state.withLock { state in
            state.ticks = ticks
            let ready = state.waiters.filter { $0.value.deadline <= ticks }
            for id in ready.keys { state.waiters.removeValue(forKey: id) }
            return ready.values.map(\.continuation)
        }
        for continuation in ready { continuation.resume() }
    }
    func sleep(until deadline: MonotonicInstant) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Int in
                    if Task.isCancelled { return 1 }
                    if state.ticks >= deadline.uptimeNanoseconds { return 2 }
                    state.waiters[id] = Waiter(deadline: deadline.uptimeNanoseconds, continuation: continuation)
                    return 0
                }
                if result == 1 { continuation.resume(throwing: CancellationError()) }
                if result == 2 { continuation.resume() }
            }
        } onCancel: {
            let waiter = self.state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}

private func resourceEventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<10_000 {
        if await condition() { return }
        await Task.yield()
    }
    throw ResourceCheckFailure(message: "sampler did not reach expected state")
}

private func checkSamplingLifecycle() async throws {
    let clock = ResourceClock()
    let recorder = DiagnosticsRecorder(clock: clock)
    let reads = Mutex(0)
    let sampler = RuntimeResourceSampler(diagnostics: recorder, clock: clock, interval: .seconds(1)) {
        let value = reads.withLock { reads in reads += 1; return reads }
        return RuntimeResourceSample(residentMemoryBytes: UInt64(value), thermalState: .fair)
    }
    await sampler.start()
    await sampler.start()
    try await resourceEventually { clock.waiterCount == 1 }
    try resourceRequire(reads.withLock { $0 } == 1, "repeated start created multiple sampling loops")
    clock.advance(to: 1_000_000_000)
    try await resourceEventually { await recorder.snapshot().count == 4 && clock.waiterCount == 1 }
    await sampler.stop()
    await sampler.stop()
    try resourceRequire(clock.waiterCount == 0, "stop left a clock waiter alive")
    clock.advance(to: 10_000_000_000)
    try resourceRequire(reads.withLock { $0 } == 2, "stopped sampler kept reading resources")
    let samples = await recorder.snapshot()
    try resourceRequire(samples[0].line.hasSuffix("resident_bytes=1"), "RSS sample missing")
    try resourceRequire(samples[1].line.hasSuffix("thermal_state=fair"), "thermal sample missing")
    await sampler.start()
    try await resourceEventually { await recorder.snapshot().count == 6 && clock.waiterCount == 1 }
    await sampler.stop()
    try resourceRequire(reads.withLock { $0 } == 3, "sampler could not restart after stop")
}

private func checkRecorderBoundedRing() async throws {
    let clock = ResourceClock()
    let recorder = DiagnosticsRecorder(clock: clock)
    for value in 0..<(RuntimePolicy.diagnosticEventLimit + 7) {
        await recorder.record(.residentMemory(bytes: UInt64(value)))
    }
    let samples = await recorder.snapshot()
    try resourceRequire(samples.count == RuntimePolicy.diagnosticEventLimit, "diagnostic ring grew beyond its limit")
    try resourceRequire(samples.first?.line.hasSuffix("resident_bytes=7") == true, "ring did not evict oldest sample")
    await recorder.clearSession()
    try resourceRequire(await recorder.snapshot().isEmpty, "clearing diagnostics retained samples")
}

private func checkUnavailableMemoryStillRecordsThermal() async throws {
    let clock = ResourceClock()
    let recorder = DiagnosticsRecorder(clock: clock)
    let sampler = RuntimeResourceSampler(diagnostics: recorder, clock: clock, interval: .seconds(1)) {
        RuntimeResourceSample(residentMemoryBytes: nil, thermalState: .critical)
    }
    await sampler.start()
    try await resourceEventually { clock.waiterCount == 1 }
    await sampler.stop()
    let samples = await recorder.snapshot()
    try resourceRequire(samples.count == 1 && samples[0].line.hasSuffix("thermal_state=critical"),
                        "unavailable RSS invented a zero value or suppressed thermal state")
}

private func checkCurrentProcessSample() throws {
    let sample = RuntimeResourceSampler.currentProcessSample()
    try resourceRequire((sample.residentMemoryBytes ?? 0) > 0, "task_info did not return current-process RSS")
}

private actor BlockingResourceRecorder: DiagnosticsRecording {
    nonisolated let cancellationSeen = Mutex(false)
    private var waiter: CheckedContinuation<Void, Never>?
    func record(_ event: DiagnosticEvent) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = $0 }
        } onCancel: { cancellationSeen.withLock { $0 = true } }
    }
    var entered: Bool { waiter != nil }
    func release() { waiter?.resume(); waiter = nil }
    func clearSession() async {}
}

private func checkConcurrentStopsWaitForInflightRecord() async throws {
    let recorder = BlockingResourceRecorder()
    let sampler = RuntimeResourceSampler(diagnostics: recorder, clock: ResourceClock(), interval: .seconds(1)) {
        RuntimeResourceSample(residentMemoryBytes: 1, thermalState: .nominal)
    }
    await sampler.start()
    try await resourceEventually { await recorder.entered }
    let firstStop = Task { await sampler.stop() }
    try await resourceEventually { recorder.cancellationSeen.withLock { $0 } }
    let secondReturned = Mutex(false)
    let secondStop = Task { await sampler.stop(); secondReturned.withLock { $0 = true } }
    for _ in 0..<1_000 { await Task.yield() }
    let returnedEarly = secondReturned.withLock { $0 }
    await recorder.release()
    await firstStop.value
    await secondStop.value
    try resourceRequire(!returnedEarly, "repeated stop returned before in-flight record completed")
}

#if TASK14_RESOURCE_HOST_CHECK
@main private struct ResourceHostChecks {
    static func main() async throws {
        try await checkSamplingLifecycle()
        try await checkRecorderBoundedRing()
        try await checkUnavailableMemoryStillRecordsThermal()
        try checkCurrentProcessSample()
        try await checkConcurrentStopsWaitForInflightRecord()
        print("5 runtime resource host checks passed")
    }
}
#else
struct RuntimeResourceSamplerTests {
    @Test func testSamplingLifecycle() async throws { try await checkSamplingLifecycle() }
    @Test func testRecorderBoundedRing() async throws { try await checkRecorderBoundedRing() }
    @Test func testUnavailableMemoryStillRecordsThermal() async throws {
        try await checkUnavailableMemoryStillRecordsThermal()
    }
    @Test func testCurrentProcessSample() throws { try checkCurrentProcessSample() }
    @Test func testConcurrentStopsWaitForInflightRecord() async throws {
        try await checkConcurrentStopsWaitForInflightRecord()
    }
}
#endif
