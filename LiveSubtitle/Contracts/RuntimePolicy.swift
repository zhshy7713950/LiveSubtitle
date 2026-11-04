/// Initial tuning values from development-spec §§4, 7, 9–12.
/// These are limits for future implementations, not implemented enforcement.
enum RuntimePolicy {
    static let defaultDisplayCount = 3
    static let displayCountRange = 1...10
    static let retainedSegmentLimit = 10
    static let audioBufferDuration: Duration = .seconds(2)
    static let aiConcurrency = 2
    static let localConcurrency = 1
    static let pendingTranslationLimit = 4
    static let jobLifetime: Duration = .seconds(6)
    static let aiFirstTextTimeout: Duration = .seconds(3)
    static let aiAutomaticRetryLimit = 0
    static let aiSubmissionInterval: Duration = .milliseconds(800)
    static let aiProvisionalRequestLimit = 2
    static let aiFinalRequestLimit = 1
    static let sourceCharacterLimit = 120
    static let translationCharacterLimit = 800
    static let sourceDisplayInterval: Duration = .milliseconds(150)
    static let translationDisplayInterval: Duration = .milliseconds(100)
    static let preferredPause: Duration = .milliseconds(450)
    static let stablePrefixAge: Duration = .milliseconds(300)
    static let stablePrefixUpdateCount = 2
    static let preferredSegmentDuration: Duration = .seconds(2)
    static let preferredSegmentCharacterCount = 80
    static let provisionalSegmentDeadline: Duration = .seconds(3)
    static let transcriptWindowDuration: Duration = .seconds(30)
    static let transcriptWindowCharacterLimit = 2_000
    static let sseEventByteLimit = 64 * 1_024
    static let responseByteLimit = 256 * 1_024
    static let maximumRenderFPS = 10
    /// In-memory diagnostic ring; never persisted or automatically exported.
    static let diagnosticEventLimit = 256
}
