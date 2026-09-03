using System;

namespace XMLMacker.Editor;

/// <summary>
/// The <c>lineStarts</c> engine (1:1 port of the Swift <c>SourceViewController.lineStarts</c> maintenance). An
/// <see cref="int"/>[] where entry <c>i</c> = the UTF-16 char offset at which line <c>i+1</c> begins; the first
/// entry is always <c>0</c>. Line/offset mapping is O(log N) binary search, never a linear scan on the
/// render/scroll path. Offsets are safe as <see cref="int"/> (655 M UTF-16 units &lt; int.MaxValue).
///
/// <para>Maintenance policy on edit (owned here, driven by the editor):</para>
/// <list type="bullet">
/// <item><b>Single-line edit</b> (no <c>\n</c> added or removed) → <see cref="IncrementalUpdate"/> delta-shifts
/// the tail only.</item>
/// <item><b>Newline-introducing edit</b> → <see cref="SpliceEdit"/> rebuilds only the affected span + shifts the
/// tail (O(lineCount) int-copy), or <see cref="Rebuild"/> rescans the whole document (used for bulk ReplaceAll).</item>
/// </list>
/// </summary>
public sealed class LineIndex
{
    private int[] _starts = { 0 };

    /// <summary>The raw offset table (first entry always <c>0</c>). Exposed for the ruler and minimap.</summary>
    public int[] Starts => _starts;

    /// <summary>Number of lines (= <c>Starts.Length</c>).</summary>
    public int LineCount => _starts.Length;

    /// <summary>Replaces the whole table (used after a background <see cref="BuildLineStarts(string)"/> at load).</summary>
    public void SetStarts(int[] starts)
        => _starts = (starts is { Length: > 0 }) ? starts : new[] { 0 };

    /// <summary>Offset of the 0-based line <paramref name="lineIndex0"/> (clamped).</summary>
    public int OffsetForLineIndex(int lineIndex0)
    {
        if (lineIndex0 <= 0) return _starts[0];
        if (lineIndex0 >= _starts.Length) return _starts[^1];
        return _starts[lineIndex0];
    }

    /// <summary>Offset where the 1-based <paramref name="line"/> begins (clamped to <c>[1, LineCount]</c>).</summary>
    public int OffsetForLine(int line)
    {
        int idx = Math.Clamp(line - 1, 0, _starts.Length - 1);
        return _starts[idx];
    }

    /// <summary>
    /// 1-based line number containing char offset <paramref name="offset"/>, the upper-bound binary search from
    /// the spec (largest index whose start is &lt;= offset, plus one).
    /// </summary>
    /// <summary>0-based line containing <paramref name="offset"/>, for any line-start table.</summary>
    public static int LineForOffset(int[] starts, int offset)
    {
        int lo = 0, hi = starts.Length - 1;
        while (lo < hi)
        {
            int mid = (lo + hi + 1) >> 1;
            if (starts[mid] <= offset) lo = mid; else hi = mid - 1;
        }
        return lo;
    }

    public int LineForOffset(int offset)
    {
        int lo = 0, hi = _starts.Length - 1;
        while (lo < hi)
        {
            int mid = (lo + hi + 1) >> 1;
            if (_starts[mid] <= offset) lo = mid; else hi = mid - 1;
        }
        return lo + 1;
    }

    /// <summary>
    /// Single-line edit maintenance: every line start strictly after the edited line shifts by
    /// <paramref name="delta"/>. <paramref name="editOffset"/> is the char offset where the replacement began.
    /// Attribute/text/fix edits with no newline use this (exact; O(tailLength) int adds, the Swift delta-shift).
    /// </summary>
    public void IncrementalUpdate(int editOffset, int delta)
    {
        if (delta == 0) return;
        int editLine = LineForOffset(editOffset); // 1-based; starts at index editLine begin the NEXT line.
        for (int i = editLine; i < _starts.Length; i++)
            _starts[i] += delta;
    }

    /// <summary>
    /// Delta-shifts every start at or after 0-based index <paramref name="fromIndex"/> by <paramref name="delta"/>.
    /// Low-level primitive behind <see cref="IncrementalUpdate"/>.
    /// </summary>
    public void DeltaShift(int fromIndex, int delta)
    {
        if (delta == 0) return;
        for (int i = Math.Max(0, fromIndex); i < _starts.Length; i++)
            _starts[i] += delta;
    }

    /// <summary>
    /// Newline-introducing edit maintenance. Splices the table for an edit at <paramref name="editOffset"/> that
    /// removed <paramref name="removedText"/> and inserted <paramref name="addedText"/>: drops the line starts that
    /// fell inside the removed span, inserts new starts for each <c>\n</c> in the inserted text, and shifts the tail
    /// by the length delta. O(lineCount) int-copy, far cheaper than an O(docLen) full rescan, so pressing Enter in
    /// a 12.6 M-line file stays responsive.
    /// </summary>
    public void SpliceEdit(int editOffset, string removedText, string addedText)
    {
        int delta = addedText.Length - removedText.Length;
        int removedEnd = editOffset + removedText.Length;

        // Starts to drop: those strictly greater than editOffset and <= removedEnd (newlines inside the removed span).
        // Find first index with start > editOffset (== first potentially-affected start).
        int firstAffected = UpperBoundIndex(editOffset);
        int firstAfter = firstAffected;
        while (firstAfter < _starts.Length && _starts[firstAfter] <= removedEnd)
            firstAfter++;

        // New starts introduced by newlines in the inserted text.
        int newlineCount = 0;
        for (int i = 0; i < addedText.Length; i++)
            if (addedText[i] == '\n') newlineCount++;

        int keptHead = firstAffected;               // entries [0, firstAffected)
        int tailCount = _starts.Length - firstAfter; // entries [firstAfter, end)
        var next = new int[keptHead + newlineCount + tailCount];

        Array.Copy(_starts, 0, next, 0, keptHead);

        int w = keptHead;
        for (int i = 0; i < addedText.Length; i++)
            if (addedText[i] == '\n')
                next[w++] = editOffset + i + 1;

        for (int i = 0; i < tailCount; i++)
            next[w++] = _starts[firstAfter + i] + delta;

        _starts = next;
    }

    // Smallest index whose start is strictly greater than offset (first start that survives an edit at `offset`).
    private int UpperBoundIndex(int offset)
    {
        int lo = 0, hi = _starts.Length; // [lo, hi)
        while (lo < hi)
        {
            int mid = (lo + hi) >> 1;
            if (_starts[mid] <= offset) lo = mid + 1; else hi = mid;
        }
        return lo;
    }

    /// <summary>Rebuilds the table from a whole-document string (bulk edits that shift everything).</summary>
    public void Rebuild(string text) => _starts = BuildLineStarts(text);

    /// <summary>Rebuilds the table by scanning the buffer (chunked, no whole-document string materialization).</summary>
    public void Rebuild(ITextBuffer buffer) => _starts = BuildLineStarts(buffer);

    /// <summary>
    /// Builds the line-start table for <paramref name="text"/> in a single O(n) pass over the UTF-16 code units.
    /// <c>starts[0] = 0</c>; a new entry is appended after every <c>\n</c> (0x0A). NOTE: offsets are UTF-16 char
    /// offsets, exactly as the NSString original, never scalars or bytes.
    /// </summary>
    public static int[] BuildLineStarts(string text)
    {
        int n = text.Length;
        int count = 1;
        for (int i = 0; i < n; i++)
            if (text[i] == '\n') count++;

        var starts = new int[count];
        starts[0] = 0;
        int k = 1;
        for (int i = 0; i < n; i++)
            if (text[i] == '\n') starts[k++] = i + 1;
        return starts;
    }

    /// <summary>
    /// Builds the line-start table by scanning an <see cref="ITextBuffer"/> in 1 MB windows so a 655 MB buffer is
    /// never materialized as one string. Two passes (count, then fill) over the buffer.
    /// </summary>
    public static int[] BuildLineStarts(ITextBuffer buffer)
    {
        int n = buffer.Length;
        const int Window = 1 << 20;

        int count = 1;
        for (int off = 0; off < n; off += Window)
        {
            string chunk = buffer.Substring(off, Math.Min(Window, n - off));
            for (int i = 0; i < chunk.Length; i++)
                if (chunk[i] == '\n') count++;
        }

        var starts = new int[count];
        starts[0] = 0;
        int k = 1;
        for (int off = 0; off < n; off += Window)
        {
            string chunk = buffer.Substring(off, Math.Min(Window, n - off));
            for (int i = 0; i < chunk.Length; i++)
                if (chunk[i] == '\n') starts[k++] = off + i + 1;
        }
        return starts;
    }
}
