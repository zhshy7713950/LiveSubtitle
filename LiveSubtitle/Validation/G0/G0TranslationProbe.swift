#if DEBUG && !targetEnvironment(simulator)
import Foundation
import Translation

/// Each async operation owns its SDK session locally. Only strings/Bool cross domains.
enum G0TranslationProbe {
    static let source = Locale.Language(identifier: "en")
    static let target = Locale.Language(identifier: "zh-Hans")

    static func preparationAction(
        token: UUID?,
        completed: @escaping @Sendable (UUID?) async -> Void,
        failed: @escaping @Sendable (UUID?) async -> Void
    ) -> (TranslationSession) async -> Void {
        // Construct this closure outside View's MainActor isolation. SwiftUI's
        // borrowed session remains in its original task for the entire operation.
        { session in
            do {
                try await prepare(using: session)
                try Task.checkCancellation()
                await completed(token)
            } catch {
                guard !Task.isCancelled else { return }
                await failed(token)
            }
        }
    }

    static func prepare(using uiSession: TranslationSession) async throws {
        defer { uiSession.cancel() }
        try await uiSession.prepareTranslation()
        guard await LanguageAvailability().status(from: source, to: target) == .installed else {
            throw FailureCode.assetsMissing
        }
        let installed = TranslationSession(installedSource: source, target: target)
        defer { installed.cancel() }
        guard await installed.isReady else { throw FailureCode.assetsMissing }
    }

    static func translate(_ text: String) async throws -> String {
        let session = TranslationSession(installedSource: source, target: target)
        defer { session.cancel() }
        guard await session.isReady else { throw FailureCode.assetsMissing }
        try Task.checkCancellation()
        let result = try await session.translate(text)
        try Task.checkCancellation()
        return String(result.targetText.prefix(RuntimePolicy.translationCharacterLimit))
    }
}
#endif
