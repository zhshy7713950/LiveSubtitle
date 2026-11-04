import Foundation

/// Keeps one coordinator-facing stream while AVKit creates a fresh PiP after UI restoration.
@MainActor
final class LifecyclePiPController: PiPControlling {
    private let base: any PiPControlling
    private var sessionID: UUID?
    private var generation: UInt64 = 0
    private var restored = false
    private var output: PiPEventOutput?
    private var forwarding: Task<Void, Never>?

    init(base: any PiPControlling) { self.base = base }

    func start(sessionID: UUID) async throws -> AsyncStream<PiPEvent> {
        if let old = self.sessionID { await stop(sessionID: old) }
        generation &+= 1
        let generation = generation
        self.sessionID = sessionID
        restored = false
        let output = PiPEventOutput()
        self.output = output
        let stream = output.makeStream { [weak self] in
            Task { [weak self] in
                guard let self, self.generation == generation else { return }
                await self.stop(sessionID: sessionID)
            }
        }
        do { try await attach(sessionID: sessionID, generation: generation) }
        catch { await stop(sessionID: sessionID); throw error }
        return stream
    }

    func resumeAfterRestoration(sessionID: UUID) async {
        guard self.sessionID == sessionID, restored else { return }
        let generation = generation
        restored = false
        forwarding?.cancel()
        do { try await attach(sessionID: sessionID, generation: generation) }
        catch {
            guard self.generation == generation, self.sessionID == sessionID else { return }
            await terminate(.failed(sessionID: sessionID, reason: .pipFailed), sessionID: sessionID)
        }
    }

    private func attach(sessionID: UUID, generation: UInt64) async throws {
        let stream = try await base.start(sessionID: sessionID)
        guard self.sessionID == sessionID, self.generation == generation else { return }
        forwarding = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled, let self, self.generation == generation, self.sessionID == sessionID else { return }
                guard event.belongs(to: sessionID) else { continue }
                if case .restoredInterface = event { self.restored = true }
                switch event {
                case .closed, .replaced, .failed:
                    await self.terminate(event, sessionID: sessionID)
                    return
                default:
                    if self.output?.emit(event) == false {
                        await self.terminate(.failed(sessionID: sessionID, reason: .pipFailed), sessionID: sessionID)
                        return
                    }
                }
            }
            guard !Task.isCancelled, let self, self.generation == generation, self.sessionID == sessionID else { return }
            await self.terminate(.failed(sessionID: sessionID, reason: .pipFailed), sessionID: sessionID)
        }
    }

    private func terminate(_ event: PiPEvent, sessionID: UUID) async {
        // PiPEventOutput preserves terminal events under pressure and finishes after delivery.
        _ = output?.emit(event)
        restored = false
        await base.stop(sessionID: sessionID)
    }

    func stop(sessionID: UUID) async {
        guard self.sessionID == sessionID else { return }
        generation &+= 1
        self.sessionID = nil
        restored = false
        forwarding?.cancel()
        forwarding = nil
        output?.finish()
        output = nil
        await base.stop(sessionID: sessionID)
    }
}

private extension PiPEvent {
    func belongs(to sessionID: UUID) -> Bool {
        switch self {
        case .started(let id), .restoringInterface(let id), .restoredInterface(let id),
             .closed(let id), .replaced(let id), .failed(let id, _): id == sessionID
        }
    }
}
