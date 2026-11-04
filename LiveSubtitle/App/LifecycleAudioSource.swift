import Foundation
import UIKit

/// MainActor mirror of an identity received from the coordinator, bound before the picker awaits.
@MainActor
final class CaptureLifecycleScope {
    private(set) var sessionID: UUID?
    func bind(_ id: UUID) { sessionID = id }
    func clear(_ id: UUID?) {
        if sessionID == id { sessionID = nil }
    }
}

@MainActor
final class LifecycleAudioSource: AudioSource {
    private let base: any AudioSource
    private let scope: CaptureLifecycleScope
    private let mayStart: @MainActor () -> Bool

    init(base: any AudioSource, scope: CaptureLifecycleScope,
         mayStart: @escaping @MainActor () -> Bool = {
             UIApplication.shared.isProtectedDataAvailable &&
             ProcessInfo.processInfo.thermalState != .serious && ProcessInfo.processInfo.thermalState != .critical
         }) {
        self.base = base
        self.scope = scope
        self.mayStart = mayStart
    }

    func start(config: CaptureConfig) async throws -> AsyncStream<AudioSourceEvent> {
        guard mayStart() else { throw FailureCode.unavailable }
        let id = config.identity.sessionID
        scope.bind(id)
        do { return try await base.start(config: config) }
        catch { scope.clear(id); throw error }
    }

    func stop() async {
        scope.clear(scope.sessionID)
        await base.stop()
    }
}
