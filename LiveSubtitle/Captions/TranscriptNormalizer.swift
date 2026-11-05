import Foundation

enum CaptionTimeOrder {
    case ascending, same, descending
}

func captionCompare(_ lhs: AudioTimestamp, _ rhs: AudioTimestamp) -> CaptionTimeOrder {
    let left = Int128(lhs.value) * Int128(rhs.timescale)
    let right = Int128(rhs.value) * Int128(lhs.timescale)
    if left < right { return .ascending }
    if left > right { return .descending }
    return .same
}

func captionSeconds(_ timestamp: AudioTimestamp) -> Double {
    Double(timestamp.value) / Double(timestamp.timescale)
}

func captionRange(start: AudioTimestamp, end: AudioTimestamp) -> AudioRange {
    captionCompare(start, end) == .descending ? AudioRange(start: end, end: start) : AudioRange(start: start, end: end)
}

struct TranscriptNormalizer {
    private(set) var events: [TranscriptEvent] = []
    private var checkpoints: [UUID: AudioTimestamp] = [:]
    // Compacts retired per-utterance checkpoints without forgetting consumed audio.
    // New events crossing this boundary still require real character/audio mapping.
    private var retiredThrough: AudioTimestamp?
    private(set) var requiresDiscontinuity = false
    var checkpointCount: Int { checkpoints.count }

    mutating func normalize(_ event: TranscriptEvent) -> TranscriptEvent? {
        guard !requiresDiscontinuity, !event.text.isEmpty else { return nil }
        if let previous = events.first(where: { $0.utteranceID == event.utteranceID }) {
            if previous.isFinal && previous.audioRange == event.audioRange { return nil }
            if event.revision < previous.revision { return nil }
        }

        events.removeAll { $0.utteranceID == event.utteranceID }
        events.append(event)
        events.sort { captionCompare($0.audioRange.start, $1.audioRange.start) == .ascending }

        let latestEnd = events.map { captionSeconds($0.audioRange.end) }.max() ?? 0
        let cutoff = latestEnd - Double(RuntimePolicy.transcriptWindowDuration.components.seconds)
        events = events.filter { captionSeconds($0.audioRange.end) >= cutoff }
        var retained: [TranscriptEvent] = []
        for event in events {
            guard let windowed = clipToWindow(event, cutoff: cutoff) else { continue }
            let checkpoint = latestCheckpoint(checkpoints[event.utteranceID], retiredThrough)
            if let clipped = clip(windowed, checkpoint: checkpoint) {
                retained.append(clipped)
            }
        }
        events = retained
        if requiresDiscontinuity {
            reset()
            requiresDiscontinuity = true
            return nil
        }
        trimToCharacterLimit()
        return events.first { $0.utteranceID == event.utteranceID }
    }

    mutating func consume(utteranceID: UUID, through checkpoint: AudioTimestamp) {
        guard !requiresDiscontinuity else { return }
        if let existing = checkpoints[utteranceID], captionCompare(existing, checkpoint) != .ascending {
            return
        }
        if checkpoints[utteranceID] == nil && checkpoints.count >= RuntimePolicy.retainedSegmentLimit,
           let oldest = checkpoints.min(by: { captionCompare($0.value, $1.value) == .ascending }) {
            retiredThrough = latestCheckpoint(retiredThrough, oldest.value)
            checkpoints.removeValue(forKey: oldest.key)
        }
        checkpoints[utteranceID] = checkpoint
        guard let index = events.firstIndex(where: { $0.utteranceID == utteranceID }) else { return }
        let event = events[index]
        if let clipped = clip(event, checkpoint: checkpoint) {
            events[index] = clipped
        } else {
            events.remove(at: index)
        }
        if requiresDiscontinuity {
            events.removeAll()
            checkpoints.removeAll()
        }
    }

    mutating func reset() {
        events.removeAll()
        checkpoints.removeAll()
        retiredThrough = nil
        requiresDiscontinuity = false
    }

    private mutating func trimToCharacterLimit() {
        var total = events.reduce(0) { $0 + $1.text.count }
        while total > RuntimePolicy.transcriptWindowCharacterLimit, events.count > 1 {
            total -= events.removeFirst().text.count
        }
        guard total > RuntimePolicy.transcriptWindowCharacterLimit, let event = events.first else { return }
        guard !event.spans.isEmpty else {
            requiresDiscontinuity = true
            reset()
            requiresDiscontinuity = true
            return
        }
        let start = event.text.count - RuntimePolicy.transcriptWindowCharacterLimit
        events[0] = clipCharacters(event, range: start..<event.text.count)
    }

    private mutating func clipToWindow(_ event: TranscriptEvent, cutoff: Double) -> TranscriptEvent? {
        guard captionSeconds(event.audioRange.start) < cutoff else { return event }
        let consumed = event.spans.filter {
            $0.characterRange.upperBound <= event.text.count && captionSeconds($0.audioRange.end) <= cutoff
        }.map(\.characterRange.upperBound).max() ?? 0
        if consumed == event.text.count { return nil }
        guard consumed > 0 else {
            requiresDiscontinuity = true
            return nil
        }
        return clipCharacters(event, range: consumed..<event.text.count)
    }

    private func latestCheckpoint(_ lhs: AudioTimestamp?, _ rhs: AudioTimestamp?) -> AudioTimestamp? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return captionCompare(lhs, rhs) == .ascending ? rhs : lhs
    }

    private mutating func clip(_ event: TranscriptEvent, checkpoint: AudioTimestamp?) -> TranscriptEvent? {
        guard let checkpoint else { return event }
        if captionCompare(event.audioRange.end, checkpoint) != .descending { return nil }
        if captionCompare(event.audioRange.start, checkpoint) != .ascending { return event }
        let consumed = event.spans.filter {
            $0.characterRange.upperBound <= event.text.count &&
            captionCompare($0.audioRange.end, checkpoint) != .descending
        }.map(\.characterRange.upperBound).max() ?? 0
        if consumed == event.text.count { return nil }
        guard consumed > 0 else {
            requiresDiscontinuity = true
            return nil
        }
        return clipCharacters(event, range: consumed..<event.text.count, minimumStart: checkpoint)
    }

    private func clipCharacters(
        _ event: TranscriptEvent,
        range: Range<Int>,
        minimumStart: AudioTimestamp? = nil
    ) -> TranscriptEvent {
        var range = range
        if range.lowerBound > 0 {
            while range.lowerBound < range.upperBound {
                let index = event.text.index(event.text.startIndex, offsetBy: range.lowerBound)
                guard event.text[index].isWhitespace else { break }
                range = (range.lowerBound + 1)..<range.upperBound
            }
        }
        let lower = event.text.index(event.text.startIndex, offsetBy: range.lowerBound)
        let upper = event.text.index(event.text.startIndex, offsetBy: range.upperBound)
        let text = String(event.text[lower..<upper])
        let spans = event.spans.compactMap { span -> TranscriptSpan? in
            let lower = max(span.characterRange.lowerBound, range.lowerBound)
            let upper = min(span.characterRange.upperBound, range.upperBound)
            guard lower < upper else { return nil }
            return TranscriptSpan(characterRange: (lower - range.lowerBound)..<(upper - range.lowerBound),
                                  audioRange: span.audioRange)
        }
        let spanStart = spans.first?.audioRange.start
        let start = spanStart ?? minimumStart ?? event.audioRange.start
        return TranscriptEvent(utteranceID: event.utteranceID,
                               audioRange: captionRange(start: start, end: event.audioRange.end),
                               revision: event.revision, text: text, spans: spans,
                               isFinal: event.isFinal, receivedAt: event.receivedAt)
    }
}
