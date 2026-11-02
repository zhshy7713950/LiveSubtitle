import Foundation

protocol CapabilityChecking: Sendable {
    func check(config: SessionConfig) async -> CapabilityReport
}

/// Front-end adapter owns any UI-mediated preparation, including translationTask.
@MainActor
protocol LanguageAssetManaging: AnyObject {
    func status(source: LanguageIdentifier, target: LanguageIdentifier) async -> LanguageAssetStatus
    func prepare(source: LanguageIdentifier, target: LanguageIdentifier) -> AsyncStream<AssetEvent>
    func cancelPreparation()
    func releaseReservations() async
}

protocol MonotonicClock: Sendable {
    func now() -> MonotonicInstant
    /// Cancellation-aware; a test clock advances waiters without real sleeps.
    func sleep(until deadline: MonotonicInstant) async throws
}
