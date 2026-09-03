using System;
using System.Collections.Generic;
using System.Linq;

namespace XMLMacker.Core;

/// <summary>The four marker colours; <see cref="None"/> is the eraser.</summary>
public enum HighlightColor { None = 0, Red = 1, Blue = 2, Yellow = 3, Green = 4 }

/// <summary>One marker stroke: a stretch of text by document offset.</summary>
public readonly record struct HighlightRange(int Start, int Length, HighlightColor Color)
{
    public int End => Start + Length;
}

/// <summary>
/// The marker strokes of one document, sorted and non-overlapping. Painting over an existing stroke
/// replaces that part (another colour recolours it, None erases it). Strokes move with the text when
/// it is edited and are stored per file (HighlightStore), so they are back after the file is closed
/// and opened again.
/// </summary>
public sealed class TextHighlights
{
    private readonly List<HighlightRange> _ranges = new();

    /// <summary>Raised after any change: a stroke painted or erased, or strokes moved by an edit.</summary>
    public event EventHandler? Changed;

    public int Count => _ranges.Count;
    public bool IsEmpty => _ranges.Count == 0;

    /// <summary>Every stroke, in document order.</summary>
    public IReadOnlyList<HighlightRange> All => _ranges;

    /// <summary>Paints the span in <paramref name="color"/> (None erases). True when anything changed.</summary>
    public bool Paint(int start, int length, HighlightColor color)
    {
        if (length <= 0 || start < 0) return false;
        int end = start + length;
        var next = new List<HighlightRange>(_ranges.Count + 2);
        bool inserted = false, changed = false;
        foreach (HighlightRange r in _ranges)
        {
            if (r.End <= start) { next.Add(r); continue; }
            if (r.Start >= end)
            {
                if (!inserted && color != HighlightColor.None) { next.Add(new HighlightRange(start, length, color)); inserted = true; }
                next.Add(r);
                continue;
            }
            // Overlap: keep the parts of the old stroke outside the painted span.
            changed = true;
            if (r.Start < start) next.Add(new HighlightRange(r.Start, start - r.Start, r.Color));
            if (!inserted && color != HighlightColor.None) { next.Add(new HighlightRange(start, length, color)); inserted = true; }
            if (r.End > end) next.Add(new HighlightRange(end, r.End - end, r.Color));
        }
        if (!inserted && color != HighlightColor.None) { next.Add(new HighlightRange(start, length, color)); changed = true; }
        if (!changed) return false;
        Replace(next);
        return true;
    }

    /// <summary>True when every character of the span already carries <paramref name="color"/>.</summary>
    public bool IsCovered(int start, int length, HighlightColor color)
    {
        if (length <= 0) return false;
        int pos = start, end = start + length;
        foreach (HighlightRange r in _ranges)
        {
            if (r.End <= pos) continue;
            if (r.Start > pos || r.Color != color) return false;
            pos = r.End;
            if (pos >= end) return true;
        }
        return pos >= end;
    }

    public void Clear()
    {
        if (_ranges.Count == 0) return;
        _ranges.Clear();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Replaces every stroke (used when a file's stored strokes are loaded).</summary>
    public void ReplaceAll(IEnumerable<HighlightRange> ranges)
    {
        Replace(ranges.Where(r => r.Length > 0 && r.Start >= 0 && r.Color != HighlightColor.None).OrderBy(r => r.Start).ToList());
    }

    private void Replace(List<HighlightRange> sorted)
    {
        _ranges.Clear();
        foreach (HighlightRange r in sorted)
        {
            if (r.Length <= 0) continue;
            if (_ranges.Count > 0)
            {
                HighlightRange last = _ranges[^1];
                if (last.Color == r.Color && last.End >= r.Start)   // touching or overlapping, same colour: one stroke
                {
                    _ranges[^1] = new HighlightRange(last.Start, Math.Max(last.End, r.End) - last.Start, last.Color);
                    continue;
                }
            }
            _ranges.Add(r);
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>The first stroke starting after <paramref name="offset"/>, wrapping to the first stroke; null when none.</summary>
    public HighlightRange? Next(int offset)
    {
        foreach (HighlightRange r in _ranges) if (r.Start > offset) return r;
        return _ranges.Count > 0 ? _ranges[0] : null;
    }

    /// <summary>The last stroke starting before <paramref name="offset"/>, wrapping to the last stroke; null when none.</summary>
    public HighlightRange? Previous(int offset)
    {
        HighlightRange? before = null;
        foreach (HighlightRange r in _ranges) { if (r.Start < offset) before = r; else break; }
        return before ?? (_ranges.Count > 0 ? _ranges[^1] : null);
    }

    /// <summary>1-based position of a stroke among all strokes ("Highlight 3 of 12"), or 0.</summary>
    public int OrdinalOf(HighlightRange range)
    {
        for (int i = 0; i < _ranges.Count; i++) if (_ranges[i].Start == range.Start) return i + 1;
        return 0;
    }

    /// <summary>Strokes touching the span [from, to), for drawing the visible part of a document.</summary>
    public IEnumerable<HighlightRange> Intersecting(int from, int to)
    {
        foreach (HighlightRange r in _ranges)
        {
            if (r.End <= from) continue;
            if (r.Start >= to) break;
            yield return r;
        }
    }

    /// <summary>
    /// The text [start, start+removed) was replaced by <paramref name="inserted"/> characters: strokes
    /// after the edit move by the difference, a stroke whose text was removed disappears, text typed
    /// inside a stroke joins it, text typed right before or after a stroke stays outside it.
    /// </summary>
    public void ShiftForEdit(int start, int removed, int inserted)
    {
        if (_ranges.Count == 0 || (removed == 0 && inserted == 0)) return;
        int delta = inserted - removed, removedEnd = start + removed;
        var next = new List<HighlightRange>(_ranges.Count);
        bool changed = false;
        foreach (HighlightRange r in _ranges)
        {
            int a = r.Start, b = r.End;
            int a2 = a < start ? a : (a >= removedEnd ? a + delta : start);
            int b2 = b <= start ? b : (b >= removedEnd ? b + delta : start);
            if (a2 != a || b2 != b) changed = true;
            if (b2 - a2 > 0) next.Add(new HighlightRange(a2, b2 - a2, r.Color));
        }
        if (!changed) return;
        Replace(next);
    }
}
