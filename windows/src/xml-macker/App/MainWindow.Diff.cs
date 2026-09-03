using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.Win32;
using XMLMacker.Core;
using XMLMacker.Windows;
using XMLMacker.Shared;

namespace XMLMacker.App;

/// <summary>
/// The Diff window's host side for swapping either compared file from inside the window.
/// <para>A swap to a file that is already open is immediate. A swap to a new file goes through the
/// normal open path, the file becomes a tab in the main window, exactly as if it had been opened from
/// the File menu, and the comparison is refreshed when that load finishes.</para>
/// </summary>
public partial class MainWindow
{
    /// <summary>The two documents a Diff window is comparing. Mutable so a swap re-targets edits too.</summary>
    internal sealed class DiffPair
    {
        public DocumentSession Left;
        public DocumentSession Right;
        public DiffPair(DocumentSession left, DocumentSession right) { Left = left; Right = right; }
    }

    private (DiffWindow Diff, DiffPair Pair, DiffSide Side)? _pendingDiffSwap;

    /// <summary>Open tabs the Diff window may offer for a side (name + full path).</summary>
    private IReadOnlyList<(string Name, string Path)> DiffCandidateFiles()
        => _sessions.Where(s => !s.IsLoading).Select(s => (FileNameOf(s.Url), s.Url)).ToList();

    /// <summary>
    /// Called by the Diff window: put <paramref name="path"/> on <paramref name="side"/>; a null path
    /// means "let me choose another file", which opens the usual file dialog.
    /// </summary>
    private void ChangeDiffFile(DiffWindow diff, DiffPair pair, DiffSide side, string? path)
    {
        if (path is null)
        {
            var dlg = new OpenFileDialog
            {
                Title = side == DiffSide.Left ? "Choose the file for the LEFT side" : "Choose the file for the RIGHT side",
                Filter = "XML files (*.xml)|*.xml|All files (*.*)|*.*",
                CheckFileExists = true,
            };
            if (dlg.ShowDialog(this) != true) return;
            path = dlg.FileName;
        }

        DocumentSession? open = _sessions.FirstOrDefault(s => string.Equals(s.Url, path, StringComparison.OrdinalIgnoreCase));
        if (open is not null && !open.IsLoading)
        {
            SwapDiffSide(diff, pair, side, open);
            return;
        }

        // Not open yet: load it as a tab, then finish the swap when the text has arrived.
        _pendingDiffSwap = (diff, pair, side);
        SetStatus($"Opening {FileNameOf(path)} for the comparison…");
        LoadFile(path);
    }

    /// <summary>Runs from the file-loaded path; true when a pending swap was completed.</summary>
    private bool TryFinishDiffFileSwap()
    {
        if (_pendingDiffSwap is not { } p) return false;
        if (ActiveSession is not { IsLoading: false } session) return false;
        _pendingDiffSwap = null;
        if (!p.Diff.IsLoaded) return true;   // the window was closed meanwhile
        SwapDiffSide(p.Diff, p.Pair, p.Side, session);
        return true;
    }

    private void SwapDiffSide(DiffWindow diff, DiffPair pair, DiffSide side, DocumentSession session)
    {
        string? text = SessionText(session);
        if (text is null) { NativeMethods.Beep(); SetStatus("That file is not ready yet"); return; }
        if (text.Length > 64_000_000)
        {
            NativeMethods.Beep();
            SetStatus("That file is too large to diff (64 MB cap)");
            return;
        }
        if (side == DiffSide.Left) pair.Left = session; else pair.Right = session;
        diff.ReplaceSide(side, FileNameOf(session.Url), text);
        SetStatus($"Comparing {FileNameOf(pair.Left.Url)} ⟷ {FileNameOf(pair.Right.Url)}");
    }
}
