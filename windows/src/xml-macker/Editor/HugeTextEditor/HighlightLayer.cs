using System;
using System.Windows;
using System.Windows.Media;
using XMLMacker.Theme;

namespace XMLMacker.Editor;

/// <summary>
/// The rectangle-band highlight renderer (port of the Swift <c>HighlightingTextView.draw</c>). Highlights are drawn
/// as background rectangles behind the visible text, NEVER as document-wide text-run attributes (that approach
/// crashed on huge non-contiguous layout in AppKit and is slow in WPF). Only the bands overlapping the visible
/// lines are painted; geometry comes from <see cref="ViewportLayout"/> so bands align with the text and gutter.
///
/// <para>Two bands, drawn in order:</para>
/// <list type="number">
/// <item><b>Box wash</b>, the whole selected element (open-tag line → close-tag line): <c>lineHighlight</c> fill at
/// alpha 0.10 plus a 2 px left stripe in <c>accent</c> at alpha 0.55.</item>
/// <item><b>Landing line</b>, the single emphasized line: <c>lineHighlight</c> (full alpha) plus a 2 px left stripe
/// in <c>accent</c> (full alpha).</item>
/// </list>
/// Brushes/pens are cached and rebuilt on <see cref="ThemeManager.ThemeChanged"/>.
/// </summary>
public sealed class HighlightLayer
{
    private const double StripeWidth = 2.0;

    /// <summary>The single landing line to emphasize (doc offset range), or null.</summary>
    public (int Start, int Length)? LandingRange { get; set; }

    /// <summary>The whole-element box range (open-tag line start → close-tag line end), or null.</summary>
    public (int Start, int Length)? BoxRange { get; set; }

    private Brush? _boxWash;    // lineHighlight @ 0.10
    private Brush? _boxStripe;  // accent @ 0.55
    private Brush? _landFill;   // lineHighlight (full)
    private Brush? _landStripe; // accent (full)
    private bool _valid;

    public HighlightLayer()
    {
        ThemeManager.ThemeChanged += (_, __) => _valid = false;
    }

    /// <summary>Forces a brush rebuild (theme change hook, also invoked by the editor's RebuildColors).</summary>
    public void Rebuild() => _valid = false;

    private void EnsureBrushes()
    {
        if (_valid) return;
        Color line = XMColor.Color(XMColor.LineHighlight);
        Color accent = XMColor.Color(XMColor.Accent);

        _boxWash = FrozenBrush(WithAlpha(line, 0.10));
        _boxStripe = FrozenBrush(WithAlpha(accent, 0.55));
        _landFill = FrozenBrush(line);
        _landStripe = FrozenBrush(accent);
        _valid = true;
    }

    /// <summary>Clears both highlight ranges.</summary>
    public void Clear()
    {
        LandingRange = null;
        BoxRange = null;
    }

    /// <summary>
    /// Draws the highlight bands over the visible band. <paramref name="viewportWidth"/> is the text area width.
    /// </summary>
    public void Draw(DrawingContext dc, ViewportLayout layout, LineIndex index, int docLen,
                     double scrollY, double viewportWidth, double viewportHeight)
    {
        EnsureBrushes();
        int count = index.LineCount;
        if (count <= 0) return;

        double firstY = layout.YForLine(0, scrollY);

        // Box wash first (behind the landing line).
        if (BoxRange is { } box && box.Length > 0)
            DrawBand(dc, layout, index, docLen, scrollY, viewportWidth, viewportHeight, box, _boxWash!, _boxStripe!);

        // Landing line on top.
        if (LandingRange is { } land)
            DrawBand(dc, layout, index, docLen, scrollY, viewportWidth, viewportHeight, land, _landFill!, _landStripe!);
    }

    private static void DrawBand(DrawingContext dc, ViewportLayout layout, LineIndex index, int docLen,
                                 double scrollY, double viewportWidth, double viewportHeight,
                                 (int Start, int Length) range, Brush fill, Brush stripe)
    {
        int startLine = index.LineForOffset(range.Start) - 1;                       // 0-based
        int endOffset = range.Length > 0 ? range.Start + range.Length - 1 : range.Start;
        int endLine = index.LineForOffset(endOffset) - 1;                          // 0-based
        if (endLine < startLine) endLine = startLine;

        double top = layout.YForLine(startLine, scrollY);
        double bottom = layout.YForLine(endLine, scrollY) + layout.LineHeight;

        // Clip to the visible band.
        if (bottom <= 0 || top >= viewportHeight) return;
        double y = Math.Max(0, top);
        double h = Math.Min(viewportHeight, bottom) - y;
        if (h <= 0) return;

        dc.DrawRectangle(fill, null, new Rect(0, y, viewportWidth, h));
        dc.DrawRectangle(stripe, null, new Rect(0, y, StripeWidth, h));
    }

    private static Color WithAlpha(Color c, double alpha)
        => Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255), c.R, c.G, c.B);

    private static Brush FrozenBrush(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }
}
