import Foundation

private struct CaptionSystemClock: MonotonicClock {
    func now() -> MonotonicInstant {
        MonotonicInstant(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    func sleep(until deadline: MonotonicInstant) async throws {
        let current = now().uptimeNanoseconds
        if deadline.uptimeNanoseconds > current {
            let difference = deadline.uptimeNanoseconds - current
            try await Task.sleep(for: .nanoseconds(Int64(min(difference, UInt64(Int64.max)))))
        }
        try Task.checkCancellation()
    }
}

private actor CaptionEventChannel {
    private let limit = 32
    private var events: [SegmentEvent] = []
    private var consumers: [CheckedContinuation<SegmentEvent?, Never>] = []
    private var producers: [CheckedContinuation<Void, Never>] = []
    private var closed = false

    func push(_ event: SegmentEvent) async {
        while events.count >= limit && !closed {
            await withCheckedContinuation { producers.append($0) }
        }
        guard !closed else { return }
        if consumers.isEmpty {
            events.append(event)
        } else {
            let consumer = consumers.removeFirst()
            consumer.resume(returning: event)
        }
    }

    func next() async -> SegmentEvent? {
        if !events.isEmpty {
            let event = events.removeFirst()
            if !producers.isEmpty { producers.removeFirst().resume() }
            return event
        }
        if closed { return nil }
        return await withCheckedContinuation { consumers.append($0) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        for consumer in consumers { consumer.resume(returning: nil) }
        for producer in producers { producer.resume() }
        consumers.removeAll()
        producers.removeAll()
    }
}

private func captionNanoseconds(_ duration: Duration) -> UInt64 {
    let components = duration.components
    return UInt64(components.seconds) * 1_000_000_000 + UInt64(components.attoseconds / 1_000_000_000)
}

actor CaptionSegmenter: CaptionSegmenting {
    private struct StablePrefix {
        var text: String
        var updateCount: Int
        var since: MonotonicInstant
    }

    private struct ActiveSegment {
        var segmentID: UUID
        var event: TranscriptEvent
        var sourceRevision: UInt64 = 0
        var startedAt: MonotonicInstant
        var lastUpdatedAt: MonotonicInstant
        var stable: StablePrefix
        var hasEmitted = false
        var lastEmittedText: String?
        var lastEmittedRevision: UInt64 = 0
        var lastEmittedStability: CaptionStability = .provisional
    }

    private let clock: any MonotonicClock
    private var generation: UInt64 = 0
    private var normalizer = TranscriptNormalizer()
    private var active: ActiveSegment?
    private var closedSegments: [CaptionSegment] = []
    private var channel: CaptionEventChannel?
    private var inputTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    init(clock: any MonotonicClock = CaptionSystemClock()) {
        self.clock = clock
    }

    func start(input: AsyncStream<SpeechEvent>) async -> AsyncStream<SegmentEvent> {
        generation &+= 1
        let generation = generation
        await stopCurrent()
        guard self.generation == generation else {
            return AsyncStream { $0.finish() }
        }
        let channel = CaptionEventChannel()
        self.channel = channel
        inputTask = Task {
            for await event in input {
                await receive(event, generation: generation)
            }
            await finishInput(generation: generation)
        }
        return AsyncStream(unfolding: {
            await channel.next()
        }, onCancel: {
            Task { await self.cancelOutput(generation: generation) }
        })
    }

    func reset() async {
        generation &+= 1
        await stopCurrent()
    }

    private func stopCurrent() async {
        inputTask?.cancel()
        timerTask?.cancel()
        inputTask = nil
        timerTask = nil
        let oldChannel = channel
        channel = nil
        active = nil
        closedSegments.removeAll()
        normalizer.reset()
        await oldChannel?.close()
    }

    private func cancelOutput(generation: UInt64) async {
        guard self.generation == generation else { return }
        await reset()
    }

    private func finishInput(generation: UInt64) async {
        guard self.generation == generation else { return }
        let channel = channel
        await closeActive(generation: generation)
        guard self.generation == generation else { return }
        timerTask?.cancel()
        await channel?.close()
    }

    private func receive(_ event: SpeechEvent, generation: UInt64) async {
        guard self.generation == generation else { return }
        switch event {
        case .transcript(let transcript):
            await receive(transcript, generation: generation)
        case .discontinuity(let timestamp):
            active = nil
            closedSegments.removeAll()
            normalizer.reset()
            timerTask?.cancel()
            await channel?.push(.discontinuity(timestamp))
        case .ended, .failed:
            await finishInput(generation: generation)
        }
    }

    private func receive(_ event: TranscriptEvent, generation: UInt64) async {
        await applyDueRules(generation: generation)
        guard self.generation == generation else { return }
        if event.isFinal {
            if await coordinateFinal(event, generation: generation) { return }
        }
        guard self.generation == generation else { return }
        guard let normalized = normalizer.normalize(event) else {
            if normalizer.requiresDiscontinuity {
                active = nil
                closedSegments.removeAll()
                normalizer.reset()
                await channel?.push(.discontinuity(event.audioRange.start))
            }
            return
        }
        if let active, active.event.utteranceID != normalized.utteranceID {
            await closeActive(generation: generation)
            guard self.generation == generation else { return }
        }
        if var active {
            let previous = active.event
            active.stable = updatedStable(active.stable, previous: previous, current: normalized)
            if previous.text != normalized.text || previous.audioRange != normalized.audioRange ||
                previous.isFinal != normalized.isFinal {
                active.sourceRevision += 1
            }
            active.event = normalized
            active.lastUpdatedAt = normalized.receivedAt
            self.active = active
        } else {
            self.active = ActiveSegment(segmentID: UUID(), event: normalized,
                                        startedAt: normalized.receivedAt, lastUpdatedAt: normalized.receivedAt,
                                        stable: StablePrefix(text: normalized.text, updateCount: 1,
                                                             since: normalized.receivedAt))
        }
        await processActive(generation: generation)
        guard self.generation == generation else { return }
        scheduleTimer(generation: generation)
    }

    private func processActive(generation: UInt64) async {
        while self.generation == generation, let active {
            let now = clock.now()
            if active.event.text.count >= RuntimePolicy.preferredSegmentCharacterCount {
                await closePrefix(characterCount: RuntimePolicy.preferredSegmentCharacterCount, generation: generation)
                continue
            }
            if let boundary = punctuationBoundary(in: active.event.text) {
                if boundary == active.event.text.count {
                    await closeActive(generation: generation)
                } else {
                    await closePrefix(characterCount: boundary, generation: generation)
                }
                continue
            }
            if active.event.isFinal {
                await closeActive(generation: generation)
                return
            }
            if elapsed(now, since: active.startedAt) >= captionNanoseconds(RuntimePolicy.preferredSegmentDuration),
               !active.stable.text.isEmpty {
                await closeActive(generation: generation)
                return
            }
            if active.hasEmitted {
                await emitCurrent(generation: generation)
            } else if stableQualified(active.stable, now: now) {
                await emitStablePrefix(generation: generation)
            } else if elapsed(now, since: active.startedAt) >= captionNanoseconds(RuntimePolicy.provisionalSegmentDeadline) {
                await emitCurrent(generation: generation)
            }
            return
        }
    }

    private func timerFired(generation: UInt64) async {
        guard self.generation == generation else { return }
        if (active?.event.text.count ?? 0) >= RuntimePolicy.preferredSegmentCharacterCount {
            await processActive(generation: generation)
        }
        await applyDueRules(generation: generation)
        scheduleTimer(generation: generation)
    }

    private func applyDueRules(generation: UInt64) async {
        guard self.generation == generation, let active else { return }
        let now = clock.now()
        if elapsed(now, since: active.startedAt) >= captionNanoseconds(RuntimePolicy.preferredSegmentDuration),
           !active.stable.text.isEmpty {
            await closeActive(generation: generation)
        } else if !active.hasEmitted && stableQualified(active.stable, now: now) {
            await emitStablePrefix(generation: generation)
        } else if !active.hasEmitted &&
                    elapsed(now, since: active.startedAt) >= captionNanoseconds(RuntimePolicy.provisionalSegmentDeadline) {
            await emitCurrent(generation: generation)
        } else if elapsed(now, since: active.lastUpdatedAt) >= captionNanoseconds(RuntimePolicy.preferredPause) {
            await closeActive(generation: generation)
        }
    }

    private func scheduleTimer(generation: UInt64) {
        guard self.generation == generation else { return }
        timerTask?.cancel()
        guard let active, let deadline = nextDeadline(active) else { return }
        timerTask = Task {
            do {
                try await clock.sleep(until: deadline)
                await self.timerFired(generation: generation)
            } catch {
                // Cancellation invalidates only this timer; generation checks protect replacements.
            }
        }
    }

    private func nextDeadline(_ active: ActiveSegment) -> MonotonicInstant? {
        var deadlines = [active.lastUpdatedAt.uptimeNanoseconds + captionNanoseconds(RuntimePolicy.preferredPause)]
        if !active.hasEmitted && active.stable.updateCount >= RuntimePolicy.stablePrefixUpdateCount {
            deadlines.append(active.stable.since.uptimeNanoseconds + captionNanoseconds(RuntimePolicy.stablePrefixAge))
        }
        if !active.stable.text.isEmpty {
            deadlines.append(active.startedAt.uptimeNanoseconds + captionNanoseconds(RuntimePolicy.preferredSegmentDuration))
        }
        if !active.hasEmitted {
            deadlines.append(active.startedAt.uptimeNanoseconds + captionNanoseconds(RuntimePolicy.provisionalSegmentDeadline))
        }
        guard let value = deadlines.min() else { return nil }
        return MonotonicInstant(uptimeNanoseconds: value)
    }

    private func coordinateFinal(_ event: TranscriptEvent, generation: UInt64) async -> Bool {
        let matches = closedSegments.filter {
            $0.utteranceID == event.utteranceID && $0.stability == .provisional &&
            captionCompare($0.audioRange.start, event.audioRange.end) != .descending &&
            captionCompare(event.audioRange.start, $0.audioRange.end) != .descending
        }.sorted { captionCompare($0.audioRange.start, $1.audioRange.start) == .ascending }
        guard let canonical = matches.first else { return false }
        let matchedIDs = Set(matches.map(\.segmentID))
        closedSegments.removeAll { matchedIDs.contains($0.segmentID) }
        let final = CaptionSegment(segmentID: canonical.segmentID, utteranceID: event.utteranceID,
                                   audioRange: event.audioRange,
                                   sourceRevision: (matches.map(\.sourceRevision).max() ?? canonical.sourceRevision) + 1,
                                   sourceText: event.text, stability: .final, translationState: .pending)
        normalizer.consume(utteranceID: event.utteranceID, through: event.audioRange.end)
        if normalizer.requiresDiscontinuity {
            active = nil
            closedSegments.removeAll()
            normalizer.reset()
            await channel?.push(.discontinuity(event.audioRange.start))
            return true
        }
        for removed in matches.dropFirst() {
            await channel?.push(.remove(segmentID: removed.segmentID))
            guard self.generation == generation else { return true }
        }
        await channel?.push(.upsert(final))
        return true
    }

    private func recordClosed(_ active: ActiveSegment, textEvent: TranscriptEvent) {
        guard let text = active.lastEmittedText else { return }
        let segment = CaptionSegment(segmentID: active.segmentID, utteranceID: active.event.utteranceID,
                                     audioRange: textEvent.audioRange, sourceRevision: active.lastEmittedRevision,
                                     sourceText: text, stability: .provisional, translationState: .pending)
        closedSegments.removeAll { $0.segmentID == segment.segmentID }
        closedSegments.append(segment)
        closedSegments.sort { captionCompare($0.audioRange.start, $1.audioRange.start) == .ascending }
        if closedSegments.count > RuntimePolicy.retainedSegmentLimit { closedSegments.removeFirst() }
    }

    private func closeActive(generation: UInt64) async {
        guard let active else { return }
        var event = prepareEmission(active, textEvent: active.event,
                                    stability: active.event.isFinal ? .final : .provisional,
                                    generation: generation)
        if !active.event.isFinal, let emitted = self.active { recordClosed(emitted, textEvent: active.event) }
        normalizer.consume(utteranceID: active.event.utteranceID, through: active.event.audioRange.end)
        self.active = nil
        if normalizer.requiresDiscontinuity {
            normalizer.reset()
            closedSegments.removeAll()
            event = .discontinuity(active.event.audioRange.start)
        }
        if let event { await channel?.push(event) }
    }

    private func closePrefix(characterCount: Int, generation: UInt64) async {
        guard let active, characterCount > 0, characterCount < active.event.text.count else {
            await closeActive(generation: generation)
            return
        }
        guard let (prefix, remainder) = split(active.event, at: characterCount) else {
            self.active = nil
            normalizer.reset()
            closedSegments.removeAll()
            await channel?.push(.discontinuity(active.event.audioRange.start))
            return
        }
        var event = prepareEmission(active, textEvent: prefix, stability: .provisional, generation: generation)
        if let emitted = self.active { recordClosed(emitted, textEvent: prefix) }
        normalizer.consume(utteranceID: active.event.utteranceID, through: prefix.audioRange.end)
        self.active = ActiveSegment(segmentID: UUID(), event: remainder,
                                    startedAt: remainder.receivedAt, lastUpdatedAt: remainder.receivedAt,
                                    stable: StablePrefix(text: remainder.text, updateCount: 1,
                                                         since: remainder.receivedAt))
        if normalizer.requiresDiscontinuity {
            self.active = nil
            normalizer.reset()
            closedSegments.removeAll()
            event = .discontinuity(active.event.audioRange.start)
        }
        if let event { await channel?.push(event) }
    }

    private func emitCurrent(generation: UInt64) async {
        guard let active else { return }
        await emit(active, textEvent: active.event, stability: active.event.isFinal ? .final : .provisional,
                   generation: generation)
    }

    private func emitStablePrefix(generation: UInt64) async {
        guard let active else { return }
        var end = active.stable.text.endIndex
        while end > active.stable.text.startIndex {
            let previous = active.stable.text.index(before: end)
            guard active.stable.text[previous].isWhitespace else { break }
            end = previous
        }
        let text = String(active.stable.text[..<end])
        guard !text.isEmpty, let prefix = transcriptPrefix(active.event, characterCount: text.count) else { return }
        await emit(active, textEvent: prefix, stability: .provisional, generation: generation)
    }

    private func emit(
        _ input: ActiveSegment,
        textEvent: TranscriptEvent,
        stability: CaptionStability,
        generation: UInt64
    ) async {
        guard let event = prepareEmission(input, textEvent: textEvent, stability: stability, generation: generation) else { return }
        await channel?.push(event)
    }

    private func prepareEmission(
        _ input: ActiveSegment,
        textEvent: TranscriptEvent,
        stability: CaptionStability,
        generation: UInt64
    ) -> SegmentEvent? {
        guard self.generation == generation, !textEvent.text.isEmpty else { return nil }
        var active = input
        if active.hasEmitted && active.lastEmittedRevision == active.sourceRevision &&
            (active.lastEmittedText != textEvent.text || active.lastEmittedStability != stability) {
            active.sourceRevision += 1
        }
        if active.hasEmitted && active.lastEmittedText == textEvent.text &&
            active.lastEmittedRevision == active.sourceRevision && active.lastEmittedStability == stability {
            self.active = active
            return nil
        }
        let segment = CaptionSegment(segmentID: active.segmentID, utteranceID: active.event.utteranceID,
                                     audioRange: textEvent.audioRange, sourceRevision: active.sourceRevision,
                                     sourceText: textEvent.text, stability: stability, translationState: .pending)
        active.hasEmitted = true
        active.lastEmittedText = textEvent.text
        active.lastEmittedRevision = active.sourceRevision
        active.lastEmittedStability = stability
        if self.active?.segmentID == active.segmentID { self.active = active }
        return .upsert(segment)
    }

    private func updatedStable(_ stable: StablePrefix, previous: TranscriptEvent, current: TranscriptEvent) -> StablePrefix {
        let prefix = commonPrefix(previous.text, current.text)
        guard !prefix.isEmpty else {
            return StablePrefix(text: "", updateCount: 0, since: current.receivedAt)
        }
        if stable.text.hasPrefix(prefix) {
            return StablePrefix(text: prefix, updateCount: stable.updateCount + 1, since: stable.since)
        }
        if prefix.hasPrefix(stable.text), prefix.count > stable.text.count {
            return StablePrefix(text: prefix, updateCount: 1, since: current.receivedAt)
        }
        return StablePrefix(text: prefix, updateCount: 1, since: current.receivedAt)
    }

    private func commonPrefix(_ lhs: String, _ rhs: String) -> String {
        var index = lhs.startIndex
        var other = rhs.startIndex
        while index < lhs.endIndex && other < rhs.endIndex && lhs[index] == rhs[other] {
            lhs.formIndex(after: &index)
            rhs.formIndex(after: &other)
        }
        return String(lhs[..<index])
    }

    private func stableQualified(_ stable: StablePrefix, now: MonotonicInstant) -> Bool {
        !stable.text.isEmpty && stable.updateCount >= RuntimePolicy.stablePrefixUpdateCount &&
        elapsed(now, since: stable.since) >= captionNanoseconds(RuntimePolicy.stablePrefixAge)
    }

    private func elapsed(_ now: MonotonicInstant, since: MonotonicInstant) -> UInt64 {
        now.uptimeNanoseconds >= since.uptimeNanoseconds ? now.uptimeNanoseconds - since.uptimeNanoseconds : 0
    }

    private func punctuationBoundary(in text: String) -> Int? {
        let terminals: Set<Character> = [".", "!", "?", "。", "！", "？", "\n"]
        for (offset, character) in text.enumerated().reversed() where terminals.contains(character) {
            return offset + 1
        }
        return nil
    }

    private func transcriptPrefix(_ event: TranscriptEvent, characterCount: Int) -> TranscriptEvent? {
        split(event, at: min(characterCount, event.text.count))?.prefix
    }

    private func split(_ event: TranscriptEvent, at offset: Int) -> (prefix: TranscriptEvent, remainder: TranscriptEvent)? {
        guard offset > 0, offset <= event.text.count, !event.spans.isEmpty,
              !event.spans.contains(where: { $0.characterRange.lowerBound < offset && $0.characterRange.upperBound > offset }) else {
            return nil
        }
        let prefixSpans = event.spans.filter { $0.characterRange.lowerBound < offset }.map {
            TranscriptSpan(characterRange: $0.characterRange.lowerBound..<min($0.characterRange.upperBound, offset),
                           audioRange: $0.audioRange)
        }
        let remainderSpans = event.spans.filter { $0.characterRange.upperBound > offset }.map {
            TranscriptSpan(characterRange: max($0.characterRange.lowerBound, offset) - offset..<$0.characterRange.upperBound - offset,
                           audioRange: $0.audioRange)
        }
        let boundaryEnd = prefixSpans.last?.audioRange.end ?? event.audioRange.end
        let boundaryStart = remainderSpans.first?.audioRange.start ?? boundaryEnd
        let prefix = makeEvent(event, range: 0..<offset, spans: prefixSpans,
                               audioRange: captionRange(start: event.audioRange.start, end: boundaryEnd),
                               isFinal: false)
        let remainder = makeEvent(event, range: offset..<event.text.count, spans: remainderSpans,
                                  audioRange: captionRange(start: boundaryStart, end: event.audioRange.end),
                                  isFinal: event.isFinal)
        return (prefix, remainder)
    }

    private func makeEvent(
        _ event: TranscriptEvent,
        range: Range<Int>,
        spans: [TranscriptSpan],
        audioRange: AudioRange,
        isFinal: Bool
    ) -> TranscriptEvent {
        let lower = event.text.index(event.text.startIndex, offsetBy: range.lowerBound)
        let upper = event.text.index(event.text.startIndex, offsetBy: range.upperBound)
        return TranscriptEvent(utteranceID: event.utteranceID, audioRange: audioRange,
                               revision: event.revision, text: String(event.text[lower..<upper]),
                               spans: spans, isFinal: isFinal, receivedAt: event.receivedAt)
    }
}
