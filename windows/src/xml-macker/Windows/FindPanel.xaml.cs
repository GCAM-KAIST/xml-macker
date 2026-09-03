using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Input;
using Microsoft.Win32;
using XMLMacker.Editor;
using XMLMacker.Shared;
using XMLMacker.Theme;

namespace XMLMacker.Windows;

/// <summary>
/// Find &amp; Replace popup. Works whole-file or scoped to an element. Find All docks a
/// Line | Path | Text results table INTO the window (the window grows downward keeping its Top).
/// All search/edit goes through <see cref="ISourceEditor"/> primitives; results export to CSV.
/// </summary>
public partial class FindPanel : Window
{
    private const string PlacementKey = "xml-mackerFind";
    private const int CollapsedHeight = 190;
    private const int ResultsHeight = 300;
    private const int ExpandExtra = 40;

    /// <summary>A single Find-All result row.</summary>
    public sealed class Row
    {
        public int Line { get; init; }
        public string Path { get; init; } = "";
        public string Text { get; init; } = "";
    }

    /// <summary>The search/edit backend (host-injected).</summary>
    public ISourceEditor? Source { get; set; }

    /// <summary>Ancestor path label for a line (host owns the tree).</summary>
    public Func<int, string>? PathForLine { get; set; }

    /// <summary>Fires after ANY replacement so the host can rebuild the tree / refresh + revalidate.</summary>
    public Action<string, string>? OnReplaced { get; set; }

    /// <summary>Window closed.</summary>
    public Action? OnClose { get; set; }

    private string _scopeTitle = "whole file";
    private (int Start, int Length)? _scopeRange;
    private (int Start, int Length)? _lastMatch;
    private readonly ObservableCollection<Row> _rows = new();
    private bool _resultsShown;

    public FindPanel()
    {
        InitializeComponent();
        ZoomGestures.AttachContentZoom(this);   // Ctrl + wheel / Ctrl +/- zoom this window only   // Ctrl + wheel, Ctrl +/-, Ctrl 0

        ResultsTable.ItemsSource = _rows;

        PrevBtn.Click += (_, _) => Step(false);
        NextBtn.Click += (_, _) => Step(true);
        FindAllBtn.Click += (_, _) => FindAll();
        ReplaceBtn.Click += (_, _) => ReplaceCurrent();
        ReplaceAllBtn.Click += (_, _) => ReplaceAll();
        ExportBtn.Click += (_, _) => ExportCsv();
        ResultsTable.ItemActivated += (_, item) => RowClicked(item as Row);

        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };

        SourceInitialized += (_, _) => WindowPlacement.Restore(this, PlacementKey);
        Closed += (_, _) => { WindowPlacement.Save(this, PlacementKey); OnClose?.Invoke(); };
    }

    // ================= present =================

    /// <summary>Shows the panel for a scope, focusing the Find or Replace field.</summary>
    public void Present(string? scopeTitle, (int Start, int Length)? scopeRange, bool focusReplace)
    {
        _scopeTitle = string.IsNullOrEmpty(scopeTitle) ? "whole file" : scopeTitle!;
        _scopeRange = scopeRange;
        _lastMatch = null;
        ScopeLabel.Text = "Scope: " + _scopeTitle;
        StatusLabel.Text = "";
        SetResultsVisible(false, animate: false);

        if (!IsVisible) Show();
        Activate();
        if (focusReplace) ReplField.Focus();
        else FindField.Focus();
    }

    // ================= search mechanics =================

    private string Needle => FindField.Text ?? "";
    private bool CaseSensitive => CaseBox.IsChecked == true;
    private bool WholeWord => WordBox.IsChecked == true;

    private (int Start, int Length) EffectiveScope()
        => _scopeRange ?? (Source?.FullDocumentRange ?? (0, 0));

    private void Note(string s, bool isError = false)
    {
        StatusLabel.Text = s;
        StatusLabel.Foreground = isError ? XMColor.Brush(XMColor.Err) : XMColor.Brush(XMColor.Text2);
        if (isError) NativeMethods.Beep();
    }

    private void Step(bool forward)
    {
        if (Needle.Length == 0 || Source == null) return;
        var scope = EffectiveScope();
        int from;
        if (_lastMatch is { } last)
            from = forward ? last.Start + last.Length : last.Start;
        else
            from = forward ? scope.Start : scope.Start + scope.Length;

        var hit = Source.MatchRange(Needle, from, forward, CaseSensitive, WholeWord, scope);
        if (hit == null)
        {
            _lastMatch = null;
            Note($"Not found in {_scopeTitle}", true);
            return;
        }
        _lastMatch = hit.Value;
        Source.RevealMatch(hit.Value);
        Note($"Line {Source.LineNumberForOffset(hit.Value.Start)}");
    }

    private void ReplaceCurrent()
    {
        if (Source == null || Needle.Length == 0) return;
        if (_lastMatch == null) { Step(true); return; }   // first Replace finds, doesn't replace

        var hit = _lastMatch.Value;
        string repl = ReplField.Text ?? "";
        if (!Source.PerformEdit(hit, repl)) { Note("Could not replace", true); return; }

        int delta = repl.Length - hit.Length;
        if (_scopeRange is { } sr) _scopeRange = (sr.Start, sr.Length + delta);
        _lastMatch = (hit.Start, repl.Length);
        OnReplaced?.Invoke(Needle, repl);
        Note("Replaced, finding next…");
        Step(true);
    }

    private void ReplaceAll()
    {
        if (Source == null || Needle.Length == 0) return;
        var scope = EffectiveScope();
        string repl = ReplField.Text ?? "";
        int n = Source.ReplaceAll(Needle, repl, CaseSensitive, WholeWord, scope);
        if (n < 0) { Note("Scope too large (over 100 M characters)", true); return; }
        if (n == 0) { Note($"Not found in {_scopeTitle}", true); return; }

        int delta = (repl.Length - Needle.Length) * n;
        if (_scopeRange is { } sr) _scopeRange = (sr.Start, sr.Length + delta);
        _lastMatch = null;
        OnReplaced?.Invoke(Needle, repl);
        string s = n == 1 ? "" : "s";
        Note($"Replaced {n} occurrence{s} in {_scopeTitle}");
    }

    private void FindAll()
    {
        if (Source == null || Needle.Length == 0) return;
        var scope = EffectiveScope();
        var hits = Source.AllMatchRanges(Needle, CaseSensitive, WholeWord, scope);
        if (hits.Count == 0)
        {
            _rows.Clear();
            SetResultsVisible(false, animate: false);
            Note($"Not found in {_scopeTitle}", true);
            return;
        }

        _rows.Clear();
        int lastLine = -1;
        string lastPath = "";
        foreach (var hit in hits)
        {
            int line = Source.LineNumberForOffset(hit.Start);
            if (line != lastLine)
            {
                lastPath = PathForLine?.Invoke(line) ?? "";
                lastLine = line;
            }
            _rows.Add(new Row { Line = line, Path = lastPath, Text = Source.LineText(line) });
        }

        bool capped = hits.Count >= 5000;
        string plus = capped ? "+" : "";
        ResultsHeader.Text = $"{_rows.Count}{plus} matches for \"{Needle}\" in {_scopeTitle}"
                           + (capped ? " · first 5000" : "");
        SetResultsVisible(true, animate: true);
        string es = _rows.Count == 1 ? "" : "es";
        Note($"{_rows.Count}{plus} match{es}");
    }

    private void RowClicked(Row? row)
    {
        if (row == null || Source == null) return;
        Source.ScrollToLine(row.Line);
    }

    // ================= results docking =================

    private void SetResultsVisible(bool visible, bool animate)
    {
        _resultsShown = visible;
        ResultsHeaderRow.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        ResultsScroll.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;

        // Grow the window downward, keeping Top pinned (WPF grows down when Height increases).
        double target = CollapsedHeight + (visible ? ResultsHeight + ExpandExtra : 0);
        Height = target;
    }

    // ================= CSV export =================

    private void ExportCsv()
    {
        if (_rows.Count == 0) return;
        var dlg = new SaveFileDialog
        {
            FileName = "find-results.csv",
            Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*",
            Title = "Export the Find All results as CSV"
        };
        if (dlg.ShowDialog(this) != true) return;

        var rows = new List<IEnumerable<string>>
        {
            new[] { "Line", "Path", "Text" }
        };
        foreach (var r in _rows)
            rows.Add(new[] { r.Line.ToString(System.Globalization.CultureInfo.InvariantCulture), r.Path, r.Text });

        try
        {
            Csv.Write(rows, dlg.FileName);
            Process.Start(new ProcessStartInfo(dlg.FileName) { UseShellExecute = true });
        }
        catch
        {
            Note("Could not write the CSV file", true);
        }
    }
}
