import CoreGraphics
import CoreText
import Foundation

enum SubtitleLineRole: Sendable {
    case translation
    case source
    case status
}

struct SubtitleLayoutInput: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let segmentID: UUID
        let sourceText: String
        let translationText: String?
    }

    let segments: [Segment]
    let displayCount: Int
    let translationOnly: Bool
    let statusText: String?

    init(snapshot: SubtitleSnapshot) {
        segments = snapshot.segments.map { segment in
            let translation: String?
            switch segment.translationState {
            case .translated(let text, _, _): translation = text
            case .updating(let previousText, _): translation = previousText
            case .pending, .failed: translation = nil
            }
            return Segment(
                segmentID: segment.segmentID,
                sourceText: segment.sourceText,
                translationText: translation
            )
        }
        displayCount = snapshot.displayCount
        translationOnly = snapshot.displayStyle == .translationOnly
        switch snapshot.status {
        case .waitingForAudio: statusText = "等待声音"
        case .listening: statusText = nil
        case .processingSlowly: statusText = "处理较慢"
        case .localFallback: statusText = "AI 不可用，已切换本地"
        case .stopping: statusText = "正在停止"
        case .failed: statusText = "字幕已停止"
        }
    }
}

struct SubtitleLayout: Sendable {
    struct Line: Sendable {
        let text: String
        let role: SubtitleLineRole
        let segmentID: UUID?
        let fontSize: CGFloat
        let baseline: CGPoint
    }

    private struct DraftLine {
        let text: String
        let role: SubtitleLineRole
        let segmentID: UUID?
        let fontSize: CGFloat
        let ascent: CGFloat
        let height: CGFloat
    }

    private struct DraftGroup {
        var lines: [DraftLine]

        var height: CGFloat {
            lines.reduce(0) { $0 + $1.height } + (lines.isEmpty ? 0 : 8)
        }
    }

    let size: CGSize
    let lines: [Line]

    init(snapshot: SubtitleSnapshot, size: CGSize) {
        self.init(input: SubtitleLayoutInput(snapshot: snapshot), size: size)
    }

    init(input: SubtitleLayoutInput, size: CGSize) {
        self.size = size
        guard size.width > 0, size.height > 0 else {
            lines = []
            return
        }

        let inset = max(8, min(28, size.width * 0.035))
        let contentWidth = size.width - inset * 2
        guard contentWidth > 0 else {
            lines = []
            return
        }

        let translationSize = max(18, min(34, size.height * 0.075))
        let sourceSize = max(12, translationSize * 0.7)
        let statusSize = max(12, min(18, size.height * 0.045))
        let statusGroup = Self.statusGroup(text: input.statusText, width: contentWidth, fontSize: statusSize)
        let availableHeight = max(0, size.height - inset * 2 - (statusGroup?.height ?? 0))

        let displayCount = min(max(input.displayCount, 1), RuntimePolicy.retainedSegmentLimit)
        var selected: [DraftGroup] = []
        var usedHeight: CGFloat = 0
        for segment in input.segments.suffix(displayCount).reversed() {
            let group = Self.segmentGroup(
                segment,
                translationOnly: input.translationOnly,
                width: contentWidth,
                translationSize: translationSize,
                sourceSize: sourceSize
            )
            guard !group.lines.isEmpty else { continue }
            if usedHeight + group.height <= availableHeight {
                selected.insert(group, at: 0)
                usedHeight += group.height
                continue
            }
            if selected.isEmpty {
                var remaining = availableHeight
                let partial = group.lines.prefix { line in
                    guard line.height <= remaining else { return false }
                    remaining -= line.height
                    return true
                }
                if !partial.isEmpty { selected = [DraftGroup(lines: Array(partial))] }
            }
            break
        }

        var groups = selected
        if let statusGroup { groups.append(statusGroup) }
        var top = size.height - inset
        var positioned: [Line] = []
        for group in groups {
            for draft in group.lines {
                top -= draft.ascent
                positioned.append(Line(
                    text: draft.text,
                    role: draft.role,
                    segmentID: draft.segmentID,
                    fontSize: draft.fontSize,
                    baseline: CGPoint(x: inset, y: top)
                ))
                top -= draft.height - draft.ascent
            }
            top -= 8
        }
        lines = positioned
    }

    func draw(in context: CGContext) {
        context.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 0.94))
        context.fill(CGRect(origin: .zero, size: size))
        for line in lines {
            let font = CTFontCreateUIFontForLanguage(.system, line.fontSize, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, line.fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(for: line.role)
            ]
            let attributed = NSAttributedString(string: line.text, attributes: attributes)
            let coreTextLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = line.baseline
            CTLineDraw(coreTextLine, context)
        }
    }

    private func color(for role: SubtitleLineRole) -> CGColor {
        switch role {
        case .translation: CGColor(gray: 1, alpha: 1)
        case .source: CGColor(gray: 0.82, alpha: 1)
        case .status: CGColor(gray: 0.82, alpha: 1)
        }
    }

    private static func segmentGroup(
        _ segment: SubtitleLayoutInput.Segment,
        translationOnly: Bool,
        width: CGFloat,
        translationSize: CGFloat,
        sourceSize: CGFloat
    ) -> DraftGroup {
        let translation = segment.translationText
        var drafts: [DraftLine] = []
        if let translation, !translation.isEmpty {
            drafts.append(contentsOf: wrap(
                text: translation,
                role: .translation,
                segmentID: segment.segmentID,
                fontSize: translationSize,
                color: CGColor(gray: 1, alpha: 1),
                width: width
            ))
            if !translationOnly, !segment.sourceText.isEmpty {
                drafts.append(contentsOf: wrap(
                    text: segment.sourceText,
                    role: .source,
                    segmentID: segment.segmentID,
                    fontSize: sourceSize,
                    color: CGColor(gray: 0.78, alpha: 1),
                    width: width
                ))
            }
        } else if !translationOnly, !segment.sourceText.isEmpty {
            drafts.append(contentsOf: wrap(
                text: segment.sourceText,
                role: .source,
                segmentID: segment.segmentID,
                fontSize: sourceSize,
                color: CGColor(gray: 0.9, alpha: 1),
                width: width
            ))
        }
        return DraftGroup(lines: drafts)
    }

    private static func statusGroup(text: String?, width: CGFloat, fontSize: CGFloat) -> DraftGroup? {
        guard let text else { return nil }
        return DraftGroup(lines: wrap(
            text: text,
            role: .status,
            segmentID: nil,
            fontSize: fontSize,
            color: CGColor(gray: 0.82, alpha: 1),
            width: width
        ))
    }

    private static func wrap(
        text: String,
        role: SubtitleLineRole,
        segmentID: UUID?,
        fontSize: CGFloat,
        color: CGColor,
        width: CGFloat
    ) -> [DraftLine] {
        guard !text.isEmpty, width > 0 else { return [] }
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        var result: [DraftLine] = []
        for paragraph in text.components(separatedBy: .newlines) where !paragraph.isEmpty {
            let attributed = NSAttributedString(string: paragraph, attributes: attributes)
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let nsText = paragraph as NSString
            var start = 0
            while start < nsText.length {
                var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
                if count <= 0 {
                    let index = String.Index(utf16Offset: start, in: paragraph)
                    let range = paragraph.rangeOfComposedCharacterSequence(at: index)
                    count = range.upperBound.utf16Offset(in: paragraph) - start
                }
                guard count > 0 else { break }
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                result.append(DraftLine(
                    text: nsText.substring(with: NSRange(location: start, length: count)),
                    role: role,
                    segmentID: segmentID,
                    fontSize: fontSize,
                    ascent: ascent,
                    height: ceil(ascent + descent + leading) + 4
                ))
                start += count
            }
        }
        return result
    }
}
