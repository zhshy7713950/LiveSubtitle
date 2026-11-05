import Darwin.Mach
import Foundation

struct RuntimeResourceSample: Sendable {
    /// A failed task_info call is absent, never an invented zero-byte measurement.
    let residentMemoryBytes: UInt64?
    let thermalState: DiagnosticThermalState
}

/// Samples current-process numeric state into the existing bounded, in-memory recorder.
actor RuntimeResourceSampler {
    private let diagnostics: any DiagnosticsRecording
    private let clock: any MonotonicClock
    private let intervalNanoseconds: UInt64
    private let sample: @Sendable () -> RuntimeResourceSample
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    init(
        diagnostics: any DiagnosticsRecording,
        clock: any MonotonicClock = SystemMonotonicClock(),
        interval: Duration,
        sample: @escaping @Sendable () -> RuntimeResourceSample = RuntimeResourceSampler.currentProcessSample
    ) {
        precondition(interval >= .nanoseconds(1), "Resource sampling interval must be positive")
        self.diagnostics = diagnostics
        self.clock = clock
        self.sample = sample
        let parts = interval.components
        let (seconds, overflow) = UInt64(parts.seconds).multipliedReportingOverflow(by: 1_000_000_000)
        let (total, sumOverflow) = seconds.addingReportingOverflow(UInt64(parts.attoseconds / 1_000_000_000))
        self.intervalNanoseconds = overflow || sumOverflow ? .max : total
    }

    deinit { task?.cancel() }

    func start() {
        guard task == nil else { return }
        generation &+= 1
        let current = generation
        let clock = clock
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let deadline = await self?.sampleAndDeadline(generation: current) else { return }
                do { try await clock.sleep(until: deadline) }
                catch { return }
            }
        }
    }

    /// Waits for any in-flight record and clock wait before the caller clears diagnostics.
    func stop() async {
        guard let previous = task else { return }
        generation &+= 1
        let stoppedGeneration = generation
        previous.cancel()
        await previous.value
        if generation == stoppedGeneration { task = nil }
    }

    private func sampleAndDeadline(generation current: UInt64) async -> MonotonicInstant? {
        guard current == generation, !Task.isCancelled else { return nil }
        let value = sample()
        if let bytes = value.residentMemoryBytes {
            await diagnostics.record(.residentMemory(bytes: bytes))
        }
        guard current == generation, !Task.isCancelled else { return nil }
        await diagnostics.record(.thermalState(value.thermalState))
        guard current == generation, !Task.isCancelled else { return nil }
        let (deadline, overflow) = clock.now().uptimeNanoseconds.addingReportingOverflow(intervalNanoseconds)
        return MonotonicInstant(uptimeNanoseconds: overflow ? .max : deadline)
    }

    nonisolated static func currentProcessSample() -> RuntimeResourceSample {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let thermalState: DiagnosticThermalState
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalState = .nominal
        case .fair: thermalState = .fair
        case .serious: thermalState = .serious
        case .critical: thermalState = .critical
        @unknown default: thermalState = .unknown
        }
        return RuntimeResourceSample(
            residentMemoryBytes: result == KERN_SUCCESS ? UInt64(info.resident_size) : nil,
            thermalState: thermalState
        )
    }
}
