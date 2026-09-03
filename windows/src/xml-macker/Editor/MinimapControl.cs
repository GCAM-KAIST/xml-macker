using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using XMLMacker.Theme;
using TextHighlights = XMLMacker.Core.TextHighlights;
using HighlightRange = XMLMacker.Core.HighlightRange;

namespace XMLMacker.Editor;

/// <summary>
/// The right-side minimap strip (port of Swift <c>MinimapView</c>). A thin column docked right of the
/// editor showing the whole file's SHAPE as sampled horizontal bars (one every 2 px, length-bucketed
/// width + syntax-tinted color), a moving viewport-overlay box, magnet-snap hover targets on the left
/// half, and click/drag scrubbing. Bars are SAMPLED proportionally, the 12.6 M-line file is never
/// enumerated.
///
/// <para>Hovering raises a floating <see cref="MinimapMagnifier"/> showing a ±12-line colored preview;
/// clicking a line inside the magnifier fires <see cref="LineClicked"/> (absolute 1-based line).</para>
/// </summary>
public sealed class MinimapControl : FrameworkElement
{
    private readonly struct Bar
    {
        public readonly double Y;
        public readonly double W;
        public readonly Brush Brush;
        public Bar(double y, double w, Brush brush) { Y = y; W = w; Brush = brush; }
    }

    private HugeTextEditor? _editor;
    private int[] _lineStarts = { 0 };

    private TextHighlights? _highlights;
    private static readonly Brush[] HighlightTicks =
    {
        Brushes.Transparent,
        FrozenBrush(Color.FromRgb(0xE5, 0x39, 0x35)), FrozenBrush(Color.FromRgb(0x3B, 0x82, 0xF6)),
        FrozenBrush(Color.FromRgb(0xE8, 0xB9, 0x10)), FrozenBrush(Color.FromRgb(0x22, 0xB5, 0x5E)),
    };

    /// <summary>The document's marker strokes, shown as short colour ticks at the right edge of the LINE lane.</summary>
    public TextHighlights? Highlights
    {
        get => _highlights;
        set
        {
            if (ReferenceEquals(_highlights, value)) return;
            if (_highlights is not null) _highlights.Changed -= OnHighlightsChanged;
            _highlights = value;
            if (_highlights is not null) _highlights.Changed += OnHighlightsChanged;
            InvalidateVisual();
        }
    }

    private void OnHighlightsChanged(object? sender, EventArgs e) => InvalidateVisual();
    private IReadOnlyList<int> _snapLines = Array.Empty<int>();
    private readonly List<Bar> _barCache = new(256);

    private double? _hoverY;
    private bool _dragging;

    private MinimapMagnifier? _magnifier;
    private int _magnifierFirstLine = 1;

    /// <summary>
    /// The hover-preview panel, created on first use and re-created if a previous one was destroyed.
    /// <para>WPF kills every owned window when its owner closes, so a magnifier owned by a popped-out
    /// pane window dies when that pane is docked back. Calling <c>Show()</c> on the corpse throws and
    /// used to take the whole application down. Two defences: the panel is always owned by the
    /// long-lived main window (see <see cref="UpdateHover"/>), and a retired one is replaced here.</para>
    /// </summary>
    private MinimapMagnifier Magnifier
    {
        get
        {
            if (_magnifier is null || _magnifier.IsClosed)
            {
                _magnifier = new MinimapMagnifier();
                _magnifier.LineClicked += line => LineClicked?.Invoke(line);
            }
            return _magnifier;
        }
    }

    // Cached theme resources.
    private Brush? _bg;
    private Pen? _borderPen;
    private Pen? _guidePen;
    private Brush? _snapBrush;
    private Brush? _hoverBrush;
    private Brush? _overlayFill;
    private Pen? _overlayStroke;
    private Brush? _barAttr, _barText2, _barTag, _barMint;
    private Brush? _parentLaneFill, _laneLabelFill, _laneLabelText;
    private bool _valid;

    /// <summary>Fired with the ABSOLUTE (1-based) line number when a line is clicked in the magnifier popup.</summary>
    public event Action<int>? LineClicked;

    /// <summary>Fired when the right-hand free-navigation lane is released on an exact source line.</summary>
    public event Action<int>? ExactLineClicked;

    public MinimapControl()
    {
        Width = XMMetric.MinimapW;
        SnapsToDevicePixels = true;
        UseLayoutRounding = true;
        ClipToBounds = true;
        Cursor = Cursors.Arrow;

        // The magnifier is created lazily by the Magnifier property, never eagerly here, so merely
        // constructing a minimap (or leaving one) can never build a Window.

        ThemeManager.ThemeChanged += (_, __) => { _valid = false; RebuildBars(); InvalidateVisual(); };
    }

    // ── Wiring ──────────────────────────────────────────────────────────────────────────────────

    /// <summary>Binds the minimap to the editor whose scroll/geometry it mirrors and samples.</summary>
    public void Attach(HugeTextEditor editor)
    {
        if (_editor is not null) _editor.ViewportChanged -= OnViewportChanged;
        _editor = editor;
        _editor.ViewportChanged += OnViewportChanged;
        _lineStarts = editor.CurrentLineStarts;
        RebuildBars();
        InvalidateVisual();
    }

    /// <summary>Re-reads the line table and re-samples the bars (after a load / bulk edit).</summary>
    public void RefreshAfterLoad()
    {
        if (_editor is not null) _lineStarts = _editor.CurrentLineStarts;
        RebuildBars();
        InvalidateVisual();
    }

    /// <summary>Sets the magnet-snap target lines (parent-level element start lines).</summary>
    public void SetSnapLines(IReadOnlyList<int> lines)
    {
        _snapLines = lines ?? Array.Empty<int>();
        InvalidateVisual();
    }

    /// <summary>Re-applies theme colors (background, border, bar tints) and redraws.</summary>
    public void RebuildColors()
    {
        _valid = false;
        RebuildBars();
        InvalidateVisual();
    }

    private void OnViewportChanged(object? sender, EventArgs e) => InvalidateVisual();

    protected override void OnRenderSizeChanged(SizeChangedInfo info)
    {
        base.OnRenderSizeChanged(info);
        RebuildBars();
        InvalidateVisual();
    }

    // ── Sampling ────────────────────────────────────────────────────────────────────────────────

    private void RebuildBars()
    {
        EnsureResources();
        _barCache.Clear();

        double h = ActualHeight, w = ActualWidth;
        if (h <= 0 || w <= 0) return;

        int count = _lineStarts.Length;
        if (count <= 0) return;

        int slots = Math.Max(1, (int)Math.Floor(h / 2.0));
        for (int slot = 0; slot < slots; slot++)
        {
            double y = slot * 2 + 0.5;
            double t = slots > 1 ? slot / (double)(slots - 1) : 0.0;
            int lineIdx = Math.Min(count - 1, (int)Math.Floor(t * (count - 1)));

            int lineLen = (lineIdx + 1 < count)
                ? _lineStarts[lineIdx + 1] - _lineStarts[lineIdx]
                : 40; // last line assumes +40

            double f = lineLen < 8 ? 0.12
                     : lineLen < 24 ? 0.28
                     : lineLen < 64 ? 0.48
                     : lineLen < 160 ? 0.72
                     : 0.92;

            double barW = (w - 8) * f;

            Brush brush = f < 0.25 ? _barAttr!
                        : f < 0.55 ? _barText2!
                        : f < 0.80 ? _barTag!
                        : _barMint!;

            _barCache.Add(new Bar(y, barW, brush));
        }
    }

    // ── Rendering ───────────────────────────────────────────────────────────────────────────────

    protected override void OnRender(DrawingContext dc)
    {
        EnsureResources();
        double w = ActualWidth, h = ActualHeight;
        if (w <= 0 || h <= 0) return;

        var cardGeo = new RectangleGeometry(new Rect(0, 0, w, h), XMMetric.RadiusCard, XMMetric.RadiusCard);
        dc.DrawGeometry(_bg, null, cardGeo);

        int count = _lineStarts.Length;

        dc.PushClip(cardGeo);
        try
        {
            // The left lane is a parent/current-element navigation surface; the right lane is
            // exact free-line navigation. A faint wash makes the split discoverable before hover.
            dc.DrawRectangle(_parentLaneFill, null, new Rect(0, 0, w / 2, h));

            // 1. Center vertical guide (lane boundary).
            dc.DrawLine(_guidePen, new Point(w / 2, 0), new Point(w / 2, h));

            // 2. Snap ticks (4×1 on the left edge).
            if (_snapLines.Count > 0 && count > 0)
            {
                foreach (int s in _snapLines)
                {
                    double y = (s - 1) / (double)count * h;
                    dc.DrawRectangle(_snapBrush, null, new Rect(0, y, 4, 1));
                }
            }

            // 3. Sampled bars (height 1.6).
            foreach (Bar b in _barCache)
                dc.DrawRectangle(b.Brush, null, new Rect(4, b.Y, b.W, 1.6));

            // 3b. Highlight marks: a colour tick at the right edge, so marked lines are easy to find.
            if (_highlights is { IsEmpty: false } && count > 0)
            {
                foreach (HighlightRange stroke in _highlights.All)
                {
                    double y = LineIndex.LineForOffset(_lineStarts, stroke.Start) / (double)count * h;
                    dc.DrawRectangle(HighlightTicks[(int)stroke.Color], null, new Rect(w - 6, y, 5, 2));
                }
            }

            // 4. Hover marker (full-width 1 px line).
            if (_hoverY is { } hy)
                dc.DrawRectangle(_hoverBrush, null, new Rect(0, hy, w, 1));

            // 5. Viewport overlay box.
            if (_editor is not null && count > 0)
            {
                double docHeight = _editor.Layout.ContentHeight(count);
                if (docHeight > 0)
                {
                    double scrollY = _editor.ScrollOffsetY;
                    double visH = _editor.ViewportHeight;
                    double top = scrollY / docHeight * h;
                    double overlayH = Math.Max(14, visH / docHeight * h);
                    var rect = new Rect(1, top, Math.Max(0, w - 2), overlayH);
                    dc.DrawRectangle(_overlayFill, null, rect);
                    var sr = new Rect(rect.X + 0.5, rect.Y + 0.5,
                        Math.Max(0, rect.Width - 1), Math.Max(0, rect.Height - 1));
                    dc.DrawRectangle(null, _overlayStroke, sr);
                }
            }

            // Permanent labels explain the two click behaviours without requiring a tooltip.
            if (h >= 30)
            {
                DrawLaneLabel(dc, "PARENT", new Rect(1, 1, Math.Max(0, w / 2 - 2), 13));
                DrawLaneLabel(dc, "LINE", new Rect(w / 2 + 1, 1, Math.Max(0, w / 2 - 2), 13));
            }
        }
        finally
        {
            dc.Pop();
        }

        // Border on top (crisp rounded edge).
        dc.DrawGeometry(null, _borderPen, cardGeo);
    }

    // ── Mouse: hover / scrub ──────────────────────────────────────────────────────────────────────

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (_editor is null) return;
        Point p = e.GetPosition(this);
        Cursor = IsParentLane(p) ? Cursors.Hand : Cursors.SizeNS;
        if (_dragging) { Scrub(p); return; }
        UpdateHover(p);
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        if (_editor is null) return;

        Point p = e.GetPosition(this);
        if (IsParentLane(p))
        {
            int line = ResolveLine(p, alwaysSnap: true);
            SetHoverLine(line);
            _magnifier?.HideDeferred();
            // Move the viewport ourselves as well. Without this the left lane was the only click
            // surface in the control that moved nothing by itself, so a click that resolved to an
            // already-visible element looked like it had simply been ignored.
            Scrub(p);
            LineClicked?.Invoke(line);
            e.Handled = true;
            return;
        }

        _dragging = true;
        CaptureMouse();
        _magnifier?.HideDeferred();
        Scrub(p);
        e.Handled = true;
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        if (_dragging)
        {
            Point p = e.GetPosition(this);
            Scrub(p);
            _dragging = false;
            ReleaseMouseCapture();
            ExactLineClicked?.Invoke(PositionalLine(p));
            e.Handled = true;
        }
    }

    protected override void OnMouseEnter(MouseEventArgs e)
    {
        base.OnMouseEnter(e);
        if (_editor is null) return;
        Point p = e.GetPosition(this);
        Cursor = IsParentLane(p) ? Cursors.Hand : Cursors.SizeNS;
        UpdateHover(p);
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        _hoverY = null;
        _magnifier?.HideDeferred();
        InvalidateVisual();
    }

    private void UpdateHover(Point p)
    {
        double h = ActualHeight;
        if (h <= 0 || _editor is null) return;

        int count = _lineStarts.Length;
        if (count <= 1) return;

        int line = ResolveLine(p, alwaysSnap: false);
        int lineIdx = line - 1;
        SetHoverLine(line);

        ITextBuffer? buf = _editor.Buffer;
        if (buf is null) { InvalidateVisual(); return; }
        int docLen = buf.Length;

        // ±12-line context, substring capped at 4096 chars.
        int firstLine = Math.Max(1, (lineIdx + 1) - 12);
        int lastLine = Math.Min(count, (lineIdx + 1) + 12);
        int startOff = _lineStarts[firstLine - 1];
        int endOff = (lastLine < count) ? _lineStarts[lastLine] - 1 : docLen;
        int len = Math.Max(0, Math.Min(endOff - startOff, 4096));
        string preview = buf.Substring(startOff, len);
        int highlightLocal = (lineIdx + 1) - firstLine;
        _magnifierFirstLine = firstLine;

        // Anchor at the minimap's left edge, hovered Y, in device-independent SCREEN coordinates.
        Point deviceAnchor = PointToScreen(new Point(0, p.Y));
        PresentationSource? src = PresentationSource.FromVisual(this);
        Point anchor = src?.CompositionTarget is not null
            ? src.CompositionTarget.TransformFromDevice.Transform(deviceAnchor)
            : deviceAnchor;

        // Own the panel to the MAIN window, never to a transient pane pop-out: closing a pop-out that
        // owned it would destroy it and the next hover would throw (see MinimapMagnifier.IsClosed).
        Magnifier.Attach(System.Windows.Application.Current?.MainWindow ?? Window.GetWindow(this));
        Magnifier.Show(preview, highlightLocal, lineIdx + 1, _magnifierFirstLine, anchor);

        InvalidateVisual();
    }

    private bool IsParentLane(Point p) => p.X < ActualWidth / 2;

    private int PositionalLine(Point p)
    {
        int count = Math.Max(1, _lineStarts.Length);
        if (ActualHeight <= 0) return 1;
        double t = Math.Clamp(p.Y / ActualHeight, 0, 1);
        return Math.Min(count, (int)Math.Floor(t * (count - 1)) + 1);
    }

    private int ResolveLine(Point p, bool alwaysSnap)
    {
        int target = PositionalLine(p);
        if (!IsParentLane(p) || _snapLines.Count == 0) return target;

        int best = target;
        int bestDistance = int.MaxValue;
        foreach (int candidate in _snapLines)
        {
            if (candidate < 1 || candidate > _lineStarts.Length) continue;
            int distance = Math.Abs(candidate - target);
            if (distance < bestDistance)
            {
                best = candidate;
                bestDistance = distance;
            }
        }

        if (bestDistance == int.MaxValue) return target;
        if (alwaysSnap) return best;

        double linesPerPixel = _lineStarts.Length / Math.Max(1, ActualHeight);
        int hoverWindow = (int)Math.Floor(18 * linesPerPixel);
        return bestDistance <= hoverWindow ? best : target;
    }

    private void SetHoverLine(int line)
    {
        int count = Math.Max(1, _lineStarts.Length);
        line = Math.Clamp(line, 1, count);
        _hoverY = count > 1 ? (line - 1) / (double)(count - 1) * ActualHeight : 0;
        InvalidateVisual();
    }

    private void Scrub(Point p)
    {
        if (_editor is null) return;
        int count = _lineStarts.Length;
        double docHeight = _editor.Layout.ContentHeight(count);
        double visH = _editor.ViewportHeight;
        double h = ActualHeight;
        if (h <= 0) return;

        double t = Math.Clamp(p.Y / h, 0, 1);
        double targetY = Math.Clamp(t * docHeight - visH / 2, 0, Math.Max(0, docHeight - visH));
        _editor.ScrollOffsetY = targetY;
    }

    private void DrawLaneLabel(DrawingContext dc, string text, Rect rect)
    {
        if (rect.Width <= 2 || rect.Height <= 2) return;
        dc.DrawRoundedRectangle(_laneLabelFill, null, rect, 3, 3);

        double pixelsPerDip;
        try { pixelsPerDip = VisualTreeHelper.GetDpi(this).PixelsPerDip; }
        catch { pixelsPerDip = 1; }
        var ft = new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface(XMFont.UiFamily, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal),
            6.5, _laneLabelText, pixelsPerDip);
        dc.DrawText(ft, new Point(rect.X + Math.Max(0, (rect.Width - ft.Width) / 2),
            rect.Y + Math.Max(0, (rect.Height - ft.Height) / 2)));
    }

    // ── Theme resources ───────────────────────────────────────────────────────────────────────────

    private void EnsureResources()
    {
        if (_valid) return;
        _bg = FrozenBrush(WithAlpha(XMColor.Color(XMColor.BgDeep), 0.92));

        var border = new Pen(FrozenBrush(XMColor.Color(XMColor.HairlineS)), 0.5);
        border.Freeze();
        _borderPen = border;

        var guide = new Pen(FrozenBrush(XMColor.Color(XMColor.HairlineS)), 0.5);
        guide.Freeze();
        _guidePen = guide;

        _snapBrush = FrozenBrush(WithAlpha(XMColor.Color(XMColor.Accent), 0.55));
        _hoverBrush = FrozenBrush(WithAlpha(XMColor.Color(XMColor.Accent), 0.85));
        _overlayFill = FrozenBrush(WithAlpha(XMColor.Color(XMColor.Accent), 0.14));

        var os = new Pen(FrozenBrush(WithAlpha(XMColor.Color(XMColor.Accent), 0.55)), 1.0);
        os.Freeze();
        _overlayStroke = os;

        _barAttr = FrozenBrush(WithAlpha(XMColor.Color(XMColor.SyntaxAttr), 0.55));
        _barText2 = FrozenBrush(XMColor.Color(XMColor.Text2));
        _barTag = FrozenBrush(WithAlpha(XMColor.Color(XMColor.SyntaxTag), 0.60));
        _barMint = FrozenBrush(WithAlpha(XMColor.Color(XMColor.SyntaxText), 0.65));
        _parentLaneFill = FrozenBrush(WithAlpha(XMColor.Color(XMColor.Accent), 0.055));
        _laneLabelFill = FrozenBrush(WithAlpha(XMColor.Color(XMColor.BgDeep), 0.88));
        _laneLabelText = FrozenBrush(XMColor.Color(XMColor.Text2));

        _valid = true;
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
