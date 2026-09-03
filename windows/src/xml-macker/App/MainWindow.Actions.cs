using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using XMLMacker.Charts;
using XMLMacker.Core;
using XMLMacker.Editor;
using XMLMacker.Shared;
using XMLMacker.Theme;
using XMLMacker.Windows;

namespace XMLMacker.App;

/// <summary>
/// Cross-cutting actions: diff flow, orbit, the validation window, the chart pop-out, the Share/Print
/// menu, window-close choice, Quit, About, and the shared themed-dialog helpers.
/// </summary>
public partial class MainWindow
{
    private bool _quitting;
    private bool _closeReviewInProgress;
    private bool _sessionEndingReviewScheduled;
    private Action? _reviewApprovedAction;

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Diff
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void StartDiff()
    {
        if (_sessions.Any(s => s.IsLoading))
        {
            NativeMethods.Beep();
            SetStatus("Still loading, try again in a moment");
            return;
        }

        // Always the picker, with or without open files: it confirms which file is left and which
        // is right, and either side can be browsed to a file that is not open yet (it is opened first).
        if (PickTwoFiles(ActiveSession) is { } pick) StartDiff(pick.left, pick.right);
    }

    /// <summary>One side of a comparison: an open document, or a file that will be opened first.</summary>
    private sealed record DiffSpec(DocumentSession? Session, string? Path, string Name);

    private (DiffSpec Left, DiffSpec Right)? _pendingDiffSpecs;

    /// <summary>Opens the comparison now when both sides are open; otherwise loads the missing file(s) first.</summary>
    private void StartDiff(DiffSpec left, DiffSpec right)
    {
        if (left.Session is not null && right.Session is not null)
        {
            OpenDiff(left.Session, right.Session);
            return;
        }
        _pendingDiffSpecs = (left, right);
        string next = left.Session is null ? left.Path! : right.Path!;
        SetStatus($"Opening {FileNameOf(next)} for the comparison…");
        LoadFile(next);
    }

    /// <summary>
    /// From the file-loaded path: attaches the document that just loaded to the pending comparison, loads
    /// the other side if it is still missing, and opens the Diff once both are ready. True when it acted.
    /// </summary>
    private bool TryContinuePendingDiff()
    {
        if (_pendingDiffSpecs is not { } p || ActiveSession is not { IsLoading: false } s) return false;
        DiffSpec left = p.Left, right = p.Right;
        if (left.Session is null && PathEquals(left.Path!, s.Url)) left = left with { Session = s };
        else if (right.Session is null && PathEquals(right.Path!, s.Url)) right = right with { Session = s };
        else return false;   // some other file finished loading

        if (left.Session is null || right.Session is null)
        {
            _pendingDiffSpecs = (left, right);
            string next = left.Session is null ? left.Path! : right.Path!;
            Dispatcher.BeginInvoke(new Action(() => LoadFile(next)));   // after this load has fully finished
            return true;
        }
        _pendingDiffSpecs = null;
        OpenDiff(left.Session, right.Session);
        return true;
    }

    private void OpenDiff(DocumentSession left, DocumentSession right)
    {
        string? lt = SessionText(left);
        string? rt = SessionText(right);
        if (lt is null || rt is null) return;
        if (lt.Length > 64_000_000 || rt.Length > 64_000_000)
        {
            NativeMethods.Beep();
            SetStatus("One of the files is too large to diff (64 MB cap)");
            return;
        }

        SetStatus("Comparing…");
        var pair = new DiffPair(left, right);   // mutable: a side can be swapped from inside the window
        var diff = new DiffWindow(FileNameOf(left.Url), lt, FileNameOf(right.Url), rt) { Owner = this };
        diff.ApplyEdit = (side, range, replacement) =>
        {
            DocumentSession target = side == DiffSide.Left ? pair.Left : pair.Right;
            return ApplyDiffEdit(target, range, replacement);
        };
        diff.OpenFilesProvider = DiffCandidateFiles;
        diff.ChangeFileRequested = (side, path) => ChangeDiffFile(diff, pair, side, path);
        diff.Present();
        SetStatus($"Comparing {FileNameOf(left.Url)} ⟷ {FileNameOf(right.Url)}");
    }

    private string? SessionText(DocumentSession s)
        => ReferenceEquals(s, ActiveSession) ? _source.DocumentText : s.Storage?.GetText();

    private bool ApplyDiffEdit(DocumentSession session, (int Start, int Length) range, string replacement)
    {
        var clock = System.Diagnostics.Stopwatch.StartNew();
        if (ReferenceEquals(session, ActiveSession))
        {
            if (!_source.PerformEdit(range, replacement)) return false;
            long editMs = clock.ElapsedMilliseconds;
            MarkDirty();
            ReparseFromEditor();
            Diag.Log($"diff edit (active tab): editor {editMs} ms, reparse queued at {clock.ElapsedMilliseconds} ms");
            return true;
        }

        ITextBuffer? storage = session.Storage;
        if (storage is null || range.Start + range.Length > storage.Length) return false;
        storage.Replace(range.Start, range.Length, replacement);
        session.IsDirty = true;
        session.LineStarts = LineIndex.BuildLineStarts(storage.GetText());
        session.Highlights.ShiftForEdit(range.Start, range.Length, replacement.Length);
        SaveHighlights(session);
        session.NeedsReparse = true;
        Diag.Log($"diff edit (parked tab): {clock.ElapsedMilliseconds} ms");
        return true;
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Orbit
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void OpenOrbit()
    {
        if (_orbitWindow is null)
        {
            _orbitWindow = new OrbitWindow { Owner = this };
            _orbitWindow.NodeActivated += n => { _tree.Select(n, expandAncestors: true); _orbitWindow?.SetNode(n); };
            _orbitWindow.NodeEditRequested += OrbitQuickEdit;
            _orbitWindow.AttributeEditRequested = OrbitAttributeEdit;
            _orbitWindow.TextEditRequested = OrbitTextEdit;
            _orbitWindow.Closed += (_, _) => _orbitWindow = null;
        }
        _orbitWindow.Present(_currentSelectedNode);
    }

    private void OrbitQuickEdit(XmlTreeNode node)
    {
        bool isLeaf = !node.Children.Any(c => c.Kind == NodeKind.Element);
        bool editingText = isLeaf && !string.IsNullOrEmpty(node.TextValue);

        (string Name, string Value)? keyAttr = null;
        foreach (string pref in KeyAttrNames)
        {
            foreach ((string Name, string Value) a in node.Attributes)
                if (a.Name == pref) { keyAttr = a; break; }
            if (keyAttr is not null) break;
        }
        if (keyAttr is null && node.Attributes.Count > 0) keyAttr = node.Attributes[0];

        if (!editingText && keyAttr is null)
        {
            NativeMethods.Beep();
            SetStatus($"{node.DisplayLabel} has no value or attribute to edit here, use the Inspector");
            return;
        }

        string title = editingText ? $"Edit value of {node.DisplayLabel}" : $"Edit {keyAttr!.Value.Name} of {node.DisplayLabel}";
        string initial = editingText ? node.TextValue : keyAttr!.Value.Value;
        string? val = PromptText(title, "", initial, "Apply");
        if (val is null) return;

        bool ok = editingText
            ? _source.ApplyTextEdit(node, val)
            : _source.ApplyAttrEdit(node, keyAttr!.Value.Name, val);
        if (ok)
        {
            MarkDirty();
            _tree.RefreshNode(node);
            _subtags.RefreshValuesOnly();
            _inspector.RefreshValuesOnly();
            _chart.RefreshCurrent();
            if (_currentSelectedNode is not null) _orbitWindow?.SetNode(_currentSelectedNode);
            ScheduleAutoValidation();
            SetStatus($"Updated {node.DisplayLabel}");
        }
        else
        {
            NativeMethods.Beep();
        }
    }

    private bool OrbitAttributeEdit(XmlTreeNode node, string name, string value)
    {
        if (!_source.ApplyAttrEdit(node, name, value)) { NativeMethods.Beep(); return false; }
        MarkDirty();
        _tree.RefreshNode(node);
        _subtags.RefreshValuesOnly();
        _inspector.RefreshValuesOnly();
        _chart.RefreshCurrent();
        ScheduleAutoValidation();
        SetStatus($"Updated {node.DisplayLabel}");
        return true;
    }

    private bool OrbitTextEdit(XmlTreeNode node, string value)
    {
        if (!_source.ApplyTextEdit(node, value)) { NativeMethods.Beep(); return false; }
        MarkDirty();
        _tree.RefreshNode(node);
        _subtags.RefreshValuesOnly();
        _inspector.RefreshValuesOnly();
        _chart.RefreshCurrent();
        ScheduleAutoValidation();
        SetStatus($"Updated {node.DisplayLabel}");
        return true;
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Validation window + chart pop-out
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void ShowValidation()
    {
        if (_validationWindow is not null)
        {
            _validationWindow.SetErrors(_lastParseErrors);
            _validationWindow.Show();
            _validationWindow.Activate();
            return;
        }

        var w = new ValidationWindow { Owner = this };
        w.SetErrors(_lastParseErrors);
        w.Closed2 += () => _validationWindow = null;
        w.RevalidateRequested += Revalidate;
        w.ErrorClicked += (line, _) => _source.ScrollToLine(line);
        w.FixClicked += ApplyLintFix;
        _validationWindow = w;
        w.Show();
    }

    private void OpenChartPopout()
    {
        string path = _currentSelectedNode is not null ? TreePath(_currentSelectedNode) : "";

        if (_chartPopout is not null)
        {
            _chartPopout.Show();
            _chartPopout.Activate();
            _chartPopout.SetMirroredSeries(_chart.CurrentTrendSeries, path, _currentSelectedNode, _currentTree);
            return;
        }

        var w = new ChartPopoutWindow { Owner = this };
        w.PopoutClosed += () => _chartPopout = null;
        w.RevealNodeRequested += node => _tree.Select(node, expandAncestors: true);
        w.SetMirroredSeries(_chart.CurrentTrendSeries, path, _currentSelectedNode, _currentTree);
        _chartPopout = w;
        w.Show();
    }

    private void OpenChartBuilder()
    {
        OpenChartPopout();
        _chartPopout?.ShowBuilder(_currentSelectedNode, _currentTree);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Share / Print
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void SharePrintSelection()
    {
        string? text = ShareSelectionText(2_000_000);
        if (text is null) { NativeMethods.Beep(); SetStatus("Select some text in the source first"); return; }
        string job = _currentFileUrl is not null ? FileNameOf(_currentFileUrl) : "xml-macker";
        PrintService.Print(text, $"Selection, {job}");
    }

    private void SharePrintCurrentElement()
    {
        if (_currentSelectedNode is not { } node || ElementText(node, 2_000_000, announce: false) is not { } et)
        {
            NativeMethods.Beep();
            SetStatus("Select an element in the tree first (2 M character print cap)");
            return;
        }
        PrintService.Print(et.Text, $"{node.DisplayLabel}, {FileNameOf(_currentFileUrl)}");
    }

    private void SharePrintPickElement()
    {
        if (_currentTree is null) { NativeMethods.Beep(); return; }
        var picker = new ElementPickerWindow(_currentTree) { Owner = this, Title = "Choose an element to print" };
        if (picker.ShowDialog() == true && picker.ChosenNode is { } node
            && ElementText(node, 2_000_000, announce: false) is { } et)
        {
            PrintService.Print(et.Text, $"{node.DisplayLabel}, {FileNameOf(_currentFileUrl)}");
        }
    }

    private void ShareToLLM(LLMTarget target, string kind)
    {
        string prompt;
        if (kind == "selection")
        {
            string? text = ShareSelectionText(100_000_000);
            if (text is null) { NativeMethods.Beep(); return; }
            prompt = ShareService.SelectionPrompt(FileNameOf(_currentFileUrl), text);
        }
        else // element
        {
            if (_currentSelectedNode is not { } node || ElementText(node, announce: false) is not { } et)
            {
                NativeMethods.Beep();
                SetStatus("Select an element in the tree first");
                return;
            }
            prompt = ShareService.ElementPrompt(node.DisplayLabel, TreePath(node), FileNameOf(_currentFileUrl), et.Text);
        }

        // Type it straight into the site inside the Learn pane, the same mechanism "Define" uses, 
        // instead of only opening the site in an external browser and hoping for a manual paste. The Learn
        // pane also copies the prompt to the clipboard first, so Ctrl+V still works if the site's chat
        // box cannot be found. Sites the embedded pane cannot host (Gemini) keep the external route.
        int chat = LearnPane.ChatIndexFor(target.DisplayName());
        if (chat < 0)
        {
            ShareXmlText(kind == "selection" ? prompt : prompt, target, p => p);
            return;
        }

        if (_workspaceMode != WorkspaceMode.Learn) ApplyWorkspace(WorkspaceMode.Learn, save: true);
        else EnsureLearnPane();
        if (_learn is null) { ShareXmlText(prompt, target, p => p); return; }

        _learn.OpenAndInsert(chat, prompt);
        SetStatus($"Typing the {(kind == "selection" ? "selection" : "element")} into {target.DisplayName()}, it is on the clipboard too");
    }

    /// <summary>
    /// Sends XML to a chat service: the WHOLE text goes to the clipboard whenever Windows will take it,
    /// and the site opens (pre-filled only when small enough for a URL).
    /// <para>The old flow stopped on long text with a three-button question, and on a very long element
    /// the clipboard call could fail silently so nothing was copied at all. Now there is no question:
    /// copy everything; if the clipboard refuses that much, fall back to the largest excerpt it will
    /// accept and SAY so in the status bar, with the exact byte counts.</para>
    /// </summary>
    private void ShareXmlText(string xml, LLMTarget target, Func<string, string> makePrompt)
    {
        string fullPrompt = makePrompt(xml);
        int fullBytes = System.Text.Encoding.UTF8.GetByteCount(xml);

        if (TrySetClipboard(fullPrompt))
        {
            string status = ShareService.DeliverPrompt(fullPrompt, target, alreadyOnClipboard: true);
            SetStatus($"{status}, {fullBytes:N0} UTF-8 bytes of XML copied in full");
            return;
        }

        // Windows would not take the whole thing (memory pressure or a locked clipboard). Halve the
        // size until it does, always ending on a complete Unicode character.
        int limit = Math.Max(ShareTextPolicy.CompatibilityUtf8ByteLimit, fullBytes / 2);
        while (limit >= ShareTextPolicy.CompatibilityUtf8ByteLimit)
        {
            ShareTextExcerpt excerpt = ShareTextPolicy.Excerpt(xml, limit);
            string prompt = makePrompt(excerpt.Text)
                + $"\n\nxml-macker excerpt: {excerpt.IncludedUtf8Bytes:N0} of {excerpt.TotalUtf8Bytes:N0} UTF-8 bytes "
                + "included; the XML may end before its closing tags.";
            if (TrySetClipboard(prompt))
            {
                string status = ShareService.DeliverPrompt(prompt, target, alreadyOnClipboard: true);
                SetStatus($"{status}, the clipboard would not take the full {fullBytes:N0} bytes, so "
                          + $"{excerpt.IncludedUtf8Bytes:N0} of them were copied");
                return;
            }
            if (limit == ShareTextPolicy.CompatibilityUtf8ByteLimit) break;
            limit = Math.Max(ShareTextPolicy.CompatibilityUtf8ByteLimit, limit / 2);
        }

        NativeMethods.Beep();
        SetStatus($"Couldn't copy, the clipboard refused even a {ShareTextPolicy.CompatibilityUtf8ByteLimit:N0}-byte excerpt");
    }

    private void ShareCopySelectionInFull()
    {
        string? text = ShareSelectionText(100_000_000);
        if (text is null) { NativeMethods.Beep(); SetStatus("Select some text in the source first"); return; }
        TrySetClipboard(text);
        int bytes = System.Text.Encoding.UTF8.GetByteCount(text);
        SetStatus($"Copied the complete selection ({bytes:N0} UTF-8 bytes); xml-macker applied no share limit");
    }

    private void ShareExportElement()
    {
        if (_currentSelectedNode is not { } node) { NativeMethods.Beep(); SetStatus("Select an element in the tree first"); return; }
        ExportElementToFile(node);
    }

    private void EnsureFileCurrentForShare(Action proceed)
    {
        if (!_docDirty || _currentFileUrl is null) { proceed(); return; }

        switch (_rememberedShareChoice)
        {
            case ShareUnsavedChoice.SaveFirst: PerformSave(_currentFileUrl, updateCurrent: false, proceed); return;
            case ShareUnsavedChoice.ShareDisk: proceed(); return;
        }

        (int index, bool remember) = ShowAlert("This file has unsaved changes",
            "Sharing sends the file as it is on disk. Save first so your latest edits are included, or share the last saved version.",
            new[] { "Save and Share", "Share Saved Version", "Cancel" },
            suppressionText: "Remember my choice for this session");

        if (index == 0) { if (remember) _rememberedShareChoice = ShareUnsavedChoice.SaveFirst; PerformSave(_currentFileUrl, updateCurrent: false, proceed); }
        else if (index == 1) { if (remember) _rememberedShareChoice = ShareUnsavedChoice.ShareDisk; proceed(); }
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Window close choice + Quit / About / Bring All to Front
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void OnWindowClosing(object? sender, CancelEventArgs e)
    {
        if (_quitting) { AskReopenPreferenceIfNeeded(); return; }

        if (_closeReviewInProgress || _sessionEndingReviewScheduled)
        {
            e.Cancel = true;
            return;
        }

        if (FileWorkIsActive())
        {
            e.Cancel = true;
            ShowFileWorkInProgress();
            return;
        }

        if (_sessions.Count == 0) return;
        if (_sessions.Count == 1)
        {
            if (!IsSessionDirty(0)) { AskReopenPreferenceIfNeeded(); return; }
            e.Cancel = true;
            ReviewDirtySessionsAndClose();
            return;
        }

        string choice = AppSettings.Instance.GetString(CloseChoiceKey, "");
        if (choice == "all") { e.Cancel = true; ReviewDirtySessionsAndClose(); return; }
        if (choice == "tab") { CloseCurrentFile(); e.Cancel = true; return; }

        (int index, bool remember) = ShowAlert($"You have {_sessions.Count} files open",
            "Close only the current tab, or close all files and quit?",
            new[] { "Close Current Tab", "Close All Files", "Cancel" },
            suppressionText: "Remember my choice");

        if (index == 0)
        {
            if (remember) AppSettings.Instance.SetString(CloseChoiceKey, "tab");
            CloseCurrentFile();
            e.Cancel = true;
        }
        else if (index == 1)
        {
            if (remember) AppSettings.Instance.SetString(CloseChoiceKey, "all");
            e.Cancel = true;
            ReviewDirtySessionsAndClose();
        }
        else
        {
            e.Cancel = true;
        }
    }

    private void ReviewDirtySessionsAndClose()
        => BeginDirtySessionReview(CloseAfterReview);

    private void BeginDirtySessionReview(Action approvedAction)
    {
        if (_closeReviewInProgress) return;
        if (FileWorkIsActive())
        {
            ShowFileWorkInProgress();
            return;
        }

        _closeReviewInProgress = true;
        _reviewApprovedAction = approvedAction;
        ScheduleMenuRefresh();
        ContinueDirtySessionReview();
    }

    private void ContinueDirtySessionReview()
    {
        SnapshotActiveSession();
        var dirtyIds = new List<Guid>();
        for (int i = 0; i < _sessions.Count; i++)
            if (IsSessionDirty(i)) dirtyIds.Add(_sessions[i].Id);

        if (dirtyIds.Count == 0)
        {
            CompleteDirtySessionReview();
            return;
        }

        string names = string.Join(", ", dirtyIds.Select(id =>
            _sessions.First(s => s.Id == id)).Select(s => FileNameOf(s.Url)));
        string heading = dirtyIds.Count == 1
            ? "Save changes before closing?"
            : $"Save changes in {dirtyIds.Count} files before closing?";
        string saveLabel = dirtyIds.Count == 1 ? "Save" : "Save All";
        int reviewChoice = ShowAlert(heading, names,
            new[] { saveLabel, "Don't Save", "Cancel" }).index;

        if (reviewChoice == 0)
            SaveDirtySessions(dirtyIds, 0, ContinueDirtySessionReview, CancelDirtySessionReview);
        else if (reviewChoice == 1)
            CompleteDirtySessionReview();
        else
            CancelDirtySessionReview();
    }

    private void QuitApp()
    {
        if (_closeReviewInProgress || _sessionEndingReviewScheduled) return;
        if (FileWorkIsActive())
        {
            ShowFileWorkInProgress();
            return;
        }
        ReviewDirtySessionsAndClose();
    }

    private void SaveDirtySessions(IReadOnlyList<Guid> dirtyIds, int position,
                                   Action completed, Action failed)
    {
        if (position >= dirtyIds.Count)
        {
            completed();
            return;
        }

        DocumentSession? session = _sessions.FirstOrDefault(s => s.Id == dirtyIds[position]);
        if (session is null)
        {
            SaveDirtySessions(dirtyIds, position + 1, completed, failed);
            return;
        }

        string? scratch = IsUntitled(session.Url) ? session.Url : null;
        if (scratch is not null)
        {
            string? chosen = AskWhereToSave(FileNameOf(session.Url));
            if (chosen is null) { failed(); return; }
            session.Url = chosen;
        }
        SaveParkedSession(session,
            () => { DeleteScratchIfUntitled(scratch); SaveDirtySessions(dirtyIds, position + 1, completed, failed); },
            failed);
    }

    private void CompleteDirtySessionReview()
    {
        Action? approvedAction = _reviewApprovedAction;
        _reviewApprovedAction = null;
        _closeReviewInProgress = false;
        ScheduleMenuRefresh();
        approvedAction?.Invoke();
    }

    private void CancelDirtySessionReview()
    {
        _reviewApprovedAction = null;
        _closeReviewInProgress = false;
        ScheduleMenuRefresh();
    }

    private bool FileWorkIsActive()
        => _openBusy || _openQueue.Count > 0 || _sessions.Any(s => s.IsLoading) || _savingSessionIds.Count > 0;

    private void ShowFileWorkInProgress()
    {
        NativeMethods.Beep();
        ShowAlert("Please wait for the file operation",
            "xml-macker is still opening or saving a file. The window will stay open until that operation finishes.",
            new[] { "OK" });
    }

    private void CloseAfterReview()
    {
        _quitting = true;
        ScheduleMenuRefresh();
        Dispatcher.BeginInvoke(new Action(Close));
    }

    private void MenuResetAllSettings()
    {
        if (_closeReviewInProgress || _sessionEndingReviewScheduled) return;
        if (FileWorkIsActive())
        {
            ShowFileWorkInProgress();
            return;
        }
        if (!_appDelegate.ConfirmResetAllSettings(this)) return;
        BeginDirtySessionReview(ResetAllSettingsAfterReview);
    }

    private void ResetAllSettingsAfterReview()
    {
        _quitting = true;
        _appDelegate.ResetAllSettingsAndRelaunch();
    }

    internal bool ProtectSessionEnding()
    {
        if (_quitting) return false;

        SnapshotActiveSession();
        bool hasDirtySession = _sessions.Select((_, i) => i).Any(IsSessionDirty);
        bool mustCancel = hasDirtySession || FileWorkIsActive() ||
                          _closeReviewInProgress || _sessionEndingReviewScheduled;
        if (!mustCancel)
        {
            _quitting = true;
            return false;
        }

        if (!_closeReviewInProgress && !_sessionEndingReviewScheduled)
        {
            _sessionEndingReviewScheduled = true;
            Dispatcher.BeginInvoke(new Action(() =>
            {
                _sessionEndingReviewScheduled = false;
                QuitApp();
            }));
        }
        return true;
    }

    private void ShowAbout()
        => new AboutWindow(AppVersion) { Owner = this }.ShowDialog();

    private static void OpenProjectWebsite()
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("https://github.com/GCAM-KAIST")
            {
                UseShellExecute = true,
            });
        }
        catch
        {
            NativeMethods.Beep();
        }
    }

    private void ShowTour()
    {
        if (_tourWindow is { IsVisible: true }) { _tourWindow.Activate(); return; }
        if (_workspaceMode != WorkspaceMode.Full) ApplyWorkspace(WorkspaceMode.Full, save: true);
        _tourWindow = new TourWindow(this, TourAnchors);
        _tourWindow.Closed += (_, _) => _tourWindow = null;
        AppSettings.Instance.SetBool(TourShownKey, true);
        _tourWindow.Show();
    }

    private void BringAllToFront()
    {
        Activate();
        foreach (Window w in _popouts.Values) { try { w.Activate(); } catch { } }
        _chartPopout?.Activate();
        _validationWindow?.Activate();
        _findPanel?.Activate();
        _orbitWindow?.Activate();
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Themed dialog helpers
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private Window MakeDialog(string title, double minWidth)
    {
        var dlg = new Window
        {
            Title = title,
            SizeToContent = SizeToContent.WidthAndHeight,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = this,
            ShowInTaskbar = false,
            MinWidth = minWidth,
        };
        dlg.SetResourceReference(BackgroundProperty, XMColor.Bg);
        dlg.SetResourceReference(ForegroundProperty, XMColor.Text);
        return dlg;
    }

    private static Button DialogButton(string content, bool isDefault, bool isCancel, Thickness margin)
    {
        var b = new Button
        {
            Content = content,
            MinWidth = 90,
            Padding = new Thickness(12, 4, 12, 4),
            Margin = margin,
            IsDefault = isDefault,
            IsCancel = isCancel,
        };
        return b;
    }

    /// <summary>A themed modal alert. Returns the pressed button index (last button on Esc / −1 if
    /// dismissed) and whether the optional suppression checkbox was ticked.</summary>
    private (int index, bool remembered) ShowAlert(string title, string body, string[] buttons, string? suppressionText = null)
    {
        Window dlg = MakeDialog(title, 380);
        var root = new StackPanel { Margin = new Thickness(20) };

        var head = new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10), MaxWidth = 460 };
        XMFont.UiHeader.ApplyTo(head);
        head.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text);
        root.Children.Add(head);

        if (!string.IsNullOrEmpty(body))
        {
            var b = new TextBlock { Text = body, TextWrapping = TextWrapping.Wrap, MaxWidth = 460, Margin = new Thickness(0, 0, 0, 16) };
            XMFont.UiBody.ApplyTo(b);
            b.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text2);
            root.Children.Add(b);
        }

        CheckBox? suppress = null;
        if (suppressionText is not null)
        {
            suppress = new CheckBox { Content = suppressionText, Margin = new Thickness(0, 0, 0, 14) };
            suppress.SetResourceReference(ForegroundProperty, XMColor.Text2);
            root.Children.Add(suppress);
        }

        var btnRow = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        int result = -1;
        for (int i = 0; i < buttons.Length; i++)
        {
            int idx = i;
            Button btn = DialogButton(buttons[i], isDefault: i == 0, isCancel: i == buttons.Length - 1, new Thickness(8, 0, 0, 0));
            btn.Click += (_, _) => { result = idx; dlg.Close(); };
            btnRow.Children.Add(btn);
        }
        root.Children.Add(btnRow);

        dlg.Content = root;
        dlg.ShowDialog();
        return (result, suppress?.IsChecked == true);
    }

    /// <summary>A themed single-line text prompt. Returns the entered text, or null on Cancel/Esc.</summary>
    private string? PromptText(string title, string body, string initial, string okText)
    {
        Window dlg = MakeDialog(title, 320);
        var root = new StackPanel { Margin = new Thickness(20) };

        var head = new TextBlock { Text = title, Margin = new Thickness(0, 0, 0, 8) };
        XMFont.UiHeader.ApplyTo(head);
        head.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text);
        root.Children.Add(head);

        if (!string.IsNullOrEmpty(body))
        {
            var b = new TextBlock { Text = body, Margin = new Thickness(0, 0, 0, 8) };
            XMFont.UiBody.ApplyTo(b);
            b.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text2);
            root.Children.Add(b);
        }

        var box = new TextBox { Text = initial, Width = 220, Margin = new Thickness(0, 0, 0, 14) };
        root.Children.Add(box);

        var btnRow = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        string? result = null;
        Button ok = DialogButton(okText, isDefault: true, isCancel: false, new Thickness(0, 0, 8, 0));
        Button cancel = DialogButton("Cancel", isDefault: false, isCancel: true, new Thickness(0));
        ok.MinWidth = cancel.MinWidth = 80;
        ok.Click += (_, _) => { result = box.Text; dlg.Close(); };
        cancel.Click += (_, _) => { result = null; dlg.Close(); };
        btnRow.Children.Add(ok);
        btnRow.Children.Add(cancel);
        root.Children.Add(btnRow);

        dlg.Content = root;
        dlg.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        dlg.ShowDialog();
        return result;
    }

    /// <summary>The "Compare which two files?" picker with two dropdowns.</summary>
    private (DiffSpec left, DiffSpec right)? PickTwoFiles(DocumentSession? active)
    {
        Window dlg = MakeDialog("Compare which two files?", 470);
        var root = new StackPanel { Margin = new Thickness(20) };

        var head = new TextBlock { Text = "Compare which two files?", Margin = new Thickness(0, 0, 0, 12) };
        XMFont.UiHeader.ApplyTo(head);
        head.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text);
        root.Children.Add(head);

        // The choices: every open tab, plus any file browsed in from disk (opened when Compare is pressed).
        var specs = new List<DiffSpec>(_sessions.Select(s => new DiffSpec(s, null, FileNameOf(s.Url))));
        var names = new System.Collections.ObjectModel.ObservableCollection<string>(specs.Select(s => s.Name));

        var leftLabel = new TextBlock { Text = "Left:", Margin = new Thickness(0, 0, 0, 2) };
        leftLabel.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text2);
        var leftCombo = new ComboBox { ItemsSource = names, Width = 300 };

        var rightLabel = new TextBlock { Text = "Right:", Margin = new Thickness(0, 0, 0, 2) };
        rightLabel.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text2);
        var rightCombo = new ComboBox { ItemsSource = names, Width = 300 };

        // Browse… beside each side: pick a file that is not open yet; it joins the list and is selected.
        void Browse(ComboBox target)
        {
            var ofd = new OpenFileDialog
            {
                Title = ReferenceEquals(target, leftCombo) ? "Choose the file for the LEFT side" : "Choose the file for the RIGHT side",
                Filter = "XML Files (*.xml)|*.xml|All Files (*.*)|*.*",
                CheckFileExists = true,
            };
            try
            {
                string? near = active?.Url ?? RecentFiles.All.FirstOrDefault();
                if (near is not null) ofd.InitialDirectory = Path.GetDirectoryName(near);
            }
            catch { /* ignore */ }
            if (ofd.ShowDialog(dlg) != true || string.IsNullOrEmpty(ofd.FileName)) return;
            string chosen = ofd.FileName;
            int idx = specs.FindIndex(s => PathEquals(s.Session is not null ? s.Session.Url : s.Path!, chosen));
            if (idx < 0)
            {
                specs.Add(new DiffSpec(null, chosen, FileNameOf(chosen)));
                names.Add(FileNameOf(chosen) + "   (will be opened)");
                idx = specs.Count - 1;
            }
            target.SelectedIndex = idx;
        }

        Button leftBrowse = DialogButton("Browse…", isDefault: false, isCancel: false, new Thickness(8, 0, 0, 0));
        Button rightBrowse = DialogButton("Browse…", isDefault: false, isCancel: false, new Thickness(8, 0, 0, 0));
        leftBrowse.ToolTip = "Compare a file that is not open yet (it will be opened as a tab)";
        rightBrowse.ToolTip = leftBrowse.ToolTip;
        leftBrowse.Click += (_, _) => Browse(leftCombo);
        rightBrowse.Click += (_, _) => Browse(rightCombo);

        var leftRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 10) };
        leftRow.Children.Add(leftCombo); leftRow.Children.Add(leftBrowse);
        var rightRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 14) };
        rightRow.Children.Add(rightCombo); rightRow.Children.Add(rightBrowse);

        int activeIdx = active is null ? -1 : _sessions.IndexOf(active);
        leftCombo.SelectedIndex = activeIdx;                                                  // -1 with no file: browse
        rightCombo.SelectedIndex = _sessions.FindIndex(s => !ReferenceEquals(s, active));   // -1 with one file: browse
        if (_sessions.Count == 0)
        {
            var hint = new TextBlock { Text = "No file is open: use Browse\u2026 on each side.", Margin = new Thickness(0, 0, 0, 10), TextWrapping = TextWrapping.Wrap };
            hint.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text3);
            root.Children.Add(hint);
        }

        root.Children.Add(leftLabel);
        root.Children.Add(leftRow);
        root.Children.Add(rightLabel);
        root.Children.Add(rightRow);

        var btnRow = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        bool ok = false;
        Button compare = DialogButton("Compare", isDefault: true, isCancel: false, new Thickness(0, 0, 8, 0));
        Button cancel = DialogButton("Cancel", isDefault: false, isCancel: true, new Thickness(0));
        compare.Click += (_, _) => { ok = true; dlg.Close(); };
        cancel.Click += (_, _) => { ok = false; dlg.Close(); };
        btnRow.Children.Add(compare);
        btnRow.Children.Add(cancel);
        root.Children.Add(btnRow);

        dlg.Content = root;
        dlg.ShowDialog();

        if (!ok) return null;
        int li = leftCombo.SelectedIndex, ri = rightCombo.SelectedIndex;
        if (li < 0 || ri < 0 || li == ri) { NativeMethods.Beep(); SetStatus("Pick two different files"); return null; }
        return (specs[li], specs[ri]);
    }
}
