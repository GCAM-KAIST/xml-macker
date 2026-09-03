using System;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using XMLMacker.Theme;

namespace XMLMacker.Windows;

/// <summary>
/// A read-only, no-wrap, virtualized mono text pane for the diff window. Only the visible line band
/// is drawn each paint (the WPF analog of TextKit non-contiguous layout) so the two
/// aligned outputs, which can each approach the per-side cap, never realize the whole document.
/// It renders per-row background bands (changed / removed / added / filler), mono text, horizontal
/// and vertical scrollers, and exposes a pixel <see cref="VerticalOffset"/> for mirrored scrolling
/// (aligned rows have identical heights on both sides, so offsets mirror 1:1).
/// This is a purpose-built control rather than <c>SourceEditorControl</c> because
/// <see cref="xml-macker.Editor.ISourceEditor"/> exposes neither arbitrary per-range background
/// bands nor a scroll-offset change signal, both of which the row model requires.
/// </summary>
public sealed class DiffTextView : Grid
{
    // Band kinds (per visual row).
    public const byte BandNone = 0;
    public const byte BandChanged = 1;
    public const byte BandRemoved = 2;
    public const byte BandAdded = 3;
    public const byte BandFiller = 4;

    private readonly Content _content;
    private readonly ScrollBar _vScroll;
    private readonly ScrollBar _hScroll;

    private string[] _lines = Array.Empty<string>();
    private byte[] _bands = Array.Empty<byte>();
    private int _maxCols;

    // For each row that BEGINS a run of filler rows, how long that run is (0 elsewhere). Computed once
    // in SetContent so the label "N lines only in the other file" costs nothing per paint.
    private int[] _fillerRunLength = Array.Empty<int>();

    /// <summary>
    /// The OTHER file's name, used to caption filler runs: "1,146 lines only in transportation_UCD_CORE.xml".
    /// </summary>
    public string OtherSideName { get; set; } = "the other file";

    private double _vOffset;   // pixels
    private double _hOffset;   // pixels

    private int _emphasisStart = -1;
    private int _emphasisCount;

    // Row selection, for line-by-line copies. Anchor = where the press started; End = the row the
    // pointer is on now. Rows are shared between the two sides, so the window mirrors it 1:1.
    private int _selAnchor = -1;
    private int _selEnd = -1;

    /// <summary>Raised when the row selection changes with the mouse (never on programmatic sets).</summary>
    public event EventHandler? SelectionChanged;

    /// <summary>The selected rows as (Start, Count); Count is 0 when nothing is selected.</summary>
    public (int Start, int Count) SelectedRows
        => _selAnchor < 0 || _selEnd < 0
            ? (-1, 0)
            : (Math.Min(_selAnchor, _selEnd), Math.Abs(_selEnd - _selAnchor) + 1);

    /// <summary>Sets the selection without raising <see cref="SelectionChanged"/> (used to mirror the other side).</summary>
    public void SetSelection(int start, int count)
    {
        if (count <= 0 || start < 0) { _selAnchor = -1; _selEnd = -1; }
        else { _selAnchor = start; _selEnd = start + count - 1; }
        _content.InvalidateVisual();
    }

    public void ClearSelection() => SetSelection(-1, 0);

    private void RaiseSelectionChanged() => SelectionChanged?.Invoke(this, EventArgs.Empty);

    /// <summary>The visual row under a y coordinate inside the content area, or -1 when there are no rows.</summary>
    private int RowAtY(double y)
    {
        if (_lines.Length == 0) return -1;
        int row = (int)Math.Floor((y + _vOffset - PadY) / _lineHeight);
        return Math.Clamp(row, 0, _lines.Length - 1);
    }

    private double _lineHeight = 16;
    private double _charWidth = 8;
    private double _emSize = 11;
    private Typeface _typeface = new(XMFont.MonoFamily, FontStyles.Normal, FontWeights.Regular, FontStretches.Normal);
    private GlyphTypeface? _glyphTypeface;

    private const double PadX = 4;
    private const double PadY = 4;

    private bool _suppressScrollEvent;

    /// <summary>Raised when the vertical pixel offset changes (scroll / wheel), drives the mirror.</summary>
    public event EventHandler? VerticalOffsetChanged;

    public DiffTextView()
    {
        Background = XMColor.Brush(XMColor.BgDeep);

        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        _content = new Content(this);
        SetRow(_content, 0); SetColumn(_content, 0);
        Children.Add(_content);

        _vScroll = new ScrollBar { Orientation = Orientation.Vertical };
        SetRow(_vScroll, 0); SetColumn(_vScroll, 1);
        _vScroll.Scroll += OnVScroll;
        Children.Add(_vScroll);

        _hScroll = new ScrollBar { Orientation = Orientation.Horizontal };
        SetRow(_hScroll, 1); SetColumn(_hScroll, 0);
        _hScroll.Scroll += OnHScroll;
        Children.Add(_hScroll);

        RebuildFontMetrics();
        ThemeManager.ThemeChanged += OnThemeChanged;
        MetricsScaleService.Instance.RebuildFonts += OnRebuildFonts;
        SizeChanged += (_, _) => UpdateScrollBars();
        Unloaded += (_, _) =>
        {
            ThemeManager.ThemeChanged -= OnThemeChanged;
            MetricsScaleService.Instance.RebuildFonts -= OnRebuildFonts;
        };
    }

    private void OnThemeChanged(object? s, EventArgs e)
    {
        Background = XMColor.Brush(XMColor.BgDeep);
        _content.InvalidateVisual();
    }

    private void OnRebuildFonts(object? s, EventArgs e)
    {
        RebuildFontMetrics();
        UpdateScrollBars();
        _content.InvalidateVisual();
    }

    private double _localScale = 1;

    /// <summary>This view's own zoom (Ctrl + wheel / Ctrl +/- in the Diff window), multiplied onto the application zoom.</summary>
    public double LocalScale
    {
        get => _localScale;
        set
        {
            _localScale = Math.Clamp(value, 0.5, 3.0);
            RebuildFontMetrics();
            UpdateScrollBars();
            _content.InvalidateVisual();
        }
    }

    private void RebuildFontMetrics()
    {
        _emSize = XMFont.Scaled(11) * _localScale;
        _typeface = new Typeface(XMFont.MonoFamily, FontStyles.Normal, FontWeights.Regular, FontStretches.Normal);
        if (_typeface.TryGetGlyphTypeface(out var gt))
        {
            _glyphTypeface = gt;
            _lineHeight = Math.Ceiling(gt.Height * _emSize);
            ushort gi = gt.CharacterToGlyphMap.TryGetValue('0', out ushort g) ? g : (ushort)0;
            double adv = gi < gt.AdvanceWidths.Count ? gt.AdvanceWidths[gi] : 0.6;
            _charWidth = adv * _emSize;
        }
        else
        {
            _glyphTypeface = null;
            var ft = MakeText("0");
            _lineHeight = Math.Ceiling(ft.Height);
            _charWidth = ft.WidthIncludingTrailingWhitespace;
        }
        if (_lineHeight < 1) _lineHeight = 16;
        if (_charWidth < 1) _charWidth = 8;
    }

    private FormattedText MakeText(string s) => new(
        s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
        _typeface, _emSize, XMColor.Brush(XMColor.Text), 1.0);

    /// <summary>Replaces the displayed lines and their per-row band kinds, resetting scroll to the top-left.</summary>
    public void SetContent(string[] lines, byte[] bands)
    {
        _lines = lines;
        _bands = bands;
        _maxCols = 0;
        for (int i = 0; i < lines.Length; i++)
            if (lines[i].Length > _maxCols) _maxCols = lines[i].Length;

        // Measure every run of consecutive filler rows once.
        _fillerRunLength = new int[bands.Length];
        int runStart = -1;
        for (int i = 0; i <= bands.Length; i++)
        {
            bool isFiller = i < bands.Length && bands[i] == BandFiller;
            if (isFiller && runStart < 0) runStart = i;
            if (!isFiller && runStart >= 0) { _fillerRunLength[runStart] = i - runStart; runStart = -1; }
        }
        _emphasisStart = -1;
        _emphasisCount = 0;
        _selAnchor = -1;
        _selEnd = -1;
        _vOffset = 0;
        _hOffset = 0;
        UpdateScrollBars();
        _content.InvalidateVisual();
    }

    public int LineCount => _lines.Length;
    public double LineHeight => _lineHeight;

    /// <summary>How many aligned rows the view currently shows.</summary>
    public int RowCount => _lines.Length;

    /// <summary>The vertical scroll position in pixels. Setting it does NOT re-raise the change event (mirror-safe).</summary>
    public double VerticalOffset
    {
        get => _vOffset;
        set
        {
            double v = Clamp(value, 0, MaxVOffset);
            if (Math.Abs(v - _vOffset) < 0.01) return;
            _vOffset = v;
            _suppressScrollEvent = true;
            _vScroll.Value = v;
            _suppressScrollEvent = false;
            _content.InvalidateVisual();
        }
    }

    /// <summary>Sets the emphasized (selected) hunk row span drawn as a highlight band.</summary>
    public void SetEmphasis(int startRow, int count)
    {
        _emphasisStart = startRow;
        _emphasisCount = count;
        _content.InvalidateVisual();
    }

    /// <summary>Scrolls so 0-based visual <paramref name="row"/> is visible (near the top if it was off-screen).</summary>
    public void EnsureRowVisible(int row)
    {
        if (row < 0) return;
        double viewport = _content.ActualHeight;
        double top = row * _lineHeight;
        double bottom = top + _lineHeight;
        if (top < _vOffset || bottom > _vOffset + viewport)
        {
            // Place the target roughly a quarter down from the top of the viewport.
            double target = top - viewport * 0.25;
            SetVerticalOffsetRaising(Clamp(target, 0, MaxVOffset));
        }
    }

    private void SetVerticalOffsetRaising(double v)
    {
        v = Clamp(v, 0, MaxVOffset);
        if (Math.Abs(v - _vOffset) < 0.01) return;
        _vOffset = v;
        _suppressScrollEvent = true;
        _vScroll.Value = v;
        _suppressScrollEvent = false;
        _content.InvalidateVisual();
        VerticalOffsetChanged?.Invoke(this, EventArgs.Empty);
    }

    private double ContentHeight => Math.Max(0, _lines.Length * _lineHeight + PadY * 2);
    private double ContentWidth => Math.Max(0, _maxCols * _charWidth + PadX * 2);
    private double MaxVOffset => Math.Max(0, ContentHeight - _content.ActualHeight);
    private double MaxHOffset => Math.Max(0, ContentWidth - _content.ActualWidth);

    private void UpdateScrollBars()
    {
        double vp = _content.ActualHeight;
        double maxV = MaxVOffset;
        _vScroll.Minimum = 0;
        _vScroll.Maximum = maxV;
        _vScroll.ViewportSize = vp;
        _vScroll.SmallChange = _lineHeight;
        _vScroll.LargeChange = Math.Max(_lineHeight, vp - _lineHeight);
        _vScroll.Visibility = maxV > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (_vOffset > maxV) { _vOffset = maxV; _vScroll.Value = maxV; }

        double hvp = _content.ActualWidth;
        double maxH = MaxHOffset;
        _hScroll.Minimum = 0;
        _hScroll.Maximum = maxH;
        _hScroll.ViewportSize = hvp;
        _hScroll.SmallChange = _charWidth * 4;
        _hScroll.LargeChange = Math.Max(_charWidth, hvp - _charWidth * 4);
        _hScroll.Visibility = maxH > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (_hOffset > maxH) { _hOffset = maxH; _hScroll.Value = maxH; }
    }

    private void OnVScroll(object? sender, ScrollEventArgs e)
    {
        if (_suppressScrollEvent) return;
        _vOffset = Clamp(_vScroll.Value, 0, MaxVOffset);
        _content.InvalidateVisual();
        VerticalOffsetChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnHScroll(object? sender, ScrollEventArgs e)
    {
        _hOffset = Clamp(_hScroll.Value, 0, MaxHOffset);
        _content.InvalidateVisual();
    }

    private static double Clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

    // The drawing surface.
    private sealed class Content : FrameworkElement
    {
        private readonly DiffTextView _owner;
        public Content(DiffTextView owner)
        {
            _owner = owner;
            ClipToBounds = true;
            Focusable = false;
        }

        protected override void OnMouseWheel(MouseWheelEventArgs e)
        {
            double delta = -(e.Delta / 120.0) * 3 * _owner._lineHeight;
            _owner.SetVerticalOffsetRaising(_owner._vOffset + delta);
            e.Handled = true;
        }

        // ── row selection: press selects a row, drag or Shift+press extends it ─────────────────
        private bool _selecting;

        protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
        {
            base.OnMouseLeftButtonDown(e);
            int row = _owner.RowAtY(e.GetPosition(this).Y);
            if (row < 0) return;
            bool extend = (Keyboard.Modifiers & ModifierKeys.Shift) != 0 && _owner._selAnchor >= 0;
            if (extend) _owner._selEnd = row;
            else { _owner._selAnchor = row; _owner._selEnd = row; }
            _selecting = true;
            CaptureMouse();
            InvalidateVisual();
            _owner.RaiseSelectionChanged();
            e.Handled = true;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (!_selecting || e.LeftButton != MouseButtonState.Pressed) return;
            int row = _owner.RowAtY(e.GetPosition(this).Y);
            if (row < 0 || row == _owner._selEnd) return;
            _owner._selEnd = row;
            InvalidateVisual();
            _owner.RaiseSelectionChanged();
        }

        protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
        {
            base.OnMouseLeftButtonUp(e);
            if (!_selecting) return;
            _selecting = false;
            ReleaseMouseCapture();
        }

        protected override Size ArrangeOverride(Size finalSize)
        {
            var r = base.ArrangeOverride(finalSize);
            _owner.UpdateScrollBars();
            return r;
        }

        protected override void OnRender(DrawingContext dc)
        {
            double w = ActualWidth, h = ActualHeight;
            var bg = XMColor.Brush(XMColor.BgDeep);
            dc.DrawRectangle(bg, null, new Rect(0, 0, w, h));

            var lines = _owner._lines;
            if (lines.Length == 0) return;

            double lh = _owner._lineHeight;
            double vOff = _owner._vOffset;
            double hOff = _owner._hOffset;

            var changed = AlphaBrush(XMColor.Warn, 0.16);
            var removed = AlphaBrush(XMColor.Err, 0.16);
            var added = AlphaBrush(XMColor.Ok, 0.16);
            var emphasis = AlphaBrush(XMColor.Accent, 0.22);
            var textBrush = XMColor.Brush(XMColor.Text);
            var captionBrush = XMColor.Brush(XMColor.Text3);

            // Filler = "no line exists here on this side". The old flat hairline wash was a 10 % grey that
            // vanished on the Light theme, so a 4,000-row run of it read as "the file did not load".
            // A diagonal hatch is visible on every theme and cannot be mistaken for text or for blank paper.
            var filler = FillerHatch();
            var fillerEdge = new Pen(AlphaBrush(XMColor.Text3, 0.35), 1);
            fillerEdge.Freeze();

            int first = Math.Max(0, (int)((vOff - PadY) / lh));
            int last = Math.Min(lines.Length - 1, (int)((vOff + h - PadY) / lh) + 1);

            (int selStart, int selCount) = _owner.SelectedRows;
            var selection = AlphaBrush(XMColor.Accent, 0.30);
            var selectionEdge = XMColor.Brush(XMColor.Accent);

            double xText = PadX - hOff;

            for (int i = first; i <= last; i++)
            {
                double y = PadY + i * lh - vOff;
                byte band = i < _owner._bands.Length ? _owner._bands[i] : BandNone;
                Brush? bandBrush = band switch
                {
                    BandChanged => changed,
                    BandRemoved => removed,
                    BandAdded => added,
                    BandFiller => filler,
                    _ => null
                };
                if (bandBrush != null)
                    dc.DrawRectangle(bandBrush, null, new Rect(0, y, w, lh));

                if (selCount > 0 && i >= selStart && i < selStart + selCount)
                {
                    // Selected rows: a stronger wash plus a solid bar on the left edge, on both sides.
                    dc.DrawRectangle(selection, null, new Rect(0, y, w, lh));
                    dc.DrawRectangle(selectionEdge, null, new Rect(0, y, 3, lh));
                }

                bool emphasised = _owner._emphasisStart >= 0
                    && i >= _owner._emphasisStart
                    && i < _owner._emphasisStart + _owner._emphasisCount;
                if (emphasised && band != BandFiller)
                    dc.DrawRectangle(emphasis, null, new Rect(0, y, w, lh));

                if (band == BandFiller)
                {
                    // Emphasis over filler is an OUTLINE, not a solid wash: a solid wash turned the
                    // whole hunk into a blue wall that hid the hatch and looked like nothing had loaded.
                    if (emphasised)
                        dc.DrawRectangle(null, new Pen(emphasis, 2), new Rect(1, y + 0.5, Math.Max(0, w - 2), lh - 1));

                    int run = i < _owner._fillerRunLength.Length ? _owner._fillerRunLength[i] : 0;
                    if (run > 0)
                    {
                        // Caption the START of every filler run so the reader knows what the gap means.
                        string what = run == 1 ? "1 line" : run.ToString("N0", CultureInfo.InvariantCulture) + " lines";
                        var caption = new FormattedText(
                            $"\u22ef {what} only in {_owner.OtherSideName}",
                            CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                            _owner._typeface, _owner._emSize, captionBrush, 1.0);
                        double capW = caption.WidthIncludingTrailingWhitespace + 12;
                        dc.DrawRoundedRectangle(XMColor.Brush(XMColor.BgDeep), fillerEdge,
                            new Rect(PadX + 2, y + 1, capW, lh - 2), 4, 4);
                        dc.DrawText(caption, new Point(PadX + 8, y));
                    }
                    continue;
                }

                string s = lines[i];
                if (s.Length == 0) continue;
                var ft = new FormattedText(
                    s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                    _owner._typeface, _owner._emSize, textBrush, 1.0);
                dc.DrawText(ft, new Point(xText, y));
            }
        }

        private static Brush? _hatchCache;
        private static string _hatchTheme = "";

        /// <summary>A diagonal-stripe brush in the theme's muted text colour, reads as "no content here".</summary>
        private static Brush FillerHatch()
        {
            string theme = XMColor.Color(XMColor.Text3).ToString();
            if (_hatchCache is not null && _hatchTheme == theme) return _hatchCache;

            var stripe = new Pen(AlphaBrush(XMColor.Text3, 0.28), 1.2);
            stripe.Freeze();
            var g = new DrawingGroup();
            using (DrawingContext gc = g.Open())
            {
                gc.DrawRectangle(AlphaBrush(XMColor.Text3, 0.06), null, new Rect(0, 0, 8, 8));
                gc.DrawLine(stripe, new Point(-2, 10), new Point(10, -2));
            }
            g.Freeze();
            var brush = new DrawingBrush(g)
            {
                TileMode = TileMode.Tile,
                Viewport = new Rect(0, 0, 8, 8),
                ViewportUnits = BrushMappingMode.Absolute,
            };
            brush.Freeze();
            _hatchCache = brush;
            _hatchTheme = theme;
            return brush;
        }

        private static Brush AlphaBrush(string key, double alpha)
        {
            Color c = XMColor.Color(key);
            var b = new SolidColorBrush(Color.FromArgb((byte)Math.Round(alpha * 255), c.R, c.G, c.B));
            b.Freeze();
            return b;
        }
    }
}
