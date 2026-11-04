import Foundation
import Testing
@testable import LiveSubtitle

enum AcceptanceFault: CaseIterable, Sendable {
    case unauthorized401, unauthorized403, rateLimited, server500, server503, malformed, empty, refused, offline
    var response: AcceptanceHTTP.Response {
        switch self {
        case .unauthorized401: .init(status: 401)
        case .unauthorized403: .init(status: 403)
        case .rateLimited: .init(status: 429)
        case .server500: .init(status: 500)
        case .server503: .init(status: 503)
        case .malformed: .init(chunks: [Data("not-json".utf8)])
        case .empty: .init(chunks: [Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8)])
        case .refused: .init(chunks: [Data(#"{"choices":[{"message":{"refusal":"fixture"}}]}"#.utf8)])
        case .offline: .init(error: .notConnectedToInternet)
        }
    }
    var reason: FailureCode {
        switch self {
        case .unauthorized401, .unauthorized403: .unauthorized
        case .rateLimited: .rateLimited
        case .server500, .server503: .server
        case .malformed: .incompatibleResponse
        case .empty: .invalidOutput
        case .refused: .refused
        case .offline: .network
        }
    }
}

@MainActor
@Suite(.serialized)
struct AcceptanceCloudTests {
    // Catches adapters whose safe error does not lock the real coordinator/scheduler to local.
    @Test(arguments: AcceptanceFault.allCases)
    func testA11FaultLocksSubsequentSegmentsToLocal(_ fault: AcceptanceFault) async throws {
        try await withAcceptanceRig(response: fault.response) { rig in
            let original = try #require(await rig.session.currentStatus.identity)
            await rig.emit("Fault fixture.")
            try await rig.waitForTranslation("Fault fixture.")
            #expect(await rig.session.currentStatus.effectiveMode == .localFallback)
            #expect(await rig.session.currentStatus.failure == fault.reason)
            #expect(rig.translated("Fault fixture.")?.provider == .local)
            let fallback = try #require(await rig.session.currentStatus.identity)
            #expect(fallback.sessionID == original.sessionID)
            #expect(fallback.engineEpoch > original.engineEpoch)
            AcceptanceHTTP.replace(.json, host: rig.host)
            await rig.emit("Later fixture.", at: 2_000)
            try await rig.waitForTranslation("Later fixture.")
            #expect(rig.translated("Later fixture.")?.provider == .local)
            #expect(AcceptanceHTTP.bodies(host: rig.host).count == 1)
        }
    }

    // Catches loss or double-append between the byte decoder, scheduler, store and display.
    @Test(arguments: [UInt64(1), 42, 2026])
    func testA10RandomUTF8ChunksReachDisplayAsReplacement(_ seed: UInt64) async throws {
        try await withAcceptanceRig(response: .sse(seed: seed)) { rig in
            await rig.emit("Unicode fixture.")
            try await rig.waitForTranslation("Unicode fixture.")
            #expect(rig.translated("Unicode fixture.")?.text == "你👩🏽‍💻好")
            #expect(rig.translated("Unicode fixture.")?.provider == .ai)
            #expect(rig.renderer.latest?.segments.count == 1)
            #expect(await rig.session.currentStatus.effectiveMode == .ai)
        }
    }

    @Test func testA12RealFixedProbeRestoresOnlyFutureSegments() async throws {
        try await withAcceptanceRig(response: .init(status: 401)) { rig in
            await rig.emit("Private previous fixture.")
            try await rig.waitForTranslation("Private previous fixture.")
            let fallback = try #require(await rig.session.currentStatus.identity)
            AcceptanceHTTP.replace(.json, host: rig.host)
            await rig.session.restoreAI()
            #expect(await rig.session.currentStatus.effectiveMode == .ai)
            #expect(await rig.session.currentStatus.identity?.engineEpoch == fallback.engineEpoch + 1)
            let afterProbe = AcceptanceHTTP.bodies(host: rig.host)
            #expect(afterProbe.count == 2)
            let probe = try #require(afterProbe.last)
            let object = try #require(JSONSerialization.jsonObject(with: probe) as? [String: Any])
            let messages = try #require(object["messages"] as? [[String: String]])
            #expect(messages.filter { $0["role"] == "user" }.map { $0["content"] } == ["Hello, how are you?"])
            #expect(!String(decoding: probe, as: UTF8.self).contains("Private previous fixture."))
            await rig.emit("Future cloud fixture.", at: 2_000)
            try await rig.waitForTranslation("Future cloud fixture.")
            #expect(rig.translated("Future cloud fixture.")?.provider == .ai)
            #expect(rig.translated("Private previous fixture.")?.provider == .local)
            #expect(AcceptanceHTTP.bodies(host: rig.host).count == 3)
        }
    }

    @Test func testA11FirstTextDeadlineFallsBackExactlyOnce() async throws {
        try await withAcceptanceRig(response: .init(contentType: "text/event-stream", staysOpen: true)) { rig in
            await rig.emit("Timeout fixture.")
            try await integrationEventually("Open response was not delivered") { AcceptanceHTTP.delivered(host: rig.host) == 1 }
            rig.clock.advance(toMilliseconds: 3_000)
            try await rig.waitForTranslation("Timeout fixture.")
            #expect(await rig.session.currentStatus.failure == .firstTextTimeout)
            let fallback = try #require(await rig.session.currentStatus.identity)
            rig.clock.advance(toMilliseconds: 6_000)
            await rig.emit("After timeout fixture.", at: 2_000)
            try await rig.waitForTranslation("After timeout fixture.")
            #expect(await rig.session.currentStatus.identity == fallback)
            #expect(AcceptanceHTTP.bodies(host: rig.host).count == 1)
        }
    }

    // Deliberately leaves the response open: a completed SSE event must be visible before EOF/4 KiB.
    @Test(arguments: [false, true])
    func testA09CompleteSSEEventsAppearBeforeResponseEnds(_ padded: Bool) async throws {
        try await withAcceptanceRig(response: .sse(seed: 42, staysOpen: true, padding: padded ? 4_096 : 0)) { rig in
            await rig.emit("Open streaming fixture.")
            try await integrationEventually("Open SSE was not delivered") { AcceptanceHTTP.delivered(host: rig.host) == 1 }
            let end = ContinuousClock.now.advanced(by: .seconds(2))
            var visible = false
            while ContinuousClock.now < end {
                if let segment = rig.renderer.latest?.segments.first,
                   case .translated(let text, _, .ai) = segment.translationState,
                   ["你", "你👩🏽‍💻", "你👩🏽‍💻好"].contains(text) {
                    visible = true
                    break
                }
                await Task.yield()
            }
            #expect(visible, "A09: first valid SSE text must reach display while HTTP remains open")
        }
    }

    @Test func testA19ActiveRequestCancellationCannotPoisonRestart() async throws {
        try await withAcceptanceRig(response: .init(contentType: "text/event-stream", staysOpen: true)) { rig in
            let old = try #require(await rig.session.currentStatus.identity)
            await rig.emit("Cancelled fixture.")
            try await integrationEventually("Active request did not start") { AcceptanceHTTP.delivered(host: rig.host) == 1 }
            await rig.session.stop(reason: .user)
            #expect(rig.renderer.latest == nil)
            #expect(await rig.captions.snapshot(mode: .local, status: .listening) == nil)
            let requestCount = AcceptanceHTTP.bodies(host: rig.host).count
            rig.clock.advance(toMilliseconds: 6_000)
            await rig.emit("Stopped callback fixture.")
            AcceptanceHTTP.replace(.json, host: rig.host)
            try await rig.start()
            await rig.emit("Restarted fixture.", stream: 1)
            try await rig.waitForTranslation("Restarted fixture.")
            #expect(await rig.session.currentStatus.identity?.sessionID != old.sessionID)
            #expect(await rig.session.currentStatus.effectiveMode == .ai)
            #expect(await rig.session.currentStatus.failure == nil)
            #expect(rig.renderer.latest?.segments.map(\.sourceText) == ["Restarted fixture."])
            #expect(AcceptanceHTTP.bodies(host: rig.host).count == requestCount + 1)
            #expect(AcceptanceHTTP.cancelled(host: rig.host) >= 1)
        }
    }
}
