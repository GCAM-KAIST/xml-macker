// StructuralDiff.swift
//
// Element-aware alignment for the Diff window. A direct port of the
// Windows edition's StructuralDiff, so both apps compare files the same
// way.
//
// Why it exists: a plain line-by-line comparison of two GCAM files falls
// apart the moment the same sectors appear in a different ORDER. CORE
// lists trn_aviation_intl first under USA, an SSP override lists
// trn_freight first, and the line algorithm can only say "1,146 lines
// removed here, 1,146 lines added over there", which reads as if the
// second file had not loaded at all.
//
// This walker pairs elements by what they ARE, the tag name plus the
// identifying attribute (name, year, type, id, key), wherever they sit
// among their siblings. It recurses into every matched pair and only
// line-compares the text INSIDE matched elements. An element with no
// partner becomes one clean "only in this file" block.
//
// The output is the same [DiffEngine.Hunk] the line engine produces, so
// navigation, copying and the aligned views work unchanged. Left lines
// are emitted in strict file order, which the tree sidebar depends on,
// and the walker checks that it held. If anything about a file breaks
// the assumptions (elements sharing lines, a range that does not
// partition cleanly), align returns nil and the caller falls back to the
// line comparison. Never a broken model.

import Foundation

enum StructuralDiff {

    /// One run of aligned rows. Line indices are 0-based; a hunk may have
    /// zero lines on one side.
    ///
    /// The equal runs are explicit rather than implied by the gaps
    /// between hunks, because pairing by identity visits the RIGHT file
    /// out of order: when two regions swap places, the run of equal lines
    /// after the first difference is at line 4 on the left and line 1 on
    /// the right. A hunk list with implicit gaps cannot say that.
    struct Segment {
        let isHunk: Bool
        var leftStart: Int, leftCount: Int, rightStart: Int, rightCount: Int
        static func same(_ l: Int, _ r: Int, _ count: Int) -> Segment {
            Segment(isHunk: false, leftStart: l, leftCount: count, rightStart: r, rightCount: count)
        }
        static func diff(_ l: Int, _ lc: Int, _ r: Int, _ rc: Int) -> Segment {
            Segment(isHunk: true, leftStart: l, leftCount: lc, rightStart: r, rightCount: rc)
        }
    }

    /// Attribute names that identify an element to a reader, in priority
    /// order.
    private static let keyNames = ["name", "year", "type", "id", "key"]

    /// Aligns two parsed documents. Returns the segment list in display
    /// order, or nil when the files do not fit the element-per-line shape
    /// this walker relies on.
    static func align(leftRoot: XMLTreeNode, rightRoot: XMLTreeNode,
                      leftLines: [String], rightLines: [String]) -> [Segment]? {
        let w = Walker(leftLines, rightLines)
        w.emitPair(leftRoot, 0, leftLines.count, rightRoot, 0, rightLines.count, 0)
        guard w.valid, w.leftNext == leftLines.count else { return nil }

        // Every line of BOTH files must be shown exactly once, or the two
        // sides would not line up on screen. Prove it before returning.
        var lSeen = 0, rSeen = 0
        for s in w.segments { lSeen += s.leftCount; rSeen += s.rightCount }
        guard lSeen == leftLines.count, rSeen == rightLines.count else { return nil }
        return w.segments
    }

    /// The same shape for the line engine, so the model builder has one
    /// code path: the equal runs between hunks made explicit.
    static func segments(fromLineHunks hunks: [DiffEngine.Hunk],
                         leftCount: Int, rightCount: Int) -> [Segment] {
        var out: [Segment] = []
        var li = 0, ri = 0
        for h in hunks {
            let gap = h.leftStart - li
            if gap > 0 { out.append(.same(li, ri, gap)) }
            li = h.leftStart; ri = h.rightStart
            out.append(.diff(h.leftStart, h.leftCount, h.rightStart, h.rightCount))
            li += h.leftCount; ri += h.rightCount
        }
        if leftCount - li > 0 { out.append(.same(li, ri, leftCount - li)) }
        return out
    }

    private final class Walker {
        private static let maxDepth = 80

        private let l: [String]
        private let r: [String]
        var segments: [Segment] = []

        /// Invariant: every left line is emitted exactly once, in order.
        var leftNext = 0
        var valid = true

        /// Where an unpaired block would be inserted on the other side:
        /// right after the last content shown on that side.
        private var lCursor = 0
        private var rCursor = 0

        init(_ l: [String], _ r: [String]) { self.l = l; self.r = r }

        // MARK: emitting

        private func same(_ l: Int, _ r: Int, _ count: Int) {
            if count <= 0 { return }
            if l != leftNext { valid = false; return }
            segments.append(.same(l, r, count))
            leftNext = l + count
            lCursor = l + count
            rCursor = r + count
        }

        private func diff(_ l: Int, _ lc: Int, _ r: Int, _ rc: Int) {
            if lc <= 0 && rc <= 0 { return }
            if lc > 0 && l != leftNext { valid = false; return }

            // A one-sided block that continues straight on from the
            // previous hunk on the same side, with the other side
            // unmoved, joins it. Five unmatched siblings in a row are
            // then ONE difference, so the count stops being a count of
            // elements.
            if let prev = segments.last, prev.isHunk {
                let prevLeftEnd = prev.leftStart + prev.leftCount == l
                let prevRightEnd = prev.rightStart + prev.rightCount == r
                let joinLeft = lc > 0 && rc == 0 && prevLeftEnd && prevRightEnd
                let joinRight = rc > 0 && lc == 0 && prevRightEnd && prevLeftEnd
                if joinLeft || joinRight {
                    segments[segments.count - 1] = .diff(prev.leftStart, prev.leftCount + lc,
                                                         prev.rightStart, prev.rightCount + rc)
                    if lc > 0 { leftNext = l + lc; lCursor = l + lc }
                    if rc > 0 { rCursor = r + rc }
                    return
                }
            }

            segments.append(.diff(l, lc, r, rc))
            if lc > 0 { leftNext = l + lc; lCursor = l + lc }
            if rc > 0 { rCursor = r + rc }
        }

        /// Line-compares two ranges with the patience engine and emits
        /// the result.
        private func emitLineDiff(_ lFrom: Int, _ lTo: Int, _ rFrom: Int, _ rTo: Int) {
            let lc = lTo - lFrom, rc = rTo - rFrom
            if lc <= 0 && rc <= 0 { return }
            if lc <= 0 || rc <= 0 { diff(lFrom, lc, rFrom, rc); return }

            let hunks = DiffEngine.diffSlice(left: l, lFrom: lFrom, lTo: lTo,
                                             right: r, rFrom: rFrom, rTo: rTo)
            var li = lFrom, ri = rFrom
            for h in hunks {
                let equal = h.leftStart - li
                if equal != h.rightStart - ri { valid = false; return }   // engine invariant
                same(li, ri, equal)
                diff(h.leftStart, h.leftCount, h.rightStart, h.rightCount)
                li = h.leftStart + h.leftCount
                ri = h.rightStart + h.rightCount
                if !valid { return }
            }
            if lTo - li != rTo - ri { valid = false; return }
            same(li, ri, lTo - li)
        }

        // MARK: the structural walk

        private static func kids(_ n: XMLTreeNode) -> [XMLTreeNode] {
            n.children.filter { $0.kind == .element }
        }

        private static func key(_ n: XMLTreeNode) -> String? {
            for name in keyNames {
                for a in n.attributes where a.name == name { return a.value }
            }
            return nil
        }

        /// Cuts a node's line range into: its opening line(s), one block
        /// per element child (each block runs from the child's first line
        /// up to the next child's first line, so comment and text lines
        /// between children travel with the child before them), and its
        /// closing line(s). Returns nil when the children do not sit on
        /// distinct, ascending lines.
        private static func partition(_ kids: [XMLTreeNode], _ from: Int, _ to: Int)
            -> (openEnd: Int, blockStart: [Int], closeStart: Int)? {
            guard !kids.isEmpty else { return nil }
            let first = kids[0].startLine - 1              // 0-based
            let lastEnd = kids[kids.count - 1].endLine     // 0-based EXCLUSIVE end
            guard first >= from, lastEnd <= to else { return nil }

            var blockStart = [Int](repeating: 0, count: kids.count + 1)
            for i in 0..<kids.count {
                let s = kids[i].startLine - 1
                let e = kids[i].endLine                    // exclusive
                if e < s + 1 { return nil }
                if i > 0, s < blockStart[i - 1] + 1 { return nil }        // must move forward
                if i > 0, kids[i - 1].endLine > s { return nil }          // previous child must have closed
                blockStart[i] = s
            }
            blockStart[kids.count] = lastEnd
            return (first, blockStart, lastEnd)
        }

        func emitPair(_ lNode: XMLTreeNode, _ lFrom: Int, _ lTo: Int,
                      _ rNode: XMLTreeNode, _ rFrom: Int, _ rTo: Int, _ depth: Int) {
            if !valid { return }

            let lKids = Self.kids(lNode)
            let rKids = Self.kids(rNode)

            guard depth < Self.maxDepth, !lKids.isEmpty, !rKids.isEmpty,
                  let lPart = Self.partition(lKids, lFrom, lTo),
                  let rPart = Self.partition(rKids, rFrom, rTo) else {
                emitLineDiff(lFrom, lTo, rFrom, rTo)
                return
            }
            let lBlock = lPart.blockStart, rBlock = rPart.blockStart

            // 1. The opening tag line(s).
            emitLineDiff(lFrom, lPart.openEnd, rFrom, rPart.openEnd)
            if !valid { return }

            // 2. Pair the children by identity, whatever their order.
            struct Identity: Hashable { let name: String; let key: String? }
            var rQueue: [Identity: [Int]] = [:]
            for j in 0..<rKids.count {
                let k = Identity(name: rKids[j].name, key: Self.key(rKids[j]))
                rQueue[k, default: []].append(j)
            }
            var match = [Int](repeating: -1, count: lKids.count)
            var rMatched = [Bool](repeating: false, count: rKids.count)
            for i in 0..<lKids.count {
                let k = Identity(name: lKids[i].name, key: Self.key(lKids[i]))
                if var q = rQueue[k], !q.isEmpty {
                    let j = q.removeFirst()
                    rQueue[k] = q
                    match[i] = j
                    rMatched[j] = true
                }
            }

            // A right-only child is shown just before the next right child
            // that DID find a partner, so it appears where it sits in its
            // own file; leftovers after the last partner go at the end.
            var before: [Int: [Int]] = [:]
            var pending: [Int] = []
            for j in 0..<rKids.count {
                if !rMatched[j] { pending.append(j); continue }
                if !pending.isEmpty { before[j] = pending; pending = [] }
            }
            let tail = pending

            // 3. Walk the LEFT children in file order.
            for i in 0..<lKids.count {
                let j = match[i]
                if j >= 0 {
                    if let extras = before[j] {
                        for jj in extras { emitRightOnly(rBlock[jj], rBlock[jj + 1]) }
                    }
                    emitPair(lKids[i], lBlock[i], lBlock[i + 1],
                             rKids[j], rBlock[j], rBlock[j + 1], depth + 1)
                } else {
                    emitLeftOnly(lBlock[i], lBlock[i + 1])
                }
                if !valid { return }
            }
            for jj in tail { emitRightOnly(rBlock[jj], rBlock[jj + 1]) }

            // 4. The closing tag line(s).
            emitLineDiff(lPart.closeStart, lTo, rPart.closeStart, rTo)
        }

        private func emitLeftOnly(_ from: Int, _ to: Int) { diff(from, to - from, rCursor, 0) }
        private func emitRightOnly(_ from: Int, _ to: Int) { diff(lCursor, 0, from, to - from) }
    }
}
