using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using XMLMacker.Shared;
using XMLMacker.Theme;

namespace XMLMacker.Charts;

/// <summary>
/// Custom-drawn sparkline / bar chart control, 1:1 port of the Swift <c>TrendView</c>.
/// Everything is drawn in <see cref="OnRender"/> (no child controls): line + area, bars, axes,
/// min/max labels, hover crosshair + ring + tooltip, and the "Open ↗" pop-out pill.
/// The Swift original draws in AppKit's <b>bottom-left</b> coordinate system (y grows up); WPF is
/// <b>top-left</b> (y grows down). Every y computation here is expressed directly in WPF coordinates,
/// flipping the AppKit math (<c>y_wpf = height - y_appkit</c>).
/// </summary>
public sealed class TrendView : FrameworkElement
{
    // ── Layout constants ───────────────────────────────────────
    private const double InsetLeft = 10;
    // NOT a constant: the bottom band must grow with the text it has to hold. The pop-out renders at
    // _fontScale 1.5, where a 15-point label line box is about 20 pixels tall, taller than the old flat
    // 14, so the year labels ran past the axis and sat on the area fill.
    private double InsetBottom => 16 * _fontScale;
    private const double RightGutter = 12;          // was 40: the value labels moved to the left axis

    // Width reserved for the left y-axis: measured from the tick labels every paint (font-scaled).
    private double _leftGutter = 44;
    private const int YTicks = 5;
    private const double TopReserve = 28;
    private const double CornerRadius = 8;

    private TrendSeries? _series;
    private bool _showLabels;
    private double _fontScale = 1;
    private bool _isRenderingForExport;
    private string _placeholderText = "No trend";

    private int? _hoverIndex;
    private Rect _popoutButtonRect = Rect.Empty;
    private Rect _buildButtonRect = Rect.Empty;

    public TrendView()
    {
        ThemeManager.ThemeChanged += OnThemeChanged;
        MetricsScaleService.Instance.RebuildFonts += OnThemeChanged;
        Unloaded += (_, _) =>
        {
            ThemeManager.ThemeChanged -= OnThemeChanged;
            MetricsScaleService.Instance.RebuildFonts -= OnThemeChanged;
        };
    }

    private void OnThemeChanged(object? sender, EventArgs e) => InvalidateVisual();

    // ── Public / observable properties ───────────────────────────────

    /// <summary>The series to plot. Setting it clears the hover state and requests a redraw.</summary>
    public TrendSeries? Series
    {
        get => _series;
        set { _series = value; _hoverIndex = null; InvalidateVisual(); }
    }

    /// <summary>Whether each value's number is drawn above its point/bar. Off inline, on in the pop-out.</summary>
    public bool ShowLabels
    {
        get => _showLabels;
        set { _showLabels = value; InvalidateVisual(); }
    }

    /// <summary>Multiplier applied to all text sizes (on top of <see cref="XMFont.GlobalScale"/>). Pop-out sets 1.5.</summary>
    public double FontScale
    {
        get => _fontScale;
        set { _fontScale = value; InvalidateVisual(); }
    }

    /// <summary>
    /// When true the background is drawn fully opaque (for bitmap capture so exported images aren't
    /// gray); when false it is translucent (0.35 alpha). Redraw is implied by callers.
    /// </summary>
    public bool IsRenderingForExport
    {
        get => _isRenderingForExport;
        set => _isRenderingForExport = value;
    }

    /// <summary>Text shown centered when <see cref="Series"/> is <c>null</c>.</summary>
    public string PlaceholderText
    {
        get => _placeholderText;
        set { _placeholderText = value; InvalidateVisual(); }
    }

    /// <summary>Fired when the "Open ↗" pill is clicked. When non-null the pill is drawn; when null it is hidden.</summary>
    public event Action? PopoutRequested;
    public event Action? BuildRequested;

    // ════════════════════════════════════════════════════════════════════════════════════
    //  Rendering
    // ════════════════════════════════════════════════════════════════════════════════════

    protected override void OnRender(DrawingContext dc)
    {
        RenderChart(dc, ActualWidth, ActualHeight, VisualTreeHelper.GetDpi(this).PixelsPerDip);
    }

    /// <summary>Repaint whenever layout hands this element a new size (maximize, restore, drag-resize).</summary>
    protected override void OnRenderSizeChanged(SizeChangedInfo info)
    {
        base.OnRenderSizeChanged(info);
        InvalidateVisual();
    }

    /// <summary>
    /// Renders the chart with the given opaque-background flag into a <see cref="RenderTargetBitmap"/>,
    /// used by the pop-out Copy/Save commands. Toggles the export flag around the draw.
    /// </summary>
    public RenderTargetBitmap RenderToBitmap()
    {
        double w = ActualWidth, h = ActualHeight;
        double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
        if (scale <= 0) scale = 1;

        bool prev = _isRenderingForExport;
        _isRenderingForExport = true;

        var dv = new DrawingVisual();
        using (var g = dv.RenderOpen())
            RenderChart(g, w, h, dpi);

        _isRenderingForExport = prev;

        int pw = Math.Max(1, (int)Math.Ceiling(w * scale));
        int ph = Math.Max(1, (int)Math.Ceiling(h * scale));
        var rtb = new RenderTargetBitmap(pw, ph, 96 * scale, 96 * scale, PixelFormats.Pbgra32);
        rtb.Render(dv);
        return rtb;
    }

    private void RenderChart(DrawingContext dc, double w, double h, double pixelsPerDip)
    {
        // 1. Background (rounded rect corner 8, opaque for export else 0.35).
        double bgAlpha = _isRenderingForExport ? 1.0 : 0.35;
        var bgRect = new Rect(0.25, 0.25, Math.Max(0, w - 0.5), Math.Max(0, h - 0.5));
        dc.DrawRoundedRectangle(BrushA(XMColor.BgDeep, bgAlpha),
            new Pen(BrushA(XMColor.Hairline, 1.0), XMMetric.Hairline), bgRect, CornerRadius, CornerRadius);

        DrawHeaderPills(dc, w, pixelsPerDip);

        if (_series is null)
        {
            DrawPlaceholder(dc, w, h, pixelsPerDip);
            return;
        }

        TrendSeries s = _series;

        // 3. Title (top-left, uppercased, truncating tail).
        {
            var ft = new FormattedText(s.Title.ToUpperInvariant(), Inv, FlowDirection.LeftToRight,
                new Typeface(XMFont.UiFamily, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal),
                Sz(11), BrushA(XMColor.Text, 1.0), pixelsPerDip)
            {
                MaxLineCount = 1,
                Trimming = TextTrimming.CharacterEllipsis,
                MaxTextWidth = Math.Max(80, w - (BuildRequested is not null ? 165 : 90))
            };
            dc.DrawText(ft, new Point(InsetLeft, 2 * _fontScale));
        }

        // 4. "Open ↗" pill (only when a handler is attached). Fixed 11pt bold white.
        if (PopoutRequested is not null)
        {
            var pillFt = new FormattedText("Open ↗", Inv, FlowDirection.LeftToRight,
                new Typeface(XMFont.UiFamily, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal),
                11, Brushes.White, pixelsPerDip);
            double tw = pillFt.WidthIncludingTrailingWhitespace;
            double th = pillFt.Height;
            var rect = new Rect(w - tw - 26, 4, tw + 20, th + 6);
            _popoutButtonRect = rect;
            double r = rect.Height / 2;
            dc.DrawRoundedRectangle(BrushA(XMColor.Accent, 0.95),
                new Pen(BrushA(XMColor.Accent, 1.0), XMMetric.Hairline), rect, r, r);
            dc.DrawText(pillFt, new Point(rect.Left + 10, rect.Top + (rect.Height - th) / 2));
        }
        else
        {
            _popoutButtonRect = Rect.Empty;
        }

        // 5. Y-axis ticks first: the plot's left edge depends on how wide the tick labels are.
        (double visMin, double visMax) = AutoScaleRange(s);
        var yFace = new Typeface(XMFont.MonoFamily, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
        double ySize = Sz(9.5);
        var tickText = new FormattedText[YTicks];
        double widest = 0;
        for (int i = 0; i < YTicks; i++)
        {
            double v = visMin + (visMax - visMin) * i / (YTicks - 1);
            tickText[i] = new FormattedText(NumberFmt.FormatNumber(v), Inv, FlowDirection.LeftToRight,
                yFace, ySize, BrushA(XMColor.Text2, 1.0), pixelsPerDip);
            widest = Math.Max(widest, tickText[i].WidthIncludingTrailingWhitespace);
        }
        _leftGutter = Math.Ceiling(widest + 14 * _fontScale);

        Plot p = GetPlot(w, h);
        if (p.Width <= 10 || p.Height <= 10 || s.Values.Count < 2) return;

        // 6. Axes, gridlines at every tick, tick marks and value labels down the LEFT.
        var axisPen = new Pen(BrushA(XMColor.Text3, 0.45), 1);
        dc.DrawLine(axisPen, new Point(p.Left, p.Top), new Point(p.Left, p.Bottom));
        dc.DrawLine(axisPen, new Point(p.Left, p.Bottom), new Point(p.Right, p.Bottom));

        var gridPen = new Pen(BrushA(XMColor.Text3, 0.15), 1);
        // Line charts keep a 4-px breathing space inside the plot; bars use the full height.
        double axisBottom = s.Kind == TrendKind.Line ? p.Bottom - 4 : p.Bottom;
        double axisHeight = s.Kind == TrendKind.Line ? p.Height - 8 : p.Height;
        for (int i = 0; i < YTicks; i++)
        {
            double y = axisBottom - axisHeight * i / (YTicks - 1);
            if (i > 0) dc.DrawLine(gridPen, new Point(p.Left, y), new Point(p.Right, y));
            dc.DrawLine(axisPen, new Point(p.Left - 4, y), new Point(p.Left, y));
            FormattedText ft = tickText[i];
            double ty = Math.Clamp(y - ft.Height / 2, 0, Math.Max(0, h - ft.Height));
            dc.DrawText(ft, new Point(p.Left - 7 - ft.WidthIncludingTrailingWhitespace, ty));
        }

        // 7. Dispatch.
        if (s.Kind == TrendKind.Line) DrawLine(dc, s, p, h, pixelsPerDip);
        else DrawBars(dc, s, p, h, pixelsPerDip);

        // 8. (The old right-gutter min/max labels are gone: the left axis carries the values.)

        // 9. Hover overlay.
        if (_hoverIndex is int hi && hi < s.Values.Count)
            DrawHover(dc, s, p, hi, pixelsPerDip);
    }

    private void DrawHeaderPills(DrawingContext dc, double width, double pixelsPerDip)
    {
        _popoutButtonRect = Rect.Empty;
        _buildButtonRect = Rect.Empty;
        if (BuildRequested is null) return;

        double rightEdge = width - 6;
        if (PopoutRequested is not null && _series is not null)
        {
            var open = new FormattedText("Open ↗", Inv, FlowDirection.LeftToRight,
                new Typeface(XMFont.UiFamily, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal),
                11, Brushes.White, pixelsPerDip);
            rightEdge -= open.WidthIncludingTrailingWhitespace + 28;
        }

        var text = new FormattedText("Build", Inv, FlowDirection.LeftToRight,
            new Typeface(XMFont.UiFamily, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal),
            11, BrushA(XMColor.Accent, 1), pixelsPerDip);
        var rect = new Rect(rightEdge - text.WidthIncludingTrailingWhitespace - 20, 4,
            text.WidthIncludingTrailingWhitespace + 20, text.Height + 6);
        _buildButtonRect = rect;
        double radius = rect.Height / 2;
        dc.DrawRoundedRectangle(BrushA(XMColor.Accent, 0.10),
            new Pen(BrushA(XMColor.Accent, 0.65), XMMetric.Hairline), rect, radius, radius);
        dc.DrawText(text, new Point(rect.Left + 10, rect.Top + (rect.Height - text.Height) / 2));
    }

    private void DrawLine(DrawingContext dc, TrendSeries s, Plot p, double h, double pixelsPerDip)
    {
        int count = s.Values.Count;
        (double visMin, double visMax) = AutoScaleRange(s);
        double span = Math.Max(visMax - visMin, 1e-12);
        double innerTop = p.Top + 4, innerBottom = p.Bottom - 4;
        double innerHeight = p.Height - 8;

        double YFor(double v)
        {
            double c = Math.Clamp(v, visMin, visMax);
            double t = (c - visMin) / span;
            return innerBottom - t * innerHeight;
        }
        double XFor(int i) => LineX(s, p, i);

        // Area under curve → clip + vertical gradient (accent 0.32 top → 0.02 baseline).
        var area = new StreamGeometry();
        using (var ctx = area.Open())
        {
            ctx.BeginFigure(new Point(XFor(0), p.Bottom), true, true);
            for (int i = 0; i < count; i++)
                ctx.LineTo(new Point(XFor(i), YFor(s.Values[i])), true, false);
            ctx.LineTo(new Point(XFor(count - 1), p.Bottom), true, false);
        }
        area.Freeze();
        var areaBrush = new LinearGradientBrush
        {
            StartPoint = new Point(0, p.Top),
            EndPoint = new Point(0, p.Bottom),
            MappingMode = BrushMappingMode.Absolute
        };
        areaBrush.GradientStops.Add(new GradientStop(ColA(XMColor.Accent, 0.32), 0));
        areaBrush.GradientStops.Add(new GradientStop(ColA(XMColor.Accent, 0.02), 1));
        dc.DrawGeometry(areaBrush, null, area);

        // Line (accent, width 2, round join/cap).
        var line = new StreamGeometry();
        using (var ctx = line.Open())
        {
            ctx.BeginFigure(new Point(XFor(0), YFor(s.Values[0])), false, false);
            for (int i = 1; i < count; i++)
                ctx.LineTo(new Point(XFor(i), YFor(s.Values[i])), true, false);
        }
        line.Freeze();
        var linePen = new Pen(BrushA(XMColor.Accent, 1.0), 2)
        {
            LineJoin = PenLineJoin.Round,
            StartLineCap = PenLineCap.Round,
            EndLineCap = PenLineCap.Round
        };
        dc.DrawGeometry(null, linePen, line);

        // Dots + optional value labels.
        var dotBrush = BrushA(XMColor.Accent, 1.0);
        var labelFace = new Typeface(XMFont.MonoFamily, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
        for (int i = 0; i < count; i++)
        {
            double x = XFor(i), y = YFor(s.Values[i]);
            dc.DrawEllipse(dotBrush, null, new Point(x, y), 2, 2);
            if (_showLabels)
            {
                var ft = new FormattedText(NumberFmt.FormatNumber(s.Values[i]), Inv, FlowDirection.LeftToRight,
                    labelFace, Sz(11), BrushA(XMColor.Text, 1.0), pixelsPerDip);
                dc.DrawText(ft, new Point(x - ft.WidthIncludingTrailingWhitespace / 2, y - 6 - ft.Height));
            }
        }

        // X labels (bottom): widest-fit stride.
        var xFace = new Typeface(XMFont.UiFamily, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
        double xSize = Sz(10);
        double widest = 0;
        var widths = new double[count];
        for (int i = 0; i < count; i++)
        {
            var ft = new FormattedText(s.XLabels[i], Inv, FlowDirection.LeftToRight, xFace, xSize,
                BrushA(XMColor.Text2, 1.0), pixelsPerDip);
            widths[i] = ft.WidthIncludingTrailingWhitespace;
            if (widths[i] > widest) widest = widths[i];
        }
        // Place the labels by MEASURED pixel position, left to right, never letting one start before the
        // previous one has ended. The old rule picked labels by a fixed stride and then force-appended the
        // final year with no collision test, so on the GCAM axis "2095" and "2100" were drawn on top of
        // each other and read as "20951 00". Because every test here is against a real measured position,
        // it is also correct for the irregular GCAM year spacing, and widening the window automatically
        // reveals MORE years instead of keeping the same stride.
        FormattedText Make(int i) => new(s.XLabels[i], Inv, FlowDirection.LeftToRight, xFace, xSize,
            BrushA(XMColor.Text2, 1.0), pixelsPerDip);

        double gap = 6 * _fontScale;

        // Reserve the LAST label first, right-anchored inside the plot; nothing may reach its barrier.
        FormattedText lastFt = Make(count - 1);
        double lastW = lastFt.WidthIncludingTrailingWhitespace;
        double labelY = h - 1 - lastFt.Height;
        double lastLeft = Math.Clamp(XFor(count - 1) - lastW / 2, 2, Math.Max(2, p.Right - lastW));
        double barrier = lastLeft - gap;

        // The FIRST label is always drawn when it clears that barrier.
        double cursor = 0;
        if (count > 1)
        {
            double firstLeft = Math.Max(2, XFor(0) - widths[0] / 2);
            if (firstLeft + widths[0] <= barrier)
            {
                dc.DrawText(Make(0), new Point(firstLeft, labelY));
                cursor = firstLeft + widths[0] + gap;
            }
        }

        // Middle labels: emitted only when clear of the previous one AND of the reserved final one.
        for (int i = 1; i < count - 1; i++)
        {
            double wI = widths[i];
            double left = Math.Max(2, XFor(i) - wI / 2);
            if (left < cursor) continue;
            if (left + wI > barrier) continue;
            dc.DrawText(Make(i), new Point(left, labelY));
            cursor = left + wI + gap;
        }

        dc.DrawText(lastFt, new Point(lastLeft, labelY));
    }

    private void DrawBars(DrawingContext dc, TrendSeries s, Plot p, double h, double pixelsPerDip)
    {
        int count = s.Values.Count;
        var fill = XMColor.Color(XMColor.SyntaxText);
        (double visMin, double visMax) = AutoScaleRange(s);
        double span = Math.Max(visMax - visMin, 1e-12);
        double slot = p.Width / count;
        double barW = Math.Max(4, Math.Min(slot * 0.70, 40));

        double TFor(double v) => (Math.Clamp(v, visMin, visMax) - visMin) / span;

        var strokePen = new Pen(new SolidColorBrush(WithA(fill, 0.90)), XMMetric.Hairline);
        var labelFace = new Typeface(XMFont.MonoFamily, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);

        for (int i = 0; i < count; i++)
        {
            double cx = p.Left + slot * i + slot / 2;
            double hBar = Math.Max(2, TFor(s.Values[i]) * p.Height);
            double barTop = p.Bottom - hBar;
            var rect = new Rect(cx - barW / 2, barTop, barW, hBar);
            double rTop = Math.Min(4, barW / 3);
            rTop = Math.Max(0, Math.Min(rTop, Math.Min(barW / 2, hBar / 2)));

            var geo = new StreamGeometry();
            using (var ctx = geo.Open())
            {
                ctx.BeginFigure(new Point(rect.Left, rect.Bottom), true, true);
                ctx.LineTo(new Point(rect.Left, rect.Top + rTop), true, false);
                if (rTop > 0)
                    ctx.ArcTo(new Point(rect.Left + rTop, rect.Top), new Size(rTop, rTop), 0, false,
                        SweepDirection.Clockwise, true, false);
                ctx.LineTo(new Point(rect.Right - rTop, rect.Top), true, false);
                if (rTop > 0)
                    ctx.ArcTo(new Point(rect.Right, rect.Top + rTop), new Size(rTop, rTop), 0, false,
                        SweepDirection.Clockwise, true, false);
                ctx.LineTo(new Point(rect.Right, rect.Bottom), true, false);
            }
            geo.Freeze();

            var grad = new LinearGradientBrush
            {
                StartPoint = new Point(0, rect.Top),
                EndPoint = new Point(0, rect.Bottom),
                MappingMode = BrushMappingMode.Absolute
            };
            grad.GradientStops.Add(new GradientStop(WithA(fill, 0.90), 0));
            grad.GradientStops.Add(new GradientStop(WithA(fill, 0.35), 1));
            dc.DrawGeometry(grad, strokePen, geo);

            if (_showLabels)
            {
                var ft = new FormattedText(NumberFmt.FormatNumber(s.Values[i]), Inv, FlowDirection.LeftToRight,
                    labelFace, Sz(11), BrushA(XMColor.Text, 1.0), pixelsPerDip);
                double lx = cx - ft.WidthIncludingTrailingWhitespace / 2;
                double aboveTop = barTop - 2 - ft.Height;
                double ly = aboveTop >= p.Top ? aboveTop : barTop + 2;
                ly = Math.Min(ly, p.Bottom - 2 - ft.Height);
                dc.DrawText(ft, new Point(lx, ly));
            }
        }

        // X labels (category, middle-truncated, centered per slot).
        var xFace = new Typeface(XMFont.UiFamily, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
        double xSize = Sz(10);
        for (int i = 0; i < count; i++)
        {
            double cx = p.Left + slot * i + slot / 2;
            double boxW = Math.Max(20, slot - 4);
            string label = MiddleTruncate(s.XLabels[i], xFace, xSize, boxW, pixelsPerDip);
            var ft = new FormattedText(label, Inv, FlowDirection.LeftToRight, xFace, xSize,
                BrushA(XMColor.Text2, 1.0), pixelsPerDip)
            {
                MaxLineCount = 1,
                MaxTextWidth = boxW,
                TextAlignment = TextAlignment.Center
            };
            dc.DrawText(ft, new Point(cx - boxW / 2, h - 1 - ft.Height));
        }
    }

    private void DrawHover(DrawingContext dc, TrendSeries s, Plot p, int i, double pixelsPerDip)
    {
        int count = s.Values.Count;
        double v = s.Values[i];
        (double visMin, double visMax) = AutoScaleRange(s);
        double span = Math.Max(visMax - visMin, 1e-12);

        double pointX, pointY;
        if (s.Kind == TrendKind.Line)
        {
            // Use the SAME value-based helper the plotted points use. Even index spacing put the
            // crosshair, ring and tooltip up to 50-odd pixels away from the dot they described on the
            // irregular GCAM year axis.
            double innerBottom = p.Bottom - 4;
            double innerHeight = p.Height - 8;
            pointX = LineX(s, p, i);
            pointY = innerBottom - ((Math.Clamp(v, visMin, visMax) - visMin) / span) * innerHeight;
        }
        else
        {
            double slot = p.Width / count;
            pointX = p.Left + slot * i + slot / 2;
            pointY = p.Bottom - ((Math.Clamp(v, visMin, visMax) - visMin) / span) * p.Height;
        }

        // Crosshair (vertical dashed).
        var crossPen = new Pen(BrushA(XMColor.Accent, 0.55), 0.8)
        {
            DashStyle = new DashStyle(new double[] { 2 / 0.8, 3 / 0.8 }, 0)
        };
        dc.DrawLine(crossPen, new Point(pointX, p.Bottom), new Point(pointX, p.Top));

        // Point ring + dot.
        dc.DrawEllipse(null, new Pen(BrushA(XMColor.Accent, 1.0), 1.5), new Point(pointX, pointY), 5, 5);
        dc.DrawEllipse(BrushA(XMColor.Accent, 1.0), null, new Point(pointX, pointY), 2, 2);

        // Tooltip pill.
        string text = $"{s.XLabels[i]}: {NumberFmt.FormatNumber(v)}";
        var face = new Typeface(XMFont.MonoFamily, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
        var ft = new FormattedText(text, Inv, FlowDirection.LeftToRight, face, Sz(10),
            BrushA(XMColor.Text, 1.0), pixelsPerDip);
        double tw = ft.WidthIncludingTrailingWhitespace, th = ft.Height;
        double pillW = tw + 12, pillH = th + 6;
        double left = pointX - tw / 2 - 6;
        double top = pointY - 8 - pillH;      // default above the point
        if (top < 2) top = pointY + 8;         // flip below if it would overflow the top
        left = Math.Clamp(left, 2, Math.Max(2, ActualWidth - pillW - 2));
        var pill = new Rect(left, top, pillW, pillH);
        dc.DrawRoundedRectangle(BrushA(XMColor.Bg, 0.92),
            new Pen(BrushA(XMColor.Accent, 0.6), XMMetric.Hairline), pill, 5, 5);
        dc.DrawText(ft, new Point(pill.Left + 6, pill.Top + 3));
    }

    private void DrawPlaceholder(DrawingContext dc, double w, double h, double pixelsPerDip)
    {
        var ft = new FormattedText(_placeholderText, Inv, FlowDirection.LeftToRight,
            new Typeface(XMFont.UiFamily, FontStyles.Normal, FontWeights.Medium, FontStretches.Normal),
            Sz(10), BrushA(XMColor.Text3, 1.0), pixelsPerDip);
        dc.DrawText(ft, new Point((w - ft.WidthIncludingTrailingWhitespace) / 2, (h - ft.Height) / 2));
    }

    /// <summary>
    /// Computes the visual y-range so nearly-flat data still shows variation.
    /// <c>preferZeroBaseline</c> is always <c>false</c> in the current code.
    /// </summary>
    private static (double, double) AutoScaleRange(TrendSeries s)
    {
        double mn = s.Min, mx = s.Max;
        double range = mx - mn;
        double magnitude = Math.Max(Math.Abs(mx), Math.Abs(mn));
        if (magnitude > 0 && range < magnitude * 0.01)
        {
            double mean = (mx + mn) / 2;
            double pad = Math.Max(magnitude * 0.05, range * 4);
            return (mean - pad, mean + pad);
        }
        if (range == 0) return (mn - 0.5, mx + 0.5);
        return (mn, mx);
    }

    private static double LineX(TrendSeries series, Plot plot, int index)
    {
        if (series.XPositions is { } positions && positions.Count == series.Values.Count &&
            positions.Count > 1 && double.IsFinite(positions[0]) &&
            double.IsFinite(positions[^1]) && positions[^1] > positions[0])
        {
            double value = positions[index];
            if (double.IsFinite(value))
                return plot.Left + (value - positions[0]) / (positions[^1] - positions[0]) * plot.Width;
        }
        return plot.Left + index * plot.Width / Math.Max(1, series.Values.Count - 1);
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  Mouse interaction
    // ════════════════════════════════════════════════════════════════════════════════════

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        Point pt = e.GetPosition(this);
        if (!_popoutButtonRect.IsEmpty && _popoutButtonRect.Contains(pt))
            PopoutRequested?.Invoke();
        else if (!_buildButtonRect.IsEmpty && _buildButtonRect.Contains(pt))
            BuildRequested?.Invoke();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (_series is null) return;
        TrendSeries s = _series;
        int count = s.Values.Count;

        Plot p = GetPlot(ActualWidth, ActualHeight);
        Point pt = e.GetPosition(this);
        var plotRect = new Rect(p.Left, p.Top, p.Width, p.Height);
        if (count < 2 || !plotRect.Contains(pt))
        {
            if (_hoverIndex is not null) { _hoverIndex = null; InvalidateVisual(); }
            return;
        }

        int idx;
        if (s.Kind == TrendKind.Line)
        {
            idx = Enumerable.Range(0, count)
                .MinBy(index => Math.Abs(LineX(s, p, index) - pt.X));
        }
        else
        {
            double slot = p.Width / count;
            idx = (int)Math.Floor((pt.X - p.Left) / slot);
        }
        idx = Math.Clamp(idx, 0, count - 1);

        if (_hoverIndex != idx) { _hoverIndex = idx; InvalidateVisual(); }
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        if (_hoverIndex is not null) { _hoverIndex = null; InvalidateVisual(); }
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  Helpers
    // ════════════════════════════════════════════════════════════════════════════════════

    private readonly struct Plot
    {
        public double Left { get; init; }
        public double Right { get; init; }
        public double Top { get; init; }
        public double Bottom { get; init; }
        public double Width => Right - Left;
        public double Height => Bottom - Top;
    }

    private Plot GetPlot(double w, double h) => new()
    {
        Left = _leftGutter,
        Right = w - RightGutter,
        Top = TopReserve,
        Bottom = h - InsetBottom
    };

    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    /// <summary>Scaled font size: <c>XMFont.Scaled(base * fontScale)</c>, global zoom then this view's own scale.</summary>
    private double Sz(double baseSize) => XMFont.Scaled(baseSize * _fontScale);

    private static Color WithA(Color c, double alpha)
        => Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255), c.R, c.G, c.B);

    private static Color ColA(string key, double alpha) => WithA(XMColor.Color(key), alpha);

    private static SolidColorBrush BrushA(string key, double alpha) => new(ColA(key, alpha));

    private string MiddleTruncate(string text, Typeface face, double size, double maxWidth, double pixelsPerDip)
    {
        double Measure(string t) => new FormattedText(t, Inv, FlowDirection.LeftToRight, face, size,
            Brushes.Black, pixelsPerDip).WidthIncludingTrailingWhitespace;

        if (Measure(text) <= maxWidth || text.Length <= 1) return text;

        const string ell = "…";
        int left = text.Length;
        while (left > 1)
        {
            left--;
            int head = (int)Math.Ceiling(left / 2.0);
            int tail = left - head;
            string candidate = text.Substring(0, head) + ell + text.Substring(text.Length - tail);
            if (Measure(candidate) <= maxWidth) return candidate;
        }
        return ell;
    }
}
