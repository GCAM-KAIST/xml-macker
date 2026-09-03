using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using XMLMacker.Core;
using XMLMacker.Editor;
using XMLMacker.Shared;

namespace XMLMacker.App;

/// <summary>
/// The marker pen. Clicking the highlighter button (or Ctrl+H) turns the pointer into a marker: every
/// drag over text paints it in the current colour, a plain click paints the whole line, painting the
/// same colour again erases. It stays on until Esc or the button. The small arrow beside the button
/// picks the colour (or the eraser) and offers "remove all"; the down arrow jumps from stroke to
/// stroke. Strokes live with the document, follow edits, and are stored per file.
/// </summary>
public partial class MainWindow
{
    private const string HighlightColorKey = "xml-macker.highlightColor";

    private HighlightColor _highlightColor = HighlightColor.Yellow;   // None = the eraser
    private bool _markerOn;

    private static readonly (HighlightColor Color, string Name, Color Swatch)[] HighlightPalette =
    {
        (HighlightColor.Red, "Red", Color.FromRgb(0xE5, 0x39, 0x35)),
        (HighlightColor.Blue, "Blue", Color.FromRgb(0x3B, 0x82, 0xF6)),
        (HighlightColor.Yellow, "Yellow", Color.FromRgb(0xE8, 0xB9, 0x10)),
        (HighlightColor.Green, "Green", Color.FromRgb(0x22, 0xB5, 0x5E)),
    };

    private void InitHighlights()
    {
        int saved = AppSettings.Instance.GetInt(HighlightColorKey, (int)HighlightColor.Yellow);
        _highlightColor = saved is >= 0 and <= 4 ? (HighlightColor)saved : HighlightColor.Yellow;
        Toolbar.SetHighlightSwatch(SwatchOf(_highlightColor));
        Toolbar.HighlightClicked += (_, _) => ToggleMarker();
        Toolbar.HighlightMenuRequested += (_, _) => ShowHighlightMenu();
        Toolbar.HighlightJumpClicked += (_, direction) => JumpToHighlight(direction);
        // After the editor has finished its own mouse-up handling (the selection is final), paint.
        _source.Editor.AddHandler(MouseLeftButtonUpEvent, new MouseButtonEventHandler(OnEditorMouseUpForMarker), handledEventsToo: true);
        PreviewKeyDown += (_, e) =>
        {
            if (_markerOn && e.Key == Key.Escape) { SetMarker(false); e.Handled = true; }
        };
    }

    private static Color? SwatchOf(HighlightColor color)
    {
        foreach ((HighlightColor c, string _, Color swatch) in HighlightPalette)
            if (c == color) return swatch;
        return null;
    }

    private static string NameOf(HighlightColor color)
    {
        foreach ((HighlightColor c, string name, Color _) in HighlightPalette)
            if (c == color) return name;
        return "eraser";
    }

    // ── the marker ───────────────────────────────────────────────────────────────────────────────

    private void ToggleMarker() => SetMarker(!_markerOn);

    private void SetMarker(bool on)
    {
        if (on && (_currentFileUrl is null || _source.Editor.Buffer is null)) { NativeMethods.Beep(); return; }
        _markerOn = on;
        Toolbar.SetHighlighterActive(on);
        _source.Editor.OverrideCursor = on ? Cursors.Pen : null;
        if (on)
        {
            _source.Editor.Focus();
            SetStatus(_highlightColor == HighlightColor.None
                ? "Eraser on, drag over marked text to remove the mark; Esc or the highlighter button turns it off"
                : $"Highlighter on ({NameOf(_highlightColor).ToLowerInvariant()}), drag over text to mark it, click a line to mark the whole line; Esc or the button turns it off");
        }
        else SetStatus("Highlighter off");
    }

    private void OnEditorMouseUpForMarker(object sender, MouseButtonEventArgs e)
    {
        if (!_markerOn) return;
        Dispatcher.BeginInvoke(new Action(() => { if (_markerOn) PaintCurrent(collapseSelection: true); }), DispatcherPriority.Input);
    }

    /// <summary>Paints the selection, or the caret's whole line, in the current colour; the same colour again erases.</summary>
    private void PaintCurrent(bool collapseSelection)
    {
        if (ActiveSession is not { } session || _source.Editor.Buffer is null) { NativeMethods.Beep(); return; }
        HugeTextEditor ed = _source.Editor;
        int start = ed.SelectionStart, length = ed.SelectionLength;
        if (length == 0)
        {
            int line = ed.LineIndex.LineForOffset(ed.CaretOffset);
            start = ed.LineIndex.Starts[line];
            int end = line + 1 < ed.LineIndex.LineCount ? ed.LineIndex.Starts[line + 1] - 1 : ed.DocumentLength;
            length = Math.Max(0, end - start);
            if (length == 0) return;   // an empty line has nothing to mark
        }
        TextHighlights strokes = session.Highlights;
        bool erase = _highlightColor == HighlightColor.None || strokes.IsCovered(start, length, _highlightColor);
        strokes.Paint(start, length, erase ? HighlightColor.None : _highlightColor);
        if (collapseSelection) ed.MoveCaretTo(start + length, scrollIntoView: false);
        AfterHighlightChange(session, erase ? "Mark removed" : $"Marked in {NameOf(_highlightColor).ToLowerInvariant()}", start);
    }

    private void RemoveAllHighlights()
    {
        if (ActiveSession is not { } session || session.Highlights.IsEmpty) return;
        int n = session.Highlights.Count;
        session.Highlights.Clear();
        AfterHighlightChange(session, $"Removed {n:N0} mark{(n == 1 ? "" : "s")}", null);
    }

    private void AfterHighlightChange(DocumentSession session, string what, int? offset)
    {
        SaveHighlights(session);
        int n = session.Highlights.Count;
        string where = offset is { } o ? $", line {_source.Editor.LineIndex.LineForOffset(o) + 1:N0}" : "";
        SetStatus($"{what}{where} · {n:N0} mark{(n == 1 ? "" : "s")} in this file");
    }

    /// <summary>The down arrow / Ctrl+Shift+H: go to the next (+1) or previous (−1) stroke, wrapping around.</summary>
    private void JumpToHighlight(int direction)
    {
        if (ActiveSession is not { } session || _source.Editor.Buffer is null) { NativeMethods.Beep(); return; }
        if (session.Highlights.IsEmpty)
        {
            NativeMethods.Beep();
            SetStatus("No marks in this file, click the highlighter (Ctrl+H) and drag over text");
            return;
        }
        int here = _source.Editor.CaretOffset;
        HighlightRange? found = direction >= 0 ? session.Highlights.Next(here) : session.Highlights.Previous(here);
        if (found is not { } r) return;
        _source.RevealMatch((r.Start, r.Length));
        bool wrapped = direction >= 0 ? r.Start <= here : r.Start >= here;
        SetStatus($"Mark {session.Highlights.OrdinalOf(r)} of {session.Highlights.Count:N0}, line {_source.Editor.LineIndex.LineForOffset(r.Start) + 1:N0}"
                  + (wrapped ? (direction >= 0 ? " (back at the first one)" : " (round to the last one)") : ""));
    }

    private void ChooseColor(HighlightColor color)
    {
        _highlightColor = color;
        AppSettings.Instance.SetInt(HighlightColorKey, (int)color);
        Toolbar.SetHighlightSwatch(SwatchOf(color));
        if (!_markerOn) SetMarker(true);   // choosing a colour starts marking
        else SetStatus(color == HighlightColor.None ? "Eraser on, drag over marked text" : $"Highlighter colour: {NameOf(color).ToLowerInvariant()}");
    }

    private void ShowHighlightMenu()
    {
        bool hasDoc = _currentFileUrl is not null && _source.Editor.Buffer is not null;
        int count = ActiveSession?.Highlights.Count ?? 0;
        var menu = new ContextMenu { PlacementTarget = Toolbar.HighlightAnchor, Placement = PlacementMode.Bottom };

        foreach ((HighlightColor color, string name, Color swatch) in HighlightPalette)
        {
            var item = new MenuItem
            {
                Header = color == _highlightColor ? name + "   (current)" : name,
                IsEnabled = hasDoc,
                Icon = new Border { Width = 14, Height = 14, CornerRadius = new CornerRadius(3), Background = new SolidColorBrush(swatch) },
            };
            HighlightColor chosen = color;
            item.Click += (_, _) => ChooseColor(chosen);
            menu.Items.Add(item);
        }
        var eraser = new MenuItem { Header = _highlightColor == HighlightColor.None ? "Eraser   (current)" : "Eraser, drag to remove marks", IsEnabled = hasDoc };
        eraser.Click += (_, _) => ChooseColor(HighlightColor.None);
        menu.Items.Add(eraser);

        menu.Items.Add(new Separator());
        var now = new MenuItem { Header = "Mark the selection or this line now", InputGestureText = "Ctrl+Alt+H", IsEnabled = hasDoc };
        now.Click += (_, _) => PaintCurrent(collapseSelection: false);
        menu.Items.Add(now);
        var next = new MenuItem { Header = "Next mark", InputGestureText = "Ctrl+Shift+H", IsEnabled = count > 0 };
        next.Click += (_, _) => JumpToHighlight(+1);
        menu.Items.Add(next);
        var prev = new MenuItem { Header = "Previous mark", InputGestureText = "Ctrl+Shift+Alt+H", IsEnabled = count > 0 };
        prev.Click += (_, _) => JumpToHighlight(-1);
        menu.Items.Add(prev);

        menu.Items.Add(new Separator());
        var clear = new MenuItem
        {
            Header = count > 0 ? $"Remove all {count:N0} mark{(count == 1 ? "" : "s")} in this file" : "Remove all marks in this file",
            IsEnabled = count > 0,
        };
        clear.Click += (_, _) => RemoveAllHighlights();
        menu.Items.Add(clear);

        menu.IsOpen = true;
    }

    // ── persistence ──────────────────────────────────────────────────────────────────────────────

    /// <summary>Reads the stored strokes of a freshly loaded document (re-anchored to their text).</summary>
    private void LoadHighlights(DocumentSession session)
    {
        if (session.Storage is null || IsUntitled(session.Url)) return;
        ITextBuffer storage = StorageOf(session);
        HighlightStore.Load(session.Url, session.Highlights, LineStartsOf(session), storage.Length, TextReader(session));
    }

    /// <summary>Writes the strokes of a document; untitled documents keep theirs in memory only.</summary>
    private void SaveHighlights(DocumentSession session, string? asPath = null)
    {
        string path = asPath ?? session.Url;
        if (session.Storage is null || IsUntitled(path)) return;
        HighlightStore.Save(path, session.Highlights, LineStartsOf(session), TextReader(session));
    }

    private int[] LineStartsOf(DocumentSession session)
        => ReferenceEquals(session, ActiveSession) ? _source.CurrentLineStarts : session.LineStarts;

    private ITextBuffer StorageOf(DocumentSession session)
        => (ReferenceEquals(session, ActiveSession) ? _source.CurrentStorage : session.Storage) ?? session.Storage!;

    /// <summary>Document text by offset and length, live for the active tab.</summary>
    private Func<int, int, string> TextReader(DocumentSession session) => (offset, length) =>
    {
        ITextBuffer storage = StorageOf(session);
        if (offset < 0 || offset >= storage.Length || length <= 0) return "";
        return storage.Substring(offset, Math.Min(length, storage.Length - offset));
    };
}
