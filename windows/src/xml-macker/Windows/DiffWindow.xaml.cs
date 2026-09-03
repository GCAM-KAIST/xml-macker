using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using XMLMacker.Core;
using XMLMacker.Shared;

namespace XMLMacker.Windows;

/// <summary>Which real document a copy-hunk edits, passed to the host's <c>ApplyEdit</c> callback.</summary>
public enum DiffSide { Left, Right }

/// <summary>
/// Side-by-side diff window. Two aligned no-wrap panes with mirrored
/// scrolling, coloured hunk bands, a lazy element-tree sidebar that scopes navigation, hunk
/// navigation with an anchor-pending state machine, and copy-hunk-into-the-real-document routed
/// through the injected <see cref="ApplyEdit"/> callback.
/// </summary>
public partial class DiffWindow : Window
{
    private const string PlacementKey = "xml-mackerDiff";
    // 64 MB per side (characters): a bigger file is refused with a message instead of stalling.
    private const int PerSideCharCap = 64 * 1024 * 1024;

    // Keep the window alive while shown (the Swift `selfRef` trick).
    private static readonly HashSet<DiffWindow> Live = new();

    private string _leftName;
    private string _rightName;

    /// <summary>Host: the open tabs this window may offer when a side changes.</summary>
    public Func<IReadOnlyList<(string Name, string Path)>>? OpenFilesProvider { get; set; }

    /// <summary>Host: put a file on a side (null path = show the file picker). The host calls
    /// <see cref="ReplaceSide"/> when the text is ready.</summary>
    public Action<DiffSide, string?>? ChangeFileRequested { get; set; }
    private string _leftText;
    private string _rightText;

    /// <summary>
    /// Applies a copy-hunk into the REAL document behind a side (host routes: active tab → undoable
    /// edit; parked tab → direct storage edit + dirty). Returns success. Same contract as the Swift
    /// <c>applyEdit</c>.
    /// </summary>
    public Func<DiffSide, (int Start, int Length), string, bool>? ApplyEdit { get; set; }

    // ---- aligned build state ----
    private List<string> _lLines = new();
    private List<string> _rLines = new();
    private int[] _leftLineStarts = { 0 };
    private int[] _rightLineStarts = { 0 };
    private List<Hunk> _hunks = new();
    private List<int> _rowForLeftLine = new();
    private List<int> _rowForRightLine = new();
    private int[] _hunkRowStart = Array.Empty<int>();
    private int[] _hunkRowSpan = Array.Empty<int>();

    private readonly DiffTextView _leftView = new();
    private readonly DiffTextView _rightView = new();
    private bool _syncing;

    // ---- scoped navigation state machine ----
    private List<int> _scopedIndices = new();
    private int _scopedPos;
    private bool _anchorPending;
    private XmlTreeNode? _scopeNode;
    private (int Lower, int Upper)? _scopeLines;

    // ---- tree sidebar ----
    private XmlTreeNode? _tree;

    /// <summary>Which file the sidebar tree (and the scope filter) belongs to. The file-name row switches it.</summary>
    private DiffSide _treeSide = DiffSide.Left;
    private bool _treeParseStarted;
    private int _treeGeneration;
    private readonly ObservableCollection<DiffTreeRow> _treeRows = new();
    private readonly HashSet<int> _expanded = new();
    private bool _treeUpdating;
    private bool _tooLarge;
    private bool _isComparing;
    private string? _compareError;
    private int _compareGeneration;
    private bool _closed;

    private sealed class CompareModel
    {
        public required List<string> LeftLines { get; init; }
        public required List<string> RightLines { get; init; }
        public required int[] LeftLineStarts { get; init; }
        public required int[] RightLineStarts { get; init; }
        public required List<Hunk> Hunks { get; init; }
        public required List<int> RowForLeftLine { get; init; }
        public required List<int> RowForRightLine { get; init; }
        public required int[] HunkRowStart { get; init; }
        public required int[] HunkRowSpan { get; init; }
        public required string[] LeftOutput { get; init; }
        public required string[] RightOutput { get; init; }
        public required byte[] LeftBands { get; init; }
        public required byte[] RightBands { get; init; }
        /// <summary>How the two files were aligned, for the status line: "by element" or the fallback reason.</summary>
        public required string Note { get; init; }
    }

    public DiffWindow(string leftName, string leftText, string rightName, string rightText)
    {
        InitializeComponent();
        ZoomGestures.Attach(this, () => ZoomDiff(ZoomGestures.Step), () => ZoomDiff(1 / ZoomGestures.Step), () => ZoomDiff(0));   // Ctrl + wheel, Ctrl +/-, Ctrl 0

        _leftName = leftName;
        _rightName = rightName;
        _leftText = leftText;
        _rightText = rightText;

        Title = $"Diff, {leftName} ⟷ {rightName}";
        LeftNameLabel.Text = leftName;
        RightNameLabel.Text = rightName;

        LeftHost.Child = _leftView;
        RightHost.Child = _rightView;

        // A filler gap on the LEFT means those lines exist only in the RIGHT file, and vice versa.
        _leftView.OtherSideName = rightName;
        _rightView.OtherSideName = leftName;

        _leftView.VerticalOffsetChanged += (_, _) => Mirror(_leftView, _rightView);
        _rightView.VerticalOffsetChanged += (_, _) => Mirror(_rightView, _leftView);
        _leftView.SelectionChanged += (_, _) => OnRowSelection(_leftView, _rightView);
        _rightView.SelectionChanged += (_, _) => OnRowSelection(_rightView, _leftView);
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Escape && _leftView.SelectedRows.Count > 0)
            { ClearRowSelection(); e.Handled = true; }
        };

        PrevBtn.Click += (_, _) => PrevHunk();
        NextBtn.Click += (_, _) => NextHunk();
        _lineMode = AppSettings.Instance.GetBool(LineModeKey, false);
        LineModeCheck.IsChecked = _lineMode;
        LineModeCheck.Checked += (_, _) => SetLineMode(true);
        LineModeCheck.Unchecked += (_, _) => SetLineMode(false);
        TreeBtn.Click += (_, _) => ToggleTree();
        ScopeBtn.Click += (_, _) => ClearScope();
        CopyLeftBtn.Click += (_, _) => CopyHunk(DiffSide.Left);
        CopyRightBtn.Click += (_, _) => CopyHunk(DiffSide.Right);
        UndoCopyBtn.Click += (_, _) => UndoLastCopy();
        LeftChangeBtn.Click += (_, _) => ShowChangeMenu(DiffSide.Left, LeftChangeBtn);
        RightChangeBtn.Click += (_, _) => ShowChangeMenu(DiffSide.Right, RightChangeBtn);
        CopyLeftBtn.ToolTip = $"Replace this difference in {rightName} with the lines from {leftName}";
        CopyRightBtn.ToolTip = $"Replace this difference in {leftName} with the lines from {rightName}";

        TreeList.ItemsSource = _treeRows;
        TreeList.SelectionChanged += OnTreeSelectionChanged;
        TreeList.AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler(OnTreeButtonClick));
        TreeList.MouseDoubleClick += OnTreeDoubleClick;

        SourceInitialized += (_, _) => WindowPlacement.Restore(this, PlacementKey);
        Closed += OnClosed;

        Recompare(scrollToFirst: true);
    }

    // ================= changing a compared file =================

    private void ShowChangeMenu(DiffSide side, Button anchor)
    {
        if (ChangeFileRequested is null) { NativeMethods.Beep(); return; }
        string current = side == DiffSide.Left ? _leftName : _rightName;
        var menu = new ContextMenu { PlacementTarget = anchor, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };

        var open = OpenFilesProvider?.Invoke() ?? Array.Empty<(string, string)>();
        int offered = 0;
        foreach ((string name, string path) in open)
        {
            if (string.Equals(name, current, StringComparison.OrdinalIgnoreCase)) continue;
            string p = path;
            var item = new MenuItem { Header = name, ToolTip = path };
            item.Click += (_, _) => ChangeFileRequested(side, p);
            menu.Items.Add(item);
            offered++;
        }
        if (offered > 0) menu.Items.Add(new Separator());
        var pick = new MenuItem { Header = "Open another file…" };
        pick.Click += (_, _) => ChangeFileRequested(side, null);
        menu.Items.Add(pick);
        menu.IsOpen = true;
    }

    /// <summary>
    /// Replaces one side of the comparison and compares again from the top. Called by the host once the
    /// new file's text is available (immediately for an open tab, after loading for a new file).
    /// </summary>
    public void ReplaceSide(DiffSide side, string name, string text)
    {
        if (_closed) return;
        if (side == DiffSide.Left)
        {
            _leftName = name; _leftText = text;
            LeftNameLabel.Text = name;
            _rightView.OtherSideName = name;
        }
        else
        {
            _rightName = name; _rightText = text;
            RightNameLabel.Text = name;
            _leftView.OtherSideName = name;
        }
        if (side == _treeSide)
        {
            InvalidateTree();
            if (TreePane.Visibility == Visibility.Visible) StartTreeParse();
        }
        _copyUndo.Clear();
        UndoCopyBtn.IsEnabled = false;
        _treeNote = "";
        Title = $"Diff, {_leftName} ⟷ {_rightName}";
        CopyLeftBtn.ToolTip = $"Replace this difference in {_rightName} with the lines from {_leftName}";
        CopyRightBtn.ToolTip = $"Replace this difference in {_leftName} with the lines from {_rightName}";
        _scopeNode = null; _scopeLines = null;
        ScopeBtn.Visibility = Visibility.Collapsed;
        Recompare(scrollToFirst: true);
    }

    /// <summary>Shows the window and keeps a strong reference while it is on screen.</summary>
    public void Present()
    {
        Live.Add(this);
        Show();
        Activate();
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        _closed = true;
        _compareGeneration++; // discard any background comparison still in flight
        _treeGeneration++;
        WindowPlacement.Save(this, PlacementKey);
        Live.Remove(this);
    }

    // ================= mirrored scrolling =================

    private void Mirror(DiffTextView from, DiffTextView to)
    {
        if (_syncing) return;
        _syncing = true;
        to.VerticalOffset = from.VerticalOffset;
        _syncing = false;
    }

    // ================= building the aligned views =================

    private static List<string> SplitLines(string s)
    {
        var parts = new List<string>(s.Split('\n'));
        if (parts.Count > 0 && parts[parts.Count - 1].Length == 0)
            parts.RemoveAt(parts.Count - 1);   // kill phantom trailing line
        return parts;
    }

    private static int[] LineStarts(List<string> lines, int textLength)
    {
        var arr = new int[lines.Count + 1];
        int acc = 0;
        for (int i = 0; i < lines.Count; i++)
        {
            arr[i] = acc;
            acc += lines[i].Length + 1;   // UTF-16 length + newline
        }
        // The last source line is not guaranteed to end with LF. Keep the
        // sentinel at the real text length so a final-line copy never asks
        // the host to replace one character beyond the document.
        arr[lines.Count] = textLength;
        return arr;
    }

    private static string CopyTextForLines(List<string> lines, string sourceText,
                                           int start, int count)
    {
        if (count == 0) return "";
        bool rangeHasFinalNewline = start + count < lines.Count || sourceText.EndsWith('\n');
        return string.Join("\n", lines.GetRange(start, count)) +
               (rangeHasFinalNewline ? "\n" : "");
    }

    private async void Recompare(bool scrollToFirst)
    {
        int generation = ++_compareGeneration;
        if (_leftText.Length > PerSideCharCap || _rightText.Length > PerSideCharCap)
        {
            _isComparing = false;
            _tooLarge = true;
            _compareError = null;
            ClearCompareModel();
            _leftView.SetContent(Array.Empty<string>(), Array.Empty<byte>());
            _rightView.SetContent(Array.Empty<string>(), Array.Empty<byte>());
            PrevBtn.IsEnabled = NextBtn.IsEnabled = CopyLeftBtn.IsEnabled = CopyRightBtn.IsEnabled = false;
            UpdateStatus();
            return;
        }

        _tooLarge = false;
        _isComparing = true;
        _compareError = null;
        UpdateStatus();
        PrevBtn.IsEnabled = NextBtn.IsEnabled = CopyLeftBtn.IsEnabled = CopyRightBtn.IsEnabled = false;

        string leftText = _leftText;
        string rightText = _rightText;
        CompareModel model;
        var clock = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            // ConfigureAwait(false): do NOT depend on whatever synchronisation context happens to be
            // ambient; the hop back to the UI thread is made explicitly below, the way the Mac version
            // and ReparseFromEditor do it. The two views and every field touched after this line are
            // UI-thread objects.
            model = await Task.Run(() => BuildCompareModel(leftText, rightText)).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            await Dispatcher.InvokeAsync(() =>
            {
                if (_closed || generation != _compareGeneration) return;
                _isComparing = false;
                _compareError = $"Couldn't compare the files, {ex.Message}";
                UpdateStatus();
            });
            return;
        }

        if (!Dispatcher.CheckAccess())
        {
            await Dispatcher.InvokeAsync(() => AdoptCompareModel(model, generation, scrollToFirst, clock));
            return;
        }
        AdoptCompareModel(model, generation, scrollToFirst, clock);
    }

    /// <summary>UI-thread half of <see cref="Recompare"/>: installs the freshly built model into the views.</summary>
    private void AdoptCompareModel(CompareModel model, int generation, bool scrollToFirst,
                                   System.Diagnostics.Stopwatch clock)
    {
        if (_closed || generation != _compareGeneration) return;

        _lLines = model.LeftLines;
        _rLines = model.RightLines;
        _leftLineStarts = model.LeftLineStarts;
        _rightLineStarts = model.RightLineStarts;
        _hunks = model.Hunks;
        _rowForLeftLine = model.RowForLeftLine;
        _rowForRightLine = model.RowForRightLine;
        _hunkRowStart = model.HunkRowStart;
        _hunkRowSpan = model.HunkRowSpan;

        // A copy that leaves a file malformed (typically a PARTIAL element copied line by line) drops the
        // comparison from "by element" to "line by line". Say so loudly in the status line,
        _compareNote = model.Note;
        // A copy that just turned an element-aware comparison into a line-by-line one broke the XML: say so.
        if (_lastCopyNote.Length > 0 && _noteBeforeCopy == "by element" && _compareNote.StartsWith("line by line", StringComparison.Ordinal))
            _lastCopyNote = "⚠ That copy broke the XML (" + _compareNote.Replace("line by line, ", "") + "). Undo Copy is on the right., " + _lastCopyNote;
        _noteBeforeCopy = "";

        long modelMs = clock.ElapsedMilliseconds;
        _leftView.SetContent(model.LeftOutput, model.LeftBands);
        _rightView.SetContent(model.RightOutput, model.RightBands);
        _isComparing = false;
        Diag.Log($"diff compare: model {modelMs} ms, views {clock.ElapsedMilliseconds - modelMs} ms, "
               + $"{model.Hunks.Count} hunks, {model.LeftOutput.Length} aligned rows");

        RebuildScopedIndices();
        int keptRow = _keepRow >= 0 && _keepRow < _leftView.RowCount ? _keepRow : -1;   // -1: past the end
        if (scrollToFirst) _scopedPos = 0;
        else if (_keepRow >= 0 && _hunks.Count > 0)
        {
            // The first difference at or BELOW the row that follows what the copy just put in, never
            // the block's first row (a line-by-line copy splits a block; its top part lies above the
            // copied line and used to win). If nothing is left at or below (the copied difference was
            // the last one in the scope), stay put and highlight nothing.
            int first = keptRow < 0 ? _hunks.Count : FirstHunkEndingAfterRow(keptRow);
            int pos = 0;
            while (pos < _scopedIndices.Count && _scopedIndices[pos] < first) pos++;
            _pastEnd = pos >= _scopedIndices.Count;
            _scopedPos = Math.Min(pos, Math.Max(0, _scopedIndices.Count - 1));
        }
        if (_scopedPos >= _scopedIndices.Count) _scopedPos = Math.Max(0, _scopedIndices.Count - 1);
        bool hasDifferences = _scopedIndices.Count > 0;
        PrevBtn.IsEnabled = NextBtn.IsEnabled = CopyLeftBtn.IsEnabled = CopyRightBtn.IsEnabled = hasDifferences;
        UpdateCopyButtons();
        if (hasDifferences && _pastEnd)
        {
            // Stay exactly where the walk was; nothing is current until Next/Previous is pressed.
            _syncing = true;
            _leftView.SetEmphasis(-1, 0);
            _rightView.SetEmphasis(-1, 0);
            _leftView.ClearSelection();
            _rightView.ClearSelection();
            if (_keepOffset >= 0) { _leftView.VerticalOffset = _keepOffset; _rightView.VerticalOffset = _keepOffset; }
            _syncing = false;
            CopyLeftBtn.IsEnabled = CopyRightBtn.IsEnabled = false;
            StatusField.Text = $"{_lastCopyNote}No differences after this point{ScopeSuffix}{WholeFileHint}, press ◀ Previous, or Next ▶ to start from the top{CompareNoteSuffix}{TreeNoteSuffix}";
            _lastCopyNote = "";
        }
        else if (hasDifferences) FocusCurrentHunk(_keepOffset >= 0 ? _keepOffset : null);
        else UpdateStatus();
        _keepRow = -1;
        _keepOffset = -1;
        // In line mode land on the row right after the copied line while it is still inside the current
        // difference (the rest of a block being copied line by line); otherwise on the difference's
        // first line. Never when nothing is current (past the end): that would select a row above.
        if (hasDifferences && _lineMode && !_anchorPending && !_pastEnd)
        {
            int idx = _scopedIndices[_scopedPos];
            int row = _hunkRowStart[idx];
            if (keptRow >= row && keptRow < row + _hunkRowSpan[idx]) row = keptRow;
            SelectRow(row, idx);
        }
    }

    private void ClearCompareModel()
    {
        _lLines = new List<string>();
        _rLines = new List<string>();
        _leftLineStarts = new[] { 0 };
        _rightLineStarts = new[] { 0 };
        _hunks = new List<Hunk>();
        _rowForLeftLine = new List<int>();
        _rowForRightLine = new List<int>();
        _hunkRowStart = Array.Empty<int>();
        _hunkRowSpan = Array.Empty<int>();
        _scopedIndices = new List<int>();
        _scopedPos = 0;
        _anchorPending = false;
    }

    private static CompareModel BuildCompareModel(string leftText, string rightText)
    {
        List<string> leftLines = SplitLines(leftText);
        List<string> rightLines = SplitLines(rightText);
        int[] leftLineStarts = LineStarts(leftLines, leftText.Length);
        int[] rightLineStarts = LineStarts(rightLines, rightText.Length);

        // Element-aware first. A GCAM override file lists the same sectors in a different order and
        // omits most of them; a line comparison of that is a wall of "removed" and "added". Pairing
        // elements by tag + name/year, whatever their order, gives a comparison a person can read.
        // Falls back to the plain line comparison when either file is not well-formed XML, or when the
        // walker cannot partition it cleanly.
        List<StructuralDiff.Segment>? segments = null;
        string note;
        try
        {
            ParseResult lp = new XmlStreamParser().ParseText(leftText);
            ParseResult rp = new XmlStreamParser().ParseText(rightText);
            if (lp.Errors.Count > 0)
                note = $"line by line, left file has an XML error at line {lp.Errors[0].Line}";
            else if (rp.Errors.Count > 0)
                note = $"line by line, right file has an XML error at line {rp.Errors[0].Line}";
            else
            {
                segments = StructuralDiff.Align(lp.Root, rp.Root, leftLines, rightLines);
                note = segments is null ? "line by line, elements share lines" : "by element";
            }
        }
        catch (Exception ex)
        {
            note = $"line by line, {ex.Message}";
        }

        if (segments is not null)
            return BuildFromSegments(leftText, rightText, leftLines, rightLines, leftLineStarts, rightLineStarts, segments, note);

        List<Hunk> hunks = DiffEngine.Diff(leftLines, rightLines);

        var leftOutput = new List<string>();
        var rightOutput = new List<string>();
        var leftBands = new List<byte>();
        var rightBands = new List<byte>();
        var rowForLeftLine = new List<int>(leftLines.Count);
        var rowForRightLine = new List<int>(rightLines.Count);
        var hunkRowStart = new int[hunks.Count];
        var hunkRowSpan = new int[hunks.Count];

        void AppendLeft(int from, int count, byte band)
        {
            for (int index = 0; index < count; index++)
            {
                rowForLeftLine.Add(leftOutput.Count);
                leftOutput.Add(leftLines[from + index]);
                leftBands.Add(band);
            }
        }

        void FillLeft(int count)
        {
            for (int index = 0; index < count; index++)
            {
                leftOutput.Add("");
                leftBands.Add(DiffTextView.BandFiller);
            }
        }

        void AppendRight(int from, int count, byte band)
        {
            for (int index = 0; index < count; index++)
            {
                rowForRightLine.Add(rightOutput.Count);
                rightOutput.Add(rightLines[from + index]);
                rightBands.Add(band);
            }
        }

        void FillRight(int count)
        {
            for (int index = 0; index < count; index++)
            {
                rightOutput.Add("");
                rightBands.Add(DiffTextView.BandFiller);
            }
        }

        int leftIndex = 0;
        int rightIndex = 0;
        for (int hunkIndex = 0; hunkIndex < hunks.Count; hunkIndex++)
        {
            Hunk hunk = hunks[hunkIndex];
            AppendLeft(leftIndex, hunk.LeftStart - leftIndex, DiffTextView.BandNone);
            AppendRight(rightIndex, hunk.RightStart - rightIndex, DiffTextView.BandNone);

            hunkRowStart[hunkIndex] = leftOutput.Count;
            int paired = Math.Min(hunk.LeftCount, hunk.RightCount);
            AppendLeft(hunk.LeftStart, paired, DiffTextView.BandChanged);
            AppendRight(hunk.RightStart, paired, DiffTextView.BandChanged);

            int leftExtra = hunk.LeftCount - paired;
            int rightExtra = hunk.RightCount - paired;
            if (leftExtra > 0)
            {
                AppendLeft(hunk.LeftStart + paired, leftExtra, DiffTextView.BandRemoved);
                FillRight(leftExtra);
            }
            if (rightExtra > 0)
            {
                AppendRight(hunk.RightStart + paired, rightExtra, DiffTextView.BandAdded);
                FillLeft(rightExtra);
            }

            leftIndex = hunk.LeftStart + hunk.LeftCount;
            rightIndex = hunk.RightStart + hunk.RightCount;
            hunkRowSpan[hunkIndex] = leftOutput.Count - hunkRowStart[hunkIndex];
        }

        AppendLeft(leftIndex, leftLines.Count - leftIndex, DiffTextView.BandNone);
        AppendRight(rightIndex, rightLines.Count - rightIndex, DiffTextView.BandNone);

        return new CompareModel
        {
            LeftLines = leftLines,
            RightLines = rightLines,
            LeftLineStarts = leftLineStarts,
            RightLineStarts = rightLineStarts,
            Hunks = hunks,
            RowForLeftLine = rowForLeftLine,
            RowForRightLine = rowForRightLine,
            HunkRowStart = hunkRowStart,
            HunkRowSpan = hunkRowSpan,
            LeftOutput = leftOutput.ToArray(),
            RightOutput = rightOutput.ToArray(),
            LeftBands = leftBands.ToArray(),
            RightBands = rightBands.ToArray(),
            Note = note,
        };
    }

    /// <summary>Turns the element-aware segment list into the same aligned-row model the line path builds.</summary>
    private static CompareModel BuildFromSegments(string leftText, string rightText,
        List<string> leftLines, List<string> rightLines, int[] leftLineStarts, int[] rightLineStarts,
        List<StructuralDiff.Segment> segments, string note)
    {
        var leftOutput = new List<string>(leftLines.Count + 1024);
        var rightOutput = new List<string>(rightLines.Count + 1024);
        var leftBands = new List<byte>(leftLines.Count + 1024);
        var rightBands = new List<byte>(rightLines.Count + 1024);
        var rowForLeftLine = new List<int>(leftLines.Count);
        var rowForRightLine = new List<int>(rightLines.Count);
        var hunks = new List<Hunk>();
        var hunkRowStart = new List<int>();
        var hunkRowSpan = new List<int>();

        foreach (StructuralDiff.Segment seg in segments)
        {
            if (!seg.IsHunk)
            {
                for (int k = 0; k < seg.LeftCount; k++)
                {
                    rowForLeftLine.Add(leftOutput.Count);
                    leftOutput.Add(leftLines[seg.LeftStart + k]);  leftBands.Add(DiffTextView.BandNone);
                    rowForRightLine.Add(rightOutput.Count);
                    rightOutput.Add(rightLines[seg.RightStart + k]); rightBands.Add(DiffTextView.BandNone);
                }
                continue;
            }

            hunkRowStart.Add(leftOutput.Count);
            int paired = Math.Min(seg.LeftCount, seg.RightCount);
            for (int k = 0; k < paired; k++)
            {
                rowForLeftLine.Add(leftOutput.Count);
                leftOutput.Add(leftLines[seg.LeftStart + k]);   leftBands.Add(DiffTextView.BandChanged);
                rowForRightLine.Add(rightOutput.Count);
                rightOutput.Add(rightLines[seg.RightStart + k]); rightBands.Add(DiffTextView.BandChanged);
            }
            for (int k = paired; k < seg.LeftCount; k++)
            {
                rowForLeftLine.Add(leftOutput.Count);
                leftOutput.Add(leftLines[seg.LeftStart + k]); leftBands.Add(DiffTextView.BandRemoved);
                rightOutput.Add("");                          rightBands.Add(DiffTextView.BandFiller);
            }
            for (int k = paired; k < seg.RightCount; k++)
            {
                leftOutput.Add("");                             leftBands.Add(DiffTextView.BandFiller);
                rowForRightLine.Add(rightOutput.Count);
                rightOutput.Add(rightLines[seg.RightStart + k]); rightBands.Add(DiffTextView.BandAdded);
            }
            hunkRowSpan.Add(leftOutput.Count - hunkRowStart[^1]);
            hunks.Add(new Hunk(seg.LeftStart, seg.LeftCount, seg.RightStart, seg.RightCount));
        }

        return new CompareModel
        {
            LeftLines = leftLines,
            RightLines = rightLines,
            LeftLineStarts = leftLineStarts,
            RightLineStarts = rightLineStarts,
            Hunks = hunks,
            RowForLeftLine = rowForLeftLine,
            RowForRightLine = rowForRightLine,
            HunkRowStart = hunkRowStart.ToArray(),
            HunkRowSpan = hunkRowSpan.ToArray(),
            LeftOutput = leftOutput.ToArray(),
            RightOutput = rightOutput.ToArray(),
            LeftBands = leftBands.ToArray(),
            RightBands = rightBands.ToArray(),
            Note = note,
        };
    }

    // ================= scoped navigation =================

    private void RebuildScopedIndices()
    {
        _scopedIndices = new List<int>();
        if (_scopeLines is { } range)
        {
            for (int i = 0; i < _hunks.Count; i++)
            {
                var h = _hunks[i];
                int hStart = _treeSide == DiffSide.Left ? h.LeftStart : h.RightStart;
                int hCount = _treeSide == DiffSide.Left ? h.LeftCount : h.RightCount;
                int hEnd = hCount > 0 ? hStart + hCount - 1 : hStart;
                if (hStart <= range.Upper && hEnd >= range.Lower)
                    _scopedIndices.Add(i);
            }
        }
        else
        {
            for (int i = 0; i < _hunks.Count; i++) _scopedIndices.Add(i);
        }
    }

    private void ClearScope()
    {
        _scopeNode = null;
        _scopeLines = null;
        RebuildScopedIndices();
        if (_scopedPos >= _scopedIndices.Count) _scopedPos = Math.Max(0, _scopedIndices.Count - 1);
        _anchorPending = false;
        ScopeBtn.Visibility = Visibility.Collapsed;
        ScopeBtn.ToolTip = "Stop limiting to the selected element, walk every difference again";
        UpdateStatus();
    }

    /// <summary>Attribute names that identify an element to a reader, in the order the Mac version uses.</summary>
    private static readonly HashSet<string> ScopeKeyNames =
        new(StringComparer.Ordinal) { "name", "year", "id", "key", "type" };

    /// <summary>The scoped element as it reads on screen, e.g. <c>region EU-12</c>. Empty when unscoped.</summary>
    private string _scopeLabel = "";

    /// <summary>
    /// ", inside region EU-12 only". Naming only the TAG (the old behaviour) was useless on a GCAM file
    /// where every one of 32 regions reads "&lt;region&gt;": the header could not say WHICH
    /// region the 825 differences had been counted inside.
    /// </summary>
    private string ScopeSuffix
    {
        get
        {
            if (_scopeNode == null) { _scopeLabel = ""; return ""; }

            string? key = null;
            foreach ((string Name, string Value) a in _scopeNode.Attributes)
                if (ScopeKeyNames.Contains(a.Name)) { key = a.Value; break; }
            if (key is null && _scopeNode.Attributes.Count > 0) key = _scopeNode.Attributes[0].Value;

            _scopeLabel = string.IsNullOrEmpty(key)
                ? $"<{_scopeNode.DisplayLabel}>"
                : $"{_scopeNode.DisplayLabel} {key}";
            return $", inside {_scopeLabel} only";
        }
    }

    /// <summary>How many differences exist outside the scope, shown so the restriction is unmissable.</summary>
    private string WholeFileHint => _scopeNode != null ? $" ({_hunks.Count:N0} in the whole file)" : "";

    /// <summary>"by element", or why the comparison had to fall back to lines.</summary>
    private string _compareNote = "";

    /// <summary>Where the sidebar tree had to stop because of an XML error, or empty.</summary>
    private string _treeNote = "";
    private string TreeNoteSuffix => _treeNote.Length > 0 ? $"  ·  {_treeNote}" : "";
    private string CompareNoteSuffix => _compareNote.Length > 0 ? $"  ·  {_compareNote}" : "";

    private void UpdateStatus()
    {
        if (_isComparing)
        {
            StatusField.Text = "Comparing…";
            return;
        }
        if (_tooLarge)
        {
            StatusField.Text = "One side is over 64 MB, too large to diff";
            return;
        }
        if (_compareError is { Length: > 0 } error)
        {
            StatusField.Text = error;
            return;
        }

        int count = _scopedIndices.Count;
        if (count == 0)
        {
            StatusField.Text = (_hunks.Count == 0
                ? "No differences, the files are identical"
                : $"No differences{ScopeSuffix}") + CompareNoteSuffix + TreeNoteSuffix;
            return;
        }
        if (_anchorPending)
        {
            string s = count == 1 ? "" : "s";
            StatusField.Text = $"{count} difference{s}{HunkSizeNote}{ScopeSuffix}, press Next ▶{WholeFileHint}{CompareNoteSuffix}{TreeNoteSuffix}";
            return;
        }
        StatusField.Text = $"{_lastCopyNote}{LinePrefix}Difference {_scopedPos + 1} of {count}{HunkSizeNote}{SelectionNote}{ScopeSuffix}{WholeFileHint}{CompareNoteSuffix}{TreeNoteSuffix}";
        _lastCopyNote = "";
    }

    private void NextHunk()
    {
        if (_isComparing || _tooLarge || _compareError is not null)
        {
            NativeMethods.Beep();
            UpdateStatus();
            return;
        }
        if (_scopedIndices.Count == 0) { NativeMethods.Beep(); UpdateStatus(); return; }
        if (_pastEnd) { _pastEnd = false; _scopedPos = 0; FocusCurrentHunk(); return; }   // nothing below: start from the top
        if (_lineMode) { StepLine(+1); return; }
        if (_anchorPending) { FocusCurrentHunk(); return; }
        _scopedPos = (_scopedPos + 1) % _scopedIndices.Count;
        FocusCurrentHunk();
    }

    private void PrevHunk()
    {
        if (_isComparing || _tooLarge || _compareError is not null)
        {
            NativeMethods.Beep();
            UpdateStatus();
            return;
        }
        if (_scopedIndices.Count == 0) { NativeMethods.Beep(); UpdateStatus(); return; }
        if (_pastEnd) { _pastEnd = false; _scopedPos = _scopedIndices.Count - 1; FocusCurrentHunk(); return; }   // the nearest one above
        if (_lineMode) { StepLine(-1); return; }
        if (_anchorPending) { _scopedPos = _scopedIndices.Count - 1; }
        else _scopedPos = (_scopedPos - 1 + _scopedIndices.Count) % _scopedIndices.Count;
        FocusCurrentHunk();
    }

    // ================= line-by-line mode =================

    private const string LineModeKey = "xml-macker.diffLineMode";
    private bool _lineMode;

    private void SetLineMode(bool on)
    {
        _lineMode = on;
        AppSettings.Instance.SetBool(LineModeKey, on);
        if (on && _scopedIndices.Count > 0 && !_anchorPending)
        {
            int idx = _scopedIndices[_scopedPos];
            SelectRow(_hunkRowStart[idx], idx);   // start on the first line of the current difference
        }
        else
        {
            UpdateCopyButtons();
            UpdateStatus();
        }
    }

    /// <summary>
    /// Moves the one-line selection by <paramref name="delta"/> rows. Leaving a difference at either end
    /// steps into the next or previous difference (wrapping, like block mode).
    /// </summary>
    private void StepLine(int delta)
    {
        int count = _scopedIndices.Count;
        int idx = _scopedIndices[_scopedPos];
        int start = _hunkRowStart[idx], span = _hunkRowSpan[idx];
        (int selStart, int selCount) = _leftView.SelectedRows;
        bool inside = selCount > 0 && selStart >= start && selStart < start + span;

        int row;
        if (_anchorPending || !inside)
        {
            _anchorPending = false;
            row = delta > 0 ? start : start + span - 1;      // first press lands on an edge of the current block
        }
        else
        {
            row = selStart + delta;
            if (row >= start + span)
            {
                _scopedPos = (_scopedPos + 1) % count;
                idx = _scopedIndices[_scopedPos];
                row = _hunkRowStart[idx];
            }
            else if (row < start)
            {
                _scopedPos = (_scopedPos - 1 + count) % count;
                idx = _scopedIndices[_scopedPos];
                row = _hunkRowStart[idx] + _hunkRowSpan[idx] - 1;
            }
        }
        SelectRow(row, idx);
    }

    /// <summary>Selects exactly one row on both sides, emphasises its difference and scrolls to it.</summary>
    private void SelectRow(int row, int idx)
    {
        _syncing = true;
        _leftView.SetSelection(row, 1);
        _rightView.SetSelection(row, 1);
        _leftView.SetEmphasis(_hunkRowStart[idx], _hunkRowSpan[idx]);
        _rightView.SetEmphasis(_hunkRowStart[idx], _hunkRowSpan[idx]);
        _leftView.EnsureRowVisible(row);
        _rightView.VerticalOffset = _leftView.VerticalOffset;
        _syncing = false;
        UpdateCopyButtons();
        UpdateStatus();
    }

    /// <summary>"Line 3 of 108 in ", only in line mode, when one row is selected inside the current difference.</summary>
    private string LinePrefix
    {
        get
        {
            if (!_lineMode || SelectionInCurrentHunk() is not { } s) return "";
            int idx = _scopedIndices[_scopedPos];
            return $"Line {s.Start - _hunkRowStart[idx] + 1:N0} of {_hunkRowSpan[idx]:N0} in ";
        }
    }

    private void FocusCurrentHunk(double? keepOffset = null)
    {
        _anchorPending = false;
        _pastEnd = false;
        CopyLeftBtn.IsEnabled = CopyRightBtn.IsEnabled = _scopedIndices.Count > 0;
        // Moving to another difference drops any row selection from the previous one.
        _leftView.ClearSelection();
        _rightView.ClearSelection();
        UpdateCopyButtons();
        UpdateStatus();
        if (_scopedIndices.Count == 0 || _scopedPos < 0 || _scopedPos >= _scopedIndices.Count) return;
        int idx = _scopedIndices[_scopedPos];
        if (idx < 0 || idx >= _hunkRowStart.Length) return;
        int row = _hunkRowStart[idx];
        int span = _hunkRowSpan[idx];

        _syncing = true;
        _leftView.SetEmphasis(row, span);
        _rightView.SetEmphasis(row, span);
        if (keepOffset is { } o) _leftView.VerticalOffset = o;   // stay where the user was...
        _leftView.EnsureRowVisible(row);                            // ...unless that leaves the difference off screen
        _rightView.VerticalOffset = _leftView.VerticalOffset;
        _syncing = false;
    }

    private void JumpToTreeLine(int line1Based)
    {
        int row = RowForLine(_treeSide, line1Based - 1);
        if (row < 0) return;
        _syncing = true;
        _leftView.SetEmphasis(row, 1);
        _rightView.SetEmphasis(row, 1);
        _leftView.EnsureRowVisible(row);
        _rightView.VerticalOffset = _leftView.VerticalOffset;
        _syncing = false;
    }

    // ================= copy hunk =================

    private void CopyHunk(DiffSide from)
    {
        if (_tooLarge || _isComparing || _compareError is not null)
        {
            NativeMethods.Beep();
            return;
        }
        if (_scopedIndices.Count == 0 || _scopedPos < 0 || _scopedPos >= _scopedIndices.Count)
        { NativeMethods.Beep(); return; }

        int hunkIdx = _scopedIndices[_scopedPos];
        var h = _hunks[hunkIdx];
        (int srcStart, int srcCount, int dstStart, int dstCount) = CopyRange(h, hunkIdx, from);
        int anchorRow = SelectionInCurrentHunk() is { } picked ? picked.Start : _hunkRowStart[hunkIdx];   // first row being copied

        // Line by line must still move whole elements: a selected line that only opens an element (or
        // only closes one) takes its element along, on both sides, before anything is written.
        int widened = WidenSelectionToWholeElement(hunkIdx, from);
        if (widened > 0)
        {
            (srcStart, srcCount, dstStart, dstCount) = CopyRange(h, hunkIdx, from);
            if (SelectionInCurrentHunk() is { } wide) anchorRow = wide.Start;
        }
        List<string> srcLines = from == DiffSide.Left ? _lLines : _rLines;
        string sourceText = from == DiffSide.Left ? _leftText : _rightText;
        string replacement = CopyTextForLines(srcLines, sourceText, srcStart, srcCount);

        int[] dstStarts = from == DiffSide.Left ? _rightLineStarts : _leftLineStarts;
        if (dstStart < 0 || dstStart + dstCount > dstStarts.Length - 1) { NativeMethods.Beep(); return; }

        int rangeStart = dstStarts[dstStart];
        int rangeLen = dstStarts[dstStart + dstCount] - dstStarts[dstStart];
        DiffSide target = from == DiffSide.Left ? DiffSide.Right : DiffSide.Left;

        // Refuse to break the file quietly. A copy that moves an opening tag without its closing tag (or
        // the reverse) leaves the target malformed: the tree then stops at that point and the comparison
        // drops to line mode. Check both the fragment going in and the fragment being replaced.
        string targetTextNow = target == DiffSide.Left ? _leftText : _rightText;
        string removedText = rangeStart <= targetTextNow.Length
            ? targetTextNow.Substring(rangeStart, Math.Min(rangeLen, targetTextNow.Length - rangeStart))
            : "";
        if (ConfirmUnbalancedCopies && !_copyForced && (!IsBalancedFragment(replacement) || !IsBalancedFragment(removedText)))
        {
            int hunkRows = _hunkRowSpan[hunkIdx];
            MessageBoxResult answer = MessageBox.Show(this,
                "This copy would move an opening tag without its closing tag (or the other way round) and leave "
                + $"{(target == DiffSide.Left ? _leftName : _rightName)} with broken XML.\n\n"
                + $"YES, copy the whole difference block instead ({hunkRows:N0} lines, complete elements)\n"
                + "NO, copy exactly these lines anyway (Undo Copy can put them back)\n"
                + "CANCEL, do nothing",
                "This copy would break the XML", MessageBoxButton.YesNoCancel, MessageBoxImage.Warning);
            if (answer == MessageBoxResult.Cancel) return;
            if (answer == MessageBoxResult.Yes)
            {
                _leftView.ClearSelection();
                _rightView.ClearSelection();
                _copyForced = true;          // the whole block is complete elements; do not ask again
                try { CopyHunk(from); } finally { _copyForced = false; }
                return;
            }
        }

        var clock = System.Diagnostics.Stopwatch.StartNew();
        Diag.Log($"diff copy: start (hunk {_scopedIndices[_scopedPos]}, {srcCount} lines, {replacement.Length} chars)");
        bool ok = ApplyEdit?.Invoke(target, (rangeStart, rangeLen), replacement) ?? false;
        Diag.Log($"diff copy: host applied={ok} in {clock.ElapsedMilliseconds} ms");
        if (!ok) { NativeMethods.Beep(); StatusField.Text = "Couldn't apply the change"; return; }
        string targetName = target == DiffSide.Left ? _leftName : _rightName;
        string whole = widened > 0 ? " (the whole element: one line alone would break the XML)" : "";
        _lastCopyNote = srcCount > 0
            ? $"Copied {srcCount:N0} line{(srcCount == 1 ? "" : "s")} into {targetName}{whole}, "
            : $"Removed {dstCount:N0} line{(dstCount == 1 ? "" : "s")} from {targetName}{whole}, ";
        _copyUndo.Push((target, rangeStart, replacement.Length, removedText, anchorRow));
        UndoCopyBtn.IsEnabled = true;
        _noteBeforeCopy = _compareNote;

        // Mirror the edit into this window's own copy, then re-diff (fast because of prefix/suffix trim).
        string targetText = target == DiffSide.Left ? _leftText : _rightText;
        int safeLen = Math.Min(rangeLen, Math.Max(0, targetText.Length - rangeStart));
        string updated = targetText.Substring(0, Math.Min(rangeStart, targetText.Length))
                       + replacement
                       + targetText.Substring(Math.Min(rangeStart + safeLen, targetText.Length));
        // Continue from the row right after the copied lines (srcCount rows from the anchor), or, when
        // lines were only removed, from the row now standing in their place (the anchor itself).
        RememberPlace(anchorRow + srcCount);
        if (target == DiffSide.Left) _leftText = updated; else _rightText = updated;
        if (target == _treeSide)
        {
            InvalidateTree(keepScope: true, editLine: dstStart, lineDelta: CountLines(replacement) - CountLines(removedText));
            if (TreePane.Visibility == Visibility.Visible) StartTreeParse();
        }

        Diag.Log($"diff copy: texts patched in {clock.ElapsedMilliseconds} ms, recomparing");
        Recompare(scrollToFirst: false);
    }

    /// <summary>Prefix for the next status line after a copy, so the copy is visible even
    /// when the next difference looks just like the previous one (two filler walls in a row).</summary>
    private string _lastCopyNote = "";

    // ================= copy safety: balance check and undo =================

    /// <summary>Tests can turn the confirmation off; the app never does.</summary>
    internal bool ConfirmUnbalancedCopies = true;

    // "Stay in place" after a copy or an undo: the row that was current and the viewport position,
    // consumed by the next AdoptCompareModel, which then picks the difference at that row.
    private int _keepRow = -1;
    private double _keepOffset = -1;

    /// <summary>True after a copy/undo left no difference at or below the current position: nothing is current.</summary>
    private bool _pastEnd;

    private static int CountLines(string s)
    {
        int n = 0;
        foreach (char c in s) if (c == '\n') n++;
        return n;
    }

    private static int LineOfOffset(int[] lineStarts, int offset)
    {
        int lo = 0, hi = lineStarts.Length - 1;
        while (lo < hi)
        {
            int mid = (lo + hi + 1) / 2;
            if (lineStarts[mid] <= offset) lo = mid; else hi = mid - 1;
        }
        return lo;
    }

    /// <summary>
    /// "Stay in place" after a copy or an undo. <paramref name="row"/> is the aligned row to continue
    /// from: the row right after the lines a copy put in (they become "same" rows at the very rows they
    /// were selected on), the row now standing where lines were removed, or the row an undo restores a
    /// difference at. The next AdoptCompareModel makes the first difference ending after that row
    /// current, never one above it.
    /// <para>Rows, not line numbers: rows above an edit are the same in the new alignment, whereas the
    /// element-aware comparison pairs same-named elements wherever they sit, so a line number on one
    /// side can map to a row far away. And not the block's first row (the old way): a line-by-line copy
    /// splits a block, and the top part above the copied line used to win, "the selection goes up".</para>
    /// </summary>
    private void RememberPlace(int row)
    {
        _keepRow = row;
        _keepOffset = _leftView.VerticalOffset;
    }

    /// <summary>Index of the first difference whose rows end after <paramref name="row"/> (Count when none).</summary>
    private int FirstHunkEndingAfterRow(int row)
    {
        int lo = 0, hi = _hunkRowStart.Length;
        while (lo < hi)
        {
            int mid = (lo + hi) / 2;
            if (_hunkRowStart[mid] + _hunkRowSpan[mid] <= row) lo = mid + 1; else hi = mid;
        }
        return lo;
    }

    /// <summary>The aligned row showing line <paramref name="line"/> (0-based) of <paramref name="side"/>, or -1.</summary>
    private int RowForLine(DiffSide side, int line)
    {
        List<int> map = side == DiffSide.Left ? _rowForLeftLine : _rowForRightLine;
        return line >= 0 && line < map.Count ? map[line] : -1;
    }
    private bool _copyForced;
    private string _noteBeforeCopy = "";

    /// <summary>Every copy applied from this window, newest last: where it went and what it replaced.</summary>
    private readonly Stack<(DiffSide Target, int Start, int InsertedLength, string Removed, int Row)> _copyUndo = new();

    /// <summary>True when a fragment opens and closes its own elements (plain text counts as balanced).</summary>
    private static bool IsBalancedFragment(string fragment)
    {
        // Every opening tag must meet its own closing tag inside the fragment and no closing tag may
        // stand alone: that is what keeps a copy from breaking the other file. Self-closing tags,
        // comments, CDATA and declarations are skipped; text between tags does not matter.
        if (string.IsNullOrWhiteSpace(fragment) || fragment.IndexOf('<') < 0) return true;
        var open = new Stack<string>();
        int n = fragment.Length, i = 0;
        while (i < n)
        {
            int lt = fragment.IndexOf('<', i);
            if (lt < 0) break;
            if (string.CompareOrdinal(fragment, lt, "<!--", 0, 4) == 0)
            {
                int e = fragment.IndexOf("-->", lt + 4, StringComparison.Ordinal);
                if (e < 0) return true;
                i = e + 3; continue;
            }
            if (string.CompareOrdinal(fragment, lt, "<![CDATA[", 0, 9) == 0)
            {
                int e = fragment.IndexOf("]]>", lt + 9, StringComparison.Ordinal);
                if (e < 0) return true;
                i = e + 3; continue;
            }
            if (lt + 1 < n && (fragment[lt + 1] == '?' || fragment[lt + 1] == '!'))
            {
                int e = fragment.IndexOf('>', lt);
                if (e < 0) return true;
                i = e + 1; continue;
            }
            int j = lt + 1;
            char quote = '\0';
            while (j < n)
            {
                char ch = fragment[j];
                if (quote != '\0') { if (ch == quote) quote = '\0'; }
                else if (ch == '"' || ch == '\'') quote = ch;
                else if (ch == '>') break;
                j++;
            }
            if (j >= n) return true;   // an unfinished tag is the parser's business, not this check's
            bool closing = fragment[lt + 1] == '/';
            bool selfClosing = !closing && fragment[j - 1] == '/';
            int nameStart = lt + (closing ? 2 : 1), k = nameStart;
            while (k < j && !char.IsWhiteSpace(fragment[k]) && fragment[k] != '/' && fragment[k] != '>') k++;
            string name = fragment.Substring(nameStart, k - nameStart);
            if (closing)
            {
                if (open.Count == 0 || open.Pop() != name) return false;
            }
            else if (!selfClosing) open.Push(name);
            i = j + 1;
        }
        return open.Count == 0;
    }

    private void UndoLastCopy()
    {
        if (_copyUndo.Count == 0 || _isComparing) { NativeMethods.Beep(); return; }
        (DiffSide target, int start, int insertedLength, string removed, int anchorRow) = _copyUndo.Pop();
        UndoCopyBtn.IsEnabled = _copyUndo.Count > 0;

        bool ok = ApplyEdit?.Invoke(target, (start, insertedLength), removed) ?? false;
        if (!ok) { NativeMethods.Beep(); StatusField.Text = "Couldn't undo the copy"; return; }

        string text = target == DiffSide.Left ? _leftText : _rightText;
        int safeLen = Math.Min(insertedLength, Math.Max(0, text.Length - start));
        string restored = text.Substring(0, Math.Min(start, text.Length)) + removed
                        + text.Substring(Math.Min(start + safeLen, text.Length));
        int editLine = LineOfOffset(target == DiffSide.Left ? _leftLineStarts : _rightLineStarts, start);
        RememberPlace(anchorRow);   // the restored difference comes back at the row the copy was made on
        if (target == DiffSide.Left) _leftText = restored; else _rightText = restored;
        if (target == _treeSide)
        {
            int delta = CountLines(removed) - CountLines(text.Substring(Math.Min(start, text.Length), safeLen));
            InvalidateTree(keepScope: true, editLine: editLine, lineDelta: delta);
            if (TreePane.Visibility == Visibility.Visible) StartTreeParse();
        }

        _lastCopyNote = $"Undid the last copy in {(target == DiffSide.Left ? _leftName : _rightName)}, ";
        Recompare(scrollToFirst: false);
    }

    // ================= line-by-line selection =================

    /// <summary>
    /// What a copy moves: the whole difference, or, when rows inside it are selected, only those rows.
    /// Returns (source start, source count, destination start, destination count) as 0-based line indices.
    /// <para>Rows inside a difference are laid out as: the paired rows (a line on each side), then the
    /// left-only rows (filler on the right), then the right-only rows (filler on the left). A side that has
    /// no selected content becomes an insertion point there, after the difference's left lines for the
    /// left side, after the paired right lines for the right side, so copying left-only rows to the
    /// right inserts them, and copying "from left" onto right-only rows removes them.</para>
    /// </summary>
    private (int, int, int, int) CopyRange(Hunk h, int hunkIdx, DiffSide from)
    {
        int paired = Math.Min(h.LeftCount, h.RightCount);
        int leftExtra = h.LeftCount - paired;
        int lStart = h.LeftStart, lCount = h.LeftCount, rStart = h.RightStart, rCount = h.RightCount;

        if (SelectionInCurrentHunk() is { } sel)
        {
            int a = sel.Start - _hunkRowStart[hunkIdx];
            int b = a + sel.Count - 1;
            int lFirst = -1, lLast = -1, rFirst = -1, rLast = -1;
            for (int r = a; r <= b; r++)
            {
                int lLine = r < paired + leftExtra ? h.LeftStart + r : -1;
                int rLine = r < paired ? h.RightStart + r
                          : r >= paired + leftExtra ? h.RightStart + paired + (r - paired - leftExtra) : -1;
                if (lLine >= 0) { if (lFirst < 0) lFirst = lLine; lLast = lLine; }
                if (rLine >= 0) { if (rFirst < 0) rFirst = rLine; rLast = rLine; }
            }
            lStart = lFirst >= 0 ? lFirst : h.LeftStart + h.LeftCount;
            lCount = lFirst >= 0 ? lLast - lFirst + 1 : 0;
            rStart = rFirst >= 0 ? rFirst : h.RightStart + paired;
            rCount = rFirst >= 0 ? rLast - rFirst + 1 : 0;
        }

        return from == DiffSide.Left ? (lStart, lCount, rStart, rCount) : (rStart, rCount, lStart, lCount);
    }

    /// <summary>At most this many rows are tried when widening a selection to a whole element.</summary>
    private const int WidenCap = 4000;

    /// <summary>
    /// Widens the row selection inside the current difference until the lines it covers form complete
    /// XML on BOTH sides (the lines copied and the lines replaced): forward first, then backward when
    /// the selection began with a closing tag. Returns the rows added, 0 when the selection was already
    /// complete or there is none, -1 when no widening within the difference makes it complete.
    /// </summary>
    private int WidenSelectionToWholeElement(int hunkIdx, DiffSide from)
    {
        if (SelectionInCurrentHunk() is not { } sel) return 0;
        Hunk h = _hunks[hunkIdx];
        int rowBase = _hunkRowStart[hunkIdx], last = rowBase + _hunkRowSpan[hunkIdx] - 1;
        DiffSide target = from == DiffSide.Left ? DiffSide.Right : DiffSide.Left;

        string Fragment(int a, int b, DiffSide side)
        {
            List<string> lines = side == DiffSide.Left ? _lLines : _rLines;
            var sb = new System.Text.StringBuilder();
            for (int r = a; r <= b; r++)
            {
                int line = SourceLineAtRow(h, r - rowBase, side);
                if (line >= 0 && line < lines.Count) sb.Append(lines[line]).Append('\n');
            }
            return sb.ToString();
        }
        bool Complete(int a, int b) => IsBalancedFragment(Fragment(a, b, from)) && IsBalancedFragment(Fragment(a, b, target));

        int a = sel.Start, b = sel.Start + sel.Count - 1;
        if (Complete(a, b)) return 0;
        int a2 = a, b2 = b, tried = 0;
        while (b2 < last && tried++ < WidenCap && !Complete(a2, b2)) b2++;
        while (a2 > rowBase && tried++ < WidenCap && !Complete(a2, b2)) a2--;
        if (!Complete(a2, b2)) return -1;
        for (int e = b; e <= b2; e++) if (Complete(a2, e)) { b2 = e; break; }   // the smallest complete stretch, not the whole block

        _syncing = true;
        _leftView.SetSelection(a2, b2 - a2 + 1);
        _rightView.SetSelection(a2, b2 - a2 + 1);
        _syncing = false;
        return (b2 - a2 + 1) - sel.Count;
    }

    /// <summary>The line of <paramref name="side"/> shown at row <paramref name="k"/> of a difference (0-based within it), or -1 for a filler row.</summary>
    private static int SourceLineAtRow(Hunk h, int k, DiffSide side)
    {
        int paired = Math.Min(h.LeftCount, h.RightCount);
        int leftExtra = h.LeftCount - paired;
        if (side == DiffSide.Left) return k < paired + leftExtra ? h.LeftStart + k : -1;
        if (k < paired) return h.RightStart + k;
        return k >= paired + leftExtra ? h.RightStart + paired + (k - paired - leftExtra) : -1;
    }

    /// <summary>The selected rows when they lie inside the CURRENT difference; otherwise null.</summary>
    private (int Start, int Count)? SelectionInCurrentHunk()
    {
        if (_scopedIndices.Count == 0 || _scopedPos < 0 || _scopedPos >= _scopedIndices.Count) return null;
        (int start, int count) = _leftView.SelectedRows;
        if (count <= 0) return null;
        int idx = _scopedIndices[_scopedPos];
        if (idx >= _hunkRowStart.Length) return null;
        int rowBase = _hunkRowStart[idx];
        if (start < rowBase || start + count > rowBase + _hunkRowSpan[idx]) return null;
        return (start, count);
    }

    /// <summary>Index of the difference whose rows contain <paramref name="row"/>, or -1.</summary>
    private int HunkAtRow(int row)
    {
        int lo = 0, hi = _hunkRowStart.Length - 1;
        while (lo <= hi)
        {
            int mid = (lo + hi) / 2;
            if (row < _hunkRowStart[mid]) hi = mid - 1;
            else if (row >= _hunkRowStart[mid] + _hunkRowSpan[mid]) lo = mid + 1;
            else return mid;
        }
        return -1;
    }

    private void OnRowSelection(DiffTextView from, DiffTextView to)
    {
        if (_pastEnd) { _pastEnd = false; CopyLeftBtn.IsEnabled = CopyRightBtn.IsEnabled = _scopedIndices.Count > 0; }
        (int start, int count) = from.SelectedRows;
        to.SetSelection(start, count);                        // the rows are shared, so the mirror is exact
        if (count > 0)
        {
            // Selecting rows inside another difference makes THAT one the current difference.
            int idx = HunkAtRow(start);
            int pos = idx >= 0 ? _scopedIndices.IndexOf(idx) : -1;
            if (pos >= 0)
            {
                _scopedPos = pos;
                _anchorPending = false;
                _leftView.SetEmphasis(_hunkRowStart[idx], _hunkRowSpan[idx]);
                _rightView.SetEmphasis(_hunkRowStart[idx], _hunkRowSpan[idx]);
            }
        }
        UpdateCopyButtons();
        UpdateStatus();
    }

    private void ClearRowSelection()
    {
        _leftView.ClearSelection();
        _rightView.ClearSelection();
        UpdateCopyButtons();
        UpdateStatus();
    }

    /// <summary>The Copy buttons say what they will move when rows are selected.</summary>
    private void UpdateCopyButtons()
    {
        string suffix = SelectionInCurrentHunk() is { } s ? $" ({s.Count} line{(s.Count == 1 ? "" : "s")})" : "";
        CopyLeftBtn.Content = "Copy From Left ▶" + suffix;
        CopyRightBtn.Content = "◀ Copy From Right" + suffix;
    }

    /// <summary>" · 108 lines" for the current difference, a merged block is one difference but many lines.</summary>
    private string HunkSizeNote
    {
        get
        {
            if (_scopedIndices.Count == 0 || _scopedPos < 0 || _scopedPos >= _scopedIndices.Count) return "";
            int idx = _scopedIndices[_scopedPos];
            if (idx >= _hunkRowSpan.Length) return "";
            int rows = _hunkRowSpan[idx];
            return $" · {rows:N0} line{(rows == 1 ? "" : "s")}";
        }
    }

    private string SelectionNote
        => SelectionInCurrentHunk() is { } s && !(_lineMode && s.Count == 1) ? $" · {s.Count} selected" : "";

    // ================= tree sidebar =================

    private void ToggleTree()
    {
        bool showing = TreePane.Visibility != Visibility.Visible;
        TreePane.Visibility = showing ? Visibility.Visible : Visibility.Collapsed;
        TreeSplitter.Visibility = showing ? Visibility.Visible : Visibility.Collapsed;
        TreeSplitter.Width = showing ? 6 : 0;
        TreeCol.Width = showing ? new GridLength(240) : new GridLength(0);
        TreeCol.MinWidth = showing ? 120 : 0;
        TreeSplitCol.Width = showing ? GridLength.Auto : new GridLength(0);

        if (showing) StartTreeParse();
    }

    /// <summary>
    /// Drops the sidebar tree so it is parsed again. With <paramref name="keepScope"/> the "inside X only"
    /// restriction survives the edit: its line range is shifted by <paramref name="lineDelta"/> when the
    /// edit happened above it, or stretched when the edit happened inside it.
    /// </summary>
    private void InvalidateTree(bool keepScope = false, int editLine = -1, int lineDelta = 0)
    {
        _treeGeneration++;
        _treeParseStarted = false;
        _tree = null;
        _expanded.Clear();
        _treeUpdating = true;
        _treeRows.Clear();
        TreeList.SelectedItem = null;
        _treeUpdating = false;
        if (keepScope && _scopeLines is { } r && _scopeNode is not null)
        {
            if (editLine >= 0 && editLine < r.Lower) _scopeLines = (r.Lower + lineDelta, r.Upper + lineDelta);
            else if (editLine >= r.Lower && editLine <= r.Upper) _scopeLines = (r.Lower, Math.Max(r.Lower, r.Upper + lineDelta));
            return;
        }
        _scopeNode = null;
        _scopeLines = null;
        _anchorPending = false;
        ScopeBtn.Visibility = Visibility.Collapsed;
    }

    private void StartTreeParse()
    {
        if (_treeParseStarted || _closed) return;
        if (_tooLarge)
        {
            UpdateStatus();
            return;
        }

        _treeParseStarted = true;
        int generation = ++_treeGeneration;
        if (!_isComparing) StatusField.Text = "Reading the tree…";
        DiffSide side = _treeSide;
        string text = side == DiffSide.Left ? _leftText : _rightText;
        string name = side == DiffSide.Left ? _leftName : _rightName;
        Task.Run(() =>
        {
            try
            {
                var result = new XmlStreamParser().ParseText(text);
                result.Root.Name = name;
                Dispatcher.InvokeAsync(() =>
                {
                    if (_closed || generation != _treeGeneration) return;
                    _tree = result.Root;
                    BuildInitialExpansion();
                    RebuildTreeRows();
                    if (!_isComparing)
                    {
                        // The parser stops at the first well-formedness fault, so the sidebar can silently
                        // end after a few regions. Say that plainly instead of looking like a short file.
                        string sideNote = side == DiffSide.Right ? $"tree of the right file, {name}" : "";
                        string stopNote = result.Errors.Count > 0
                            ? $"tree stops at line {result.Errors[0].Line}: {result.Errors[0].Message}"
                            : "";
                        _treeNote = sideNote.Length > 0 && stopNote.Length > 0 ? sideNote + " · " + stopNote : sideNote + stopNote;
                        UpdateStatus();
                    }
                });
            }
            catch (Exception ex)
            {
                Dispatcher.InvokeAsync(() =>
                {
                    if (_closed || generation != _treeGeneration) return;
                    _treeParseStarted = false;
                    if (!_isComparing)
                        StatusField.Text = $"Couldn't read the comparison tree, {ex.Message}";
                });
            }
        });
    }

    /// <summary>
    /// Opens the tree down to the first level that actually branches, so the sidebar shows real content
    /// the moment it loads. Expanding only the root's direct children left a GCAM file showing three rows
    ///, the file, &lt;scenario&gt;, &lt;world&gt;, and none of the 32 regions, which reads as
    /// "it did not load" and forced a scroll and a click before anything appeared.
    /// </summary>
    private void BuildInitialExpansion()
    {
        _expanded.Clear();
        if (_tree == null) return;
        _expanded.Add(_tree.Id);

        const int maxLevels = 6;      // never chase a pathological chain
        const int maxFanOut = 2000;   // never expand a level that would add thousands of rows one by one

        XmlTreeNode node = _tree;
        for (int level = 0; level < maxLevels; level++)
        {
            XmlTreeNode? only = null;
            int elementChildren = 0;
            foreach (var c in node.Children)
                if (c.Kind == NodeKind.Element) { elementChildren++; only = c; if (elementChildren > 1) break; }

            if (elementChildren != 1 || only is null) break;   // this level already fans out, stop here

            int grandChildren = 0;
            foreach (var g in only.Children) if (g.Kind == NodeKind.Element) grandChildren++;
            if (grandChildren > maxFanOut) break;

            _expanded.Add(only.Id);
            node = only;
        }
    }

    private static bool HasElementChild(XmlTreeNode n)
    {
        foreach (var c in n.Children) if (c.Kind == NodeKind.Element) return true;
        return false;
    }

    /// <summary>
    /// Rebuilds the sidebar rows, PRESERVING the selected element and the scroll position.
    /// <para>Every disclosure click destroys and recreates every row. Without this restore, clearing the
    /// collection dropped the ListBox's selection (the highlight on the scoped element vanished while the
    /// scope stayed armed) and reset its scroll offset to zero, throwing the view back to the top of the
    /// tree, which is why the comparison appeared to need scrolling and re-selecting before it would
    /// show other regions.</para>
    /// </summary>
    /// <summary>Shows the tree of the other file. The comparison itself is untouched; only the sidebar,
    /// the scope filter and the tree-driven jumps now use that file's lines.</summary>
    /// <summary>Ctrl + wheel / Ctrl +/- change the text size of the two compared files in THIS window
    /// only (the slider at the bottom right of the main window is the whole-app zoom). 0 = back to normal.</summary>
    private void ZoomDiff(double factor)
    {
        double topRow = _leftView.LineHeight > 0 ? _leftView.VerticalOffset / _leftView.LineHeight : 0;
        double z = factor <= 0 ? 1 : Math.Clamp(_leftView.LocalScale * factor, 0.5, 3.0);
        _leftView.LocalScale = z;
        _rightView.LocalScale = z;
        _syncing = true;
        _leftView.VerticalOffset = topRow * _leftView.LineHeight;   // keep the same row at the top
        _rightView.VerticalOffset = _leftView.VerticalOffset;
        _syncing = false;
    }

    private void SwitchTreeSide()
    {
        _treeSide = _treeSide == DiffSide.Left ? DiffSide.Right : DiffSide.Left;
        ClearScope();
        InvalidateTree();
        _treeNote = "";
        StartTreeParse();
    }

    private void RebuildTreeRows()
    {
        int? keepId = (TreeList.SelectedItem as DiffTreeRow)?.Node.Id ?? _scopeNode?.Id;

        _treeUpdating = true;
        _treeRows.Clear();
        if (_tree != null)
            AddTreeRow(_tree, 0);

        // ORDER MATTERS: the selection is restored while _treeUpdating is still true, so
        // OnTreeSelectionChanged's guard swallows it. Restoring after the flag clears would re-enter,
        // reset _scopedPos to 0 and re-arm _anchorPending, silently losing the place in the walk.
        DiffTreeRow? keptRow = null;
        if (keepId is int wanted)
        {
            foreach (DiffTreeRow r in _treeRows)
                if (r.Node.Id == wanted) { keptRow = r; break; }
            if (keptRow != null) TreeList.SelectedItem = keptRow;
        }

        _treeUpdating = false;

        if (keptRow != null)
        {
            TreeList.UpdateLayout();
            TreeList.ScrollIntoView(keptRow);
        }
    }

    private void AddTreeRow(XmlTreeNode node, int depth)
    {
        bool hasKids = HasElementChild(node);
        bool expanded = _expanded.Contains(node.Id);
        string? detail = depth == 0
            ? (_treeSide == DiffSide.Left
                ? "left file  ·  click here to show the tree of the right file"
                : "right file  ·  click here to show the tree of the left file")
            : null;
        _treeRows.Add(new DiffTreeRow(node, depth, hasKids, expanded, detail));
        if (expanded && hasKids)
        {
            foreach (var c in node.Children)
                if (c.Kind == NodeKind.Element) AddTreeRow(c, depth + 1);
        }
    }

    /// <summary>Double-clicking a tree row opens or closes it, not only the small arrow beside it.</summary>
    private void OnTreeDoubleClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (ItemsControl.ContainerFromElement(TreeList, e.OriginalSource as DependencyObject) is not ListBoxItem item
            || item.Content is not DiffTreeRow row || !row.HasChildren) return;
        if (_expanded.Contains(row.Node.Id)) _expanded.Remove(row.Node.Id);
        else _expanded.Add(row.Node.Id);
        RebuildTreeRows();
        e.Handled = true;
    }

    private void OnTreeButtonClick(object sender, RoutedEventArgs e)
    {
        if (e.OriginalSource is Button b && (b.Tag as string) == "disc" && b.DataContext is DiffTreeRow row)
        {
            if (!row.HasChildren) return;
            if (_expanded.Contains(row.Node.Id)) _expanded.Remove(row.Node.Id);
            else _expanded.Add(row.Node.Id);
            RebuildTreeRows();
            e.Handled = true;
        }
    }

    private void OnTreeSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_treeUpdating) return;
        if (TreeList.SelectedItem is not DiffTreeRow row) return;
        var node = row.Node;

        if (node.Parent == null || node.Kind == NodeKind.Document)
        {
            // The file-name row is the switch: show the OTHER file's tree and walk differences by that
            // file's elements. The scope is dropped because its line range belongs to the old side.
            SwitchTreeSide();
            return;
        }
        else
        {
            _scopeNode = node;
            int lower = node.StartLine - 1;
            int upper = Math.Max(node.StartLine, node.EndLine) - 1;
            _scopeLines = (lower, upper);
            RebuildScopedIndices();
            _scopedPos = 0;
            _anchorPending = true;
            ScopeBtn.Visibility = Visibility.Visible;
            UpdateStatus();   // populates _scopeLabel through the ScopeSuffix getter
            ScopeBtn.ToolTip = $"Stop limiting to {_scopeLabel}, walk all {_hunks.Count:N0} differences again";
        }
        JumpToTreeLine(node.StartLine);
    }
}

/// <summary>A row in the diff window's element-only tree sidebar.</summary>
public sealed class DiffTreeRow : INotifyPropertyChanged
{
    public XmlTreeNode Node { get; }
    public int Depth { get; }
    public bool HasChildren { get; }
    private bool _isExpanded;

    private readonly string? _detail;

    public DiffTreeRow(XmlTreeNode node, int depth, bool hasChildren, bool isExpanded, string? detail = null)
    {
        Node = node;
        Depth = depth;
        HasChildren = hasChildren;
        _isExpanded = isExpanded;
        _detail = detail;
    }

    public bool IsExpanded
    {
        get => _isExpanded;
        set { _isExpanded = value; OnChanged(nameof(IsExpanded)); OnChanged(nameof(Glyph)); }
    }

    public string Label => Node.DisplayLabel;
    public string Detail => _detail ?? Node.DisplayDetail;
    public Thickness Indent => new(Depth * 12, 0, 0, 0);
    public string Glyph => HasChildren ? (_isExpanded ? "▾" : "▸") : "";

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnChanged(string n) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
}
