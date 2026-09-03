// TextHighlights.swift
//
// The marker strokes of one document. A direct port of the Windows
// edition's Core/TextHighlights.cs, so the two apps mark text the same
// way.
//
// A stroke is a stretch of the document by character offset, not a whole
// line: dragging the marker over three words marks exactly those words.
// Strokes are kept sorted and non-overlapping. Painting over an existing
// stroke replaces that part, another colour recolours it, and the eraser
// removes it. Strokes move with the text when it is edited and are
// stored per file, so they are still there after the file is closed and
// opened again.

import Foundation

/// The four marker colours. `none` is the eraser, and doubles as the
/// index-0 transparent slot in the colour tables.
enum HighlightColor: Int, Codable, CaseIterable {
    case none = 0, red = 1, blue = 2, yellow = 3, green = 4

    var label: String {
        switch self {
        case .none:   return "Eraser"
        case .red:    return "Red"
        case .blue:   return "Blue"
        case .yellow: return "Yellow"
        case .green:  return "Green"
        }
    }
}

/// One marker stroke.
struct HighlightRange: Equatable {
    var start: Int
    var length: Int
    var color: HighlightColor
    var end: Int { start + length }
}

final class TextHighlights {

    private(set) var ranges: [HighlightRange] = []

    /// Called after any change: a stroke painted or erased, or strokes
    /// moved by an edit.
    var onChanged: (() -> Void)?

    var isEmpty: Bool { ranges.isEmpty }
    var count: Int { ranges.count }

    // MARK: painting

    /// Paints the span in `color`; `.none` erases. True when anything
    /// changed.
    @discardableResult
    func paint(start: Int, length: Int, color: HighlightColor) -> Bool {
        guard length > 0, start >= 0 else { return false }
        let end = start + length
        var next: [HighlightRange] = []
        next.reserveCapacity(ranges.count + 2)
        var inserted = false, changed = false
        for r in ranges {
            if r.end <= start { next.append(r); continue }
            if r.start >= end {
                if !inserted, color != .none {
                    next.append(HighlightRange(start: start, length: length, color: color))
                    inserted = true
                }
                next.append(r)
                continue
            }
            // Overlap: keep the parts of the old stroke outside the span.
            changed = true
            if r.start < start {
                next.append(HighlightRange(start: r.start, length: start - r.start, color: r.color))
            }
            if !inserted, color != .none {
                next.append(HighlightRange(start: start, length: length, color: color))
                inserted = true
            }
            if r.end > end {
                next.append(HighlightRange(start: end, length: r.end - end, color: r.color))
            }
        }
        if !inserted, color != .none {
            next.append(HighlightRange(start: start, length: length, color: color))
            changed = true
        }
        guard changed else { return false }
        replace(next)
        return true
    }

    /// True when every character of the span already carries `color`.
    /// This is what makes dragging the same colour again erase.
    func isCovered(start: Int, length: Int, color: HighlightColor) -> Bool {
        guard length > 0 else { return false }
        var pos = start
        let end = start + length
        for r in ranges {
            if r.end <= pos { continue }
            if r.start > pos || r.color != color { return false }
            pos = r.end
            if pos >= end { return true }
        }
        return pos >= end
    }

    func clear() {
        guard !ranges.isEmpty else { return }
        ranges.removeAll()
        onChanged?()
    }

    /// Replaces every stroke, used when a file's stored strokes load.
    func replaceAll(_ incoming: [HighlightRange]) {
        replace(incoming.filter { $0.length > 0 && $0.start >= 0 && $0.color != .none }
                        .sorted { $0.start < $1.start })
    }

    /// The one funnel every mutation goes through: drops empty strokes and
    /// merges touching strokes of the same colour into one.
    private func replace(_ sorted: [HighlightRange]) {
        ranges.removeAll(keepingCapacity: true)
        for r in sorted {
            if r.length <= 0 { continue }
            if let last = ranges.last, last.color == r.color, last.end >= r.start {
                ranges[ranges.count - 1] = HighlightRange(start: last.start,
                                                          length: max(last.end, r.end) - last.start,
                                                          color: last.color)
                continue
            }
            ranges.append(r)
        }
        onChanged?()
    }

    // MARK: navigation and drawing

    /// The first stroke starting after `offset`, wrapping to the first.
    func next(after offset: Int) -> HighlightRange? {
        for r in ranges where r.start > offset { return r }
        return ranges.first
    }

    /// The last stroke starting before `offset`, wrapping to the last.
    func previous(before offset: Int) -> HighlightRange? {
        var before: HighlightRange? = nil
        for r in ranges {
            if r.start < offset { before = r } else { break }
        }
        return before ?? ranges.last
    }

    /// 1-based position among all strokes, for "Highlight 3 of 12".
    func ordinal(of range: HighlightRange) -> Int {
        for (i, r) in ranges.enumerated() where r.start == range.start { return i + 1 }
        return 0
    }

    /// Strokes touching [from, to), for drawing the visible part.
    func intersecting(from: Int, to: Int) -> [HighlightRange] {
        var out: [HighlightRange] = []
        for r in ranges {
            if r.end <= from { continue }
            if r.start >= to { break }
            out.append(r)
        }
        return out
    }

    // MARK: following edits

    /// The text [start, start+removed) became `inserted` characters.
    /// Strokes after the edit move by the difference, a stroke whose text
    /// was removed disappears, text typed INSIDE a stroke joins it, and
    /// text typed right before or right after one stays outside it.
    func shiftForEdit(start: Int, removed: Int, inserted: Int) {
        guard !ranges.isEmpty, removed != 0 || inserted != 0 else { return }
        let delta = inserted - removed
        let removedEnd = start + removed
        var next: [HighlightRange] = []
        next.reserveCapacity(ranges.count)
        var changed = false
        for r in ranges {
            let a = r.start, b = r.end
            let a2 = a < start ? a : (a >= removedEnd ? a + delta : start)
            let b2 = b <= start ? b : (b >= removedEnd ? b + delta : start)
            if a2 != a || b2 != b { changed = true }
            if b2 - a2 > 0 {
                next.append(HighlightRange(start: a2, length: b2 - a2, color: r.color))
            }
        }
        guard changed else { return }
        replace(next)
    }
}
