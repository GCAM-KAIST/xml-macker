using System;
using System.Collections.Generic;

namespace XMLMacker.Editor;

/// <summary>
/// One visual line of the viewport: a 0-based logical line, its document offset span (newline excluded), and the
/// screen-space Y of its top. In v1 there is exactly one visual line per logical line (no soft wrap, long lines
/// scroll horizontally), so the mapping is O(1); the abstraction leaves room for future wrapping.
/// </summary>
public readonly struct VisualLine
{
    public readonly int LineIndex;   // 0-based logical line
    public readonly int StartOffset; // doc offset of the line start
    public readonly int Length;      // char count, excluding the trailing '\n'
    public readonly double Y;        // screen Y of the line top

    public VisualLine(int lineIndex, int startOffset, int length, double y)
    {
        LineIndex = lineIndex;
        StartOffset = startOffset;
        Length = length;
        Y = y;
    }
}

/// <summary>
/// Generates visual lines for the VISIBLE BAND ONLY and owns the pixel geometry so the gutter and highlight bands
/// line up with the text exactly. Line height and character advance come from the mono font's actual glyph metrics
/// (set by the editor via <see cref="SetMetrics"/>), different SF-Mono → Cascadia-Mono metrics never desync the
/// gutter from the text.
/// <para><b>No soft wrap in v1.</b> The macOS NSTextView sizes its text container to the viewport (which
/// wraps), and the ruler is multi-fragment aware; however, correct wrapped vertical geometry over 12.6 M lines
/// requires measuring every logical line's wrap count, which violates the non-negotiable "never iterate all lines
/// on the scroll path" rule. v1 therefore renders one visual line per logical line and scrolls long lines
/// horizontally, the option the task authorizes. Total document height is then <c>lineCount * lineHeight</c>,
/// giving O(1) scroll math.</para>
/// </summary>
public sealed class ViewportLayout
{
    /// <summary>Height of one line in device-independent pixels (from glyph metrics).</summary>
    public double LineHeight { get; private set; } = 16;

    /// <summary>Advance width of one monospace cell in DIPs (from glyph metrics).</summary>
    public double CharWidth { get; private set; } = 8;

    /// <summary>Baseline offset within a line (top → baseline), in DIPs.</summary>
    public double Baseline { get; private set; } = 12;

    /// <summary>Text container inset (matches the Swift <c>textContainerInset = 6×6</c>).</summary>
    public double TopInset { get; set; } = 6;

    /// <summary>Left text inset.</summary>
    public double LeftInset { get; set; } = 6;

    /// <summary>Updates the per-line/char metrics from the current mono glyph typeface.</summary>
    public void SetMetrics(double lineHeight, double charWidth, double baseline)
    {
        LineHeight = lineHeight > 0 ? lineHeight : 16;
        CharWidth = charWidth > 0 ? charWidth : 8;
        Baseline = baseline > 0 ? baseline : lineHeight * 0.8;
    }

    /// <summary>Full virtual document height for <paramref name="lineCount"/> lines (drives the vertical scrollbar).</summary>
    public double ContentHeight(int lineCount) => TopInset * 2 + Math.Max(0, lineCount) * LineHeight;

    /// <summary>0-based index of the first line whose row intersects the top of the viewport.</summary>
    public int FirstVisibleLine(double scrollY, int lineCount)
    {
        if (lineCount <= 0) return 0;
        int i = (int)Math.Floor((scrollY - TopInset) / LineHeight);
        return Math.Clamp(i, 0, lineCount - 1);
    }

    /// <summary>0-based index of the last line whose row intersects the bottom of the viewport.</summary>
    public int LastVisibleLine(double scrollY, double viewportHeight, int lineCount)
    {
        if (lineCount <= 0) return 0;
        int i = (int)Math.Floor((scrollY + viewportHeight - TopInset) / LineHeight);
        return Math.Clamp(i, 0, lineCount - 1);
    }

    /// <summary>Screen Y of the top of the 0-based <paramref name="lineIndex0"/>.</summary>
    public double YForLine(int lineIndex0, double scrollY) => TopInset + lineIndex0 * LineHeight - scrollY;

    /// <summary>0-based logical line at screen Y (may be out of range, caller clamps).</summary>
    public int LineForY(double screenY, double scrollY) => (int)Math.Floor((screenY + scrollY - TopInset) / LineHeight);

    /// <summary>
    /// Materializes the visible visual lines for the band <c>[scrollY, scrollY+viewportHeight)</c> using the
    /// line-offset table. Only the visible rows are produced; text is fetched per-line by the caller (bounded to the
    /// visible columns) so a minified single-line document never copies the whole file.
    /// </summary>
    public List<VisualLine> GenerateVisibleLines(LineIndex index, int docLen, double scrollY, double viewportHeight)
    {
        var list = new List<VisualLine>();
        int count = index.LineCount;
        if (count <= 0) return list;

        int first = FirstVisibleLine(scrollY, count);
        int last = LastVisibleLine(scrollY, viewportHeight, count);
        for (int i = first; i <= last; i++)
        {
            int start = index.OffsetForLineIndex(i);
            int end = (i + 1 < count) ? index.OffsetForLineIndex(i + 1) - 1 : docLen; // exclude the '\n'
            if (end < start) end = start;
            list.Add(new VisualLine(i, start, end - start, TopInset + i * LineHeight - scrollY));
        }
        return list;
    }
}
