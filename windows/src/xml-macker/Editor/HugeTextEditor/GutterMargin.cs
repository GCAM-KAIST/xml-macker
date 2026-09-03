using System;
using System.Globalization;
using System.Windows;
using System.Windows.Media;
using XMLMacker.Theme;

namespace XMLMacker.Editor;

/// <summary>
/// The line-number gutter (port of Swift <c>LineNumberRulerView</c>). Draws the right-aligned 1-based line number
/// for the VISIBLE visual lines only, cost scales with the viewport, never the 12.6 M-line file. Width auto-sizes
/// from the digit count via <see cref="RecomputeThickness"/>; a 0.5 px hairline separates it from the text.
///
/// <para>Geometry (line height, top inset, per-line Y) comes from the same <see cref="ViewportLayout"/> the text
/// uses, so digits sit exactly on their lines. The owning editor pushes <see cref="ScrollY"/> and invalidates on
/// every scroll/resize.</para>
/// </summary>
public sealed class GutterMargin : FrameworkElement
{
    private const double PaddingLeft = 4;
    private const double PaddingRight = 6;

    private LineIndex? _index;
    private ViewportLayout? _layout;
    private double _scrollY;
    private double _digitSize = 10;

    private Brush? _bg;
    private Brush? _digit;
    private Pen? _divider;
    private Typeface? _typeface;
    private bool _valid;

    public GutterMargin()
    {
        Width = 44;
        IsHitTestVisible = false;
        SnapsToDevicePixels = true;
        UseLayoutRounding = true;
        ThemeManager.ThemeChanged += (_, __) => { _valid = false; InvalidateVisual(); };
    }

    /// <summary>Wires the gutter to the editor's line index and viewport geometry.</summary>
    public void Configure(LineIndex index, ViewportLayout layout)
    {
        _index = index;
        _layout = layout;
        InvalidateVisual();
    }

    /// <summary>Vertical scroll offset (pushed by the editor); triggers a redraw.</summary>
    public double ScrollY
    {
        get => _scrollY;
        set { if (_scrollY != value) { _scrollY = value; InvalidateVisual(); } }
    }

    /// <summary>Rebuilds cached colors/fonts (theme or zoom change).</summary>
    public void RebuildColors()
    {
        _valid = false;
        InvalidateVisual();
    }

    /// <summary>Sets the mono digit font size (points; scaled by the global zoom), matches the editor's ruler font (mono 10 pt).</summary>
    public void SetDigitSize(double size)
    {
        _digitSize = size;
        InvalidateVisual();
    }

    /// <summary>
    /// Auto-sizes the gutter width: <c>digits = max(3, len(total))</c>, measures <c>"8"*digits</c> in the digit
    /// font, width = ceil(w + paddingLeft + paddingRight).
    /// </summary>
    public void RecomputeThickness(int totalLines)
    {
        EnsureResources();
        int digits = Math.Max(3, totalLines.ToString(CultureInfo.InvariantCulture).Length);
        string sample = new string('8', digits);
        var ft = new FormattedText(sample, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            _typeface!, _digitSize, _digit!, GetDip());
        double w = Math.Ceiling(ft.WidthIncludingTrailingWhitespace + PaddingLeft + PaddingRight);
        Width = Math.Max(28, w);
        InvalidateVisual();
    }

    private double GetDip()
    {
        try { return VisualTreeHelper.GetDpi(this).PixelsPerDip; }
        catch { return 1.0; }
    }

    private void EnsureResources()
    {
        if (_valid) return;
        _typeface = new Typeface(XMFont.MonoFamily, FontStyles.Normal, FontWeights.Regular, FontStretches.Normal);

        _bg = FrozenBrush(WithAlpha(XMColor.Color(XMColor.BgDeep), 0.6));
        _digit = FrozenBrush(XMColor.Color(XMColor.Text2));
        var dv = new Pen(FrozenBrush(XMColor.Color(XMColor.Hairline)), 0.5);
        dv.Freeze();
        _divider = dv;
        _valid = true;
    }

    protected override void OnRender(DrawingContext dc)
    {
        EnsureResources();
        double w = ActualWidth, h = ActualHeight;
        dc.DrawRectangle(_bg, null, new Rect(0, 0, w, h));

        if (_index is null || _layout is null || _index.LineCount <= 1)
        {
            // Right-edge divider only.
            dc.DrawLine(_divider, new Point(w - 0.5, 0), new Point(w - 0.5, h));
            return;
        }

        int count = _index.LineCount;
        int first = _layout.FirstVisibleLine(_scrollY, count);
        int last = _layout.LastVisibleLine(_scrollY, h, count);
        double dip = GetDip();
        double lineHeight = _layout.LineHeight;

        for (int i = first; i <= last; i++)
        {
            double y = _layout.YForLine(i, _scrollY);
            string label = (i + 1).ToString(CultureInfo.InvariantCulture);
            var ft = new FormattedText(label, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                _typeface!, _digitSize, _digit!, dip);
            double x = w - ft.WidthIncludingTrailingWhitespace - PaddingRight;
            double ty = y + (lineHeight - ft.Height) / 2.0;
            dc.DrawText(ft, new Point(x, ty));
        }

        dc.DrawLine(_divider, new Point(w - 0.5, 0), new Point(w - 0.5, h));
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
