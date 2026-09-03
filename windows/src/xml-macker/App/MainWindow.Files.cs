using System;
using System.Collections.Generic;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Win32;
using XMLMacker.Core;
using XMLMacker.Editor;
using XMLMacker.Shared;

namespace XMLMacker.App;

/// <summary>
/// File open / parse pipeline, multi-file tab park/restore via
/// <see cref="DocumentSession"/>, save / save-as / revert / close, Show-in-Explorer, Copy Path,
/// the empty state, and the tree/line lookup algorithms.
/// </summary>
public partial class MainWindow
{
    private readonly record struct FileFingerprint(long ByteCount, DateTime LastWriteTimeUtc,
                                                    DateTime CreationTimeUtc);

    private FileFingerprint? _openingFingerprint;
    private int _openingGeneration;

    private DocumentSession? ActiveSession
        => (_activeIdx >= 0 && _activeIdx < _sessions.Count) ? _sessions[_activeIdx] : null;

    private void SetStatus(string text) => StatusLabel.Text = text;

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Load (the single funnel, menu Open, Explorer, CLI, Open Recent, diff second file).
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    public void LoadFile(string url) => OpenFiles(new[] { url });

    private void OpenFiles(IEnumerable<string> rawPaths, bool forceReload = false)
    {
        // Every way of opening a file reaches this funnel. Once a window-close/reset review has
        // started, accepting another request could add a fresh tab after the reviewed set was
        // captured and immediately close it when Save All completes.
        if (_closeReviewInProgress || _sessionEndingReviewScheduled || _quitting)
        {
            NativeMethods.Beep();
            SetStatus("Finish or cancel the close review before opening another file");
            return;
        }

        IReadOnlyList<string> canonical = XmlDocumentSupport.CanonicalFiles(rawPaths);
        List<string> accepted = canonical.Where(XmlDocumentSupport.IsLikelyXml).ToList();
        List<string> rejected = canonical.Except(accepted, StringComparer.OrdinalIgnoreCase).ToList();
        if (rejected.Count > 0)
            ShowAlert("Those files do not look like XML",
                string.Join(Environment.NewLine, rejected.Select(FileNameOf)), new[] { "OK" });

        foreach (string path in accepted)
        {
            if (_openQueue.Any(q => PathEquals(q.Path, path))) continue;
            _openQueue.Enqueue((path, forceReload));
        }
        ProcessNextOpen();
    }

    private void ProcessNextOpen()
    {
        if (_openBusy || _openQueue.Count == 0) return;
        (string path, bool forceReload) = _openQueue.Dequeue();

        int existing = _sessions.FindIndex(s => PathEquals(s.Url, path));
        if (existing >= 0 && !forceReload)
        {
            if (existing != _activeIdx) SwitchToTab(existing);
            Activate();
            ProcessNextOpen();
            return;
        }

        _openBusy = true;
        PerformOpenFile(path);
    }

    private void FinishOpen()
    {
        _openBusy = false;
        Dispatcher.BeginInvoke(ProcessNextOpen);
    }

    private void PerformOpenFile(string url)
    {
        int openingGeneration = unchecked(++_openingGeneration);

        // ── Tab semantics ──
        int existing = _sessions.FindIndex(s => PathEquals(s.Url, url));
        DocumentSession session;
        if (existing >= 0)
        {
            if (existing != _activeIdx)
            {
                SwitchToTab(existing);
                if (_activeIdx != existing) { FinishOpen(); return; }
            }
            // Keep the previous snapshot intact until both parsing and source decoding succeed.
            // A failed Revert can then restore the old text, tree, selection and undo history.
            SnapshotActiveSession();
            _source.DetachToFreshStorage();
            session = _sessions[existing];
            session.IsLoading = true;
            _currentSelectedNode = null;   // reload in place
        }
        else
        {
            if (_activeIdx >= 0) { SnapshotActiveSession(); _source.DetachToFreshStorage(); }
            session = new DocumentSession(url, 0) { IsLoading = true };
            _sessions.Add(session);
            _activeIdx = _sessions.Count - 1;
            _source.SessionUndoStack = null;
        }

        _docDirty = false;
        _activeEditRevision = session.EditRevision;
        _currentFileUrl = url;
        _loadingSession = session;
        ScheduleMenuRefresh();

        FileFingerprint? openingFingerprint = ReadFileFingerprint(url);
        if (openingFingerprint is null)
        {
            HandleOpenFailure(session, url, "The file's metadata could not be read.");
            return;
        }
        _openingFingerprint = openingFingerprint;

        long fileSize = openingFingerprint.Value.ByteCount;
        session.FileSize = fileSize;
        double sizeMB = fileSize / 1048576.0;

        SetStatus($"Parsing {FileNameOf(url)} ({sizeMB.ToString("0.0", Inv)} MB)…");
        RefreshTabStrip();

        _activeParser = null;
        _totalLines = 0;
        _progress.Start(() => _activeParser?.CurrentLineNumber ?? 0, () => _totalLines, Math.Max(1.0, sizeMB * 0.03));

        // ── Task A: concurrent mmap newline scan → total-lines denominator ──
        string scanUrl = url;
        Task.Run(() =>
        {
            int count = CountNewlines(scanUrl);
            Dispatcher.InvokeAsync(() =>
            {
                if (openingGeneration == _openingGeneration &&
                    ReferenceEquals(_loadingSession, session))
                    _totalLines = count;
            });
        });

        // ── Task B: streaming parse (publishes the parser so the progress timer can poll it) ──
        DateTime t0 = DateTime.UtcNow;
        Task.Run(() =>
        {
            try
            {
                var parser = new XmlStreamParser();
                Dispatcher.Invoke(() =>
                {
                    if (ReferenceEquals(_loadingSession, session)) _activeParser = parser;
                });
                ParseResult result = parser.ParseFile(url);
                double elapsed = (DateTime.UtcNow - t0).TotalSeconds;
                Dispatcher.InvokeAsync(() => OnParseComplete(session, url, fileSize, sizeMB, result, elapsed));
            }
            catch (Exception ex)
            {
                Dispatcher.InvokeAsync(() => HandleOpenFailure(session, url, ex.Message));
            }
        });
    }

    private void OnParseComplete(DocumentSession session, string url, long fileSize, double sizeMB,
                                 ParseResult result, double elapsed)
    {
        if (!ReferenceEquals(_loadingSession, session)) return;

        if (!ReferenceEquals(session, ActiveSession))
        {
            HandleOpenFailure(session, url, "The loading tab changed before the file was ready.");
            return;
        }

        if (_openingFingerprint is not { } expected || ReadFileFingerprint(url) != expected)
        {
            HandleOpenFailure(session, url,
                "The file changed while xml-macker was parsing it. Open it again after the other write finishes.");
            return;
        }

        result.Root.Name = FileNameOf(url);   // root row reads as the filename, not "#document"

        _currentTree = result.Root;
        _lastParseErrors = result.Errors;
        _validationWindow?.SetErrors(result.Errors);
        _errors.SetErrors(Array.Empty<ParseError>());
        _errors.SetValidationScope("");
        Title = FileTitle(FileNameOf(url));

        _tree.SetRoot(result.Root);
        _source.LoadFile(url, fileSize);                 // async text read → FileLoaded → OnSourceFileLoaded

        string nodeStr = $"{result.NodeCount.ToString(Inv)} nodes";
        string errStr = result.Errors.Count == 0
            ? "no errors"
            : $"{result.Errors.Count} error{(result.Errors.Count == 1 ? "" : "s")}";
        SetStatus($"{FileNameOf(url)} · {sizeMB.ToString("0.0", Inv)} MB · {nodeStr} · {errStr} · parsed in {elapsed.ToString("0.0", Inv)}s");
        _progress.Finish();
    }

    /// <summary>Editor <c>FileLoaded</c> continuation: minimap snap lines wired, tab made switchable,
    /// initial selection, then any pending diff second-file.</summary>
    private void OnSourceFileLoaded()
    {
        DocumentSession? loaded = _loadingSession;
        if (loaded is null) return;

        if (_openingFingerprint is not { } expected || ReadFileFingerprint(loaded.Url) != expected)
        {
            HandleOpenFailure(loaded, loaded.Url,
                "The file changed while xml-macker was loading its source text. Open it again after the other write finishes.");
            return;
        }

        _loadingSession = null;
        _openingFingerprint = null;

        loaded.Storage = _source.CurrentStorage;
        loaded.LineStarts = _source.CurrentLineStarts;
        loaded.TextEncoding = _source.CurrentTextEncoding;
        LoadHighlights(loaded);
        if (ReferenceEquals(loaded, ActiveSession))
        {
            _source.Editor.Highlights = loaded.Highlights;
            _source.Minimap.Highlights = loaded.Highlights;
        }
        loaded.Tree = _currentTree;
        loaded.ParseErrors = _lastParseErrors;
        // Record the fingerprint that was actually verified. Reading the timestamp again
        // here creates a small race where a just-started external write could be mistaken
        // for the version loaded into the editor and later escape the overwrite warning.
        loaded.FileSize = expected.ByteCount;
        loaded.FileModificationDateUtc = expected.LastWriteTimeUtc;
        loaded.EditRevision = _activeEditRevision;
        loaded.IsDirty = false;
        loaded.IsLoading = false;
        loaded.UndoStack = _source.SessionUndoStack;   // adopt the fresh per-tab undo stack

        if (_currentTree is not null)
            _source.Minimap.SetSnapLines(CollectSnapLines(_currentTree));

        XmlTreeNode? first = FirstElementChild(_currentTree);
        if (first is not null)
        {
            _tree.Select(first, expandAncestors: true);    // fires HandleTreeSelection
            Revalidate();                                  // immediate, not debounced
        }

        if (TryFinishDiffFileSwap()) { /* a Diff-side swap was waiting for this load */ }
        if (TryContinuePendingDiff()) { /* a comparison was waiting for this file */ }
        if (_pendingDiffLeft is { } left && ActiveSession is { } right && !ReferenceEquals(left, right))
        {
            _pendingDiffLeft = null;
            OpenDiff(left, right);
        }

        if (!IsUntitled(loaded.Url)) RecentFiles.Add(loaded.Url);
        RefreshTabStrip();
        ScheduleMenuRefresh();
        FinishOpen();
    }

    private void OnSourceFileLoadFailed(string message)
    {
        if (_loadingSession is not { } failed) return;
        HandleOpenFailure(failed, failed.Url, message);
    }

    private void HandleOpenFailure(DocumentSession failed, string url, string message)
    {
        if (!ReferenceEquals(_loadingSession, failed)) return;

        _loadingSession = null;
        _openingFingerprint = null;
        _pendingDiffLeft = null;
        _activeParser = null;
        failed.IsLoading = false;

        int index = _sessions.IndexOf(failed);
        if (index >= 0 && (failed.Storage is null || failed.Tree is null))
        {
            _sessions.RemoveAt(index);
            _activeIdx = -1;
            if (_sessions.Count == 0) ShowEmptyState();
            else ActivateSession(Math.Min(index, _sessions.Count - 1));
        }
        else if (index >= 0)
        {
            // A failed forced reload restores the intact prior session snapshot.
            ActivateSession(index);
        }

        _progress.Finish();
        SetStatus($"Could not open {FileNameOf(url)}");
        ShowAlert($"Could not open {FileNameOf(url)}", message, new[] { "OK" });
        FinishOpen();
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Tab park / restore
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void SnapshotActiveSession()
    {
        if (ActiveSession is not { } s) return;
        s.Storage = _source.CurrentStorage;
        s.LineStarts = _source.CurrentLineStarts;
        s.Tree = _currentTree;
        s.ParseErrors = _lastParseErrors;
        s.SelectedNode = _currentSelectedNode;
        s.ScrollOrigin = _source.SnapshotScroll();
        s.IsDirty = _docDirty;
        s.TextEncoding = _source.CurrentTextEncoding;
        s.EditRevision = _activeEditRevision;
        s.UndoStack = _source.SessionUndoStack;
    }

    private void SwitchToTab(int i)
    {
        if (i == _activeIdx || i < 0 || i >= _sessions.Count) return;
        if ((ActiveSession?.IsLoading ?? false) || _sessions[i].IsLoading)
        {
            NativeMethods.Beep();
            SetStatus("Still loading, try again in a moment");
            return;
        }
        SnapshotActiveSession();
        ActivateSession(i);
    }

    private void ActivateSession(int i)
    {
        DocumentSession s = _sessions[i];
        if (s.Storage is null || s.Tree is null) { NativeMethods.Beep(); return; }

        _activeIdx = i;
        _source.SessionUndoStack = s.UndoStack;
        _source.AttachSession(s.Url, s.FileSize, s.Storage!, s.LineStarts, s.ScrollOrigin, s.TextEncoding);
        _source.Editor.Highlights = s.Highlights;
        _source.Minimap.Highlights = s.Highlights;
        _currentFileUrl = s.Url;
        _currentTree = s.Tree;
        _lastParseErrors = s.ParseErrors;
        _docDirty = s.IsDirty;
        _activeEditRevision = s.EditRevision;

        _tree.SetRoot(s.Tree);
        _validationWindow?.SetErrors(s.ParseErrors);
        _source.Minimap.SetSnapLines(CollectSnapLines(s.Tree));
        Title = FileTitle(FileNameOf(s.Url));
        RefreshTabStrip();

        if (s.SelectedNode is { } sel) _tree.Select(sel, expandAncestors: true);
        else if (FirstElementChild(s.Tree) is { } first) _tree.Select(first, expandAncestors: true);

        _source.RestoreScroll(s.ScrollOrigin);   // put the user back where they left off (wins over selection scroll)
        SetStatus(FileNameOf(s.Url));

        if (s.NeedsReparse) { s.NeedsReparse = false; ReparseFromEditor(); }
        ScheduleMenuRefresh();
    }

    // An untitled document has no home yet, so it always counts as unsaved (closing must ask).
    private bool IsSessionDirty(int i)
        => (i == _activeIdx ? _docDirty : _sessions[i].IsDirty) || IsUntitled(_sessions[i].Url);

    private void RefreshTabStrip()
    {
        List<string> paths = _sessions.Select(s => s.Url).ToList();
        List<bool> dirty = _sessions.Select((_, i) => IsSessionDirty(i)).ToList();
        TabStrip.SetTabs(paths, _activeIdx, dirty);
    }

    private void CloseTab(int i)
    {
        if (i < 0 || i >= _sessions.Count) return;
        if (_sessions[i].IsLoading || _savingSessionIds.Count > 0)
        {
            NativeMethods.Beep();
            SetStatus("Wait for the file operation to finish");
            return;
        }

        if (IsSessionDirty(i))
        {
            string name = FileNameOf(_sessions[i].Url);
            bool untitled = IsUntitled(_sessions[i].Url);
            int choice = ShowAlert(untitled ? $"Save the new document {name}?" : $"Save changes to {name}?",
                untitled
                    ? "This document has not been saved anywhere yet, closing without saving discards it."
                    : "The file has unsaved changes, closing without saving loses them.",
                new[] { untitled ? "Save As… and Close" : "Save and Close", "Don't Save", "Cancel" }).index;

            if (choice == 0)
            {
                DocumentSession target = _sessions[i];
                string? scratch = untitled ? target.Url : null;
                if (untitled)
                {
                    string? chosen = AskWhereToSave(name);
                    if (chosen is null) return;                       // cancelled: keep the tab
                    target.Url = chosen;                              // the save goes to the chosen place
                }
                void Finish() { DeleteScratchIfUntitled(scratch); FinishCloseTabById(target.Id); }
                if (i == _activeIdx)
                    PerformSave(target.Url, updateCurrent: false, Finish);
                else
                    SaveParkedSession(target, Finish);
                return;
            }
            if (choice == 2 || choice < 0) return;   // Cancel
            // choice == 1 (Don't Save) falls through
        }

        FinishCloseTab(i);
    }

    /// <summary>Save As dialog for a document that has no home yet; null when cancelled.</summary>
    private string? AskWhereToSave(string suggestedName)
    {
        var dlg = new SaveFileDialog
        {
            Title = "Save the new document",
            Filter = "XML Files (*.xml)|*.xml|All Files (*.*)|*.*",
            FileName = suggestedName,
        };
        return dlg.ShowDialog(this) == true && !string.IsNullOrEmpty(dlg.FileName) ? dlg.FileName : null;
    }

    /// <summary>Right-click menu: close every tab except <paramref name="keep"/> (unsaved ones ask, one by one).</summary>
    private void CloseOtherTabs(int keep)
    {
        if (keep < 0 || keep >= _sessions.Count) return;
        Guid keepId = _sessions[keep].Id;
        foreach (Guid id in _sessions.Where(s => s.Id != keepId).Select(s => s.Id).ToList())
        {
            int index = _sessions.FindIndex(s => s.Id == id);
            if (index >= 0) CloseTab(index);
        }
    }

    private void FinishCloseTabById(Guid sessionId)
    {
        int index = _sessions.FindIndex(s => s.Id == sessionId);
        if (index >= 0) FinishCloseTab(index);
    }

    private void FinishCloseTab(int i)
    {
        if (i < 0 || i >= _sessions.Count) return;
        SaveHighlights(_sessions[i]);
        DeleteScratchIfUntitled(_sessions[i].Url);   // "Don't Save" on an untitled document: discard its copy

        if (i == _activeIdx)
        {
            _sessions.RemoveAt(i);
            _activeIdx = -1;
            if (_sessions.Count == 0)
            {
                _source.Editor.Highlights = null;
                _source.Minimap.Highlights = null;
                ShowEmptyState();
                return;
            }
            ActivateSession(Math.Min(i, _sessions.Count - 1));
        }
        else
        {
            _sessions.RemoveAt(i);
            if (i < _activeIdx) _activeIdx--;
            RefreshTabStrip();
        }
    }

    private void SaveParkedSession(DocumentSession s, Action done, Action? failed = null)
    {
        if (s.Storage is not { } storage)
        {
            NativeMethods.Beep();
            SetStatus($"Could not save {FileNameOf(s.Url)} because its document is not loaded");
            failed?.Invoke();
            return;
        }
        string text = storage.GetText();
        string url = s.Url;
        ulong savedRevision = s.EditRevision;
        XmlTextEncoding encoding;
        try { encoding = s.TextEncoding.ReconciledForSave(text); }
        catch (Exception ex)
        {
            ShowAlert("Save failed", ex.Message, new[] { "OK" });
            failed?.Invoke();
            return;
        }
        if (s.FileModificationDateUtc is { } recorded &&
            FileModificationDateUtc(url) is { } current && current != recorded)
        {
            int overwrite = ShowAlert("The file changed on disk",
                $"Another app modified {FileNameOf(url)} after it was opened. Overwriting will replace those external changes.",
                new[] { "Overwrite", "Cancel" }).index;
            if (overwrite != 0)
            {
                failed?.Invoke();
                return;
            }
        }
        if (!_savingSessionIds.Add(s.Id))
        {
            NativeMethods.Beep();
            SetStatus($"Already saving {FileNameOf(s.Url)}");
            failed?.Invoke();
            return;
        }
        ScheduleMenuRefresh();
        Task.Run(() =>
        {
            Exception? error = null;
            try { AtomicWrite(url, encoding.Encode(text)); } catch (Exception ex) { error = ex; }
            Dispatcher.InvokeAsync(() =>
            {
                _savingSessionIds.Remove(s.Id);
                ScheduleMenuRefresh();
                if (error is not null)
                {
                    ShowAlert("Save failed", error.Message, new[] { "OK" });
                    failed?.Invoke();
                    return;
                }
                s.TextEncoding = encoding;
                s.FileModificationDateUtc = FileModificationDateUtc(url);
                try { s.FileSize = new FileInfo(url).Length; } catch { }
                if (s.EditRevision == savedRevision)
                {
                    s.IsDirty = false;
                    if (ReferenceEquals(s, ActiveSession) && _activeEditRevision == savedRevision)
                        _docDirty = false;
                }
                if (ReferenceEquals(s, ActiveSession))
                    _source.AdoptSavedDocument(s.Url, s.FileSize, encoding);
                RefreshTabStrip();
                done();
            });
        });
    }

    private void ShowEmptyState()
    {
        _activeIdx = -1;
        _source.SessionUndoStack = null;
        _currentFileUrl = null;
        _currentTree = null;
        _currentSelectedNode = null;
        _docDirty = false;
        _activeEditRevision = 0;

        Breadcrumb.SetPath(null);
        var empty = new XmlTreeNode(0, NodeKind.Document, "#document");
        _tree.SetRoot(empty);
        _inspector.SetNode(null);
        _chart.SetNode(null);
        _subtags.SetNode(null);
        _hierarchy.SetNode(null);
        _preview.SetPreviewText("", false);
        _errors.SetErrors(Array.Empty<ParseError>());
        _errors.SetValidationScope("");
        _source.Clear();

        _lastParseErrors = Array.Empty<ParseError>();
        _validationWindow?.SetErrors(Array.Empty<ParseError>());
        _validateTimer.Stop();

        Title = AppTitle();
        SetStatus("Open a file (Ctrl+O)");
        RefreshTabStrip();
        ScheduleMenuRefresh();
    }

    private void CloseCurrentFile()
    {
        if (_activeIdx >= 0 && _activeIdx < _sessions.Count) CloseTab(_activeIdx);
        else ShowEmptyState();
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Save / Save As / Revert / Reveal / Copy Path
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void MenuSave()
    {
        if (FileWorkIsActive()) { ShowFileWorkInProgress(); return; }
        if (_currentFileUrl is null || IsUntitled(_currentFileUrl)) { MenuSaveAs(); return; }   // untitled: ask where
        PerformSave(_currentFileUrl, updateCurrent: false, null);
    }

    private void MenuSaveAs()
    {
        if (FileWorkIsActive()) { ShowFileWorkInProgress(); return; }
        var dlg = new SaveFileDialog
        {
            Title = "Save a copy of the current XML",
            Filter = "XML Files (*.xml)|*.xml|All Files (*.*)|*.*",
            FileName = _currentFileUrl is not null ? FileNameOf(_currentFileUrl) : "untitled.xml",
        };
        if (_currentFileUrl is not null && !IsUntitled(_currentFileUrl))
        {
            try { dlg.InitialDirectory = Path.GetDirectoryName(_currentFileUrl); } catch { /* ignore */ }
        }
        if (dlg.ShowDialog(this) == true && !string.IsNullOrEmpty(dlg.FileName))
        {
            string? previous = _currentFileUrl;
            PerformSave(dlg.FileName, updateCurrent: true, () => DeleteScratchIfUntitled(previous));
        }
    }

    // Snapshot the string on the UI thread (cheap reference); write atomically on a background task.
    private void PerformSave(string url, bool updateCurrent, Action? completion)
    {
        if (ActiveSession is not { } session) return;
        if (_openBusy || session.IsLoading)
        {
            ShowFileWorkInProgress();
            return;
        }
        try { url = Path.GetFullPath(url); }
        catch (Exception ex)
        {
            ShowAlert("Save failed", ex.Message, new[] { "OK" });
            return;
        }
        string text = _source.DocumentText;
        SaveHighlights(session, asPath: url);   // the marks belong to the file being written
        Guid sessionId = session.Id;
        ulong savedRevision = _activeEditRevision;

        if (updateCurrent && _sessions.Any(s => s.Id != sessionId && PathEquals(s.Url, url)))
        {
            ShowAlert("That file is already open",
                "Choose a different name or close the existing tab first.", new[] { "OK" });
            return;
        }

        XmlTextEncoding encoding;
        try { encoding = session.TextEncoding.ReconciledForSave(text); }
        catch (Exception ex) { ShowAlert("Save failed", ex.Message, new[] { "OK" }); return; }

        if (PathEquals(session.Url, url) && session.FileModificationDateUtc is { } recorded &&
            FileModificationDateUtc(url) is { } current && current != recorded)
        {
            int overwrite = ShowAlert("The file changed on disk",
                $"Another app modified {FileNameOf(url)} after it was opened. Overwriting will replace those external changes.",
                new[] { "Overwrite", "Cancel" }).index;
            if (overwrite != 0) return;
        }
        if (!_savingSessionIds.Add(sessionId))
        {
            NativeMethods.Beep();
            SetStatus($"Already saving {FileNameOf(url)}");
            return;
        }
        ScheduleMenuRefresh();
        SetStatus($"Saving {FileNameOf(url)}…");
        Task.Run(() =>
        {
            Exception? error = null;
            try { AtomicWrite(url, encoding.Encode(text)); } catch (Exception ex) { error = ex; }
            Dispatcher.InvokeAsync(() =>
            {
                _savingSessionIds.Remove(sessionId);
                ScheduleMenuRefresh();
                if (error is not null)
                {
                    SetStatus("Save failed");
                    ShowAlert("Save failed", error.Message, new[] { "OK" });
                    return;
                }
                DocumentSession? savedSession = _sessions.FirstOrDefault(s => s.Id == sessionId);
                if (savedSession is null) return;
                savedSession.TextEncoding = encoding;
                savedSession.FileModificationDateUtc = FileModificationDateUtc(url);
                try { savedSession.FileSize = new FileInfo(url).Length; } catch { }
                if (updateCurrent)
                {
                    savedSession.Url = url;
                    if (ReferenceEquals(savedSession, ActiveSession))
                    {
                        _currentFileUrl = url;
                        Title = FileTitle(FileNameOf(url));
                    }
                }
                RecentFiles.Add(url);
                if (savedSession.EditRevision == savedRevision)
                {
                    savedSession.IsDirty = false;
                    if (ReferenceEquals(savedSession, ActiveSession) && _activeEditRevision == savedRevision)
                        _docDirty = false;
                }
                if (ReferenceEquals(savedSession, ActiveSession))
                    _source.AdoptSavedDocument(savedSession.Url, savedSession.FileSize, encoding);
                RefreshTabStrip();
                SetStatus($"Saved {FileNameOf(url)}");
                _progress.Flash();
                completion?.Invoke();
            });
        });
    }

    private static void AtomicWrite(string url, byte[] bytes)
    {
        string dir = Path.GetDirectoryName(url) ?? ".";
        string tmp = Path.Combine(dir, Path.GetFileName(url) + ".xmtmp");
        File.WriteAllBytes(tmp, bytes);
        try
        {
            if (File.Exists(url)) File.Replace(tmp, url, null);
            else File.Move(tmp, url);
        }
        catch
        {
            // The replace did not happen (a lock, a sync client, a full disk). Remove the copy: it is
            // the whole document, under a name nobody recognises, sitting next to the original.
            try { if (File.Exists(tmp)) File.Delete(tmp); }
            catch { /* if even that fails there is nothing further to do */ }
            throw;
        }
    }

    private static DateTime? FileModificationDateUtc(string path)
    {
        try { return File.GetLastWriteTimeUtc(path); }
        catch { return null; }
    }

    private static FileFingerprint? ReadFileFingerprint(string path)
    {
        try
        {
            var info = new FileInfo(path);
            info.Refresh();
            if (!info.Exists) return null;
            return new FileFingerprint(info.Length, info.LastWriteTimeUtc, info.CreationTimeUtc);
        }
        catch { return null; }
    }

    private void MenuRevert()
    {
        if (FileWorkIsActive()) { ShowFileWorkInProgress(); return; }
        if (_currentFileUrl is null) return;
        int c = ShowAlert("Revert to saved?",
            $"This discards any unsaved changes in {FileNameOf(_currentFileUrl)}.",
            new[] { "Revert", "Cancel" }).index;
        if (c == 0) OpenFiles(new[] { _currentFileUrl }, forceReload: true);
    }

    private void MenuRevealInExplorer()
    {
        if (_currentFileUrl is null) return;
        NativeMethods.RevealInExplorer(_currentFileUrl);
    }

    private void MenuCopyPath()
    {
        if (_currentFileUrl is null) return;
        try { Clipboard.SetText(_currentFileUrl); } catch { /* clipboard may be locked */ }
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Newline scan (mmap, unsafe)
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private static int CountNewlines(string path)
    {
        try
        {
            long len = new FileInfo(path).Length;
            if (len <= 0) return 1;

            int count = 1;   // line count starts at 1
            using var mmf = MemoryMappedFile.CreateFromFile(path, FileMode.Open, null, 0, MemoryMappedFileAccess.Read);
            using var acc = mmf.CreateViewAccessor(0, len, MemoryMappedFileAccess.Read);
            unsafe
            {
                byte* ptr = null;
                acc.SafeMemoryMappedViewHandle.AcquirePointer(ref ptr);
                try
                {
                    for (long i = 0; i < len; i++)
                        if (ptr[i] == 0x0A) count++;
                }
                finally
                {
                    acc.SafeMemoryMappedViewHandle.ReleasePointer();
                }
            }
            return count;
        }
        catch
        {
            return 0;   // fall back to the time-based progress asymptote
        }
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Tree / line lookup algorithms
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private static XmlTreeNode? FirstElementChild(XmlTreeNode? node)
    {
        if (node is null) return null;
        foreach (XmlTreeNode c in node.Children)
            if (c.Kind == NodeKind.Element) return c;
        return null;
    }

    private static IReadOnlyList<int> CollectSnapLines(XmlTreeNode? root)
    {
        var lines = new List<int>();
        if (root is null) return lines;

        void Walk(XmlTreeNode n, int depth)
        {
            if (depth is >= 1 and <= 3 && n.Kind == NodeKind.Element) lines.Add(n.StartLine);
            if (depth >= 3) return;
            foreach (XmlTreeNode c in n.Children)
                if (c.Kind == NodeKind.Element) Walk(c, depth + 1);
        }

        foreach (XmlTreeNode c in root.Children)
            if (c.Kind == NodeKind.Element) Walk(c, 1);
        return lines;
    }

    /// <summary>
    /// Magnet targets for the minimap's left lane, for the currently selected element.
    /// <para>Walks the whole ANCESTOR CHAIN (outermost first), adding each ancestor and that ancestor's
    /// element children, then the node itself and its element children. Scoping the set to the immediate
    /// parent only, what this did before, made the lane's reachable line span equal the parent's span,
    /// so it shrank by an order of magnitude per level: at &lt;region&gt; depth the magnets were the 32
    /// regions and covered the file, but at &lt;supplysector&gt; depth every click anywhere in the lane
    /// landed back inside the region already in view. The chain walk keeps whole-file coverage at
    /// EVERY depth while still offering local detail near the selection.</para>
    /// </summary>
    // One per parsed tree; compared by root reference so a reparse rebuilds it automatically.
    private ElementLevelIndex? _levelIndex;

    /// <summary>
    /// Magnet targets for the minimap's left lane: every element in the file at the SAME LEVEL as the
    /// selected element (same tag name, same depth).
    /// <para>On a region the next stop is the next region; on a supplysector the next stop is the next
    /// supplysector. It works at every depth, across
    /// the whole file. If a level is too crowded to be useful as magnets (more than 4,000 elements, e.g.
    /// every &lt;speed&gt; line), the lane climbs to the nearest ancestor level that fits.</para>
    /// </summary>
    private IReadOnlyList<int> CollectLocalSnapLines(XmlTreeNode node)
    {
        const int maxTargets = 4000;

        if (_currentTree is null) return new[] { node.StartLine };
        if (_levelIndex is null || !ReferenceEquals(_levelIndex.Root, _currentTree))
            _levelIndex = new ElementLevelIndex(_currentTree);

        XmlTreeNode? level = node;
        int depth = ElementLevelIndex.DepthOf(node);
        while (level is { Kind: NodeKind.Element })
        {
            IReadOnlyList<int> lines = _levelIndex.LinesAt(depth, level.Name);
            if (lines.Count > 0 && lines.Count <= maxTargets) return lines;
            level = level.Parent;
            depth--;
        }
        return CollectSnapLines(_currentTree);
    }

    private static XmlTreeNode? FindDeepestNode(int line, XmlTreeNode node)
    {
        if (node.Kind == NodeKind.Document)
        {
            foreach (XmlTreeNode c in node.Children)
                if (c.Kind == NodeKind.Element)
                {
                    XmlTreeNode? hit = FindDeepestNode(line, c);
                    if (hit is not null) return hit;
                }
            return null;
        }

        int end = Math.Max(node.StartLine, node.EndLine);
        if (line < node.StartLine || line > end) return null;

        foreach (XmlTreeNode child in node.Children)
        {
            if (child.Kind != NodeKind.Element) continue;
            int cend = Math.Max(child.StartLine, child.EndLine);
            if (line >= child.StartLine && line <= cend)
                return FindDeepestNode(line, child) ?? child;
        }
        return node;
    }

    // Binary-search descent used for Find-All path lookups.
    private static XmlTreeNode? FastDeepestNode(int line, XmlTreeNode node)
    {
        if (node.Kind == NodeKind.Document)
        {
            foreach (XmlTreeNode c in node.Children)
                if (c.Kind == NodeKind.Element)
                {
                    XmlTreeNode? hit = FastDeepestNode(line, c);
                    if (hit is not null) return hit;
                }
            return null;
        }

        int end0 = Math.Max(node.StartLine, node.EndLine);
        if (line < node.StartLine || line > end0) return null;

        XmlTreeNode cur = node;
        while (true)
        {
            List<XmlTreeNode> kids = cur.Children;
            if (kids.Count == 0) return cur;

            int found = -1;
            for (int i = 0; i < kids.Count; i++)
            {
                if (kids[i].StartLine <= line) found = i;
                else break;
            }

            int probe = found;
            bool advanced = false;
            while (probe >= 0)
            {
                XmlTreeNode k = kids[probe];
                if (k.Kind == NodeKind.Element)
                {
                    int kend = Math.Max(k.StartLine, k.EndLine);
                    if (line >= k.StartLine && line <= kend) { cur = k; advanced = true; break; }
                    if (kend < line) break;
                }
                probe--;
            }
            if (!advanced) return cur;
        }
    }

    // Ancestor path "region[USA] › supplysector[trn_pass] › logit-exponent".
    private static string TreePath(XmlTreeNode node)
    {
        var parts = new List<string>();
        for (XmlTreeNode? cur = node; cur is { Kind: NodeKind.Element }; cur = cur.Parent)
        {
            string key = KeyAttrValue(cur);
            parts.Add(key.Length > 0 ? $"{cur.Name}[{key}]" : cur.Name);
        }
        parts.Reverse();
        return string.Join(" › ", parts);
    }

    private static readonly string[] KeyAttrNames = { "name", "year", "type", "id", "key" };

    private static string KeyAttrValue(XmlTreeNode node)
    {
        foreach (string pref in KeyAttrNames)
            foreach ((string Name, string Value) a in node.Attributes)
                if (a.Name == pref) return a.Value;
        return node.Attributes.Count > 0 ? node.Attributes[0].Value : "";
    }

    private static bool PathEquals(string a, string b)
        => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
}
