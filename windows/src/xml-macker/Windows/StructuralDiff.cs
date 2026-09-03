using System.Collections.Generic;
using XMLMacker.Core;

namespace XMLMacker.Windows;

/// <summary>
/// Element-aware alignment for the Diff window.
///
/// <para>A plain line-by-line comparison of two GCAM files falls apart the moment the same sectors appear
/// in a different ORDER: CORE lists <c>trn_aviation_intl</c> first under USA, an SSP override lists
/// <c>trn_freight</c> first, and the line algorithm can only report "1,146 lines removed here, 1,146
/// lines added over there". This walker instead pairs elements by what they ARE, the tag name plus the
/// identifying attribute (<c>name</c>, <c>year</c>, <c>type</c>, <c>id</c>, <c>key</c>), regardless of
/// where they sit among their siblings, recurses into every matched pair, and only line-compares the
/// text INSIDE matched elements. Elements with no partner become one clean "only in this file" block.</para>
///
/// <para>Output is a flat list of segments in display order: <c>Same</c> runs (identical lines on both
/// sides) and <c>Diff</c> hunks (the same shape the line engine produces, so navigation and Copy work
/// unchanged). Left lines are emitted in strict file order, the tree sidebar depends on that, and the
/// walker verifies it; if anything about a file breaks the assumptions (elements sharing lines, a range
/// that does not partition cleanly), <see cref="Align"/> returns <c>null</c> and the caller falls back to
/// the line comparison. Never a broken model.</para>
/// </summary>
internal static class StructuralDiff
{
    /// <summary>One run of aligned rows. Line indices are 0-based; counts may be 0 on one side of a hunk.</summary>
    internal readonly struct Segment
    {
        public readonly bool IsHunk;
        public readonly int LeftStart, LeftCount, RightStart, RightCount;

        private Segment(bool hunk, int l, int lc, int r, int rc)
        { IsHunk = hunk; LeftStart = l; LeftCount = lc; RightStart = r; RightCount = rc; }

        public static Segment Same(int l, int r, int count) => new(false, l, count, r, count);
        public static Segment Diff(int l, int lc, int r, int rc) => new(true, l, lc, r, rc);
    }

    /// <summary>Attribute names that identify an element to a reader, in priority order.</summary>
    private static readonly string[] KeyNames = { "name", "year", "type", "id", "key" };

    /// <summary>
    /// Aligns two parsed documents. Returns the segment list, or <c>null</c> when the files do not fit the
    /// element-per-line shape this walker relies on (the caller then uses the line comparison).
    /// </summary>
    public static List<Segment>? Align(XmlTreeNode leftRoot, XmlTreeNode rightRoot,
                                       IReadOnlyList<string> leftLines, IReadOnlyList<string> rightLines)
    {
        var w = new Walker(leftLines, rightLines);
        w.EmitPair(leftRoot, 0, leftLines.Count, rightRoot, 0, rightLines.Count, 0);
        if (!w.Valid || w.LeftNext != leftLines.Count) return null;
        return w.Segments;
    }

    private sealed class Walker
    {
        private const int MaxDepth = 80;

        private readonly IReadOnlyList<string> _l;
        private readonly IReadOnlyList<string> _r;
        public readonly List<Segment> Segments = new();

        // Invariant: every left line is emitted exactly once, in order.
        public int LeftNext;
        public bool Valid = true;

        // Where an unpaired block would be inserted on the other side: right after the last content
        // shown on that side. Kept in sync by every emit.
        private int _lCursor;
        private int _rCursor;

        public Walker(IReadOnlyList<string> l, IReadOnlyList<string> r) { _l = l; _r = r; }

        // ── emitting ────────────────────────────────────────────────────────────────────────────

        private void Same(int l, int r, int count)
        {
            if (count <= 0) return;
            if (l != LeftNext) { Valid = false; return; }
            Segments.Add(Segment.Same(l, r, count));
            LeftNext = l + count;
            _lCursor = l + count;
            _rCursor = r + count;
        }

        private void Diff(int l, int lc, int r, int rc)
        {
            if (lc <= 0 && rc <= 0) return;
            if (lc > 0 && l != LeftNext) { Valid = false; return; }

            // A one-sided block that continues straight on from the previous hunk on the same side, with
            // the other side unmoved, joins it. Five unmatched siblings in a row are then ONE difference
            // ("9 lines only in CORE"), which is what the caption on the filler run already says, and the
            // difference count stops being a count of elements.
            if (Segments.Count > 0 && Segments[^1].IsHunk)
            {
                Segment prev = Segments[^1];
                bool prevLeftEnd = prev.LeftStart + prev.LeftCount == l;
                bool prevRightEnd = prev.RightStart + prev.RightCount == r;
                bool joinLeft = lc > 0 && rc == 0 && prevLeftEnd && prevRightEnd;
                bool joinRight = rc > 0 && lc == 0 && prevRightEnd && prevLeftEnd;
                if (joinLeft || joinRight)
                {
                    Segments[^1] = Segment.Diff(prev.LeftStart, prev.LeftCount + lc, prev.RightStart, prev.RightCount + rc);
                    if (lc > 0) { LeftNext = l + lc; _lCursor = l + lc; }
                    if (rc > 0) _rCursor = r + rc;
                    return;
                }
            }

            Segments.Add(Segment.Diff(l, lc, r, rc));
            if (lc > 0) { LeftNext = l + lc; _lCursor = l + lc; }
            if (rc > 0) _rCursor = r + rc;
        }

        /// <summary>Line-compares two ranges with the patience engine and emits the result.</summary>
        private void EmitLineDiff(int lFrom, int lTo, int rFrom, int rTo)
        {
            int lc = lTo - lFrom, rc = rTo - rFrom;
            if (lc <= 0 && rc <= 0) return;
            if (lc <= 0 || rc <= 0) { Diff(lFrom, lc, rFrom, rc); return; }

            List<Hunk> hunks = DiffEngine.DiffSlice(_l, lFrom, lTo, _r, rFrom, rTo);
            int li = lFrom, ri = rFrom;
            foreach (Hunk h in hunks)
            {
                int equal = h.LeftStart - li;
                if (equal != h.RightStart - ri) { Valid = false; return; }   // engine invariant
                Same(li, ri, equal);
                Diff(h.LeftStart, h.LeftCount, h.RightStart, h.RightCount);
                li = h.LeftStart + h.LeftCount;
                ri = h.RightStart + h.RightCount;
                if (!Valid) return;
            }
            if (lTo - li != rTo - ri) { Valid = false; return; }
            Same(li, ri, lTo - li);
        }

        // ── the structural walk ─────────────────────────────────────────────────────────────────

        private static List<XmlTreeNode> Kids(XmlTreeNode n)
        {
            var kids = new List<XmlTreeNode>();
            foreach (XmlTreeNode c in n.Children) if (c.Kind == NodeKind.Element) kids.Add(c);
            return kids;
        }

        private static string? Key(XmlTreeNode n)
        {
            foreach (string name in KeyNames)
                foreach ((string Name, string Value) a in n.Attributes)
                    if (a.Name == name) return a.Value;
            return null;
        }

        /// <summary>
        /// Cuts a node's line range into: its opening line(s), one block per element child (each block
        /// runs from the child's first line up to the next child's first line, so comment and text lines
        /// between children travel with the child before them), and its closing line(s).
        /// Returns false when the children do not sit on distinct, ascending lines.
        /// </summary>
        private static bool Partition(List<XmlTreeNode> kids, int from, int to,
                                      out int openEnd, out int[] blockStart, out int closeStart)
        {
            openEnd = from; closeStart = to; blockStart = new int[kids.Count + 1];
            if (kids.Count == 0) return false;

            int first = kids[0].StartLine - 1;                 // 0-based
            int lastEnd = kids[^1].EndLine;                    // 0-based EXCLUSIVE end of the last child
            if (first < from || lastEnd > to) return false;

            for (int i = 0; i < kids.Count; i++)
            {
                int s = kids[i].StartLine - 1;
                int e = kids[i].EndLine;                        // exclusive
                if (e < s + 1) return false;
                if (i > 0 && s < blockStart[i - 1] + 1) return false;      // must move forward
                if (i > 0 && kids[i - 1].EndLine > s) return false;         // previous child must have closed
                blockStart[i] = s;
            }
            blockStart[kids.Count] = lastEnd;
            openEnd = first;
            closeStart = lastEnd;
            return true;
        }

        public void EmitPair(XmlTreeNode lNode, int lFrom, int lTo, XmlTreeNode rNode, int rFrom, int rTo, int depth)
        {
            if (!Valid) return;

            List<XmlTreeNode> lKids = Kids(lNode);
            List<XmlTreeNode> rKids = Kids(rNode);

            // Pre-initialised because the compiler cannot see through the short-circuiting chain below.
            int lOpenEnd = lFrom, rOpenEnd = rFrom, lCloseStart = lTo, rCloseStart = rTo;
            int[] lBlock = System.Array.Empty<int>(), rBlock = System.Array.Empty<int>();
            bool structural = depth < MaxDepth
                && lKids.Count > 0 && rKids.Count > 0
                && Partition(lKids, lFrom, lTo, out lOpenEnd, out lBlock, out lCloseStart)
                && Partition(rKids, rFrom, rTo, out rOpenEnd, out rBlock, out rCloseStart);

            if (!structural)
            {
                EmitLineDiff(lFrom, lTo, rFrom, rTo);
                return;
            }

            // 1. The opening tag line(s).
            EmitLineDiff(lFrom, lOpenEnd, rFrom, rOpenEnd);
            if (!Valid) return;

            // 2. Pair the children by identity, whatever their order.
            var rQueue = new Dictionary<(string Name, string? Key), Queue<int>>();
            for (int j = 0; j < rKids.Count; j++)
            {
                var k = (rKids[j].Name, Key(rKids[j]));
                if (!rQueue.TryGetValue(k, out Queue<int>? q)) { q = new Queue<int>(); rQueue[k] = q; }
                q.Enqueue(j);
            }
            var match = new int[lKids.Count];
            var rMatched = new bool[rKids.Count];
            for (int i = 0; i < lKids.Count; i++)
            {
                match[i] = -1;
                var k = (lKids[i].Name, Key(lKids[i]));
                if (rQueue.TryGetValue(k, out Queue<int>? q) && q.Count > 0)
                {
                    int j = q.Dequeue();
                    match[i] = j;
                    rMatched[j] = true;
                }
            }

            // A right-only child is shown just before the next right child that DID find a partner, so it
            // appears where it sits in its own file; leftovers after the last partner go at the end.
            var before = new Dictionary<int, List<int>>();
            var pending = new List<int>();
            for (int j = 0; j < rKids.Count; j++)
            {
                if (!rMatched[j]) { pending.Add(j); continue; }
                if (pending.Count > 0) { before[j] = pending; pending = new List<int>(); }
            }
            List<int> tail = pending;

            // 3. Walk the LEFT children in file order.
            for (int i = 0; i < lKids.Count; i++)
            {
                int j = match[i];
                if (j >= 0)
                {
                    if (before.TryGetValue(j, out List<int>? extras))
                        foreach (int jj in extras) EmitRightOnly(rBlock[jj], rBlock[jj + 1]);
                    EmitPair(lKids[i], lBlock[i], lBlock[i + 1], rKids[j], rBlock[j], rBlock[j + 1], depth + 1);
                }
                else
                {
                    EmitLeftOnly(lBlock[i], lBlock[i + 1]);
                }
                if (!Valid) return;
            }
            foreach (int jj in tail) EmitRightOnly(rBlock[jj], rBlock[jj + 1]);

            // 4. The closing tag line(s).
            EmitLineDiff(lCloseStart, lTo, rCloseStart, rTo);
        }

        private void EmitLeftOnly(int from, int to) => Diff(from, to - from, _rCursor, 0);
        private void EmitRightOnly(int from, int to) => Diff(_lCursor, 0, from, to - from);
    }
}
