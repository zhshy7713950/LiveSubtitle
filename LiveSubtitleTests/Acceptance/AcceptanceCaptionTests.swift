import CoreGraphics
import Foundation
import Testing
@testable import LiveSubtitle

@MainActor
@Suite(.serialized)
struct AcceptanceCaptionTests {
    @Test func testA15A16DisplayChangesReuseRetainedTranslations() async throws {
        try await withAcceptanceRig(mode: .local) { rig in
            for index in 0..<10 {
                let text = "Display fixture \(index)."
                await rig.emit(text, at: Int64(index) * 2_000)
                try await rig.waitForTranslation(text)
            }
            let identity = await rig.session.currentStatus.identity
            let callsBeforeDisplayChanges = await rig.localCalls.count
            #expect(callsBeforeDisplayChanges == 10)
            for count in [3, 1, 10, 3] {
                for style in [DisplayStyle.bilingual, .translationOnly] {
                    await rig.session.setDisplay(.init(displayCount: count, displayStyle: style))
                    let snapshot = try #require(rig.renderer.latest)
                    #expect(snapshot.displayCount == count)
                    #expect(snapshot.displayStyle == style)
                    #expect(snapshot.segments.count == RuntimePolicy.retainedSegmentLimit)
                    let layout = SubtitleLayout(snapshot: snapshot, size: CGSize(width: 640, height: 1_400))
                    let visible = Set(layout.lines.compactMap(\.segmentID))
                    #expect(visible == Set(snapshot.segments.suffix(count).map(\.segmentID)))
                    if style == .translationOnly { #expect(!layout.lines.contains { $0.role == .source }) }
                }
            }
            #expect(await rig.session.currentStatus.identity == identity)
            #expect(await rig.localCalls.count == callsBeforeDisplayChanges)
            #expect(rig.source.startCount == 1)
            #expect(await rig.speech.startCount == 1)
            #expect(AcceptanceHTTP.bodies(host: rig.host).isEmpty)
        }
    }


    @Test func testA14CheckpointRolloverDoesNotLoseAnUtterance() async throws {
        try await withAcceptanceRig(mode: .local) { rig in
            for index in 0..<10 {
                let text = "Checkpoint fixture \(index)."
                await rig.emit(text, at: Int64(index) * 2_000)
                try await rig.waitForTranslation(text)
            }
            await rig.emit("Eleventh fixture.", at: 20_000)
            await rig.emit("Twelfth fixture.", at: 22_000)
            try await rig.waitForTranslation("Twelfth fixture.")
            #expect(rig.translated("Eleventh fixture.") != nil,
                    "A14: bounded checkpoint rollover must not discard the triggering utterance")
            #expect(rig.renderer.latest?.segments.count == RuntimePolicy.retainedSegmentLimit)
        }
    }

    // Segmenter emits remove + upsert when final speech merges provisional rows.
    // This catches a coordinator/store contract gap that isolated module suites cannot see.
    @Test func testA13MergedFinalRemovesSupersededRowsFromDisplay() async throws {
        try await withAcceptanceRig(mode: .local) { rig in
            let utteranceID = UUID()
            for (revision, text, end) in [(0, "Alpha.", 1_000), (1, "Alpha.Bravo.", 2_000)] {
                await rig.speech.emit(.transcript(task06Event(utteranceID: utteranceID,
                    revision: UInt64(revision), text: text, range: task06Range(0, Int64(end)),
                    receivedAt: rig.clock.now())))
                try await integrationEventually("Provisional row was not displayed") {
                    (rig.renderer.latest?.segments.count ?? 0) == revision + 1
                }
            }
            await rig.speech.emit(.transcript(task06Event(utteranceID: utteranceID, revision: 2,
                text: "Alpha.Bravo.", range: task06Range(0, 2_000), isFinal: true,
                receivedAt: rig.clock.now())))
            try await rig.waitForTranslation("Alpha.Bravo.")
            #expect(rig.renderer.latest?.segments.map(\.sourceText) == ["Alpha.Bravo."],
                    "A13: superseded provisional rows must disappear after final merge")
        }
    }
}
