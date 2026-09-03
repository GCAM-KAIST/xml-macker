using System;
using System.Text.RegularExpressions;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using XMLMacker.Theme;
using TextHighlights = XMLMacker.Core.TextHighlights;
using HighlightRange = XMLMacker.Core.HighlightRange;

namespace XMLMacker.Editor;

/// <summary>
/// The custom virtualized text editor control. It opens a 655 MB / 12.6 M-line file and
/// scrolls/jumps instantly because it lays out and paints ONLY the visible band: the piece-table
/// <see cref="TextBuffer"/> never copies the document on an edit, the <see cref="LineIndex"/> maps line↔offset in
/// O(log n), and <see cref="ViewportLayout"/> generates visual lines for the visible rows alone. Text is painted
/// with <see cref="GlyphRun"/>s per colored run; highlights are rectangle bands behind the text; the gutter and
/// minimap read the same geometry so everything is pixel-aligned.
/// <para>Vertical scrolling is virtual: the control stays viewport-sized and two <see cref="ScrollBar"/> children
/// encode the (potentially 200 M-pixel) document height as scrollbar values, a real 200 M-pixel element is
/// impossible in WPF. Long lines scroll horizontally (no soft wrap in v1); for a minified single-line document only
/// the visible columns are fetched, so the whole file is never materialized.</para>
/// </summary>
public sealed class HugeTextEditor : Control
{
    // ── Composed engines ────────────────────────────────────────────────────────────────────────
    private readonly LineIndex _lineIndex = new();
    private readonly ViewportLayout _layout = new();
    private readonly HighlightLayer _highlight = new();
    private readonly SyntaxColors _syntax = new();
    private readonly GutterMargin _gutter = new();

    private ITextBuffer? _buffer;
    private ViewportXmlColorizer? _colorizer;
    private EditorUndoStack? _undo;
    private AutoScroller? _autoScroller;

    // ── Scroll children ─────────────────────────────────────────────────────────────────────────
    private readonly ScrollBar _vScroll = new() { Orientation = Orientation.Vertical };
    private readonly ScrollBar _hScroll = new() { Orientation = Orientation.Horizontal };
    private double _scrollX, _scrollY;
    private double _textWidth, _textHeight;
    private double _maxContentWidth;
    private bool _syncingScroll;

    // ── Font / metrics ──────────────────────────────────────────────────────────────────────────
    private double _fontSize = 12;
    private GlyphTypeface? _glyphTypeface;
    private double _charWidth = 8, _lineHeight = 16, _baseline = 12;
    private ushort _spaceGlyph;
    private readonly double _leftInset = 6;

    // ── Caret / selection ───────────────────────────────────────────────────────────────────────
    private int _caretOffset;
    private int _selectionAnchor;
    private bool _caretVisible = true;
    private readonly System.Windows.Threading.DispatcherTimer _caretTimer;
    private bool _mouseSelecting;

    // ── Brush caches ────────────────────────────────────────────────────────────────────────────
    private Brush? _bg;
    private Brush? _caretBrush;
    private Brush? _selectionBrush;
    private bool _brushesValid;

    private readonly List<ColorRun> _runScratch = new(64);

    // ── Linked files drawn as hyperlinks (port of the Mac's SyntaxHighlighter.markLinks, v1.0.1) ──
    // A value that names an existing file, "../input/gcamdata/xml/modeltime.xml", is drawn in the
    // accent colour with an underline; Ctrl+hover shows a hand; Ctrl+click opens it (ControlClicked).
    // The host supplies the resolver because only it knows the document's folder.

    /// <summary>Maps a raw value to the full path of an existing file, or null. Set by the host.</summary>
    public Func<string, string?>? LinkResolver
    {
        get => _linkResolver;
        set { _linkResolver = value; _linkCache.Clear(); }
    }
    private Func<string, string?>? _linkResolver;

    // Resolving means touching the disk; each distinct value is looked up once per document.
    private readonly Dictionary<string, string?> _linkCache = new(StringComparer.Ordinal);
    private readonly List<(int Start, int Length, string Path)> _linkScratch = new();
    private byte[] _clsScratch = new byte[512];

    // The same two shapes the Mac marks: an attribute value, and text between a closing '>' and an opening '<'.
    private static readonly Regex[] LinkPatterns =
    {
        new Regex("=\"([^\"\r\n]{2,400})\"", RegexOptions.Compiled),
        new Regex(">([^<>\r\n]{2,400})<", RegexOptions.Compiled),
    };

    /// <summary>Link spans in one line of text: (start, length) relative to the line, plus the resolved path.</summary>
    private List<(int Start, int Length, string Path)> LinkSpans(string lineText)
    {
        _linkScratch.Clear();
        if (_linkResolver is null || lineText.Length == 0 || lineText.Length > 4000) return _linkScratch;
        // Cheap pre-check mirroring LinkedFile.Resolve: a path has a separator or ends in .xml.
        if (lineText.IndexOf('/') < 0 && lineText.IndexOf('\\') < 0
            && lineText.IndexOf(".xml", StringComparison.OrdinalIgnoreCase) < 0) return _linkScratch;

        foreach (Regex re in LinkPatterns)
        {
            foreach (Match m in re.Matches(lineText))
            {
                Group g = m.Groups[1];
                string raw = g.Value;
                if (!_linkCache.TryGetValue(raw, out string? path))
                {
                    if (_linkCache.Count > 4000) _linkCache.Clear();
                    try { path = _linkResolver(raw); } catch { path = null; }
                    _linkCache[raw] = path;
                }
                if (path is not null) _linkScratch.Add((g.Index, g.Length, path));
            }
        }
        return _linkScratch;
    }

    /// <summary>The file a document offset points at when that text is a link; otherwise null.</summary>
    public string? LinkAtOffset(int offset)
    {
        if (_buffer is null || _linkResolver is null || offset < 0 || offset > _buffer.Length) return null;
        int start = LineStartOf(offset), end = LineEndOf(offset);
        if (end - start <= 0 || end - start > 4000) return null;
        string line = _buffer.Substring(start, end - start);
        foreach ((int s, int len, string path) in LinkSpans(line))
            if (offset >= start + s && offset <= start + s + len) return path;
        return null;
    }

    private void UpdateLinkCursor(Point p)
    {
        bool ctrl = (Keyboard.Modifiers & ModifierKeys.Control) != 0;
        Cursor = _overrideCursor ?? (ctrl && LinkAtOffset(OffsetFromPoint(p)) is not null ? Cursors.Hand : Cursors.IBeam);
    }

    protected override void OnKeyUp(KeyEventArgs e)
    {
        base.OnKeyUp(e);
        // Letting go of Ctrl turns the hand back into the text cursor.
        if (e.Key is Key.LeftCtrl or Key.RightCtrl) Cursor = _overrideCursor ?? Cursors.IBeam;
    }


    // ── Public surface ──────────────────────────────────────────────────────────────────────────

    /// <summary>The editable buffer, or null when nothing is loaded.</summary>
    // ── Marker strokes (Ctrl+H) ──────────────────────────────────────────────────
    private TextHighlights? _highlights;
    private static readonly Brush[] HighlightBands =
    {
        Brushes.Transparent,
        Frozen(Color.FromArgb(0x4D, 0xFF, 0x52, 0x52)),   // red
        Frozen(Color.FromArgb(0x47, 0x4C, 0x8D, 0xFF)),   // blue
        Frozen(Color.FromArgb(0x5C, 0xFF, 0xD4, 0x00)),   // yellow
        Frozen(Color.FromArgb(0x4D, 0x3D, 0xDC, 0x84)),   // green
    };

    /// <summary>A cursor that wins over the editor's own I-beam/hand while set (the marker pen).</summary>
    public Cursor? OverrideCursor
    {
        get => _overrideCursor;
        set { _overrideCursor = value; Cursor = value ?? Cursors.IBeam; }
    }
    private Cursor? _overrideCursor;

    /// <summary>The document's marker strokes, drawn as colour bands behind the text; null when none.</summary>
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

    public ITextBuffer? Buffer => _buffer;

    /// <summary>The shared line-offset engine.</summary>
    public LineIndex LineIndex => _lineIndex;

    /// <summary>The shared UTF-16 line-start table (for ruler + minimap).</summary>
    public int[] CurrentLineStarts => _lineIndex.Starts;

    /// <summary>Viewport geometry (line height, char width, Y↔line mapping).</summary>
    public ViewportLayout Layout => _layout;

    /// <summary>The line-number gutter this editor keeps in sync (laid out by the host).</summary>
    public GutterMargin Gutter => _gutter;

    /// <summary>Total document length in UTF-16 chars.</summary>
    public int DocumentLength => _buffer?.Length ?? 0;

    /// <summary>When true, all editing paths are refused (diff window opens read-only).</summary>
    public bool IsReadOnly { get; set; }

    /// <summary>The per-tab undo stack driving Ctrl+Z / Ctrl+Y.</summary>
    public EditorUndoStack? UndoStack
    {
        get => _undo;
        set
        {
            _undo = value;
            if (_undo is not null)
                _undo.ApplyRaw = (start, len, text) => RawApply(start, len, text, moveCaret: true);
        }
    }

    /// <summary>Caret char offset.</summary>
    public int CaretOffset => _caretOffset;

    /// <summary>Selection start (min of anchor/caret).</summary>
    public int SelectionStart => Math.Min(_selectionAnchor, _caretOffset);

    /// <summary>Selection length (0 when there is no selection).</summary>
    public int SelectionLength => Math.Abs(_caretOffset - _selectionAnchor);

    /// <summary>Vertical scroll offset in DIPs.</summary>
    public double ScrollOffsetY
    {
        get => _scrollY;
        set => SetScroll(_scrollX, value);
    }

    /// <summary>Horizontal scroll offset in DIPs.</summary>
    public double ScrollOffsetX
    {
        get => _scrollX;
        set => SetScroll(value, _scrollY);
    }

    /// <summary>Height of the text viewport (excludes the horizontal scrollbar).</summary>
    public double ViewportHeight => _textHeight;

    /// <summary>Raised on every real mutation (typed or programmatic; loads excluded), drives the dirty flag.</summary>
    public event EventHandler? DocumentMutated;

    /// <summary>Raised once after a complete undo or redo group has been applied.</summary>
    public event EventHandler? UndoRedoApplied;

    /// <summary>Raised on caret/selection change.</summary>
    public event EventHandler? SelectionChanged;

    /// <summary>Raised when the caret moves.</summary>
    public event EventHandler? CaretMoved;

    /// <summary>Raised whenever the scroll offset or viewport geometry changes (gutter + minimap listen).</summary>
    public event EventHandler? ViewportChanged;

    public HugeTextEditor()
    {
        Focusable = true;
        FocusVisualStyle = null;
        Cursor = _overrideCursor ?? Cursors.IBeam;
        SnapsToDevicePixels = true;
        ClipToBounds = true;
        AllowDrop = true;              // text dropped from anywhere lands at the drop point

        AddVisualChild(_vScroll);
        AddLogicalChild(_vScroll);
        AddVisualChild(_hScroll);
        AddLogicalChild(_hScroll);
        _vScroll.Scroll += (_, e) => OnBarScroll();
        _hScroll.Scroll += (_, e) => OnBarScroll();
        _vScroll.SmallChange = 48;
        _hScroll.SmallChange = 24;

        _autoScroller = new AutoScroller(this, dy => SetScroll(_scrollX, _scrollY + dy), () => Mouse.GetPosition(this));

        _caretTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(530) };
        _caretTimer.Tick += (_, __) =>
        {
            if (!IsKeyboardFocused || SelectionLength != 0) return;
            _caretVisible = !_caretVisible;
            InvalidateVisual();
        };

        // Routed commands make the standard Windows Edit menu operate on this custom-drawn
        // editor just as it would on a normal TextBox. Keyboard handling remains below for the
        // low-latency path, while menu clicks and accessibility clients use these bindings.
        CommandBindings.Add(new CommandBinding(ApplicationCommands.Cut,
            (_, e) => { CutSelectedText(); e.Handled = true; },
            (_, e) => { e.CanExecute = !IsReadOnly && SelectionLength > 0; e.Handled = true; }));
        CommandBindings.Add(new CommandBinding(ApplicationCommands.Copy,
            (_, e) => { CopySelectedText(); e.Handled = true; },
            (_, e) => { e.CanExecute = SelectionLength > 0; e.Handled = true; }));
        CommandBindings.Add(new CommandBinding(ApplicationCommands.Paste,
            (_, e) => { PasteClipboardText(); e.Handled = true; },
            (_, e) => { e.CanExecute = !IsReadOnly && ClipboardContainsText(); e.Handled = true; }));
        CommandBindings.Add(new CommandBinding(ApplicationCommands.SelectAll,
            (_, e) => { SelectAllText(); e.Handled = true; },
            (_, e) => { e.CanExecute = DocumentLength > 0; e.Handled = true; }));

        ThemeManager.ThemeChanged += (_, __) => { _brushesValid = false; _highlight.Rebuild(); InvalidateVisual(); };
        _syntax.Changed += (_, __) => { if (_colorizer is not null) _colorizer.InvalidateAll(); InvalidateVisual(); };

        RecomputeMetrics();
    }

    // ── Buffer attach / detach ──────────────────────────────────────────────────────────────────

    /// <summary>
    /// Hands the editor a freshly built buffer + line-start table (load or tab-attach). Takes ownership; resets
    /// scroll/caret/highlight and rewires the colorizer to the new buffer.
    /// </summary>
    public void AttachBuffer(ITextBuffer buffer, int[] lineStarts)
    {
        _linkCache.Clear();   // a new document may resolve the same relative paths differently
        _buffer = buffer;
        _lineIndex.SetStarts(lineStarts);
        _colorizer = new ViewportXmlColorizer(buffer);
        _colorizer.RepaintRequested += (_, __) => InvalidateVisual();

        _caretOffset = 0;
        _selectionAnchor = 0;
        _scrollX = 0;
        _scrollY = 0;
        _maxContentWidth = 0;
        _highlight.Clear();

        RecomputeMetrics();
        _gutter.Configure(_lineIndex, _layout);
        _gutter.RecomputeThickness(_lineIndex.LineCount);
        UpdateScrollExtent();
        _gutter.ScrollY = 0;
        InvalidateVisual();
        RaiseViewportChanged();
    }

    /// <summary>Rebuilds line starts from the current buffer (used after bulk edits that shift everything).</summary>
    public void RefreshLineStarts()
    {
        if (_buffer is null) return;
        _lineIndex.Rebuild(_buffer);
        _gutter.RecomputeThickness(_lineIndex.LineCount);
        UpdateScrollExtent();
        InvalidateVisual();
        RaiseViewportChanged();
    }

    // ── Font / zoom / theme ─────────────────────────────────────────────────────────────────────

    /// <summary>Sets the editor font size (points, already zoom-composed by the host) and recomputes metrics.</summary>
    public void ApplyFontSize(double size)
    {
        _fontSize = Math.Clamp(size, 5, 40);
        RecomputeMetrics();
        _gutter.SetDigitSize(XMFont.Scaled(10));
        _gutter.RecomputeThickness(_lineIndex.LineCount);
        UpdateScrollExtent();
        InvalidateVisual();
        RaiseViewportChanged();
    }

    /// <summary>Re-applies theme colors captured in caches (bg/caret/selection + gutter + highlight).</summary>
    public void RebuildColors()
    {
        _brushesValid = false;
        _highlight.Rebuild();
        _gutter.RebuildColors();
        if (_colorizer is not null) _colorizer.InvalidateAll();
        InvalidateVisual();
    }

    private void RecomputeMetrics()
    {
        var tf = new Typeface(XMFont.MonoFamily, FontStyles.Normal, FontWeights.Regular, FontStretches.Normal);
        if (!tf.TryGetGlyphTypeface(out var gt))
        {
            var fallback = new Typeface(new FontFamily("Consolas"), FontStyles.Normal, FontWeights.Regular, FontStretches.Normal);
            fallback.TryGetGlyphTypeface(out gt);
        }
        _glyphTypeface = gt;

        double emAdvance = 0.6;
        if (gt is not null && gt.CharacterToGlyphMap.TryGetValue('0', out ushort zi))
            emAdvance = gt.AdvanceWidths[zi];
        _charWidth = emAdvance * _fontSize;

        double h = (gt is not null && gt.Height > 0) ? gt.Height : 1.4;
        _lineHeight = h * _fontSize;
        double bl = (gt is not null && gt.Baseline > 0) ? gt.Baseline : 1.1;
        _baseline = bl * _fontSize;

        _spaceGlyph = (gt is not null && gt.CharacterToGlyphMap.TryGetValue(' ', out ushort sg)) ? sg : (ushort)0;

        _layout.SetMetrics(_lineHeight, _charWidth, _baseline);
        _vScroll.SmallChange = _lineHeight * 3;
    }

    private void EnsureBrushes()
    {
        if (_brushesValid) return;
        _bg = Frozen(XMColor.Color(XMColor.BgDeep));
        _caretBrush = Frozen(XMColor.Color(XMColor.Accent));
        _selectionBrush = Frozen(XMColor.Color(XMColor.LineHighlight));
        _brushesValid = true;
    }

    // ── Layout of the scrollbar children ────────────────────────────────────────────────────────

    protected override int VisualChildrenCount => 2;

    protected override Visual GetVisualChild(int index) => index == 0 ? _vScroll : _hScroll;

    protected override Size MeasureOverride(Size availableSize)
    {
        _vScroll.Measure(availableSize);
        _hScroll.Measure(availableSize);
        double w = double.IsInfinity(availableSize.Width) ? 400 : availableSize.Width;
        double h = double.IsInfinity(availableSize.Height) ? 300 : availableSize.Height;
        return new Size(w, h);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        double vw = SystemParameters.VerticalScrollBarWidth;
        double hh = SystemParameters.HorizontalScrollBarHeight;
        _textWidth = Math.Max(0, finalSize.Width - vw);
        _textHeight = Math.Max(0, finalSize.Height - hh);

        _vScroll.Arrange(new Rect(finalSize.Width - vw, 0, vw, finalSize.Height - hh));
        _hScroll.Arrange(new Rect(0, finalSize.Height - hh, finalSize.Width - vw, hh));

        UpdateScrollExtent();
        RaiseViewportChanged();
        return finalSize;
    }

    private void UpdateScrollExtent()
    {
        int lineCount = _lineIndex.LineCount;
        double contentHeight = _layout.ContentHeight(lineCount);
        double vMax = Math.Max(0, contentHeight - _textHeight);
        _vScroll.Minimum = 0;
        _vScroll.Maximum = vMax;
        _vScroll.ViewportSize = _textHeight;
        _vScroll.LargeChange = Math.Max(_lineHeight, _textHeight - _lineHeight);
        _vScroll.Visibility = vMax > 0 ? Visibility.Visible : Visibility.Hidden;

        double contentWidth = _maxContentWidth + _leftInset * 2;
        double hMax = Math.Max(0, contentWidth - _textWidth);
        _hScroll.Minimum = 0;
        _hScroll.Maximum = hMax;
        _hScroll.ViewportSize = _textWidth;
        _hScroll.LargeChange = Math.Max(_charWidth, _textWidth - _charWidth);
        _hScroll.Visibility = hMax > 0 ? Visibility.Visible : Visibility.Hidden;

        _scrollY = Math.Clamp(_scrollY, 0, vMax);
        _scrollX = Math.Clamp(_scrollX, 0, hMax);
        _syncingScroll = true;
        _vScroll.Value = _scrollY;
        _hScroll.Value = _scrollX;
        _syncingScroll = false;
    }

    private void OnBarScroll()
    {
        if (_syncingScroll) return;
        SetScroll(_hScroll.Value, _vScroll.Value);
    }

    private void SetScroll(double x, double y)
    {
        int lineCount = _lineIndex.LineCount;
        double vMax = Math.Max(0, _layout.ContentHeight(lineCount) - _textHeight);
        double hMax = Math.Max(0, _maxContentWidth + _leftInset * 2 - _textWidth);
        x = Math.Clamp(x, 0, hMax);
        y = Math.Clamp(y, 0, vMax);
        if (x == _scrollX && y == _scrollY) return;
        _scrollX = x;
        _scrollY = y;
        _syncingScroll = true;
        _vScroll.Value = _scrollY;
        _hScroll.Value = _scrollX;
        _syncingScroll = false;
        _gutter.ScrollY = _scrollY;
        _colorizer?.ScheduleColorVisible();
        InvalidateVisual();
        RaiseViewportChanged();
    }

    private void RaiseViewportChanged() => ViewportChanged?.Invoke(this, EventArgs.Empty);

    // ── Navigation / realize-before-scroll ──────────────────────────────────────────────────────

    /// <summary>
    /// Realizes the viewport at <paramref name="offset"/> before a far jump (analog of
    /// <c>ensureLayout(forCharacterRange:)</c>). Geometry is O(1) here, so this pre-colors the region so the first
    /// paint after the jump is already syntax-colored; every jump path calls it before scrolling.
    /// </summary>
    public void RealizeViewportAround(int offset)
    {
        if (_buffer is null || _colorizer is null) return;
        offset = Math.Clamp(offset, 0, _buffer.Length);
        _colorizer.EnsureColored(offset, offset);
    }

    /// <summary>Scrolls so the char at <paramref name="offset"/> is visible (minimal scroll, like scrollRangeToVisible).</summary>
    public void ScrollOffsetIntoView(int offset)
    {
        if (_buffer is null) return;
        int line0 = _lineIndex.LineForOffset(offset) - 1;
        double top = _layout.TopInset + line0 * _lineHeight;
        double bottom = top + _lineHeight;
        double y = _scrollY;
        if (top < _scrollY) y = top;
        else if (bottom > _scrollY + _textHeight) y = bottom - _textHeight;
        SetScroll(_scrollX, y);
    }

    /// <summary>Sets caret without extending selection; optionally scrolls into view.</summary>
    public void MoveCaretTo(int offset, bool scrollIntoView = true)
    {
        offset = Math.Clamp(offset, 0, DocumentLength);
        _caretOffset = offset;
        _selectionAnchor = offset;
        if (scrollIntoView) { RealizeViewportAround(offset); ScrollOffsetIntoView(offset); }
        _caretVisible = true;
        InvalidateVisual();
        SelectionChanged?.Invoke(this, EventArgs.Empty);
        CaretMoved?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Selects <paramref name="range"/> and scrolls it into view.</summary>
    public void SelectRange(int start, int length, bool scrollIntoView = true)
    {
        start = Math.Clamp(start, 0, DocumentLength);
        int end = Math.Clamp(start + length, 0, DocumentLength);
        _selectionAnchor = start;
        _caretOffset = end;
        if (scrollIntoView) { RealizeViewportAround(start); ScrollOffsetIntoView(start); }
        _caretVisible = true;
        InvalidateVisual();
        SelectionChanged?.Invoke(this, EventArgs.Empty);
        CaretMoved?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Sets the landing-line + whole-element highlight bands.</summary>
    public void SetHighlight((int Start, int Length)? landing, (int Start, int Length)? box)
    {
        _highlight.LandingRange = landing;
        _highlight.BoxRange = box;
        InvalidateVisual();
    }

    /// <summary>
    /// Bounding rect of the char at <paramref name="offset"/> in this control's coordinates (for the floating Define
    /// chip). Scrolls-with-text: x/y already account for the scroll offset.
    /// </summary>
    public Rect GetCharacterRect(int offset)
    {
        offset = Math.Clamp(offset, 0, DocumentLength);
        int line0 = _lineIndex.LineForOffset(offset) - 1;
        int col = offset - _lineIndex.OffsetForLineIndex(line0);
        double x = _leftInset + col * _charWidth - _scrollX;
        double y = _layout.YForLine(line0, _scrollY);
        return new Rect(x, y, _charWidth, _lineHeight);
    }

    /// <summary>Maps a point in the editor viewport to the nearest document character.</summary>
    public int HitTestDocumentOffset(Point point) => OffsetFromPoint(point);

    /// <summary>Returns the current selection without applying a share-size limit.</summary>
    public string GetSelectedText()
        => _buffer is not null && SelectionLength > 0
            ? _buffer.Substring(SelectionStart, SelectionLength)
            : string.Empty;

    /// <summary>Copies the current selection to the Windows clipboard.</summary>
    public void CopySelectedText() => CopySelection();

    /// <summary>Cuts the current selection when the document is editable.</summary>
    public void CutSelectedText()
    {
        if (IsReadOnly || SelectionLength == 0) return;
        CopySelection();
        DeleteSelection();
    }

    /// <summary>Pastes Windows clipboard text when the document is editable.</summary>
    public void PasteClipboardText()
    {
        if (!IsReadOnly) Paste();
    }

    private static bool ClipboardContainsText()
    {
        try { return Clipboard.ContainsText(); }
        catch { return false; }
    }

    /// <summary>Selects the complete document.</summary>
    public void SelectAllText()
    {
        if (_buffer is null) return;
        _selectionAnchor = 0;
        _caretOffset = DocumentLength;
        _caretVisible = true;
        InvalidateVisual();
        SelectionChanged?.Invoke(this, EventArgs.Empty);
        CaretMoved?.Invoke(this, EventArgs.Empty);
    }

    // ── Editing ─────────────────────────────────────────────────────────────────────────────────

    /// <summary>
    /// Core edit: replaces <c>[start, len]</c> with <paramref name="text"/> through the piece table, records undo
    /// (unless suppressed), maintains <c>lineStarts</c>, invalidates coloring, and raises
    /// <see cref="DocumentMutated"/>. Returns false when read-only or the range is invalid.
    /// </summary>
    public bool ReplaceText(int start, int len, string text, bool recordUndo = true, bool moveCaret = true)
    {
        if (IsReadOnly || _buffer is null) return false;
        start = Math.Clamp(start, 0, _buffer.Length);
        if (len < 0) len = 0;
        if (start + len > _buffer.Length) len = _buffer.Length - start;
        text ??= string.Empty;

        string removed = len > 0 ? _buffer.Substring(start, len) : string.Empty;
        if (recordUndo && _undo is not null && !_undo.IsApplying)
            _undo.Record(new EditRecord(start, removed, text, start + text.Length));

        RawApply(start, len, text, moveCaret, removedTextHint: removed);
        return true;
    }

    /// <summary>
    /// Applies a raw buffer edit (no undo recording): mutates the buffer, maintains <c>lineStarts</c>, invalidates
    /// coloring, shifts caret/selection, and raises <see cref="DocumentMutated"/>. Returns the caret position.
    /// </summary>
    private int RawApply(int start, int len, string text, bool moveCaret, string? removedTextHint = null)
    {
        if (_buffer is null) return _caretOffset;
        start = Math.Clamp(start, 0, _buffer.Length);
        if (len < 0) len = 0;
        if (start + len > _buffer.Length) len = _buffer.Length - start;
        text ??= string.Empty;

        string removed = removedTextHint ?? (len > 0 ? _buffer.Substring(start, len) : string.Empty);
        int delta = text.Length - len;

        _buffer.Replace(start, len, text);
        MaintainLineStarts(start, removed, text);
        _highlights?.ShiftForEdit(start, len, text.Length);
        _colorizer?.InvalidateAll();

        // Shift caret / anchor for the edit.
        _caretOffset = AdjustPos(_caretOffset, start, len, delta);
        _selectionAnchor = AdjustPos(_selectionAnchor, start, len, delta);
        int caret = start + text.Length;
        if (moveCaret)
        {
            _caretOffset = caret;
            _selectionAnchor = caret;
        }

        _maxContentWidth = 0; // recomputed as visible lines render
        UpdateScrollExtent();
        _caretVisible = true;
        InvalidateVisual();
        _gutter.InvalidateVisual();
        DocumentMutated?.Invoke(this, EventArgs.Empty);
        SelectionChanged?.Invoke(this, EventArgs.Empty);
        RaiseViewportChanged();
        return caret;
    }

    private static int AdjustPos(int pos, int start, int removedLen, int delta)
    {
        if (pos <= start) return pos;
        if (pos >= start + removedLen) return pos + delta;
        return start + Math.Max(0, delta + removedLen); // inside removed span → end of inserted text
    }

    private void MaintainLineStarts(int editOffset, string removed, string added)
    {
        bool hasNewline = removed.IndexOf('\n') >= 0 || added.IndexOf('\n') >= 0;
        if (!hasNewline)
        {
            _lineIndex.IncrementalUpdate(editOffset, added.Length - removed.Length);
        }
        else
        {
            _lineIndex.SpliceEdit(editOffset, removed, added);
            _gutter.RecomputeThickness(_lineIndex.LineCount);
        }
    }

    /// <summary>Undo the last group; returns true if anything changed.</summary>
    public bool Undo()
    {
        if (IsReadOnly || _undo is null) return false;
        int? caret = _undo.Undo();
        if (caret is null) return false;
        MoveCaretTo(caret.Value);
        UndoRedoApplied?.Invoke(this, EventArgs.Empty);
        return true;
    }

    /// <summary>Redo the last undone group; returns true if anything changed.</summary>
    public bool Redo()
    {
        if (IsReadOnly || _undo is null) return false;
        int? caret = _undo.Redo();
        if (caret is null) return false;
        MoveCaretTo(caret.Value);
        UndoRedoApplied?.Invoke(this, EventArgs.Empty);
        return true;
    }

    // ── Rendering ───────────────────────────────────────────────────────────────────────────────

    protected override void OnRender(DrawingContext dc)
    {
        EnsureBrushes();
        dc.DrawRectangle(_bg, null, new Rect(0, 0, ActualWidth, ActualHeight));

        // Fill the corner between the scrollbars with the background as well (already covered by the bg rect).
        if (_buffer is null || _glyphTypeface is null)
            return;

        dc.PushClip(new RectangleGeometry(new Rect(0, 0, _textWidth, _textHeight)));
        try
        {
            int docLen = _buffer.Length;
            var visible = _layout.GenerateVisibleLines(_lineIndex, docLen, _scrollY, _textHeight);
            if (visible.Count == 0) { return; }

            int visStart = visible[0].StartOffset;
            var lastVL = visible[^1];
            int visEnd = lastVL.StartOffset + lastVL.Length;

            // Highlight bands behind the text.
            _highlight.Draw(dc, _layout, _lineIndex, docLen, _scrollY, _textWidth, _textHeight);

            // Marker strokes: translucent bands over exactly the marked text, painted over
            // the landing and box wash and under the selection, so all three stay visible together.
            if (_highlights is { IsEmpty: false })
            {
                foreach (HighlightRange stroke in _highlights.Intersecting(visStart, visEnd + 1))
                    foreach (VisualLine vl in visible)
                    {
                        int lineStart = vl.StartOffset, lineEnd = vl.StartOffset + vl.Length;
                        int a = Math.Max(stroke.Start, lineStart), b = Math.Min(stroke.End, lineEnd);
                        if (b <= a) continue;
                        double x = _leftInset + (a - lineStart) * _charWidth - _scrollX;
                        dc.DrawRectangle(HighlightBands[(int)stroke.Color], null, new Rect(x, vl.Y, (b - a) * _charWidth, _lineHeight));
                    }
            }

            // Selection band.
            DrawSelection(dc, visible);

            // Ensure the visible band is colored.
            _colorizer!.EnsureColored(visStart, visEnd);

            double dip = GetDip();
            int firstCol = Math.Max(0, (int)Math.Floor(_scrollX / _charWidth));
            int visCols = (int)Math.Ceiling(_textWidth / _charWidth) + 2;

            double newMaxWidth = _maxContentWidth;
            foreach (VisualLine vl in visible)
            {
                double lineWidth = vl.Length * _charWidth;
                if (lineWidth > newMaxWidth) newMaxWidth = lineWidth;

                if (firstCol >= vl.Length) continue;
                int fetchLen = Math.Min(visCols, vl.Length - firstCol);
                if (fetchLen <= 0) continue;

                int fetchStart = vl.StartOffset + firstCol;
                string text = _buffer.Substring(fetchStart, fetchLen);
                double baseX = _leftInset + firstCol * _charWidth - _scrollX;
                double baselineY = vl.Y + _baseline;

                _colorizer.GetRuns(fetchStart, fetchStart + fetchLen, _runScratch);
                DrawColoredLine(dc, text, fetchStart, baseX, baselineY, dip);
            }

            if (Math.Abs(newMaxWidth - _maxContentWidth) > 0.5)
            {
                _maxContentWidth = newMaxWidth;
                UpdateScrollExtent();
            }

            // Caret.
            DrawCaret(dc);
            DrawDropCaret(dc);
        }
        finally
        {
            dc.Pop();
        }
    }

    private void DrawSelection(DrawingContext dc, List<VisualLine> visible)
    {
        int selStart = SelectionStart;
        int selLen = SelectionLength;
        if (selLen == 0) return;
        int selEnd = selStart + selLen;

        foreach (VisualLine vl in visible)
        {
            int lineStart = vl.StartOffset;
            int lineEnd = vl.StartOffset + vl.Length;
            int a = Math.Max(selStart, lineStart);
            int b = Math.Min(selEnd, lineEnd + 1); // +1 so a selected trailing newline shows a sliver
            if (b <= a) continue;
            int colA = a - lineStart;
            int colB = b - lineStart;
            double x = _leftInset + colA * _charWidth - _scrollX;
            double w = (colB - colA) * _charWidth;
            dc.DrawRectangle(_selectionBrush, null, new Rect(x, vl.Y, w, _lineHeight));
        }
    }

    private void DrawColoredLine(DrawingContext dc, string text, int fetchStart, double baseX, double baselineY, double dip)
    {
        Brush plain = _syntax.PlainText;
        if (text.Length == 0) return;

        // One class per character: plain first, the syntax runs over it, then linked-file spans on top
        // (255 = plain, 254 = link). Consecutive equal classes are drawn as one glyph run.
        if (_clsScratch.Length < text.Length) _clsScratch = new byte[Math.Max(512, text.Length * 2)];
        byte[] cls = _clsScratch;
        Array.Fill(cls, (byte)255, 0, text.Length);
        foreach (ColorRun run in _runScratch)
        {
            int a = Math.Max(0, run.Start - fetchStart);
            int b = Math.Min(text.Length, run.Start + run.Length - fetchStart);
            for (int i = a; i < b; i++) cls[i] = (byte)run.Class;
        }
        foreach ((int start, int len, string _) in LinkSpans(text))
            for (int i = start; i < start + len && i < text.Length; i++) cls[i] = 254;

        int at = 0;
        while (at < text.Length)
        {
            byte c = cls[at];
            int end = at + 1;
            while (end < text.Length && cls[end] == c) end++;
            Brush brush = c == 255 ? plain : c == 254 ? _syntax.Link : _syntax.For((XmlColorClass)c);
            DrawSpan(dc, text, fetchStart, fetchStart + at, fetchStart + end, baseX, baselineY, dip, brush);
            if (c == 254)
            {
                // The underline that says "this opens a file".
                double x0 = baseX + at * _charWidth, x1 = baseX + end * _charWidth;
                double uy = Math.Round(baselineY + 2) + 0.5;
                dc.DrawLine(_syntax.LinkPen, new Point(x0, uy), new Point(x1, uy));
            }
            at = end;
        }
    }

    private void DrawSpan(DrawingContext dc, string text, int fetchStart, int a, int b,
                          double baseX, double baselineY, double dip, Brush brush)
    {
        if (b <= a) return;
        int localA = a - fetchStart;
        int localB = b - fetchStart;
        if (localA < 0) localA = 0;
        if (localB > text.Length) localB = text.Length;
        int n = localB - localA;
        if (n <= 0) return;

        var indices = new ushort[n];
        var advances = new double[n];
        GlyphTypeface gt = _glyphTypeface!;
        for (int i = 0; i < n; i++)
        {
            char c = text[localA + i];
            ushort g;
            if (c < ' ') g = _spaceGlyph;                                  // tabs/controls occupy one cell
            else if (!gt.CharacterToGlyphMap.TryGetValue(c, out g)) g = _spaceGlyph;
            indices[i] = g;
            advances[i] = _charWidth;
        }
        double x = baseX + localA * _charWidth;
        var origin = new Point(x, baselineY);
        try
        {
            var run = new GlyphRun(gt, 0, false, _fontSize, (float)dip, indices, origin, advances,
                null, null, null, null, null, null);
            dc.DrawGlyphRun(brush, run);
        }
        catch
        {
            // A malformed glyph run (e.g. exotic surrogate) must never crash a paint.
        }
    }

    private void DrawCaret(DrawingContext dc)
    {
        if (SelectionLength != 0 || !IsKeyboardFocused || !_caretVisible) return;
        int line0 = _lineIndex.LineForOffset(_caretOffset) - 1;
        int col = _caretOffset - _lineIndex.OffsetForLineIndex(line0);
        double x = _leftInset + col * _charWidth - _scrollX;
        double y = _layout.YForLine(line0, _scrollY);
        if (x < 0 || x > _textWidth) return;
        dc.DrawRectangle(_caretBrush, null, new Rect(x, y, 1.0, _lineHeight));
    }

    /// <summary>The thick mark showing where dragged text would land.</summary>
    private void DrawDropCaret(DrawingContext dc)
    {
        if (_dropCaret < 0) return;
        int line0 = _lineIndex.LineForOffset(_dropCaret) - 1;
        int col = _dropCaret - _lineIndex.OffsetForLineIndex(line0);
        double x = _leftInset + col * _charWidth - _scrollX;
        double y = _layout.YForLine(line0, _scrollY);
        if (x < 0 || x > _textWidth) return;
        dc.DrawRectangle(_caretBrush, null, new Rect(x - 1, y, 2.0, _lineHeight));
    }

    private double GetDip()
    {
        try { return VisualTreeHelper.GetDpi(this).PixelsPerDip; }
        catch { return 1.0; }
    }

    // ── Drag and drop of text ───────────────────────────────────────────────────────────────────

    // Pressing inside an existing selection may mean "drag this text somewhere", so the press is held
    // back until the mouse moves far enough: a move starts the drag, a release just moves the caret.
    private const int DragTextCap = 2_000_000;
    private bool _dragPending;
    private Point _dragOrigin;
    private int _dragPressOffset;
    private int _dropCaret = -1;       // where dropped text would land, drawn while a drag hovers

    /// <summary>Status-line messages about a drag or a drop (host shows them).</summary>
    public event Action<string>? DragDropStatus;

    /// <summary>
    /// True when pressing at <paramref name="offset"/> should hold back and possibly drag the selected
    /// text instead of starting a new selection: there is a selection, the press is inside it, and no
    /// special pointer mode (the marker pen) owns the mouse.
    /// </summary>
    public bool WouldStartDrag(int offset)
        => _overrideCursor is null && SelectionLength > 0
           && offset >= SelectionStart && offset < SelectionStart + SelectionLength;

    /// <summary>
    /// Puts dropped text into the document at <paramref name="offset"/> (one undoable edit), selects
    /// what landed and returns true. Line endings are normalised the way pasting does.
    /// </summary>
    public bool DropTextAt(int offset, string dropped)
    {
        if (IsReadOnly || _buffer is null || string.IsNullOrEmpty(dropped)) return false;

        string text = dropped.Replace("\r\n", "\n").Replace('\r', '\n');
        int at = Math.Clamp(offset, 0, DocumentLength);
        ReplaceText(at, 0, text);
        _selectionAnchor = at;
        _caretOffset = at + text.Length;
        _caretVisible = true;
        InvalidateVisual();
        SelectionChanged?.Invoke(this, EventArgs.Empty);
        CaretMoved?.Invoke(this, EventArgs.Empty);
        DragDropStatus?.Invoke($"Dropped {text.Length:N0} characters into the file, Ctrl+Z puts it back");
        return true;
    }

    /// <summary>Takes the selected text to any drop target: this file, the LEARN page, another program.</summary>
    private void StartTextDrag()
    {
        if (_buffer is null || SelectionLength <= 0) return;
        if (SelectionLength > DragTextCap)
        {
            DragDropStatus?.Invoke($"That selection is {SelectionLength:N0} characters, too much to drag ({DragTextCap:N0} is the limit), copy it instead");
            return;
        }

        string text = _buffer.Substring(SelectionStart, SelectionLength);
        var data = new DataObject();
        data.SetData(DataFormats.UnicodeText, text);
        data.SetData(DataFormats.Text, text);
        try { DragDrop.DoDragDrop(this, data, DragDropEffects.Copy); }
        catch { /* the target refused the drop, nothing to repair */ }
        finally { _dropCaret = -1; InvalidateVisual(); }
    }

    private static string? TextFrom(IDataObject data)
    {
        try
        {
            if (data.GetDataPresent(DataFormats.UnicodeText)) return data.GetData(DataFormats.UnicodeText) as string;
            if (data.GetDataPresent(DataFormats.Text)) return data.GetData(DataFormats.Text) as string;
        }
        catch { /* a hostile source can throw here */ }
        return null;
    }

    protected override void OnDragOver(DragEventArgs e)
    {
        base.OnDragOver(e);
        // Dropped FILES stay the main window's business (they open as tabs), so leave those alone.
        if (IsReadOnly || _buffer is null || e.Data.GetDataPresent(DataFormats.FileDrop) || TextFrom(e.Data) is null)
        {
            if (_dropCaret >= 0) { _dropCaret = -1; InvalidateVisual(); }
            return;
        }
        int at = OffsetFromPoint(e.GetPosition(this));
        if (at != _dropCaret) { _dropCaret = at; InvalidateVisual(); }
        e.Effects = DragDropEffects.Copy;
        e.Handled = true;
    }

    protected override void OnDragLeave(DragEventArgs e)
    {
        base.OnDragLeave(e);
        if (_dropCaret >= 0) { _dropCaret = -1; InvalidateVisual(); }
    }

    protected override void OnDrop(DragEventArgs e)
    {
        base.OnDrop(e);
        _dropCaret = -1;
        if (IsReadOnly || _buffer is null || e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        if (TextFrom(e.Data) is not { Length: > 0 } dropped) return;
        if (!DropTextAt(OffsetFromPoint(e.GetPosition(this)), dropped)) return;

        e.Effects = DragDropEffects.Copy;
        e.Handled = true;
        Focus();
    }

    // ── Input: mouse ────────────────────────────────────────────────────────────────────────────

    protected override void OnMouseDown(MouseButtonEventArgs e)
    {
        base.OnMouseDown(e);
        Focus();

        if (e.ChangedButton == MouseButton.Middle)
        {
            _autoScroller!.OnMiddleDown(e.GetPosition(this));
            e.Handled = true;
            return;
        }
        if (_autoScroller!.OnOtherDownWhileActive())
        {
            e.Handled = true;
            return;
        }
        if (e.ChangedButton != MouseButton.Left) return;

        int offset = OffsetFromPoint(e.GetPosition(this));
        if ((Keyboard.Modifiers & ModifierKeys.Control) != 0)
        {
            bool openedLinkedFile = ControlClicked?.Invoke(offset) ?? false;
            if (openedLinkedFile)
            {
                e.Handled = true;
                return;
            }
        }
        bool shift = (Keyboard.Modifiers & ModifierKeys.Shift) != 0;
        if (e.ClickCount == 2)
        {
            SelectWordAt(offset);
        }
        else
        {
            if (shift) { _caretOffset = offset; }
            else if (WouldStartDrag(offset))
            {
                // Inside the selection: hold the press, a move drags the text, a release just moves the caret.
                _dragPending = true;
                _dragOrigin = e.GetPosition(this);
                _dragPressOffset = offset;
                e.Handled = true;
                return;
            }
            else { _caretOffset = offset; _selectionAnchor = offset; }
            _mouseSelecting = true;
            CaptureMouse();
        }
        _caretVisible = true;
        InvalidateVisual();
        SelectionChanged?.Invoke(this, EventArgs.Empty);
        CaretMoved?.Invoke(this, EventArgs.Empty);
    }

    public event Func<int, bool>? ControlClicked;

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (_dragPending)
        {
            if (e.LeftButton != MouseButtonState.Pressed) { _dragPending = false; return; }
            Point now = e.GetPosition(this);
            if (Math.Abs(now.X - _dragOrigin.X) < SystemParameters.MinimumHorizontalDragDistance
             && Math.Abs(now.Y - _dragOrigin.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            _dragPending = false;
            StartTextDrag();
            return;
        }
        if (!_mouseSelecting)
        {
            UpdateLinkCursor(e.GetPosition(this));
            return;
        }
        Point p = e.GetPosition(this);
        // Auto-scroll while dragging past the top/bottom edge.
        if (p.Y < 0) SetScroll(_scrollX, _scrollY - _lineHeight);
        else if (p.Y > _textHeight) SetScroll(_scrollX, _scrollY + _lineHeight);
        _caretOffset = OffsetFromPoint(p);
        InvalidateVisual();
        SelectionChanged?.Invoke(this, EventArgs.Empty);
        CaretMoved?.Invoke(this, EventArgs.Empty);
    }

    protected override void OnMouseUp(MouseButtonEventArgs e)
    {
        base.OnMouseUp(e);
        if (_dragPending)
        {
            // A click inside the selection that never moved: behave like a plain click.
            _dragPending = false;
            _caretOffset = _selectionAnchor = _dragPressOffset;
            _caretVisible = true;
            InvalidateVisual();
            SelectionChanged?.Invoke(this, EventArgs.Empty);
            CaretMoved?.Invoke(this, EventArgs.Empty);
        }
        if (_mouseSelecting)
        {
            _mouseSelecting = false;
            ReleaseMouseCapture();
        }
    }

    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        base.OnMouseWheel(e);
        if ((Keyboard.Modifiers & ModifierKeys.Shift) != 0)
            SetScroll(_scrollX - e.Delta / 120.0 * _charWidth * 3, _scrollY);
        else
            SetScroll(_scrollX, _scrollY - e.Delta / 120.0 * _lineHeight * 3);
        e.Handled = true;
    }

    private int OffsetFromPoint(Point p)
    {
        int count = _lineIndex.LineCount;
        int line0 = Math.Clamp(_layout.LineForY(p.Y, _scrollY), 0, Math.Max(0, count - 1));
        int lineStart = _lineIndex.OffsetForLineIndex(line0);
        int lineEnd = (line0 + 1 < count) ? _lineIndex.OffsetForLineIndex(line0 + 1) - 1 : DocumentLength;
        int col = (int)Math.Round((p.X - _leftInset + _scrollX) / _charWidth);
        if (col < 0) col = 0;
        return Math.Clamp(lineStart + col, lineStart, Math.Max(lineStart, lineEnd));
    }

    private void SelectWordAt(int offset)
    {
        if (_buffer is null) return;
        int len = _buffer.Length;
        int a = offset, b = offset;
        while (a > 0 && IsWordChar(_buffer.CharAt(a - 1))) a--;
        while (b < len && IsWordChar(_buffer.CharAt(b))) b++;
        _selectionAnchor = a;
        _caretOffset = b;
    }

    private static bool IsWordChar(char c)
        => c is (>= '0' and <= '9') or (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') || c == '_' || c == '-' || c > 0x7F;

    // ── Input: keyboard / text ──────────────────────────────────────────────────────────────────

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (_buffer is null) return;
        bool shift = (Keyboard.Modifiers & ModifierKeys.Shift) != 0;
        bool ctrl = (Keyboard.Modifiers & ModifierKeys.Control) != 0;

        switch (e.Key)
        {
            case Key.Left: MoveCaret(ctrl ? PrevWord(_caretOffset) : _caretOffset - 1, shift); e.Handled = true; break;
            case Key.Right: MoveCaret(ctrl ? NextWord(_caretOffset) : _caretOffset + 1, shift); e.Handled = true; break;
            case Key.Up: MoveCaretVertical(-1, shift); e.Handled = true; break;
            case Key.Down: MoveCaretVertical(1, shift); e.Handled = true; break;
            case Key.Home: MoveCaret(ctrl ? 0 : LineStartOf(_caretOffset), shift); e.Handled = true; break;
            case Key.End: MoveCaret(ctrl ? DocumentLength : LineEndOf(_caretOffset), shift); e.Handled = true; break;
            case Key.PageUp: MoveCaretVertical(-VisibleLineCount(), shift); e.Handled = true; break;
            case Key.PageDown: MoveCaretVertical(VisibleLineCount(), shift); e.Handled = true; break;

            case Key.Back:
                if (!IsReadOnly)
                {
                    if (SelectionLength != 0) DeleteSelection();
                    else if (_caretOffset > 0) ReplaceText(_caretOffset - 1, 1, string.Empty);
                    e.Handled = true;
                }
                break;
            case Key.Delete:
                if (!IsReadOnly)
                {
                    if (SelectionLength != 0) DeleteSelection();
                    else if (_caretOffset < DocumentLength) ReplaceText(_caretOffset, 1, string.Empty);
                    e.Handled = true;
                }
                break;
            case Key.Enter:
                if (!IsReadOnly) { InsertText("\n"); e.Handled = true; }
                break;
            case Key.Tab:
                if (!IsReadOnly) { InsertText("\t"); e.Handled = true; }
                break;

            case Key.A when ctrl:
                _selectionAnchor = 0; _caretOffset = DocumentLength;
                InvalidateVisual(); SelectionChanged?.Invoke(this, EventArgs.Empty); e.Handled = true;
                break;
            case Key.C when ctrl: CopySelection(); e.Handled = true; break;
            case Key.X when ctrl: if (!IsReadOnly) { CopySelection(); DeleteSelection(); } e.Handled = true; break;
            case Key.V when ctrl: if (!IsReadOnly) Paste(); e.Handled = true; break;
            case Key.Z when ctrl && !shift: Undo(); e.Handled = true; break;
            case Key.Y when ctrl: Redo(); e.Handled = true; break;
            case Key.Z when ctrl && shift: Redo(); e.Handled = true; break;
        }
    }

    protected override void OnTextInput(TextCompositionEventArgs e)
    {
        base.OnTextInput(e);
        if (IsReadOnly || _buffer is null) return;
        string t = e.Text;
        if (string.IsNullOrEmpty(t)) return;
        // Filter control chars except tab (Enter handled in OnKeyDown).
        if (t.Length == 1 && char.IsControl(t[0]) && t[0] != '\t') return;
        InsertText(t);
        e.Handled = true;
    }

    private void InsertText(string t)
    {
        if (SelectionLength != 0)
        {
            int s = SelectionStart, l = SelectionLength;
            ReplaceText(s, l, t);
        }
        else
        {
            ReplaceText(_caretOffset, 0, t);
        }
    }

    private void DeleteSelection()
    {
        if (SelectionLength == 0) return;
        ReplaceText(SelectionStart, SelectionLength, string.Empty);
    }

    private void CopySelection()
    {
        if (_buffer is null || SelectionLength == 0) return;
        try { Clipboard.SetText(_buffer.Substring(SelectionStart, SelectionLength)); }
        catch { /* clipboard contention, ignore */ }
    }

    private void Paste()
    {
        try
        {
            if (!Clipboard.ContainsText()) return;
            string t = Clipboard.GetText();
            if (!string.IsNullOrEmpty(t)) InsertText(t.Replace("\r\n", "\n").Replace('\r', '\n'));
        }
        catch { /* ignore */ }
    }

    private void MoveCaret(int newOffset, bool extend)
    {
        newOffset = Math.Clamp(newOffset, 0, DocumentLength);
        _caretOffset = newOffset;
        if (!extend) _selectionAnchor = newOffset;
        RealizeViewportAround(newOffset);
        ScrollOffsetIntoView(newOffset);
        _caretVisible = true;
        InvalidateVisual();
        SelectionChanged?.Invoke(this, EventArgs.Empty);
        CaretMoved?.Invoke(this, EventArgs.Empty);
    }

    private void MoveCaretVertical(int deltaLines, bool extend)
    {
        int line0 = _lineIndex.LineForOffset(_caretOffset) - 1;
        int col = _caretOffset - _lineIndex.OffsetForLineIndex(line0);
        int target = Math.Clamp(line0 + deltaLines, 0, Math.Max(0, _lineIndex.LineCount - 1));
        int targetStart = _lineIndex.OffsetForLineIndex(target);
        int targetEnd = (target + 1 < _lineIndex.LineCount) ? _lineIndex.OffsetForLineIndex(target + 1) - 1 : DocumentLength;
        MoveCaret(Math.Min(targetStart + col, targetEnd), extend);
    }

    private int LineStartOf(int offset) => _lineIndex.OffsetForLineIndex(_lineIndex.LineForOffset(offset) - 1);

    private int LineEndOf(int offset)
    {
        int line0 = _lineIndex.LineForOffset(offset) - 1;
        return (line0 + 1 < _lineIndex.LineCount) ? _lineIndex.OffsetForLineIndex(line0 + 1) - 1 : DocumentLength;
    }

    private int PrevWord(int offset)
    {
        if (_buffer is null || offset <= 0) return 0;
        int i = offset - 1;
        while (i > 0 && !IsWordChar(_buffer.CharAt(i))) i--;
        while (i > 0 && IsWordChar(_buffer.CharAt(i - 1))) i--;
        return i;
    }

    private int NextWord(int offset)
    {
        if (_buffer is null || offset >= _buffer.Length) return DocumentLength;
        int i = offset;
        int n = _buffer.Length;
        while (i < n && IsWordChar(_buffer.CharAt(i))) i++;
        while (i < n && !IsWordChar(_buffer.CharAt(i))) i++;
        return i;
    }

    private int VisibleLineCount() => Math.Max(1, (int)(_textHeight / _lineHeight));

    protected override void OnGotKeyboardFocus(KeyboardFocusChangedEventArgs e)
    {
        base.OnGotKeyboardFocus(e);
        _caretVisible = true;
        _caretTimer.Start();
        InvalidateVisual();
    }

    protected override void OnLostKeyboardFocus(KeyboardFocusChangedEventArgs e)
    {
        base.OnLostKeyboardFocus(e);
        _caretTimer.Stop();
        InvalidateVisual();
    }

    private static Brush Frozen(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }
}
