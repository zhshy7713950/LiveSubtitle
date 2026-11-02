#if DEBUG
import Foundation
import Synchronization

/// Throwaway G0 transport. Only owned values cross the capture boundary.
struct G0AudioPacket: Sendable {
    let identity: SessionIdentity
    let chunk: AudioChunk
}

struct G0AudioMetrics: Sendable {
    var buffers = 0
    var queuedSeconds = 0.0
    var maximumQueuedSeconds = 0.0
    var overflowCount = 0
    var invalidCount = 0
}

final class G0AudioInbox: Sendable {
    private struct State {
        var identity: SessionIdentity?
        var packets: [G0AudioPacket] = []
        var metrics = G0AudioMetrics()
        var failure: FailureCode?
    }
    private let state = Mutex(State())
    private let limit = Double(RuntimePolicy.audioBufferDuration.components.seconds)

    func activate(_ identity: SessionIdentity) {
        state.withLock { $0 = State(identity: identity) }
    }

    func accepts(_ identity: SessionIdentity) -> Bool {
        state.withLock { $0.identity == identity }
    }

    func push(_ packet: G0AudioPacket) {
        state.withLock { value in
            guard value.identity == packet.identity, value.failure == nil else { return }
            let seconds = Double(packet.chunk.frameCount) / packet.chunk.sampleRate
            value.metrics.buffers += 1
            guard seconds.isFinite, seconds > 0,
                  value.metrics.queuedSeconds + seconds <= limit else {
                value.metrics.overflowCount += 1
                value.failure = .speechFailed // G0 fails explicitly; never hide overload.
                return
            }
            value.packets.append(packet)
            value.metrics.queuedSeconds += seconds
            value.metrics.maximumQueuedSeconds = max(value.metrics.maximumQueuedSeconds, value.metrics.queuedSeconds)
        }
    }

    func pop(_ identity: SessionIdentity) -> G0AudioPacket? {
        state.withLock { value in
            guard value.identity == identity, !value.packets.isEmpty else { return nil }
            let packet = value.packets.removeFirst()
            return packet
        }
    }

    /// Credit is returned only when the analyzer requests input after this chunk.
    /// queuedSeconds therefore includes queued AND app-owned in-flight PCM.
    func consumed(_ identity: SessionIdentity, seconds: Double) {
        state.withLock { value in
            guard value.identity == identity else { return }
            value.metrics.queuedSeconds = max(0, value.metrics.queuedSeconds - seconds)
        }
    }

    func fail(_ identity: SessionIdentity, code: FailureCode, invalid: Bool = false) {
        state.withLock { value in
            guard value.identity == identity else { return }
            value.failure = code
            if invalid { value.metrics.invalidCount += 1 }
        }
    }

    func snapshot() -> G0AudioMetrics { state.withLock { $0.metrics } }
    func failure(_ identity: SessionIdentity) -> FailureCode? {
        state.withLock { $0.identity == identity ? $0.failure : nil }
    }
    func invalidate() {
        state.withLock {
            $0.identity = nil
            $0.packets.removeAll()
            $0.metrics.queuedSeconds = 0
        }
    }
}
#endif
