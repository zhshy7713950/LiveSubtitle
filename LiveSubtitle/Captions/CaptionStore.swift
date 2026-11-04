import Foundation

actor CaptionStore: CaptionStoring {
    private var identity: SessionIdentity?
    private var display = DisplayPreferences(displayCount: RuntimePolicy.defaultDisplayCount, displayStyle: .bilingual)
    private var segments: [CaptionSegment] = []

    func begin(identity: SessionIdentity, display: DisplayPreferences) {
        self.identity = identity
        self.display = display
        segments.removeAll()
    }

    func advanceIdentity(_ identity: SessionIdentity) {
        guard self.identity != nil else { return }
        self.identity = identity
    }

    func upsert(_ segment: CaptionSegment) {
        guard identity != nil else { return }
        if let index = segments.firstIndex(where: { $0.segmentID == segment.segmentID }) {
            let previous = segments[index]
            guard segment.sourceRevision >= previous.sourceRevision else { return }
            if previous.stability == .final && previous.audioRange == segment.audioRange &&
                previous.sourceText != segment.sourceText {
                return
            }
            let changed = segment.sourceRevision != previous.sourceRevision || segment.sourceText != previous.sourceText
            let state = changed ? updatingState(from: previous.translationState) : previous.translationState
            segments[index] = CaptionSegment(segmentID: segment.segmentID, utteranceID: segment.utteranceID,
                                             audioRange: segment.audioRange, sourceRevision: segment.sourceRevision,
                                             sourceText: segment.sourceText, stability: segment.stability,
                                             translationState: state)
        } else {
            segments.append(segment)
        }
        segments.sort { captionCompare($0.audioRange.start, $1.audioRange.start) == .ascending }
        if segments.count > RuntimePolicy.retainedSegmentLimit {
            segments.removeFirst(segments.count - RuntimePolicy.retainedSegmentLimit)
        }
    }

    func apply(_ update: TranslationUpdate, for job: TranslationJob, now: MonotonicInstant) {
        guard let identity, identity == job.identity, update.identity == job.identity,
              update.jobID == job.jobID, update.segmentID == job.segmentID,
              update.sourceRevision == job.sourceRevision,
              now.uptimeNanoseconds <= job.deadline.uptimeNanoseconds,
              let index = segments.firstIndex(where: { $0.segmentID == job.segmentID }) else { return }
        let segment = segments[index]
        guard segment.sourceRevision == job.sourceRevision else { return }
        let state: CaptionTranslationState
        if let failure = update.failure {
            state = .failed(failure)
        } else {
            state = .translated(text: update.text, isFinal: update.isFinal, provider: update.provider)
        }
        segments[index] = CaptionSegment(segmentID: segment.segmentID, utteranceID: segment.utteranceID,
                                         audioRange: segment.audioRange, sourceRevision: segment.sourceRevision,
                                         sourceText: segment.sourceText, stability: segment.stability,
                                         translationState: state)
    }

    func setDisplay(_ preferences: DisplayPreferences) {
        display = preferences
    }

    func snapshot(mode: EffectiveMode, status: SubtitleStatus) -> SubtitleSnapshot? {
        guard let identity else { return nil }
        return SubtitleSnapshot(identity: identity, segments: segments,
                                displayCount: display.displayCount, displayStyle: display.displayStyle,
                                effectiveMode: mode, status: status)
    }

    func clear() {
        identity = nil
        segments.removeAll()
    }

    private func updatingState(from state: CaptionTranslationState) -> CaptionTranslationState {
        switch state {
        case .translated(let text, _, let provider):
            return .updating(previousText: text, previousProvider: provider)
        case .updating(let text, let provider):
            return .updating(previousText: text, previousProvider: provider)
        case .pending, .failed:
            return .pending
        }
    }
}
