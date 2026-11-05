import Foundation

struct DiagnosticSample: Sendable {
    let sessionID: UUID
    let instant: MonotonicInstant
    let event: DiagnosticEvent

    /// Every string comes from a closed enum or a number, never an Error or content.
    var line: String {
        let value: String
        switch event {
        case .phase(let phase): value = "phase=\(phase.rawValue)"
        case .failure(let code): value = "failure=\(code.rawValue)"
        case .audioBuffered(let milliseconds): value = "audio_ms=\(milliseconds)"
        case .translationQueued(let count): value = "queued=\(count)"
        case .droppedAudio(let frames): value = "dropped_frames=\(frames)"
        case .droppedJob: value = "dropped_job=1"
        case .stageLatency(let stage, let nanoseconds):
            let name: String
            switch stage {
            case .captureToSpeech: name = "capture_to_speech"
            case .sourceVisible: name = "source_visible"
            case .localTranslationVisible: name = "local_visible"
            case .aiTranslationVisible: name = "ai_visible"
            case .stop: name = "stop"
            }
            value = "stage=\(name) ns=\(nanoseconds)"
        case .residentMemory(let bytes): value = "resident_bytes=\(bytes)"
        case .thermalState(let state): value = "thermal_state=\(state.rawValue)"
        }
        return "session=\(sessionID.uuidString) uptime_ns=\(instant.uptimeNanoseconds) \(value)"
    }
}

/// Ephemeral local memory only; there is no persistence, upload, or automatic export.
actor DiagnosticsRecorder: DiagnosticsRecording {
    private let clock: any MonotonicClock
    private var sessionID = UUID()
    private var samples: [DiagnosticSample] = []

    init(clock: any MonotonicClock = SystemMonotonicClock()) { self.clock = clock }

    func record(_ event: DiagnosticEvent) async {
        if samples.count == RuntimePolicy.diagnosticEventLimit { samples.removeFirst() }
        samples.append(DiagnosticSample(sessionID: sessionID, instant: clock.now(), event: event))
    }

    func snapshot() -> [DiagnosticSample] { samples }

    func clearSession() async {
        samples.removeAll(keepingCapacity: false)
        sessionID = UUID()
    }
}
