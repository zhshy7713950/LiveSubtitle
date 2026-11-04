import Dispatch
import Foundation

struct SystemMonotonicClock: MonotonicClock {
    func now() -> MonotonicInstant {
        MonotonicInstant(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    func sleep(until deadline: MonotonicInstant) async throws {
        try Task.checkCancellation()
        let current = now().uptimeNanoseconds
        guard deadline.uptimeNanoseconds > current else { return }
        try await Task.sleep(nanoseconds: deadline.uptimeNanoseconds - current)
    }
}
