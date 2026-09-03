using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Win32;
using XMLMacker.Core;
using XMLMacker.Editor;
using XMLMacker.Panes;
using XMLMacker.Shared;
using XMLMacker.Windows;

namespace XMLMacker.App;

/// <summary>
/// Scoped live validation, one-click fixes, reparse-from-editor with signature re-selection,
/// go-to-line, quick-search, Find &amp; Replace glue, subtags tag-rename, tree context-menu actions,
/// and Learn prompt routing.
/// </summary>
public partial class MainWindow
{
    // Invalidates an older background tree rebuild when another structural edit, tab switch,
    // or undo/redo starts before that parse can publish its result.
    private long _treeReparseRequestId;

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Scoped live validation
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void Revalidate()
    {
        long requestId = ++_validationRequestId;
        Guid? sessionId = ActiveSession?.Id;
        ulong revision = _activeEditRevision;
        XmlTreeNode? scope = PickValidationScope();
        int? startOffset = scope is not null ? _source.ElementStartOffset(scope) : null;
        if (scope is null || startOffset is null)
        {
            _errors.SetErrors(Array.Empty<ParseError>());
            _validationWindow?.SetErrors(Array.Empty<ParseError>());
            _lastParseErrors = Array.Empty<ParseError>();
            return;
        }

        (string text, bool reachedDocEnd) = _source.Substring(startOffset.Value, 5_000_000);
        int baseLine = scope.StartLine;
        string scopeLabel = scope.DisplayLabel;
        int baseOffset = startOffset.Value;

        Task.Run(() =>
        {
            List<ParseError> errors = XmlFragmentLinter.Lint(text, baseLine, reachedDocEnd, baseOffset);
            Dispatcher.InvokeAsync(() =>
            {
                if (requestId != _validationRequestId || ActiveSession?.Id != sessionId ||
                    _activeEditRevision != revision)
                    return;

                _lastParseErrors = errors;
                _validationWindow?.SetErrors(errors);
                _errors.SetErrors(errors);
                _errors.SetValidationScope(scopeLabel);
                SetStatus(errors.Count == 0
                    ? "Current scope · no errors"
                    : $"Current scope · {errors.Count.ToString(Inv)} error{(errors.Count == 1 ? "" : "s")}");
            });
        });
    }

    private XmlTreeNode? PickValidationScope()
    {
        if (_currentSelectedNode is not { Kind: NodeKind.Element } node) return null;
        if (node.Parent is { Kind: NodeKind.Element } parent) return parent;   // context catches sibling mismatches
        return node;                                                            // parent is the document root
    }

    private void ApplyLintFix(ParseError error)
    {
        if (error.Fix is not { } fix) return;
        bool applied = _source.ApplyFix(fix);               // verify-before-apply lives inside ApplyFix
        if (!applied) NativeMethods.Beep();
        SetStatus("Checking XML…");
        Revalidate();
        if (applied) ReparseFromEditor();
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Reparse from editor + signature re-selection
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void ReparseFromEditor()
    {
        long requestId = ++_treeReparseRequestId;
        if (ActiveSession is not { IsLoading: false } session) return;

        // Whole-doc reparse copies the entire string; guard the 655 MB case.
        // Above ~100 MB only the line table is refreshed and leave the tree until the next full load.
        if (_source.Editor.DocumentLength > 100_000_000)
        {
            _source.RefreshLineStarts();
            SetStatus("File too large to rebuild the tree automatically, save and reopen to refresh");
            return;
        }

        string text = _source.DocumentText;
        string name = FileNameOf(_currentFileUrl);
        Guid sessionId = session.Id;
        ulong revision = _activeEditRevision;
        XmlTreeNode? priorTree = _currentTree;
        List<(string Name, string? Key)>? sig = _currentSelectedNode is not null ? PathSignature(_currentSelectedNode) : null;

        SetStatus("Rebuilding tree…");
        Task.Run(() =>
        {
            ParseResult result = new XmlStreamParser().ParseText(text);
            Dispatcher.InvokeAsync(() =>
            {
                if (requestId != _treeReparseRequestId || ActiveSession?.Id != sessionId ||
                    session.IsLoading || _activeEditRevision != revision ||
                    !ReferenceEquals(session.Tree, priorTree))
                    return;

                result.Root.Name = name;
                _currentTree = result.Root;
                session.Tree = result.Root;
                session.ParseErrors = result.Errors;
                session.NeedsReparse = false;

                _tree.SetRoot(result.Root);
                _source.RefreshLineStarts();
                _lastParseErrors = result.Errors;
                _validationWindow?.SetErrors(result.Errors);
                SetStatus($"Tree rebuilt · {result.NodeCount.ToString(Inv)} nodes");

                // Re-selecting reinstalls the LOCAL magnet set through HandleTreeSelection. Only when
                // the previously selected element can no longer be found does the lane fall back to the
                // coarse whole-document set, otherwise a reparse silently coarsened the lane for good.
                if (sig is not null && NodeMatching(sig, result.Root) is { } back)
                    _tree.Select(back, expandAncestors: true);
                else
                    _source.Minimap.SetSnapLines(CollectSnapLines(result.Root));

                // A validation request started before this rebuild used the old tree scope. Run it
                // again against the newly selected node so its final status cannot describe stale XML.
                SetStatus("Checking XML…");
                Revalidate();
            });
        });
    }

    private static List<(string Name, string? Key)> PathSignature(XmlTreeNode node)
    {
        var chain = new List<XmlTreeNode>();
        for (XmlTreeNode? cur = node; cur is { Kind: NodeKind.Element }; cur = cur.Parent) chain.Add(cur);
        chain.Reverse();
        return chain.Select(n => (n.Name, KeyAttrValueOrNull(n))).ToList();
    }

    private static string? KeyAttrValueOrNull(XmlTreeNode node)
    {
        foreach (string pref in KeyAttrNames)
            foreach ((string Name, string Value) a in node.Attributes)
                if (a.Name == pref) return a.Value;
        return null;
    }

    private static XmlTreeNode? NodeMatching(List<(string Name, string? Key)> sig, XmlTreeNode root)
    {
        IEnumerable<XmlTreeNode> candidates = root.Children.Where(c => c.Kind == NodeKind.Element);
        XmlTreeNode? deepest = null;
        foreach ((string name, string? key) in sig)
        {
            XmlTreeNode? match = null;
            foreach (XmlTreeNode c in candidates)
            {
                if (c.Name != name) continue;
                if (key is not null && KeyAttrValueOrNull(c) != key) continue;
                match = c;
                break;
            }
            if (match is null) break;   // a segment vanished → its parent wins
            deepest = match;
            candidates = match.Children.Where(c => c.Kind == NodeKind.Element);
        }
        return deepest;
    }

    private static bool IsValidXmlName(string s)
    {
        if (string.IsNullOrEmpty(s)) return false;
        char f = s[0];
        if (!(char.IsLetter(f) || f == '_')) return false;
        for (int i = 1; i < s.Length; i++)
        {
            char c = s[i];
            if (!(char.IsLetterOrDigit(c) || c is '-' or '_' or '.' or ':')) return false;
        }
        return true;
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Subtags tag rename
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void HandleTagRename(XmlTreeNode node, string newName)
    {
        string trimmed = newName.Trim();
        if (trimmed == node.Name) return;

        if (!IsValidXmlName(trimmed))
        {
            NativeMethods.Beep();
            SetStatus(trimmed.Length > 0 ? $"Invalid tag name: {trimmed}" : "Invalid tag name");
            _subtags.RefreshValuesOnly();
            return;
        }

        if (_source.ApplyTagRename(node, trimmed))
        {
            node.Name = trimmed;
            SetStatus($"Renamed to {trimmed}");
            MarkDirty();
            ReparseFromEditor();
        }
        else
        {
            NativeMethods.Beep();
            SetStatus("Couldn't rename, close tag not found where expected");
            _subtags.RefreshValuesOnly();
        }
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Go to Line + line-number toggle
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void MenuGoToLine()
    {
        if (_currentFileUrl is null) return;
        string? input = PromptText("Go to Line", "Enter a line number", "", "Go");
        if (input is null) return;
        if (int.TryParse(input.Trim(), NumberStyles.Integer, Inv, out int line) && line > 0)
            _source.ScrollToLine(line);
    }

    private void MenuToggleLineNumbers()
    {
        _source.SetLineNumbersVisible(!_source.IsLineNumbersVisible);
        ValidateMenus();
    }

    private void MenuToggleMinimap()
    {
        _source.SetMinimapVisible(!_source.IsMinimapVisible);
        ValidateMenus();
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Quick search (toolbar) + Find & Replace glue
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void QuickSearch(string needle)
    {
        if (string.IsNullOrEmpty(needle)) { _quickSearchLast = null; return; }

        (int Start, int Length) scope = _source.FullDocumentRange;
        int from = _quickSearchLast is { } last ? last.Start + last.Length : 0;
        (int Start, int Length)? hit = _source.MatchRange(needle, from, forward: true, caseSensitive: false, wholeWord: false, scope);
        if (hit is null)
        {
            NativeMethods.Beep();
            SetStatus($"\"{needle}\" not found");
            _quickSearchLast = null;
            return;
        }

        _quickSearchLast = hit.Value;
        _source.RevealMatch(hit.Value);
        SetStatus($"Line {_source.LineNumberForOffset(hit.Value.Start).ToString(Inv)}");
    }

    private void PresentFindReplace(XmlTreeNode? scope, bool focusReplace)
    {
        if (_findPanel is null)
        {
            _findPanel = new FindPanel { Owner = this };
            _findPanel.OnClose = () => _findPanel = null;
        }

        _findPanel.Source = _source;
        _findPanel.PathForLine = line =>
        {
            if (_currentTree is null) return "";
            XmlTreeNode? n = FastDeepestNode(line, _currentTree);
            return n is not null ? TreePath(n) : "";
        };
        _findPanel.OnReplaced = (find, repl) =>
        {
            bool touchy = find.Contains('<') || find.Contains('>') || repl.Contains('<') || repl.Contains('>');
            if (touchy) ReparseFromEditor();
            else { _inspector.RefreshValuesOnly(); _subtags.RefreshValuesOnly(); }
        };

        string? title = null;
        (int Start, int Length)? range = null;
        if (scope is not null && _source.CharRangeForElement(scope) is { } r)
        {
            title = scope.DisplayLabel;
            range = r;
        }

        _findPanel.Present(title, range, focusReplace);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Tree context-menu actions
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void HandleTreeContext(XmlTreeNode node, ContextAction action)
    {
        switch (action)
        {
            case ContextAction.CopyPath:
                TrySetClipboard(TreePath(node));
                SetStatus("Path copied");
                break;

            case ContextAction.CopyXml:
                if (ElementText(node) is { } cx)
                {
                    TrySetClipboard(cx.Text);
                    SetStatus($"Copied {node.DisplayLabel} ({cx.Text.Length.ToString(Inv)} characters)");
                }
                break;

            case ContextAction.Cut:
                if (ElementText(node) is { } ct)
                {
                    TrySetClipboard(ct.Text);
                    _source.PerformEdit(RangeWithTrailingNewline(ct.Range), "");
                    SetStatus($"Cut {node.DisplayLabel}");
                    MarkDirty();
                    ReparseFromEditor();
                }
                break;

            case ContextAction.Delete:
                if (ElementText(node) is { } dt)
                {
                    _source.PerformEdit(RangeWithTrailingNewline(dt.Range), "");
                    SetStatus($"Deleted {node.DisplayLabel}");
                    MarkDirty();
                    ReparseFromEditor();
                }
                break;

            case ContextAction.DeleteOthers:
                DeleteSiblings(node);
                break;

            case ContextAction.ShareToLlm sl:
                ShareElementToLLM(node, sl.Target);
                break;

            case ContextAction.PrintElement:
                if (ElementText(node, 2_000_000, announce: false) is { } pt)
                    PrintService.Print(pt.Text, $"{node.DisplayLabel}, {FileNameOf(_currentFileUrl)}");
                break;

            case ContextAction.ExportElement:
                ExportElementToFile(node);
                break;

            case ContextAction.DefineInLearn:
                DefineInLearn(node);
                break;

            case ContextAction.DuplicateAbove:
                DuplicateElement(node, above: true);
                break;

            case ContextAction.DuplicateBelow:
                DuplicateElement(node, above: false);
                break;

            case ContextAction.FindReplace:
                PresentFindReplace(node, focusReplace: false);
                break;

            case ContextAction.OpenLinkedFile linked:
                LoadFile(linked.Path);
                break;
        }
    }

    /// <summary>Extract an element's source text + range, capped.</summary>
    private (string Text, (int Start, int Length) Range)? ElementText(XmlTreeNode node, int cap = 100_000_000, bool announce = true)
    {
        if (_source.CharRangeForElement(node) is not { } range || range.Length <= 0) return null;
        if (range.Length > cap)
        {
            if (announce)
            {
                NativeMethods.Beep();
                SetStatus("Element too large for this operation (over 100 M characters)");
            }
            return null;
        }
        (string text, _) = _source.Substring(range, cap);
        return (text, range);
    }

    private (int Start, int Length) RangeWithTrailingNewline((int Start, int Length) r)
    {
        ITextBuffer? buf = _source.CurrentStorage;
        int after = r.Start + r.Length;
        if (buf is not null && after < buf.Length && buf.CharAt(after) == '\n')
            return (r.Start, r.Length + 1);
        return r;
    }

    private void DeleteSiblings(XmlTreeNode node)
    {
        if (node.Parent is not { } parent) return;
        List<XmlTreeNode> victims = parent.Children
            .Where(c => c.Kind == NodeKind.Element && !ReferenceEquals(c, node)).ToList();
        if (victims.Count == 0) { SetStatus("No sibling elements to delete"); return; }

        string plural = victims.Count == 1 ? "" : "s";
        int c = ShowAlert($"Delete {victims.Count} sibling element{plural}?",
            $"Everything else inside {parent.DisplayLabel} will be removed, only {node.DisplayLabel} stays. One Ctrl+Z brings them all back.",
            new[] { "Delete Others", "Cancel" }).index;
        if (c != 0) return;

        var ranges = new List<(int Start, int Length)>();
        foreach (XmlTreeNode v in victims)
            if (_source.CharRangeForElement(v) is { } r) ranges.Add(RangeWithTrailingNewline(r));
        ranges.Sort((a, b) => b.Start.CompareTo(a.Start));   // delete back-to-front

        var undo = _source.Editor.UndoStack;
        undo?.BeginGroup();
        foreach ((int Start, int Length) r in ranges) _source.PerformEdit(r, "");
        undo?.EndGroup();

        MarkDirty();
        SetStatus($"Deleted {victims.Count} element{plural}, only {node.DisplayLabel} remains");
        ReparseFromEditor();
    }

    private void DuplicateElement(XmlTreeNode node, bool above)
    {
        if (ElementText(node) is not { } et) return;
        if (above) _source.PerformEdit((et.Range.Start, 0), et.Text + "\n");
        else _source.PerformEdit((et.Range.Start + et.Range.Length, 0), "\n" + et.Text);
        SetStatus($"Duplicated {node.DisplayLabel}");
        MarkDirty();
        ReparseFromEditor();
    }

    // Export no longer asks where to save: the element opens alone as a new document (Share menu request).
    private void ExportElementToFile(XmlTreeNode node) => ExportElementToNewTab(node);

    private void ShareElementToLLM(XmlTreeNode node, LLMTarget target)
    {
        if (ElementText(node, 2_000_000, announce: false) is not { } et) { NativeMethods.Beep(); return; }
        string prompt = ShareService.ElementPrompt(node.DisplayLabel, TreePath(node), FileNameOf(_currentFileUrl), et.Text);
        SetStatus(ShareService.DeliverPrompt(prompt, target));
    }

    /// <summary>Puts <paramref name="text"/> on the clipboard; false when Windows refused (locked, or too large).</summary>
    private static bool TrySetClipboard(string text)
    {
        try { Clipboard.SetText(text); return true; }
        catch { return false; }   // clipboard may be locked, or the text too large for it
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Learn prompts + floating "Define" chip
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private string? ShareSelectionText(int cap = 2_000_000)
    {
        int start = _source.Editor.SelectionStart;
        int len = _source.Editor.SelectionLength;
        if (len <= 0 || len > cap) return null;
        (string text, _) = _source.Substring((start, len), cap);
        return text;
    }

    private string? LearnSelectionPrompt()
    {
        string? sel = ShareSelectionText(200_000);
        if (sel is null)
        {
            NativeMethods.Beep();
            SetStatus("Select some source text first (200 k character cap for chat)");
            return null;
        }
        return ShareService.LearnPrompt("selection", FileNameOf(_currentFileUrl), sel);
    }

    private string? LearnElementPrompt()
    {
        if (_currentSelectedNode is not { } node || ElementText(node, 200_000, announce: false) is not { } et)
        {
            NativeMethods.Beep();
            SetStatus("Select an element in the tree first (200 k character cap for chat)");
            return null;
        }
        return ShareService.LearnPrompt("element", FileNameOf(_currentFileUrl), et.Text);
    }

    private void DefineInLearn(XmlTreeNode node)
    {
        if (_workspaceMode != WorkspaceMode.Learn) ApplyWorkspace(WorkspaceMode.Learn, save: true);
        else EnsureLearnPane();

        if (ElementText(node, 200_000, announce: false) is not { } et)
        {
            SetStatus("Element too large for chat (200 k character cap)");
            return;
        }
        string prompt = ShareService.LearnPrompt("element", FileNameOf(_currentFileUrl), et.Text);
        if (_learn is not null) _ = _learn.InsertPrompt(prompt);
    }

    private void DefineSelectionInLearn()
    {
        string? prompt = LearnSelectionPrompt();
        if (prompt is null) return;

        if (_workspaceMode != WorkspaceMode.Learn) ApplyWorkspace(WorkspaceMode.Learn, save: true);
        else EnsureLearnPane();

        if (_learn is not null) _ = _learn.InsertPrompt(prompt);
    }

    /// <summary>LEARN pane button: shows the open file in File Explorer, ready to be dragged into the chat.</summary>
    private void LearnOpenFileFolder()
    {
        if (_currentFileUrl is null)
        {
            NativeMethods.Beep();
            SetStatus("Open a file first, then this button shows it in File Explorer");
            return;
        }
        NativeMethods.RevealInExplorer(_currentFileUrl);
        SetStatus($"{FileNameOf(_currentFileUrl)} is selected in File Explorer, drag it into the chat");
    }

    /// <summary>LEARN pane button: copies the whole open file (the text in the source pane) to the clipboard.</summary>
    private void LearnCopyWholeFile()
    {
        if (_currentFileUrl is null || ActiveSession is not { IsLoading: false })
        {
            NativeMethods.Beep();
            SetStatus("Open a file first, then this button copies all of it");
            return;
        }

        string text = _source.DocumentText;
        if (text.Length == 0)
        {
            NativeMethods.Beep();
            SetStatus("This file is empty, there is nothing to copy");
            return;
        }

        // A chat page lays out every character that is pasted, so a model file freezes it. Say so first.
        const int ChatSafe = 200_000;
        if (text.Length > ChatSafe)
        {
            int choice = ShowAlert("This file is too big for a chat box",
                $"{FileNameOf(_currentFileUrl)} is {text.Length:N0} characters. Pasting that into a chat page "
                + $"usually freezes the page ({ChatSafe:N0} characters is about as much as they take).\n\n"
                + "Chat sites handle the file itself much better: show it in File Explorer and drag it into the chat. "
                + "You can also select a part of the file and drag that selection straight into the chat box.",
                new[] { "Show in File Explorer", "Copy anyway", "Cancel" }).index;
            if (choice == 0) { LearnOpenFileFolder(); return; }
            if (choice != 1) { SetStatus("Nothing was copied"); return; }
        }

        SetStatus(TrySetClipboard(text)
            ? $"Copied the whole file, {text.Length:N0} characters, paste it with Ctrl+V"
            : "Windows refused the clipboard, this file may be too big to copy in one piece");
    }

    private void UpdateLearnChip() => _source.SetLearnMode(_workspaceMode == WorkspaceMode.Learn);
    private void RemoveLearnChip() => _source.SetLearnMode(false);
}
