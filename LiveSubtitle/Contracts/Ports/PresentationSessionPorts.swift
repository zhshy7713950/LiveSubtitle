import Foundation

/// Non-Sendable Apple render objects stay behind this MainActor boundary.
@MainActor
protocol SubtitleRendering: AnyObject {
    func present(_ snapshot: SubtitleSnapshot)
    func clear()
}

enum PiPEvent: Sendable {
    case started(sessionID: UUID)
    case restoringInterface(sessionID: UUID)
    case restoredInterface(sessionID: UUID)
    case closed(sessionID: UUID)
    case replaced(sessionID: UUID)
    case failed(sessionID: UUID, reason: FailureCode)
}

@MainActor
protocol PiPControlling: AnyObject {
    func start(sessionID: UUID) async throws -> AsyncStream<PiPEvent>
    func stop(sessionID: UUID) async
}

protocol SessionCoordinating: Sendable {
    func statuses() async -> AsyncStream<SessionStatus>
    func prepare(config: SessionConfig) async
    func start() async
    func stop(reason: StopReason) async
    func setDisplay(_ preferences: DisplayPreferences) async
    func selectMode(_ mode: RequestedMode) async
    /// Suspend AI and await cancellation before mutating a profile or its key.
    func cloudProfileWillChange() async
    func cloudProfileDidChange() async
    func restoreAI() async
}
