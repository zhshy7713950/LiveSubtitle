import Foundation

actor CloudConnectionTester: ConnectionTesting {
    private static let probeText = "Hello, how are you?"

    private let translator: CompatibleChatTranslator
    private var generation: UInt64 = 0

    init(credentials: any CredentialStoring) {
        self.translator = CompatibleChatTranslator(credentials: credentials)
    }

    init(credentials: any CredentialStoring, configuration: URLSessionConfiguration) {
        self.translator = CompatibleChatTranslator(
            credentials: credentials, configuration: configuration
        )
    }

    func test(profile: CloudProfile) async -> Result<Void, FailureCode> {
        generation &+= 1
        let token = generation
        await translator.cancelAll()
        guard token == generation else { return .failure(.preparationCancelled) }
        let job = TranslationJob(
            jobID: UUID(),
            identity: SessionIdentity(
                sessionID: UUID(), languageEpoch: 0, engineEpoch: 0,
                cloudConfigRevision: profile.revision
            ),
            segmentID: UUID(), sourceRevision: 0, sourceText: Self.probeText,
            sourceLanguage: LanguageIdentifier(rawValue: "en"),
            targetLanguage: LanguageIdentifier(rawValue: "zh-Hans"),
            stability: .final, cloudProfile: profile,
            createdAt: MonotonicInstant(uptimeNanoseconds: 0),
            deadline: MonotonicInstant(uptimeNanoseconds: 6_000_000_000)
        )
        let stream = await translator.translate(job)
        for await update in stream {
            guard token == generation, !Task.isCancelled else {
                return .failure(.preparationCancelled)
            }
            if let failure = update.failure { return .failure(failure) }
            if update.isFinal { return .success(()) }
        }
        if token == generation, !Task.isCancelled {
            return .failure(.incompatibleResponse)
        }
        return .failure(.preparationCancelled)
    }

    func cancel() async {
        generation &+= 1
        await translator.cancelAll()
    }
}
