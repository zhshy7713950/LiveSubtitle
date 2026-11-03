import SwiftUI
import Translation

/// Embeds the system translation preparation UI without sending TranslationSession across isolation domains.
@MainActor
struct LanguagePreparationHost<Content: View>: View {
    let manager: LanguageAssetManager
    let content: Content

    init(manager: LanguageAssetManager, @ViewBuilder content: () -> Content) {
        self.manager = manager
        self.content = content()
    }

    var body: some View {
        content.translationTask(
            manager.translationConfiguration,
            action: LanguageTranslationPreparation.action(
                manager: manager,
                token: manager.preparationToken
            )
        )
    }
}

private enum LanguageTranslationPreparation {
    static func action(
        manager: LanguageAssetManager,
        token: UUID?
    ) -> (TranslationSession) async -> Void {
        { session in
            defer { session.cancel() }
            do {
                try await session.prepareTranslation()
                try Task.checkCancellation()
                await manager.completeTranslationPreparation(token: token)
            } catch {
                await manager.failTranslationPreparation(token: token, cancelled: Task.isCancelled)
            }
        }
    }
}
