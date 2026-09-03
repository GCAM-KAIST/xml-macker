using System;
using System.Collections.Generic;

namespace XMLMacker.Editor;

/// <summary>
/// A single reversible edit: at <see cref="Start"/>, <see cref="Removed"/> was replaced by <see cref="Inserted"/>.
/// Undo restores <see cref="Removed"/>; redo re-applies <see cref="Inserted"/>.
/// </summary>
public readonly struct EditRecord
{
    public readonly int Start;
    public readonly string Removed;
    public readonly string Inserted;
    public readonly int CaretAfter; // caret position to restore after redo

    public EditRecord(int start, string removed, string inserted, int caretAfter)
    {
        Start = start;
        Removed = removed;
        Inserted = inserted;
        CaretAfter = caretAfter;
    }
}

/// <summary>
/// Per-tab undo/redo stack (port of the per-<c>DocumentSession</c> <c>UndoManager</c>). A shared stack would replay
/// one document's ranges into another, so each session owns its own instance and <c>Ctrl+Z</c>/<c>Ctrl+Y</c> route
/// to the active tab's stack only.
///
/// <para><b>Grouping.</b> Multi-edit operations (e.g. tag rename touching both the opening and closing tag) call
/// <see cref="BeginGroup"/>/<see cref="EndGroup"/> so a single Undo reverses the whole group. Records inside a group
/// are applied back-to-front on undo and front-to-back on redo. A new edit clears the redo stack.</para>
///
/// <para>Applying an undo/redo is delegated to a <c>raw edit</c> callback supplied by the editor so the buffer is
/// mutated WITHOUT recording a new undo entry.</para>
/// </summary>
public sealed class EditorUndoStack
{
    private sealed class Group
    {
        public readonly List<EditRecord> Records = new();
    }

    private readonly Stack<Group> _undo = new();
    private readonly Stack<Group> _redo = new();

    private Group? _openGroup;
    private int _groupDepth;

    /// <summary>Applies a raw edit to the buffer (replace <c>[start, len]</c> with text) WITHOUT recording undo, and returns the caret to place.</summary>
    public Func<int, int, string, int>? ApplyRaw { get; set; }

    /// <summary>True while an undo/redo application is in flight, so the editor suppresses undo recording.</summary>
    public bool IsApplying { get; private set; }

    public bool CanUndo => _undo.Count > 0;
    public bool CanRedo => _redo.Count > 0;

    /// <summary>Opens (or nests) an undo group. Nested calls share one group; the outermost <see cref="EndGroup"/> commits it.</summary>
    public void BeginGroup()
    {
        if (_groupDepth == 0)
            _openGroup = new Group();
        _groupDepth++;
    }

    /// <summary>Closes the current undo group, committing it as one undoable unit (if it recorded anything).</summary>
    public void EndGroup()
    {
        if (_groupDepth == 0) return;
        _groupDepth--;
        if (_groupDepth == 0 && _openGroup is not null)
        {
            if (_openGroup.Records.Count > 0)
            {
                _undo.Push(_openGroup);
                _redo.Clear();
            }
            _openGroup = null;
        }
    }

    /// <summary>
    /// Records an edit. When a group is open the record joins it; otherwise it becomes its own single-record group.
    /// Ignored while an undo/redo is being applied.
    /// </summary>
    public void Record(EditRecord rec)
    {
        if (IsApplying) return;
        if (_openGroup is not null)
        {
            _openGroup.Records.Add(rec);
            return;
        }
        var g = new Group();
        g.Records.Add(rec);
        _undo.Push(g);
        _redo.Clear();
    }

    /// <summary>Undoes the most recent group. Returns the caret to place, or null if nothing to undo.</summary>
    public int? Undo()
    {
        if (ApplyRaw is null || _undo.Count == 0) return null;
        Group g = _undo.Pop();
        IsApplying = true;
        int caret = 0;
        try
        {
            // Reverse each record back-to-front: replace the inserted span with the removed text.
            for (int i = g.Records.Count - 1; i >= 0; i--)
            {
                EditRecord r = g.Records[i];
                caret = ApplyRaw(r.Start, r.Inserted.Length, r.Removed);
            }
        }
        finally { IsApplying = false; }
        _redo.Push(g);
        return caret;
    }

    /// <summary>Redoes the most recently undone group. Returns the caret to place, or null if nothing to redo.</summary>
    public int? Redo()
    {
        if (ApplyRaw is null || _redo.Count == 0) return null;
        Group g = _redo.Pop();
        IsApplying = true;
        int caret = 0;
        try
        {
            // Re-apply front-to-back: replace the removed span with the inserted text.
            for (int i = 0; i < g.Records.Count; i++)
            {
                EditRecord r = g.Records[i];
                ApplyRaw(r.Start, r.Removed.Length, r.Inserted);
                caret = r.CaretAfter;
            }
        }
        finally { IsApplying = false; }
        _undo.Push(g);
        return caret;
    }

    /// <summary>Clears both stacks (e.g. on a fresh document load).</summary>
    public void Clear()
    {
        _undo.Clear();
        _redo.Clear();
        _openGroup = null;
        _groupDepth = 0;
    }
}
