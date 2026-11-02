#if DEBUG && !targetEnvironment(simulator)
import Foundation
import Translation
import OSLog

/// Each async operation owns its SDK session locally. Only strings/Bool cross domains.
enum G0TranslationProbe {
    static let source = Locale.Language(identifier: "en")
    static let target = Locale.Language(identifier: "zh-Hans")

    static func preparationAction(
        token: UUID?,
        progress: @escaping @Sendable (UUID?, String) async -> Void,
        completed: @escaping @Sendable (UUID?) async -> Void,
        failed: @escaping @Sendable (UUID?) async -> Void
    ) -> (TranslationSession) async -> Void {
        // Construct this closure outside View's MainActor isolation. SwiftUI's
        // borrowed session remains in its original task for the entire operation.
        { session in
            do {
                Logger(subsystem: "com.zhshy7713950.LiveSubtitle", category: "G0Preparation").notice("translation_action_entered token_present=\(token != nil)")
                try await prepare(using: session, progress: { stage in await progress(token, stage) })
                try Task.checkCancellation()
                await completed(token)
            } catch {
                guard !Task.isCancelled else { return }
                await failed(token)
            }
        }
    }

    static func prepare(using uiSession: TranslationSession, progress: @Sendable (String) async -> Void) async throws {
        defer { uiSession.cancel() }
        await progress("翻译：等待系统下载确认 / 语言资源准备")
        try await uiSession.prepareTranslation()
        await progress("翻译：系统准备已返回，正在核对已安装资源")
        guard await LanguageAvailability(preferredStrategy: .lowLatency).status(from: source, to: target) == .installed else {
            throw FailureCode.assetsMissing
        }
        await progress("翻译：正在检查非 UI 会话就绪状态")
        let installed = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        defer { installed.cancel() }
        guard await installed.isReady else { throw FailureCode.assetsMissing }
        await progress("翻译：本地资源已就绪，即将准备英文识别")
    }

    static func translate(_ text: String) async throws -> String {
        let session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        defer { session.cancel() }
        guard await session.isReady else { throw FailureCode.assetsMissing }
        try Task.checkCancellation()
        let result = try await session.translate(text)
        try Task.checkCancellation()
        return String(result.targetText.prefix(RuntimePolicy.translationCharacterLimit))
    }
}
#endif
