using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using XMLMacker.Theme;

namespace XMLMacker.Editor;

/// <summary>
/// Floating hover-preview panel launched by <see cref="MinimapControl"/> (port of Swift
/// <c>MinimapMagnifier</c>). A borderless, <b>non-activating</b>, always-on-top child window (380×240)
/// that shows a zoomed, syntax-colored ±12-line slice of the source around the hovered minimap line,
/// with the hovered line washed. Clicking a line inside it jumps the editor there (line-accurate).
///
/// <para>Non-activating (<c>ShowActivated=false</c>) so the main window stays focused while it shows.
/// It is an OWNED window of the main window, and Windows always paints an owned window above its owner, 
/// that ownership, not <c>Topmost</c>, is what keeps the preview above the editor. <c>Topmost</c> is
/// deliberately NOT set: nothing here hides the panel when the application loses focus, so a topmost
/// panel would stay parked over whatever program is in front. Hiding is debounced <b>120 ms</b>
/// so the mouse can travel from the minimap into the magnifier without it closing.</para>
/// </summary>
public partial class MinimapMagnifier : Window
{
    private readonly DispatcherTimer _hideTimer;
    private readonly MagnifierContentView _content;
    private Window? _parent;
    private int _firstLineNumber = 1;

    /// <summary>
    /// True once this window has been closed and can never be shown again.
    /// <para>WPF destroys every owned window when its owner closes, so popping the source pane out and
    /// then closing that pop-out silently kills this panel. Calling <c>Show()</c> afterwards throws
    /// <c>InvalidOperationException("…after a Window has closed")</c>, which used to terminate the whole
    /// application on the next minimap hover. The owner (<see cref="MinimapControl"/>) checks this flag
    /// and builds a fresh magnifier instead of resurrecting a dead one.</para>
    /// </summary>
    public bool IsClosed { get; private set; }

    /// <summary>Fired with the ABSOLUTE (1-based) line number when a line inside the popup is clicked.</summary>
    public event Action<int>? LineClicked;

    public MinimapMagnifier()
    {
        InitializeComponent();

        _content = new MagnifierContentView();
        Host.Children.Add(_content);

        // Content-view row click → translate to an absolute line number for the host.
        _content.RowClicked += row => LineClicked?.Invoke(_firstLineNumber + row);

        // Mouse can travel from the minimap into the magnifier: re-entering cancels the pending hide.
        _content.PointerEntered += CancelPendingHide;
        _content.PointerExited += ScheduleHide;

        _hideTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(120) };
        _hideTimer.Tick += (_, __) => { _hideTimer.Stop(); if (!IsClosed && IsVisible) Hide(); };

        Closed += (_, __) =>
        {
            IsClosed = true;
            _hideTimer.Stop();
            _content.Detach();
        };
    }

    /// <summary>
    /// Ensures this panel is an owned (child) window of <paramref name="owner"/> so it tracks the main
    /// window's minimize/hide. Re-parents only when the owner changed.
    /// </summary>
    public void Attach(Window? owner)
    {
        if (IsClosed || owner is null || ReferenceEquals(owner, _parent)) return;

        // Re-owning a visible window can flicker it to the back; hide first when the host changed
        // (this happens when the source pane is popped out into its own window and back again).
        if (_parent is not null && IsVisible) Hide();

        Owner = owner;
        _parent = owner;
    }

    /// <summary>
    /// Shows/updates the popup with a ±12-line preview.
    /// <paramref name="anchorInScreen"/> is the hovered point in device-independent SCREEN coordinates;
    /// the panel is placed to the LEFT of it and clamped to the work area with an 8 px margin.
    /// </summary>
    public void Show(string text, int highlightLocalLine, int lineNumber, int firstLineNumber, Point anchorInScreen)
    {
        if (IsClosed) return;   // dead panel, the caller re-creates instead (see IsClosed).
        CancelPendingHide();
        _firstLineNumber = firstLineNumber;
        _content.Update(text, highlightLocalLine, lineNumber);

        double x = anchorInScreen.X - Width - 12;
        double y = anchorInScreen.Y - Height / 2.0;

        Rect wa = SystemParameters.WorkArea;
        const double margin = 8;
        x = Math.Max(wa.Left + margin, Math.Min(x, wa.Right - Width - margin));
        y = Math.Max(wa.Top + margin, Math.Min(y, wa.Bottom - Height - margin));

        Left = x;
        Top = y;

        if (!IsVisible) Show();      // ShowActivated=false → does not steal focus from the main window.
    }

    /// <summary>Requests a debounced (120 ms) hide.</summary>
    public void HideDeferred() => ScheduleHide();

    private void ScheduleHide()
    {
        if (IsClosed) return;   // never restart a timer that would touch a destroyed window.
        _hideTimer.Stop();
        _hideTimer.Start();
    }

    private void CancelPendingHide() => _hideTimer.Stop();

    // ────────────────────────────────────────────────────────────────────────────────────────────
    // Custom drawing content view, cheaper than a TextBox for per-mouseMove redraws.
    // ────────────────────────────────────────────────────────────────────────────────────────────

    private sealed class MagnifierContentView : FrameworkElement
    {
        private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        private readonly SyntaxColors _syntax = new();
        private readonly List<ColorRun> _runScratch = new(64);

        private string _text = "";
        private int _highlightLine = -1;
        private int _lineNumber = 1;
        private int[] _lineStarts = { 0 };
        private int _lineCount = 1;

        private double _lineHeight = 14;
        private double _textOriginY;

        private ViewportXmlColorizer? _colorizer;
        private TextBuffer? _buffer;

        // Cached theme resources.
        private Brush? _cardBrush;
        private Pen? _borderPen;
        private Brush? _titleBrush;
        private Brush? _hoverFill;
        private Brush? _hoverStripe;
        private bool _valid;

        public event Action? PointerEntered;
        public event Action? PointerExited;
        public event Action<int>? RowClicked;

        public MagnifierContentView()
        {
            Focusable = false;
            SnapsToDevicePixels = true;
            ThemeManager.ThemeChanged += OnThemeChanged;
            _syntax.Changed += (_, __) => InvalidateVisual();
        }

        public void Detach()
        {
            ThemeManager.ThemeChanged -= OnThemeChanged;
            _syntax.Detach();
        }

        private void OnThemeChanged(object? sender, EventArgs e)
        {
            _valid = false;
            InvalidateVisual();
        }

        private static double FontSize => XMFont.Scaled(11);
        private static double TitleSize => XMFont.Scaled(10);

        private static Typeface MonoTypeface =>
            new(XMFont.MonoFamily, FontStyles.Normal, FontWeights.Regular, FontStretches.Normal);

        private static Typeface UiTypeface =>
            new(XMFont.UiFamily, FontStyles.Normal, FontWeights.Medium, FontStretches.Normal);

        public void Update(string text, int highlightLocalLine, int lineNumber)
        {
            _text = text ?? "";
            _highlightLine = highlightLocalLine;
            _lineNumber = lineNumber;

            // Preview-local line starts.
            var starts = new List<int> { 0 };
            for (int i = 0; i < _text.Length; i++)
                if (_text[i] == '\n') starts.Add(i + 1);
            _lineStarts = starts.ToArray();
            _lineCount = _lineStarts.Length;

            // Tokenize with the same viewport colorizer the editor uses.
            _buffer = new TextBuffer(_text);
            _colorizer = new ViewportXmlColorizer(_buffer);
            _colorizer.EnsureColored(0, _text.Length);

            _lineHeight = MeasureLineHeight();
            InvalidateVisual();
        }

        private double MeasureLineHeight()
        {
            var ft = new FormattedText("Xg", Inv, FlowDirection.LeftToRight, MonoTypeface, FontSize,
                Brushes.White, GetDip());
            return ft.Height + 2; // Swift: ascender − descender + leading + 2
        }

        private void EnsureResources()
        {
            if (_valid) return;
            _cardBrush = FrozenBrush(WithAlpha(XMColor.Color(XMColor.BgDeep), 0.97));
            var bp = new Pen(FrozenBrush(XMColor.Color(XMColor.HairlineS)), 0.5);
            bp.Freeze();
            _borderPen = bp;
            _titleBrush = FrozenBrush(XMColor.Color(XMColor.Text3));
            _hoverFill = FrozenBrush(WithAlpha(XMColor.Color(XMColor.Accent), 0.20));
            _hoverStripe = FrozenBrush(XMColor.Color(XMColor.Accent));
            _valid = true;
        }

        protected override void OnRender(DrawingContext dc)
        {
            EnsureResources();
            double w = ActualWidth, h = ActualHeight;

            // Whole-panel transparent fill so the entire area hit-tests (mouse enter/leave, clicks).
            dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, w, h));

            // Rounded card (bounds inset by 4, corner 10).
            var card = new Rect(4, 4, Math.Max(0, w - 8), Math.Max(0, h - 8));
            var cardGeo = new RectangleGeometry(card, 10, 10);
            dc.DrawGeometry(_cardBrush, _borderPen, cardGeo);

            if (_text.Length == 0) return;

            double dip = GetDip();

            // Title (uppercased) at the top-left of the card.
            string title = string.Format(Inv, "line {0} · preview", _lineNumber).ToUpperInvariant();
            var titleFt = new FormattedText(title, Inv, FlowDirection.LeftToRight, UiTypeface, TitleSize,
                _titleBrush!, dip);
            dc.DrawText(titleFt, new Point(card.Left + 10, card.Top + 4));

            double textLeft = card.Left + 10;
            double textTop = card.Top + 18; // card inset 8 + offset-down 10
            _textOriginY = textTop;

            dc.PushClip(cardGeo);
            try
            {
                // Hovered-line accent wash + 2 px left stripe (behind text).
                if (_highlightLine >= 0 && _highlightLine < _lineCount)
                {
                    double hy = textTop + _highlightLine * _lineHeight - 1;
                    dc.DrawRectangle(_hoverFill, null, new Rect(card.Left + 1, hy, card.Width - 2, _lineHeight));
                    dc.DrawRectangle(_hoverStripe, null, new Rect(card.Left + 1, hy, 2, _lineHeight));
                }

                var monoTf = MonoTypeface;
                double fontSize = FontSize;
                Brush plain = _syntax.PlainText;

                for (int li = 0; li < _lineCount; li++)
                {
                    double ly = textTop + li * _lineHeight;
                    if (ly > card.Bottom) break;

                    int start = _lineStarts[li];
                    int end = (li + 1 < _lineCount) ? _lineStarts[li + 1] - 1 : _text.Length;
                    if (end < start) end = start;
                    string lineText = _text.Substring(start, end - start);
                    if (lineText.Length == 0) continue;

                    var ft = new FormattedText(lineText, Inv, FlowDirection.LeftToRight, monoTf, fontSize, plain, dip)
                    {
                        Trimming = TextTrimming.None
                    };
                    ft.MaxLineCount = 1;

                    _colorizer!.GetRuns(start, end, _runScratch);
                    foreach (ColorRun run in _runScratch)
                    {
                        int local = run.Start - start;
                        if (local < 0 || local >= lineText.Length) continue;
                        int len = Math.Min(run.Length, lineText.Length - local);
                        if (len <= 0) continue;
                        ft.SetForegroundBrush(_syntax.For(run.Class), local, len);
                    }

                    dc.DrawText(ft, new Point(textLeft, ly));
                }
            }
            finally
            {
                dc.Pop();
            }
        }

        protected override void OnMouseEnter(MouseEventArgs e)
        {
            base.OnMouseEnter(e);
            PointerEntered?.Invoke();
        }

        protected override void OnMouseLeave(MouseEventArgs e)
        {
            base.OnMouseLeave(e);
            PointerExited?.Invoke();
        }

        protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
        {
            base.OnMouseLeftButtonDown(e);
            if (_lineHeight <= 0 || _lineCount <= 0) return;
            Point p = e.GetPosition(this);
            int row = (int)Math.Floor((p.Y - _textOriginY) / _lineHeight);
            row = Math.Clamp(row, 0, _lineCount - 1);
            RowClicked?.Invoke(row);
        }

        private double GetDip()
        {
            try { return VisualTreeHelper.GetDpi(this).PixelsPerDip; }
            catch { return 1.0; }
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
}
