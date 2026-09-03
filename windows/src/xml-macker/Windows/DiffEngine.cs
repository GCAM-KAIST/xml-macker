using System.Collections.Generic;
using System.Linq;

namespace XMLMacker.Windows;

/// <summary>
/// One block of difference between the two line arrays. All indices are <b>0-based line indices</b>
/// (into <c>left</c> / <c>right</c>). Equal regions between hunks are implicit (never emitted).
/// Render semantics: <c>paired = min(LeftCount, RightCount)</c> lines are "changed"
/// (amber on both sides); <c>LeftCount - paired</c> extra left-only lines are "removed" (red left,
/// grey filler right); <c>RightCount - paired</c> extra right-only lines are "added" (green right,
/// grey filler left).
/// </summary>
public readonly struct Hunk
{
    public readonly int LeftStart;
    public readonly int LeftCount;
    public readonly int RightStart;
    public readonly int RightCount;

    public Hunk(int leftStart, int leftCount, int rightStart, int rightCount)
    {
        LeftStart = leftStart;
        LeftCount = leftCount;
        RightStart = rightStart;
        RightCount = rightCount;
    }
}

/// <summary>
/// Pure patience line-diff, no UI. 1:1 port of the Swift <c>DiffEngine</c>.
/// The win on near-identical model files comes from (1) common prefix/suffix trimming, (2) patience
/// anchors (lines unique on both sides), and (3) an O(n log n) LIS over the right indices to pick the
/// longest ordered anchor chain, recursing between anchors.
/// </summary>
public static class DiffEngine
{
    /// <summary>Entry point: diff the whole range, then coalesce overlapping/adjacent hunks.</summary>
    public static List<Hunk> Diff(IReadOnlyList<string> left, IReadOnlyList<string> right)
    {
        var outHunks = new List<Hunk>();
        DiffRange(left, 0, left.Count, right, 0, right.Count, outHunks);
        return Coalesce(outHunks);
    }

    /// <summary>
    /// Diffs only the half-open slices <c>[ls,le)</c> of <paramref name="left"/> and <c>[rs,re)</c> of
    /// <paramref name="right"/>; hunk indices stay absolute. Used by the element-aware comparison to
    /// line-compare the inside of two matched elements.
    /// </summary>
    public static List<Hunk> DiffSlice(IReadOnlyList<string> left, int ls, int le,
                                       IReadOnlyList<string> right, int rs, int re)
    {
        var outHunks = new List<Hunk>();
        DiffRange(left, ls, le, right, rs, re, outHunks);
        return Coalesce(outHunks);
    }

    /// <summary>Recursive patience diff on the half-open ranges <c>[ls,le)</c> / <c>[rs,re)</c>.</summary>
    private static void DiffRange(
        IReadOnlyList<string> l, int ls, int le,
        IReadOnlyList<string> r, int rs, int re,
        List<Hunk> outHunks)
    {
        // 1. Trim common prefix.
        while (ls < le && rs < re && l[ls] == r[rs]) { ls++; rs++; }
        // 2. Trim common suffix.
        while (le > ls && re > rs && l[le - 1] == r[re - 1]) { le--; re--; }

        // 3. Both empty → nothing.
        if (ls == le && rs == re) return;

        // 4. One side empty → a single pure add/remove hunk.
        if (ls == le || rs == re)
        {
            outHunks.Add(new Hunk(ls, le - ls, rs, re - rs));
            return;
        }

        // 5. Build patience anchors: lines that appear EXACTLY ONCE on BOTH sides.
        var lCount = new Dictionary<string, (int n, int first)>();
        for (int i = ls; i < le; i++)
        {
            string s = l[i];
            if (lCount.TryGetValue(s, out var e)) lCount[s] = (e.n + 1, e.first);
            else lCount[s] = (1, i);
        }
        var rCount = new Dictionary<string, (int n, int first)>();
        for (int i = rs; i < re; i++)
        {
            string s = r[i];
            if (rCount.TryGetValue(s, out var e)) rCount[s] = (e.n + 1, e.first);
            else rCount[s] = (1, i);
        }

        var candidates = new List<(int li, int ri)>();
        foreach (var kv in lCount)
        {
            if (kv.Value.n != 1) continue;
            if (rCount.TryGetValue(kv.Key, out var rv) && rv.n == 1)
                candidates.Add((kv.Value.first, rv.first));
        }

        // 6. No anchors → the whole remaining range is one hunk.
        if (candidates.Count == 0)
        {
            outHunks.Add(new Hunk(ls, le - ls, rs, re - rs));
            return;
        }

        // 7. Sort by left index; LIS over the right indices.
        candidates.Sort((a, b) => a.li.CompareTo(b.li));
        var chain = LongestIncreasingChain(candidates);

        // 8. Recurse between consecutive anchors, then the tail.
        int pl = ls, pr = rs;
        foreach (var a in chain)
        {
            DiffRange(l, pl, a.li, r, pr, a.ri, outHunks);
            pl = a.li + 1;
            pr = a.ri + 1;
        }
        DiffRange(l, pl, le, r, pr, re, outHunks);
    }

    /// <summary>
    /// Longest increasing subsequence over the <c>ri</c> values (patience O(n log n) with
    /// <c>tails</c>/<c>prev</c>), reconstructed as ordered anchor pairs. Reproduces the Swift exactly.
    /// </summary>
    private static List<(int li, int ri)> LongestIncreasingChain(List<(int li, int ri)> candidates)
    {
        var tails = new List<int>();          // indices into candidates
        var prev = new int[candidates.Count];

        for (int i = 0; i < candidates.Count; i++)
        {
            int target = candidates[i].ri;
            // First tails index where candidates[tails[mid]].ri >= target.
            int lo = 0, hi = tails.Count;
            while (lo < hi)
            {
                int mid = (lo + hi) / 2;
                if (candidates[tails[mid]].ri < target) lo = mid + 1;
                else hi = mid;
            }
            prev[i] = lo > 0 ? tails[lo - 1] : -1;
            if (lo == tails.Count) tails.Add(i);
            else tails[lo] = i;
        }

        var chain = new List<(int li, int ri)>();
        if (tails.Count == 0) return chain;
        int k = tails[tails.Count - 1];
        while (k != -1)
        {
            chain.Add(candidates[k]);
            k = prev[k];
        }
        chain.Reverse();
        return chain;
    }

    /// <summary>
    /// Sort by <c>LeftStart</c>; merge a hunk into the previous one when it starts at/before the
    /// previous hunk's end on BOTH sides, extending both counts via <c>max(...)</c>. Otherwise append.
    /// </summary>
    public static List<Hunk> Coalesce(List<Hunk> hunks)
    {
        var sorted = hunks.OrderBy(h => h.LeftStart).ToList();
        var result = new List<Hunk>();
        foreach (var h in sorted)
        {
            if (result.Count > 0)
            {
                var last = result[result.Count - 1];
                if (h.LeftStart <= last.LeftStart + last.LeftCount
                    && h.RightStart <= last.RightStart + last.RightCount)
                {
                    int leftEnd = System.Math.Max(last.LeftStart + last.LeftCount, h.LeftStart + h.LeftCount);
                    int rightEnd = System.Math.Max(last.RightStart + last.RightCount, h.RightStart + h.RightCount);
                    result[result.Count - 1] = new Hunk(
                        last.LeftStart, leftEnd - last.LeftStart,
                        last.RightStart, rightEnd - last.RightStart);
                    continue;
                }
            }
            result.Add(h);
        }
        return result;
    }
}
