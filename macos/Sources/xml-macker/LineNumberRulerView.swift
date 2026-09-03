import Cocoa

// Left-side gutter that draws the line number for each visible line
// of the source editor. Behaves the way code editors like Xcode /
// VS Code do: fixed-width numeric column, right-aligned, updates on
// scroll + edit.
//
// Performance note:
//   The ruler only iterates over the VISIBLE glyph range, so cost
//   scales with viewport size, not file size. Using NSTextView's
//   layout manager (TextKit 1 with allowsNonContiguousLayout = true)
//   keeps the per-line query sub-ms even on the 655 MB GCAM file.
//
// The ruler also uses the source editor's pre-computed `lineStarts`
// array to find the line number at the top of the viewport in O(log
// N), much faster than counting newlines from byte 0 every draw.
final class LineNumberRulerView: NSRulerView {

    // Supplied by SourceViewController after loadFile completes.
    // Empty at startup (no file open); drawing bails out then.
    var lineStarts: [Int] = [0]

    // Re-set via rebuildColors() from SourceViewController on theme
    // switch so the gutter follows Light/Dark/etc.
    var gutterBackground: NSColor = XMColor.bgDeep.withAlphaComponent(0.6)
    var digitColor:       NSColor = XMColor.text2   // text3 was too dim to read
    var digitFont:        NSFont  = XMFont.mono(10, .regular)
    var dividerColor:     NSColor = XMColor.hairline

    // Right-padding inside the gutter, before the text view starts.
    private let paddingRight: CGFloat = 6
    private let paddingLeft:  CGFloat = 4

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44          // bumped later by recomputeThickness
    }
    required init(coder: NSCoder) { fatalError() }

    // Re-measure the widest number we might show (doc-line count
    // digits) and expand if necessary. Called on load and after
    // inserts.
    func recomputeThickness(forTotalLines total: Int) {
        let digits = max(3, String(total).count)
        let sample = String(repeating: "8", count: digits)
        let w = (sample as NSString).size(withAttributes: [.font: digitFont]).width
        ruleThickness = (w + paddingLeft + paddingRight).rounded(.up)
    }

    // The ruler view lives in the SCROLL VIEW's coord system. The
    // text view's visible rect is what we need to map line-Y to
    // gutter-Y. AppKit gives us the correct offset via the scroll
    // view's clip-view bounds.
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = clientView as? NSTextView,
              let lm = tv.layoutManager,
              let tc = tv.textContainer,
              lineStarts.count > 1 else {
            // Nothing loaded, just paint the background so the gutter
            // isn't a stark default-gray column.
            gutterBackground.setFill()
            bounds.fill()
            return
        }

        gutterBackground.setFill()
        bounds.fill()

        // Thin hairline on the right edge so the gutter has a visible
        // boundary against the editor text.
        dividerColor.setFill()
        NSRect(x: bounds.width - 0.5, y: 0, width: 0.5, height: bounds.height).fill()

        // Visible glyph + char range in the TEXT VIEW's coordinate
        // space. The clip-view's bounds gives us the scroll offset.
        let visible = tv.visibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        guard glyphRange.length > 0 else { return }
        let charRange = lm.characterRange(forGlyphRange: glyphRange,
                                          actualGlyphRange: nil)
        let ns = tv.string as NSString
        let docLen = ns.length
        guard docLen > 0 else { return }

        // First visible line, start of the line that contains
        // charRange.location. Binary-search lineStarts for its line
        // number.
        let firstLineStart = ns.lineRange(for: NSRange(location: charRange.location,
                                                       length: 0)).location
        let startLineNumber = lineNumber(forCharOffset: firstLineStart)

        // Y offset: the ruler's coord origin is at the top-left of its
        // own bounds, but glyph rects are in text-view coords.
        // NSTextView.visibleRect.minY tells us how much we've scrolled.
        let containerYOffset = tv.textContainerOrigin.y
        let scrollY = visible.minY

        let drawAttrs: [NSAttributedString.Key: Any] = [
            .font: digitFont,
            .foregroundColor: digitColor
        ]

        var currentCharStart = firstLineStart
        var currentLine = startLineNumber

        while currentCharStart < NSMaxRange(charRange) {
            let glyphIdx = lm.glyphIndexForCharacter(at: currentCharStart)
            // Guard for edit-racing: if TextKit hasn't laid out this
            // glyph yet, skip and fall through to the next line.
            if glyphIdx >= lm.numberOfGlyphs, currentCharStart < docLen - 1 {
                break
            }
            var eff = NSRange()
            let lineRect = lm.lineFragmentRect(forGlyphAt: glyphIdx,
                                               effectiveRange: &eff)
            let yInTextView = lineRect.minY + containerYOffset
            let y = yInTextView - scrollY

            let label = "\(currentLine)" as NSString
            let size = label.size(withAttributes: drawAttrs)
            let x = bounds.width - size.width - paddingRight
            label.draw(at: NSPoint(x: x,
                                   y: y + (lineRect.height - size.height) / 2),
                       withAttributes: drawAttrs)

            // Advance to the next line, use the glyph range's end of
            // the current line fragment, mapped back to chars.
            let nextGlyph = NSMaxRange(eff)
            if nextGlyph >= lm.numberOfGlyphs { break }
            let nextChar = lm.characterIndexForGlyph(at: nextGlyph)
            if nextChar <= currentCharStart { break }    // guard against layout quirks
            currentCharStart = nextChar
            // A single logical line can wrap into multiple line
            // fragments. We only want to increment the displayed
            // number when we cross an actual `\n`.
            let prevLineOfNextChar = ns.lineRange(for:
                NSRange(location: nextChar - 1, length: 0)).location
            let newLineStart       = ns.lineRange(for:
                NSRange(location: nextChar,    length: 0)).location
            if newLineStart != prevLineOfNextChar {
                currentLine += 1
            }
        }
    }

    // Binary search `lineStarts` for the 1-based line number whose
    // starting char offset is ≤ `charOffset`. O(log N).
    private func lineNumber(forCharOffset charOffset: Int) -> Int {
        var lo = 0
        var hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= charOffset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }
}
