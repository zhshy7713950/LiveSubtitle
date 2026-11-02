#if DEBUG && !targetEnvironment(simulator)
import Foundation
import Translation
import Testing
@testable import LiveSubtitle

/// Fixed synthetic text only. Print timings, never the translation or user media.
@Suite(.serialized)
struct G0TranslationTests {
    @Test(.enabled("Requires installed low-latency translation resources") { await ready(fast: true) })
    func installedLowLatencyTranslation() async throws {
        let output = try await G0TranslationProbe.translate("The library opens at nine in the morning.")
        #expect(!output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test(.enabled("Requires both translation strategies to be ready; never downloads from tests") {
        let normal = await ready(fast: false)
        let fast = await ready(fast: true)
        return normal && fast
    })
    func installedStrategiesReturnTranslation() async throws {
        let fixtures = ["The library opens at nine in the morning.",
                        "Please put the blue book on the table.",
                        "We will meet outside the station tomorrow."]
        var normal: [Double] = []
        var low: [Double] = []
        // Alternate order to avoid attributing all first-use cost to one strategy.
        for (index, text) in fixtures.enumerated() {
            for fast in (index.isMultiple(of: 2) ? [false, true] : [true, false]) {
                let start = ProcessInfo.processInfo.systemUptime
                let output: String
                if fast {
                    output = try await G0TranslationProbe.translate(text)
                } else {
                    output = try await baseline(text)
                }
                let duration = ProcessInfo.processInfo.systemUptime - start
                #expect(!output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if fast { low.append(duration) } else { normal.append(duration) }
            }
        }
        print(String(format: "G0 synthetic translation seconds: default median=%.3f max=%.3f; lowLatency median=%.3f max=%.3f; n=3 each",
                     normal.sorted()[1], normal.max() ?? 0, low.sorted()[1], low.max() ?? 0))
    }

    private func baseline(_ text: String) async throws -> String {
        let session = TranslationSession(installedSource: G0TranslationProbe.source, target: G0TranslationProbe.target)
        defer { session.cancel() }
        #expect(await session.isReady)
        return try await session.translate(text).targetText
    }

    private static func ready(fast: Bool) async -> Bool {
        let session: TranslationSession
        if fast {
            session = TranslationSession(installedSource: G0TranslationProbe.source, target: G0TranslationProbe.target, preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: G0TranslationProbe.source, target: G0TranslationProbe.target)
        }
        defer { session.cancel() }
        let status = await session.isReady
        print("G0 synthetic translation prerequisite: lowLatency=\(fast) ready=\(status)")
        return status
    }
}
#endif
