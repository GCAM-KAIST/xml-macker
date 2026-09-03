using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using XMLMacker.Core;
using XMLMacker.Shared;
using XMLMacker.Theme;

namespace XMLMacker.Editor;

/// <summary>
/// The top-level source-editor pane (WPF port of the Swift <c>SourceViewController</c>) and the sole
/// implementation of <see cref="ISourceEditor"/>. It composes the virtualized <see cref="HugeTextEditor"/>
/// (with its <see cref="GutterMargin"/>) filling the body, a header caption + loading spinner, and the
/// <see cref="MinimapControl"/> docked right, and owns everything the rest of the app needs to
/// read/patch/search/navigate the document: file/session loading, the <c>lineStarts</c> maintenance
/// policy, the 0.40 s source-changed debounce, per-pane zoom, all programmatic edit primitives, search,
/// and jump navigation. Every far jump realizes the viewport at the target BEFORE scrolling.
/// </summary>
public partial class SourceEditorControl : UserControl, ISourceEditor
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    private const string LineNumbersPrefKey = "xml-macker.showLineNumbers";
    private const string MinimapPrefKey = "xml-macker.showMinimap";

    // Curly quotes may have leaked in via smart-quote substitution elsewhere; accept them too.
    private const string DoubleQuotes = "\"“”";
    private const string SingleQuotes = "'‘’";

    private readonly HugeTextEditor _editor = new();
    private readonly MinimapControl _minimap = new();
    private readonly Grid _minimapHost = new();          // hide button above the minimap strip
    private readonly Border _minimapHide = new();
    private readonly TextBlock _minimapHideGlyph = new();
    private readonly Button _defineChip = new();

    private string? _url;
    private long _fileSize;
    private XmlTextEncoding _textEncoding = XmlTextEncoding.Utf8;
    private int _zoomStep;

    private bool _suppressMutation;          // true during programmatic loads (mutations excluded)
    private bool _applyingProgrammaticEdit;  // true during inspector-driven edits (no source-changed debounce)
    private bool _learnMode;

    private readonly System.Windows.Threading.DispatcherTimer _sourceDebounce;

    private System.Windows.Shapes.Path? _spinner;
    private Storyboard? _spinnerStoryboard;

    // ── ISourceEditor events ──────────────────────────────────────────────────────────────────────
    public event EventHandler? SourceChanged;
    public event EventHandler? FileLoaded;
    public event Action<string>? FileLoadFailed;
    public event Action<string>? LinkedFileRequested;
    public event Action? DefineSelectionRequested;
    public event Action? PrintSelectionRequested;
    public event Action<LLMTarget>? SendSelectionRequested;
    public event EventHandler? DocumentMutated;
    public event EventHandler? SelectionChanged;

    /// <summary>The composed virtualized editor (for host wiring that needs the raw control).</summary>
    public HugeTextEditor Editor => _editor;

    /// <summary>The composed minimap (host wires <see cref="MinimapControl.LineClicked"/> + snap lines).</summary>
    public MinimapControl Minimap => _minimap;

    /// <summary>Raised after the minimap is shown or hidden (its own hide button, the menu, or Settings).</summary>
    public event Action<bool>? MinimapVisibilityChanged;

    public XmlTextEncoding CurrentTextEncoding => _textEncoding;

    public SourceEditorControl()
    {
        InitializeComponent();

        // Compose the body: gutter | editor | (8 px gap) minimap column (hide button above the strip).
        GutterMargin gutter = _editor.Gutter;
        Grid.SetColumn(gutter, 0);
        Grid.SetColumn(_editor, 1);
        Grid.SetColumn(_minimapHost, 2);
        _minimapHost.Margin = new Thickness(XMMetric.PaneGap, 0, 0, 0);
        _minimap.Width = XMMetric.MinimapW;
        BuildMinimapHost();
        Body.Children.Add(gutter);
        Body.Children.Add(_editor);
        Body.Children.Add(_minimapHost);

        BuildDefineChip();

        _minimap.Attach(_editor);

        _editor.UndoStack = new EditorUndoStack();
        gutter.Visibility = IsLineNumberVisibilityPersistedOn ? Visibility.Visible : Visibility.Collapsed;
        _minimapHost.Visibility = IsMinimapVisibilityPersistedOn ? Visibility.Visible : Visibility.Collapsed;

        // Header font + spinner.
        XMFont.UiCaption.ApplyTo(HeaderLabel);
        BuildSpinner();

        // Source-changed debounce (0.40 s after typing stops).
        _sourceDebounce = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(0.40)
        };
        _sourceDebounce.Tick += (_, __) =>
        {
            _sourceDebounce.Stop();
            SourceChanged?.Invoke(this, EventArgs.Empty);
        };

        _editor.DocumentMutated += OnEditorMutated;
        _editor.SelectionChanged += (_, __) =>
        {
            UpdateDefineChip();
            SelectionChanged?.Invoke(this, EventArgs.Empty);
        };
        _editor.ViewportChanged += (_, __) => UpdateDefineChip();
        _editor.ControlClicked += TryOpenLinkedFileAt;
        _editor.LinkResolver = text => LinkedFile.Resolve(text, _url);   // _url is read at call time
        _editor.ContextMenu = new ContextMenu();
        _editor.ContextMenuOpening += OnEditorContextMenuOpening;
        Body.SizeChanged += (_, __) => UpdateDefineChip();

        MetricsScaleService.Instance.RebuildFonts += (_, __) => RebuildFonts();

        // Apply the initial font (composes global scale + zoom step).
        ApplyZoom();
    }

    private bool TryOpenLinkedFileAt(int documentOffset)
    {
        string? path = ResolveLinkedFileAt(documentOffset);
        if (path is null) return false;
        LinkedFileRequested?.Invoke(path);
        return true;
    }

    private string? ResolveLinkedFileAt(int documentOffset)
    {
        ITextBuffer? buffer = _editor.Buffer;
        if (buffer is null || string.IsNullOrEmpty(_url)) return null;
        int start = Math.Max(0, documentOffset - 450);
        int length = Math.Min(buffer.Length - start, 900);
        if (length <= 0) return null;
        string sample = buffer.Substring(start, length);
        int localOffset = documentOffset - start;
        foreach (string pattern in new[] { "[\"']([^\"'\r\n]{2,400})[\"']", ">([^<>\r\n]{2,400})<" })
        {
            foreach (Match match in Regex.Matches(sample, pattern))
            {
                Group value = match.Groups[1];
                if (localOffset < value.Index || localOffset > value.Index + value.Length) continue;
                string? path = LinkedFile.Resolve(value.Value, _url);
                if (path is not null) return path;
            }
        }
        return null;
    }

    private void OnEditorContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        ContextMenu menu = _editor.ContextMenu!;
        menu.Items.Clear();

        MenuItem Add(string header, Action action, bool enabled = true)
        {
            var item = new MenuItem { Header = header, IsEnabled = enabled };
            item.Click += (_, __) => action();
            menu.Items.Add(item);
            return item;
        }

        int offset = _editor.HitTestDocumentOffset(Mouse.GetPosition(_editor));
        if (ResolveLinkedFileAt(offset) is { } linkedPath)
        {
            Add($"Open Linked File: {System.IO.Path.GetFileName(linkedPath)}",
                () => LinkedFileRequested?.Invoke(linkedPath));
            menu.Items.Add(new Separator());
        }

        EditorUndoStack? undo = _editor.UndoStack;
        Add("Undo", () => { _editor.Undo(); }, undo?.CanUndo ?? false);
        Add("Redo", () => { _editor.Redo(); }, undo?.CanRedo ?? false);
        menu.Items.Add(new Separator());
        Add("Cut", _editor.CutSelectedText, !_editor.IsReadOnly && _editor.SelectionLength > 0);
        Add("Copy", _editor.CopySelectedText, _editor.SelectionLength > 0);
        Add("Paste", _editor.PasteClipboardText, !_editor.IsReadOnly && ClipboardHasText());
        Add("Select All", _editor.SelectAllText, _editor.DocumentLength > 0);

        if (_editor.SelectionLength > 0)
        {
            menu.Items.Add(new Separator());
            Add("Define in Learn", () => DefineSelectionRequested?.Invoke());

            var share = new MenuItem { Header = "Share Selection" };
            void AddShare(string header, Action action)
            {
                var item = new MenuItem { Header = header };
                item.Click += (_, __) => action();
                share.Items.Add(item);
            }

            foreach (LLMTarget target in LLMTargets.All)
            {
                LLMTarget captured = target;
                AddShare($"Send to {captured.DisplayName()}", () => SendSelectionRequested?.Invoke(captured));
            }
            share.Items.Add(new Separator());
            AddShare("Print Selection…", () => PrintSelectionRequested?.Invoke());
            menu.Items.Add(share);
        }
    }

    private static bool ClipboardHasText()
    {
        try { return Clipboard.ContainsText(); }
        catch { return false; }
    }

    private void BuildDefineChip()
    {
        _defineChip.Content = "Define";
        _defineChip.ToolTip = "Explain the selected XML in Learn";
        _defineChip.Padding = new Thickness(10, 3, 10, 3);
        _defineChip.MinWidth = 64;
        _defineChip.Height = 26;
        _defineChip.HorizontalAlignment = HorizontalAlignment.Left;
        _defineChip.VerticalAlignment = VerticalAlignment.Top;
        _defineChip.Visibility = Visibility.Collapsed;
        _defineChip.FontFamily = new FontFamily("Segoe UI");
        _defineChip.FontSize = 11;
        _defineChip.FontWeight = FontWeights.SemiBold;
        _defineChip.SetResourceReference(Control.BackgroundProperty, XMColor.Panel);
        _defineChip.SetResourceReference(Control.ForegroundProperty, XMColor.Text);
        _defineChip.SetResourceReference(Control.BorderBrushProperty, XMColor.HairlineS);
        _defineChip.Click += (_, __) => DefineSelectionRequested?.Invoke();
        Grid.SetColumn(_defineChip, 1);
        Panel.SetZIndex(_defineChip, int.MaxValue);
        Body.Children.Add(_defineChip);
    }

    /// <summary>Shows the selection-side Define button only while the Learn workspace is active.</summary>
    public void SetLearnMode(bool enabled)
    {
        _learnMode = enabled;
        UpdateDefineChip();
    }

    private void UpdateDefineChip()
    {
        if (!_learnMode || _editor.SelectionLength <= 0 || _editor.SelectionLength > 2_000_000)
        {
            _defineChip.Visibility = Visibility.Collapsed;
            return;
        }

        Rect caret = _editor.GetCharacterRect(_editor.SelectionStart + _editor.SelectionLength - 1);
        if (caret.Bottom < 0 || caret.Top > _editor.ActualHeight)
        {
            _defineChip.Visibility = Visibility.Collapsed;
            return;
        }

        _defineChip.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        double width = Math.Max(_defineChip.MinWidth, _defineChip.DesiredSize.Width);
        double x = Math.Clamp(caret.Right + 10, 8, Math.Max(8, _editor.ActualWidth - width - 8));
        double y = Math.Clamp(caret.Top - 1, 4, Math.Max(4, _editor.ActualHeight - _defineChip.Height - 4));
        _defineChip.Margin = new Thickness(x, y, 0, 0);
        _defineChip.Visibility = Visibility.Visible;
    }

    private void OnEditorMutated(object? sender, EventArgs e)
    {
        if (_suppressMutation) return;                 // programmatic loads are not mutations
        DocumentMutated?.Invoke(this, EventArgs.Empty);
        if (_applyingProgrammaticEdit) return;         // inspector refreshes itself; no source-changed debounce
        _sourceDebounce.Stop();
        _sourceDebounce.Start();
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  File / session
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    public void LoadFile(string url, long fileSize)
    {
        _url = url;
        _fileSize = fileSize;

        _suppressMutation = true;
        _editor.AttachBuffer(new TextBuffer(), new[] { 0 });
        _suppressMutation = false;
        _editor.IsReadOnly = true;

        HeaderLabel.Text = $"{SafeName(url)} · {Mb(fileSize)} MB · loading…";
        StartSpinner();

        var dispatcher = Dispatcher;
        Task.Run(() =>
        {
            try
            {
                byte[] bytes = File.ReadAllBytes(url);
                (string text, XmlTextEncoding encoding) = XmlTextEncoding.Decode(bytes);
                int[] starts = LineIndex.BuildLineStarts(text);
                dispatcher.Invoke(() => ApplyLoadedText(text, starts, encoding));
            }
            catch (Exception ex)
            {
                dispatcher.Invoke(() =>
                {
                    SetErrorHeader("Failed to read file");
                    FileLoadFailed?.Invoke(ex.Message);
                });
            }
        });
    }

    private void ApplyLoadedText(string text, int[] lineStarts, XmlTextEncoding encoding)
    {
        _textEncoding = encoding;
        _suppressMutation = true;
        _editor.AttachBuffer(new TextBuffer(text), lineStarts);
        _suppressMutation = false;

        _editor.IsReadOnly = false;
        _editor.UndoStack = new EditorUndoStack();   // fresh undo per freshly-loaded file
        ApplyZoom();

        int lineCount = lineStarts.Length;
        HeaderLabel.Text = $"{SafeName(_url)} · {Mb(_fileSize)} MB · {lineCount.ToString(Inv)} lines · {_textEncoding.DisplayName}";
        StopSpinner();

        _minimap.RefreshAfterLoad();
        FileLoaded?.Invoke(this, EventArgs.Empty);
    }

    private void SetErrorHeader(string message)
    {
        HeaderLabel.Text = message;
        StopSpinner();
        _editor.IsReadOnly = true;
    }

    public void AttachSession(string url, long fileSize, ITextBuffer storage, int[] lineStarts,
                              (double X, double Y) scrollOrigin, XmlTextEncoding textEncoding)
    {
        _url = url;
        _fileSize = fileSize;
        _textEncoding = textEncoding;

        _suppressMutation = true;
        _editor.AttachBuffer(storage, (lineStarts is { Length: > 0 }) ? lineStarts : new[] { 0 });
        _suppressMutation = false;

        _editor.IsReadOnly = false;
        _editor.SetHighlight(null, null);

        int lineCount = _editor.LineIndex.LineCount;
        HeaderLabel.Text = $"{SafeName(url)} · {Mb(fileSize)} MB · {lineCount.ToString(Inv)} lines · {_textEncoding.DisplayName}";
        StopSpinner();

        _editor.RealizeViewportAround(0);            // realize layout at doc start before restoring scroll
        RestoreScroll(scrollOrigin);
        _minimap.RefreshAfterLoad();
    }

    public void DetachToFreshStorage()
    {
        _suppressMutation = true;
        _editor.AttachBuffer(new TextBuffer(), new[] { 0 });  // /untitled.xml, size 0, lineStarts [0]
        _suppressMutation = false;

        _editor.UndoStack = new EditorUndoStack();
        _url = null;
        _fileSize = 0;
        _textEncoding = XmlTextEncoding.Utf8;
        HeaderLabel.Text = string.Empty;
        _editor.SetHighlight(null, null);
        _editor.IsReadOnly = true;
        _minimap.RefreshAfterLoad();
    }

    public void Clear()
    {
        _suppressMutation = true;
        _editor.AttachBuffer(new TextBuffer(), new[] { 0 });
        _suppressMutation = false;

        _editor.UndoStack = new EditorUndoStack();
        _editor.IsReadOnly = true;
        _editor.SetHighlight(null, null);
        HeaderLabel.Text = string.Empty;
        StopSpinner();
        _url = null;
        _fileSize = 0;
        _textEncoding = XmlTextEncoding.Utf8;
        _minimap.RefreshAfterLoad();
    }

    public void AdoptSavedDocument(string url, long fileSize, XmlTextEncoding textEncoding)
    {
        _url = url;
        _fileSize = fileSize;
        _textEncoding = textEncoding;
        HeaderLabel.Text = $"{SafeName(url)} · {Mb(fileSize)} MB · {_editor.LineIndex.LineCount.ToString(Inv)} lines · {_textEncoding.DisplayName}";
    }

    public (double X, double Y) SnapshotScroll() => (_editor.ScrollOffsetX, _editor.ScrollOffsetY);

    public void RestoreScroll((double X, double Y) origin)
    {
        _editor.ScrollOffsetX = origin.X;
        _editor.ScrollOffsetY = origin.Y;
    }

    public ITextBuffer? CurrentStorage => _editor.Buffer;

    public object? SessionUndoStack
    {
        get => _editor.UndoStack;
        set => _editor.UndoStack = value as EditorUndoStack;
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Highlight / navigation
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    public void ShowElement(XmlTreeNode node)
    {
        if (_editor.Buffer is null) return;
        int count = _editor.LineIndex.LineCount;
        int startLine = Math.Clamp(node.StartLine, 1, count);
        (int Start, int Length) landing = LineCharRange(startLine);

        _editor.RealizeViewportAround(landing.Start);
        _editor.MoveCaretTo(landing.Start);          // scrolls into view + paints caret

        (int Start, int Length)? box = CharRangeForElement(node);
        if (box is { } b && b.Length > 0)
        {
            _editor.RealizeViewportAround(b.Start + b.Length - 1);
            _editor.SetHighlight(landing, b);
        }
        else
        {
            _editor.SetHighlight(landing, null);
        }
    }

    public (int Start, int Length)? CharRangeForElement(XmlTreeNode node)
    {
        if (_editor.Buffer is null) return null;
        int docLen = _editor.DocumentLength;
        int count = _editor.LineIndex.LineCount;
        int[] starts = _editor.CurrentLineStarts;

        int startLine = Math.Clamp(node.StartLine, 1, count);
        int startOff = starts[startLine - 1];
        int endLineIdx = Math.Max(node.EndLine, node.StartLine) + 1;
        int endOff = (endLineIdx <= count) ? Math.Max(startOff, starts[endLineIdx - 1] - 1) : docLen;

        startOff = Math.Clamp(startOff, 0, docLen);
        endOff = Math.Clamp(endOff, 0, docLen);
        int length = Math.Max(0, Math.Min(endOff - startOff, docLen - startOff));
        return length > 0 ? (startOff, length) : null;
    }

    public int? ElementStartOffset(XmlTreeNode node)
    {
        int count = _editor.LineIndex.LineCount;
        int[] starts = _editor.CurrentLineStarts;
        int startLine = node.StartLine < 1 ? 1 : node.StartLine;
        if (startLine > count) return null;           // past doc end
        return starts[startLine - 1];
    }

    public void ScrollToLine(int line)
    {
        if (_editor.Buffer is null) return;
        int count = _editor.LineIndex.LineCount;
        line = Math.Clamp(line, 1, count);
        (int Start, int Length) r = LineCharRange(line);

        _editor.RealizeViewportAround(r.Start);
        _editor.MoveCaretTo(r.Start);
        _editor.SetHighlight(r, null);
    }

    public void RevealMatch((int Start, int Length) range)
    {
        _editor.RealizeViewportAround(range.Start);
        _editor.SelectRange(range.Start, range.Length);
        int line = _editor.LineIndex.LineForOffset(range.Start);
        _editor.SetHighlight(LineCharRange(line), null);
    }

    public int LineNumberForOffset(int offset) => _editor.LineIndex.LineForOffset(offset);

    public string LineText(int line, int cap = 300)
    {
        if (_editor.Buffer is null) return string.Empty;
        (int Start, int Length) r = LineCharRange(line);
        int take = Math.Min(r.Length, cap);
        if (take <= 0) return string.Empty;
        return _editor.Buffer.Substring(r.Start, take).Trim();
    }

    private (int Start, int Length) LineCharRange(int line)
    {
        LineIndex idx = _editor.LineIndex;
        int count = idx.LineCount;
        int docLen = _editor.DocumentLength;
        if (count <= 0) return (0, 0);
        line = Math.Clamp(line, 1, count);
        int start = idx.OffsetForLine(line);
        int end = (line < count) ? idx.OffsetForLine(line + 1) - 1 : docLen;
        if (end < start) end = start;
        return (start, end - start);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Bounded substrings
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    public (string Text, bool Truncated) Substring((int Start, int Length) range, int cap = 1_000_000)
    {
        ITextBuffer? buf = _editor.Buffer;
        if (buf is null) return (string.Empty, false);
        int docLen = buf.Length;
        int s = Math.Clamp(range.Start, 0, docLen);
        int l = Math.Clamp(range.Length, 0, docLen - s);
        bool truncated = l > cap;
        int take = Math.Min(l, cap);
        return (buf.Substring(s, take), truncated);
    }

    public (string Text, bool ReachedDocEnd) Substring(int fromOffset, int cap)
    {
        ITextBuffer? buf = _editor.Buffer;
        if (buf is null) return (string.Empty, true);
        int docLen = buf.Length;
        int s = Math.Clamp(fromOffset, 0, docLen);
        int end = Math.Min(s + Math.Max(0, cap), docLen);
        return (buf.Substring(s, end - s), end >= docLen);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Programmatic edits
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    public bool ApplyAttrEdit(XmlTreeNode node, string attrName, string newValue)
    {
        if (_editor.Buffer is null) return false;
        (int Start, int Length)? range = FindAttributeValueRange(node, attrName);
        if (range is null) return false;

        string escaped = EscapeAttr(newValue);
        _applyingProgrammaticEdit = true;
        try { _editor.ReplaceText(range.Value.Start, range.Value.Length, escaped, recordUndo: true, moveCaret: false); }
        finally { _applyingProgrammaticEdit = false; }

        for (int i = 0; i < node.Attributes.Count; i++)
        {
            if (node.Attributes[i].Name == attrName)
            {
                node.Attributes[i] = (attrName, newValue);
                break;
            }
        }
        return true;
    }

    public bool ApplyTagRename(XmlTreeNode node, string newName)
    {
        if (string.IsNullOrEmpty(newName)) return false;
        ITextBuffer? buf = _editor.Buffer;
        if (buf is null) return false;

        (int OpenStart, string TagText)? tag = OpeningTag(node);
        if (tag is null) return false;
        int openStart = tag.Value.OpenStart;
        string tagText = tag.Value.TagText;

        string oldName = node.Name;
        if (string.IsNullOrEmpty(oldName)) return false;

        // Verify "<oldName" + a valid delimiter at the recorded position (else the tree is stale).
        if (!tagText.StartsWith("<" + oldName, StringComparison.Ordinal)) return false;
        char delim = tagText.Length > 1 + oldName.Length ? tagText[1 + oldName.Length] : '>';
        if (delim is not (' ' or '>' or '/' or '\t' or '\r' or '\n')) return false;

        bool selfClose = tagText.Length >= 2 && tagText[^2] == '/';
        int openNameStart = openStart + 1;
        int openNameLen = oldName.Length;

        // Validate the closing tag BEFORE any edit (so a refusal touches nothing).
        int closeNameStart = -1, closeNameLen = 0;
        if (!selfClose)
        {
            int count = _editor.LineIndex.LineCount;
            int[] starts = _editor.CurrentLineStarts;
            int endLine = Math.Clamp(Math.Max(node.EndLine, node.StartLine), 1, count);
            int lineStart = starts[endLine - 1];
            int lineEnd = (endLine < count) ? starts[endLine] - 1 : buf.Length;
            if (lineEnd < lineStart) lineEnd = lineStart;
            string lineText = buf.Substring(lineStart, lineEnd - lineStart);

            string needle = "</" + oldName + ">";
            int firstIdx = lineText.IndexOf(needle, StringComparison.Ordinal);
            if (firstIdx < 0) return false;                                   // no close tag in the end line
            if (lineText.IndexOf(needle, firstIdx + 1, StringComparison.Ordinal) >= 0) return false; // ambiguous → refuse
            int closeAbs = lineStart + firstIdx;
            if (closeAbs <= openStart) return false;                          // close must be after open
            closeNameStart = closeAbs + 2;                                    // skip "</"
            closeNameLen = oldName.Length;
        }

        EditorUndoStack? undo = _editor.UndoStack;
        _applyingProgrammaticEdit = true;
        undo?.BeginGroup();
        try
        {
            // Replace back-to-front (close first, then open) so offsets don't shift mid-edit.
            if (!selfClose)
                _editor.ReplaceText(closeNameStart, closeNameLen, newName, recordUndo: true, moveCaret: false);
            _editor.ReplaceText(openNameStart, openNameLen, newName, recordUndo: true, moveCaret: false);
        }
        finally
        {
            undo?.EndGroup();
            _applyingProgrammaticEdit = false;
        }

        node.Name = newName;
        return true;
    }

    public bool ApplyTextEdit(XmlTreeNode node, string newText)
    {
        if (_editor.Buffer is null) return false;
        (int Start, int Length)? range = FindTextContentRange(node);
        if (range is null) return false;                    // self-closing / content not found

        string escaped = EscapeText(newText);
        _applyingProgrammaticEdit = true;
        try { _editor.ReplaceText(range.Value.Start, range.Value.Length, escaped, recordUndo: true, moveCaret: false); }
        finally { _applyingProgrammaticEdit = false; }

        node.TextValue = newText;
        return true;
    }

    public void RefreshTextValue(XmlTreeNode node)
    {
        // Early-out: any child ELEMENT → textValue is "" without a (potentially multi-MB) content scan.
        foreach (XmlTreeNode child in node.Children)
            if (child.Kind == NodeKind.Element) { node.TextValue = ""; return; }

        (int Start, int Length)? range = FindTextContentRange(node);
        ITextBuffer? buf = _editor.Buffer;
        if (range is null || buf is null) { node.TextValue = ""; return; }

        string raw = buf.Substring(range.Value.Start, range.Value.Length);
        node.TextValue = DecodeEntities(raw).Trim();
    }

    public void RefreshAttributes(XmlTreeNode node)
    {
        (int OpenStart, string TagText)? tag = OpeningTag(node);
        if (tag is null) return;
        string tagText = tag.Value.TagText;

        // Tag name (propagates a source-edit rename to the tree/inspector).
        Match nm = Regex.Match(tagText, "<\\s*([A-Za-z_][\\w\\-.:]*)");
        if (nm.Success)
        {
            string newName = nm.Groups[1].Value;
            if (newName != node.Name) node.Name = newName;
        }

        // Attributes.
        var list = new List<(string Name, string Value)>();
        foreach (Match m in Regex.Matches(tagText, AttributePattern()))
        {
            string an = m.Groups[1].Value;
            string av = m.Groups[2].Success ? m.Groups[2].Value : (m.Groups[3].Success ? m.Groups[3].Value : "");
            list.Add((an, DecodeEntities(av)));
        }
        node.Attributes = list;
    }

    public bool ApplyFix((int Start, int Length) range, string original, string replacement)
    {
        ITextBuffer? buf = _editor.Buffer;
        if (buf is null) return false;
        int docLen = buf.Length;
        int start = range.Start, len = range.Length;
        if (start < 0 || len < 0 || start > docLen || start + len > docLen) return false;

        if (len > 0)
        {
            string current = buf.Substring(start, len);
            if (!string.Equals(current, original, StringComparison.Ordinal)) return false; // stale → refuse
        }

        _editor.RealizeViewportAround(start);
        _editor.ReplaceText(start, len, replacement, recordUndo: true, moveCaret: false);
        _editor.MoveCaretTo(start + replacement.Length);   // caret past the replacement, scroll into view
        int line = _editor.LineIndex.LineForOffset(start);
        _editor.SetHighlight(LineCharRange(line), null);
        return true;
    }

    public bool ApplyFix(FixIt fix) => ApplyFix(fix.Range, fix.Original, fix.Replacement);

    public bool PerformEdit((int Start, int Length) range, string replacement)
    {
        if (_editor.Buffer is null) return false;
        return _editor.ReplaceText(range.Start, range.Length, replacement, recordUndo: true, moveCaret: true);
    }

    public int ReplaceAll(string find, string with, bool caseSensitive, bool wholeWord, (int Start, int Length) range)
    {
        ITextBuffer? buf = _editor.Buffer;
        if (buf is null || string.IsNullOrEmpty(find)) return 0;

        int docLen = buf.Length;
        int start = Math.Clamp(range.Start, 0, docLen);
        int len = Math.Clamp(range.Length, 0, docLen - start);
        if (len > 100_000_000) return -1;                  // too large to copy on a 655 MB file

        string segment = buf.Substring(start, len);
        (string result, int count) = ReplaceInSegment(segment, find, with, caseSensitive, wholeWord);
        if (count == 0) return 0;

        PerformEdit((start, len), result);
        RefreshLineStarts();                               // bulk edit shifts everything
        return count;
    }

    private static (string Result, int Count) ReplaceInSegment(string segment, string find, string with,
                                                               bool caseSensitive, bool wholeWord)
    {
        StringComparison cmp = caseSensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        var sb = new StringBuilder(segment.Length);
        int i = 0, count = 0, flen = find.Length;
        while (true)
        {
            int idx = segment.IndexOf(find, i, cmp);
            if (idx < 0) { sb.Append(segment, i, segment.Length - i); break; }

            bool ok = true;
            if (wholeWord)
            {
                char before = idx > 0 ? segment[idx - 1] : '\0';
                char after = idx + flen < segment.Length ? segment[idx + flen] : '\0';
                ok = !IsWordChar(before) && !IsWordChar(after);
            }

            if (ok)
            {
                sb.Append(segment, i, idx - i);
                sb.Append(with);
                count++;
                i = idx + flen;
            }
            else
            {
                sb.Append(segment, i, idx - i + 1);        // keep the char, advance past it
                i = idx + 1;
            }
        }
        return (sb.ToString(), count);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Search
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    public (int Start, int Length)? MatchRange(string needle, int fromPosition, bool forward,
                                               bool caseSensitive, bool wholeWord, (int Start, int Length) scope)
    {
        ITextBuffer? buf = _editor.Buffer;
        if (buf is null || string.IsNullOrEmpty(needle)) return null;

        int docLen = buf.Length;
        int scopeStart = Math.Clamp(scope.Start, 0, docLen);
        int scopeEnd = Math.Clamp(scope.Start + scope.Length, 0, docLen);
        if (scopeEnd <= scopeStart) return null;
        int pos = Math.Clamp(fromPosition, scopeStart, scopeEnd);

        int? hit;
        if (forward)
        {
            hit = FindForward(buf, needle, pos, scopeEnd, scopeEnd, caseSensitive, wholeWord)
                  ?? FindForward(buf, needle, scopeStart, pos, scopeEnd, caseSensitive, wholeWord);
        }
        else
        {
            hit = FindLast(buf, needle, scopeStart, pos, scopeEnd, caseSensitive, wholeWord)
                  ?? FindLast(buf, needle, pos, scopeEnd, scopeEnd, caseSensitive, wholeWord);
        }
        return hit is { } h ? (h, needle.Length) : null;
    }

    public IReadOnlyList<(int Start, int Length)> AllMatchRanges(string needle, bool caseSensitive, bool wholeWord,
                                                                 (int Start, int Length) scope, int cap = 5000)
    {
        var results = new List<(int Start, int Length)>();
        ITextBuffer? buf = _editor.Buffer;
        if (buf is null || string.IsNullOrEmpty(needle)) return results;

        int docLen = buf.Length;
        int scopeStart = Math.Clamp(scope.Start, 0, docLen);
        int scopeEnd = Math.Clamp(scope.Start + scope.Length, 0, docLen);
        int nlen = needle.Length;
        int pos = scopeStart;

        while (results.Count < cap)
        {
            int? hit = FindForward(buf, needle, pos, scopeEnd, scopeEnd, caseSensitive, wholeWord);
            if (hit is not { } h) break;
            results.Add((h, nlen));
            pos = h + Math.Max(1, nlen);
        }
        return results;
    }

    public (int Start, int Length) FullDocumentRange => (0, _editor.DocumentLength);

    public string DocumentText => _editor.Buffer?.GetText() ?? string.Empty;

    // Earliest match start in [from, startBoundExclusive) whose end is <= readLimit.
    private static int? FindForward(ITextBuffer buf, string needle, int from, int startBoundExclusive,
                                    int readLimit, bool caseSensitive, bool wholeWord)
    {
        int nlen = needle.Length;
        if (nlen == 0 || startBoundExclusive <= from) return null;
        StringComparison cmp = caseSensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        int overlap = nlen - 1;
        const int Window = 1 << 20;

        int pos = from;
        while (pos < startBoundExclusive)
        {
            int hardEnd = Math.Min(startBoundExclusive, pos + Window); // accept starts in [pos, hardEnd)
            int readEnd = Math.Min(readLimit, hardEnd + overlap);
            if (readEnd <= pos) break;
            string chunk = buf.Substring(pos, readEnd - pos);

            int searchFrom = 0;
            while (true)
            {
                int idx = chunk.IndexOf(needle, searchFrom, cmp);
                if (idx < 0) break;
                int abs = pos + idx;
                if (abs >= hardEnd) break;                 // belongs to the next window
                if (abs + nlen > readLimit) break;         // out of scope
                if (!wholeWord || WholeWordOK(buf, abs, nlen)) return abs;
                searchFrom = idx + 1;
                if (pos + searchFrom >= hardEnd) break;
            }
            pos = hardEnd;
        }
        return null;
    }

    // Greatest match start in [low, highExclusive) whose end is <= readLimit.
    private static int? FindLast(ITextBuffer buf, string needle, int low, int highExclusive,
                                 int readLimit, bool caseSensitive, bool wholeWord)
    {
        int nlen = needle.Length;
        if (nlen == 0 || highExclusive <= low) return null;
        StringComparison cmp = caseSensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        int overlap = nlen - 1;
        const int Window = 1 << 20;

        int hi = highExclusive;
        while (hi > low)
        {
            int winStart = Math.Max(low, hi - Window);
            int readEnd = Math.Min(readLimit, hi + overlap);
            if (readEnd <= winStart) { hi = winStart; continue; }
            string chunk = buf.Substring(winStart, readEnd - winStart);

            int startLimit = hi - winStart;                // accept starts with local idx < startLimit
            int best = -1, idx = 0;
            while (true)
            {
                int f = chunk.IndexOf(needle, idx, cmp);
                if (f < 0 || f >= startLimit) break;
                int abs = winStart + f;
                if (abs + nlen <= readLimit && (!wholeWord || WholeWordOK(buf, abs, nlen))) best = f;
                idx = f + 1;
            }
            if (best >= 0) return winStart + best;
            hi = winStart;
        }
        return null;
    }

    private static bool WholeWordOK(ITextBuffer buf, int start, int len)
    {
        char before = start > 0 ? buf.CharAt(start - 1) : '\0';
        char after = start + len < buf.Length ? buf.CharAt(start + len) : '\0';
        return !IsWordChar(before) && !IsWordChar(after);
    }

    // XML "word" chars: digits, A-Z, a-z, '_', '-', or any char > 0x7F.
    private static bool IsWordChar(char c)
        => c is (>= '0' and <= '9') or (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') || c == '_' || c == '-' || c > 0x7F;

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Zoom / theme
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void ApplyZoom()
    {
        double size = Math.Clamp(12 * XMFont.GlobalScale + _zoomStep, 5, 40);
        _editor.ApplyFontSize(size);
    }

    public void ZoomIn() { _zoomStep++; ApplyZoom(); }
    public void ZoomOut() { _zoomStep--; ApplyZoom(); }
    public void ZoomReset() { _zoomStep = 0; ApplyZoom(); }

    public void RebuildFonts()
    {
        XMFont.UiCaption.ApplyTo(HeaderLabel);
        ApplyZoom();                                        // editor + gutter digit font
        _minimap.InvalidateVisual();
    }

    public void RebuildColors()
    {
        _editor.RebuildColors();
        _minimap.RebuildColors();
    }

    public void RefreshLineStarts()
    {
        _editor.RefreshLineStarts();
        _minimap.RefreshAfterLoad();
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Line numbers
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    public void SetLineNumbersVisible(bool visible)
    {
        _editor.Gutter.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        AppSettings.Instance.SetBool(LineNumbersPrefKey, visible);
        _editor.Gutter.InvalidateVisual();
    }

    public bool IsLineNumbersVisible => _editor.Gutter.Visibility == Visibility.Visible;

    public bool IsLineNumberVisibilityPersistedOn => AppSettings.Instance.GetBool(LineNumbersPrefKey, true);

    public int[] CurrentLineStarts => _editor.CurrentLineStarts;

    // ==============================================================================================
    //  Minimap column (the strip plus its own hide button)
    // ==============================================================================================

    /// <summary>Builds the minimap column: a small hide button on top, the minimap strip below it.</summary>
    private void BuildMinimapHost()
    {
        _minimapHost.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _minimapHost.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        _minimapHideGlyph.Text = "✕";
        _minimapHideGlyph.FontFamily = new FontFamily("Segoe UI");
        _minimapHideGlyph.FontSize = 8;
        _minimapHideGlyph.HorizontalAlignment = HorizontalAlignment.Center;
        _minimapHideGlyph.VerticalAlignment = VerticalAlignment.Center;
        _minimapHideGlyph.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text3);

        _minimapHide.Child = _minimapHideGlyph;
        _minimapHide.Width = 13;
        _minimapHide.Height = 13;
        _minimapHide.CornerRadius = new CornerRadius(3);
        _minimapHide.Background = Brushes.Transparent;
        _minimapHide.HorizontalAlignment = HorizontalAlignment.Right;
        _minimapHide.Margin = new Thickness(0, 0, 1, 2);
        _minimapHide.Cursor = Cursors.Hand;
        _minimapHide.ToolTip = "Hide the minimap (View menu, Show Minimap, or Ctrl+Shift+M, brings it back)";
        _minimapHide.MouseEnter += (_, __) => _minimapHideGlyph.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text);
        _minimapHide.MouseLeave += (_, __) => _minimapHideGlyph.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text3);
        _minimapHide.MouseLeftButtonUp += (_, e) => { e.Handled = true; SetMinimapVisible(false); };

        Grid.SetRow(_minimapHide, 0);
        Grid.SetRow(_minimap, 1);
        _minimapHost.Children.Add(_minimapHide);
        _minimapHost.Children.Add(_minimap);
    }

    /// <summary>Shows/hides the minimap column and persists the choice to <c>XMLMacker.showMinimap</c>.</summary>
    public void SetMinimapVisible(bool visible)
    {
        if (IsMinimapVisible == visible && IsMinimapVisibilityPersistedOn == visible) return;
        _minimapHost.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        AppSettings.Instance.SetBool(MinimapPrefKey, visible);
        if (visible) _minimap.InvalidateVisual();
        MinimapVisibilityChanged?.Invoke(visible);
    }

    /// <summary>Whether the minimap column is currently on screen.</summary>
    public bool IsMinimapVisible => _minimapHost.Visibility == Visibility.Visible;

    /// <summary>The persisted minimap preference; <b>default ON</b> when the key is absent (first run).</summary>
    public bool IsMinimapVisibilityPersistedOn => AppSettings.Instance.GetBool(MinimapPrefKey, true);

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Opening-tag / attribute / content scanning
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    // The opening tag "<...>" (inclusive) and its absolute start, scanned in-place up to 16 KB.
    private (int OpenStart, string TagText)? OpeningTag(XmlTreeNode node)
    {
        ITextBuffer? buf = _editor.Buffer;
        if (buf is null) return null;
        int? so = ElementStartOffset(node);
        if (so is null) return null;

        int start = so.Value;
        int docLen = buf.Length;
        if (start >= docLen) return null;
        int cap = Math.Min(16384, docLen - start);
        string window = buf.Substring(start, cap);

        int lt = window.IndexOf('<');
        if (lt < 0) return null;

        char quote = '\0';
        for (int k = lt; k < window.Length; k++)
        {
            char c = window[k];
            if (quote != '\0') { if (c == quote) quote = '\0'; }
            else if (c is '"' or '\'') quote = c;
            else if (c == '>') return (start + lt, window.Substring(lt, k - lt + 1));
        }
        return null;
    }

    private (int Start, int Length)? FindAttributeValueRange(XmlTreeNode node, string attrName)
    {
        (int OpenStart, string TagText)? tag = OpeningTag(node);
        if (tag is null) return null;

        Match m = Regex.Match(tag.Value.TagText, AttributeValuePattern(attrName));
        if (!m.Success) return null;
        Group? g = m.Groups[1].Success ? m.Groups[1] : (m.Groups[2].Success ? m.Groups[2] : null);
        if (g is null) return null;
        return (tag.Value.OpenStart + g.Index, g.Length);
    }

    // Content between the opening ">" and the matching "</name" (null for self-closing), scanned up to 4 MB.
    private (int Start, int Length)? FindTextContentRange(XmlTreeNode node)
    {
        ITextBuffer? buf = _editor.Buffer;
        if (buf is null) return null;
        (int OpenStart, string TagText)? tag = OpeningTag(node);
        if (tag is null) return null;

        int openStart = tag.Value.OpenStart;
        string tagText = tag.Value.TagText;
        if (tagText.Length >= 2 && tagText[^2] == '/') return null; // self-closing

        int contentStart = openStart + tagText.Length;    // char after '>'
        int docLen = buf.Length;
        if (contentStart > docLen) return null;

        // The window is the element's own extent, not a flat slice of the document. Copying up to four
        // megabytes per element turned selecting a row with many children into gigabytes of copying on
        // the interface thread, and a document can decide how many children a row has.
        int cap = docLen - contentStart;
        int[] starts = _editor.CurrentLineStarts;
        int endLine = node.EndLine;                       // 1-based line of the closing tag
        if (endLine > 0 && endLine <= starts.Length)
        {
            int endOffset = endLine < starts.Length ? starts[endLine] : docLen;
            if (endOffset > contentStart) cap = Math.Min(cap, endOffset - contentStart);
        }
        cap = Math.Min(cap, 4 * 1024 * 1024);
        if (cap <= 0) return null;
        string window = buf.Substring(contentStart, cap);

        int idx = window.IndexOf("</" + node.Name, StringComparison.Ordinal);
        if (idx < 0) return null;
        return (contentStart, idx);
    }

    // ── XML escape / decode ──────────────────────────────────────────────────────────────────────

    private static string EscapeAttr(string s)
        => (s ?? "").Replace("&", "&amp;").Replace("<", "&lt;").Replace("\"", "&quot;");

    private static string EscapeText(string s)
        => (s ?? "").Replace("&", "&amp;").Replace("<", "&lt;");

    private static string DecodeEntities(string s)
        => s.Replace("&lt;", "<").Replace("&gt;", ">").Replace("&quot;", "\"").Replace("&apos;", "'").Replace("&amp;", "&");

    private static string AttributeValuePattern(string attrName)
        => "(?<![\\w\\-.:])" + Regex.Escape(attrName) + "\\s*=\\s*(?:["
           + DoubleQuotes + "]([^" + DoubleQuotes + "]*)[" + DoubleQuotes + "]|["
           + SingleQuotes + "]([^" + SingleQuotes + "]*)[" + SingleQuotes + "])";

    private static string AttributePattern()
        => "([A-Za-z_][\\w\\-.:]*)\\s*=\\s*(?:["
           + DoubleQuotes + "]([^" + DoubleQuotes + "]*)[" + DoubleQuotes + "]|["
           + SingleQuotes + "]([^" + SingleQuotes + "]*)[" + SingleQuotes + "])";

    // ── Header / spinner helpers ─────────────────────────────────────────────────────────────────

    private static string SafeName(string? url)
    {
        if (string.IsNullOrEmpty(url)) return "";
        try { return System.IO.Path.GetFileName(url); }
        catch { return url; }
    }

    private static string Mb(long bytes) => (bytes / 1048576.0).ToString("0.0", Inv);

    private void BuildSpinner()
    {
        var figure = new PathFigure { StartPoint = new Point(7, 2), IsClosed = false };
        figure.Segments.Add(new ArcSegment(new Point(2, 7), new Size(5, 5), 0, true, SweepDirection.Clockwise, true));
        var geo = new PathGeometry();
        geo.Figures.Add(figure);

        _spinner = new System.Windows.Shapes.Path
        {
            Width = 14,
            Height = 14,
            StrokeThickness = 2,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            Data = geo,
            RenderTransformOrigin = new Point(0.5, 0.5),
            RenderTransform = new RotateTransform()
        };
        _spinner.SetResourceReference(Shape.StrokeProperty, XMColor.Accent);
        SpinnerHost.Children.Add(_spinner);

        var anim = new DoubleAnimation(0, 360, new Duration(TimeSpan.FromSeconds(0.9)))
        {
            RepeatBehavior = RepeatBehavior.Forever
        };
        Storyboard.SetTarget(anim, _spinner);
        Storyboard.SetTargetProperty(anim,
            new PropertyPath("(UIElement.RenderTransform).(RotateTransform.Angle)"));
        _spinnerStoryboard = new Storyboard();
        _spinnerStoryboard.Children.Add(anim);
    }

    private void StartSpinner()
    {
        SpinnerHost.Visibility = Visibility.Visible;
        _spinnerStoryboard?.Begin(_spinner, true);
    }

    private void StopSpinner()
    {
        if (_spinner is not null) _spinnerStoryboard?.Stop(_spinner);
        SpinnerHost.Visibility = Visibility.Collapsed;
    }
}
