using System;
using System.Collections.Generic;
using System.Text;

namespace XMLMacker.Editor;

/// <summary>
/// Piece-table implementation of <see cref="ITextBuffer"/>, the editable model behind the huge-file editor
/// (WPF analog of <c>NSTextStorage</c>). It NEVER copies the 655 MB document on an edit: the loaded text lives
/// once in an immutable <c>_original</c> buffer, inserted text is appended to a growable <c>_added</c> buffer,
/// and the document is described as an ordered list of <b>pieces</b> (slices into one of the two buffers).
///
/// <para>All offsets/lengths are UTF-16 char indices (a .NET <c>char</c> is one UTF-16 code unit), the single
/// offset contract shared with <c>lineStarts</c>, fix-it ranges, find/diff ranges and highlight rects. No rune
/// conversion ever happens on the offset path.</para>
///
/// <para><b>Complexity.</b> <see cref="Replace"/> splits at most two pieces and splices the list, so it does
/// O(pieceCount) work on the (small) piece list plus an O(log pieceCount) offset search, never O(docLen).
/// <see cref="CharAt"/> is O(log pieceCount); <see cref="Substring"/> is O(resultLength). The piece count grows
/// by at most a few entries per edit and sequential typing at one caret coalesces into a single piece.</para>
/// </summary>
public sealed class TextBuffer : ITextBuffer
{
    private readonly struct Piece
    {
        public readonly bool FromAdded;
        public readonly int Start;
        public readonly int Length;
        public Piece(bool fromAdded, int start, int length)
        {
            FromAdded = fromAdded;
            Start = start;
            Length = length;
        }
        public Piece WithLength(int length) => new(FromAdded, Start, length);
    }

    private readonly string _original;
    private readonly StringBuilder _added;
    private readonly List<Piece> _pieces = new();

    // Cumulative start offset of each piece; _prefix[k] = doc offset where piece k begins, _prefix[Count] = _length.
    // Lazily rebuilt (set to null on any structural change).
    private int[]? _prefix;
    private int _length;

    /// <inheritdoc/>
    public int Length => _length;

    /// <inheritdoc/>
    public event EventHandler<TextBufferMutation>? Mutated;

    /// <summary>
    /// Constructs a buffer that takes ownership of <paramref name="initial"/> as the immutable original text
    /// (the load path hands the freshly decoded document string over exactly once, no copy is made).
    /// </summary>
    public TextBuffer(string initial)
    {
        _original = initial ?? string.Empty;
        _added = new StringBuilder();
        _length = _original.Length;
        if (_original.Length > 0)
            _pieces.Add(new Piece(false, 0, _original.Length));
    }

    /// <summary>Creates an empty buffer (used for the untitled / detached state).</summary>
    public TextBuffer() : this(string.Empty) { }

    private void EnsurePrefix()
    {
        if (_prefix is not null) return;
        var pre = new int[_pieces.Count + 1];
        int acc = 0;
        for (int i = 0; i < _pieces.Count; i++)
        {
            pre[i] = acc;
            acc += _pieces[i].Length;
        }
        pre[_pieces.Count] = acc;
        _prefix = pre;
    }

    // Largest k with _prefix[k] <= offset (offset in [0, _length]). Returns a piece index in [0, Count-1] for
    // offset < _length; returns Count only via callers that special-case offset == _length.
    private int FindPieceIndex(int offset)
    {
        EnsurePrefix();
        int[] pre = _prefix!;
        int lo = 0, hi = _pieces.Count - 1;
        while (lo < hi)
        {
            int mid = (lo + hi + 1) >> 1;
            if (pre[mid] <= offset) lo = mid; else hi = mid - 1;
        }
        return lo;
    }

    // Ensures a piece boundary exactly at `offset`, splitting the containing piece if needed. Returns the index of
    // the piece that STARTS at `offset` (or _pieces.Count when offset == _length).
    private int EnsureBoundary(int offset)
    {
        if (offset <= 0) return 0;
        if (offset >= _length) return _pieces.Count;

        int k = FindPieceIndex(offset);
        int pieceStart = _prefix![k];
        if (pieceStart == offset) return k;

        Piece p = _pieces[k];
        int local = offset - pieceStart;
        _pieces[k] = p.WithLength(local);
        _pieces.Insert(k + 1, new Piece(p.FromAdded, p.Start + local, p.Length - local));
        _prefix = null;
        return k + 1;
    }

    /// <inheritdoc/>
    public char CharAt(int index)
    {
        if ((uint)index >= (uint)_length)
            throw new ArgumentOutOfRangeException(nameof(index));
        int k = FindPieceIndex(index);
        Piece p = _pieces[k];
        int local = index - _prefix![k];
        return p.FromAdded ? _added[p.Start + local] : _original[p.Start + local];
    }

    /// <inheritdoc/>
    public string Substring(int start, int length)
    {
        if (length <= 0) return string.Empty;
        if (start < 0) { length += start; start = 0; }
        if (start >= _length) return string.Empty;
        if (start + length > _length) length = _length - start;
        if (length <= 0) return string.Empty;

        var buf = new char[length];
        int written = 0;
        int k = FindPieceIndex(start);
        int local = start - _prefix![k];
        while (written < length && k < _pieces.Count)
        {
            Piece p = _pieces[k];
            int avail = p.Length - local;
            int take = Math.Min(avail, length - written);
            if (p.FromAdded)
                _added.CopyTo(p.Start + local, buf, written, take);
            else
                _original.CopyTo(p.Start + local, buf, written, take);
            written += take;
            k++;
            local = 0;
        }
        return new string(buf, 0, written);
    }

    /// <inheritdoc/>
    public void Replace(int start, int length, string text)
    {
        text ??= string.Empty;
        if (start < 0) start = 0;
        if (start > _length) start = _length;
        if (length < 0) length = 0;
        if (start + length > _length) length = _length - start;

        int si = EnsureBoundary(start);
        int ei = EnsureBoundary(start + length);
        if (ei > si)
            _pieces.RemoveRange(si, ei - si);

        if (text.Length > 0)
        {
            int addStart = _added.Length;

            // Coalesce sequential typing: if the piece just before the insertion point is an added-piece that ends
            // exactly at the current end of the added buffer, extend it instead of adding a new piece.
            if (si > 0)
            {
                Piece prev = _pieces[si - 1];
                if (prev.FromAdded && prev.Start + prev.Length == addStart)
                {
                    _added.Append(text);
                    _pieces[si - 1] = prev.WithLength(prev.Length + text.Length);
                    _length += text.Length - length;
                    _prefix = null;
                    Mutated?.Invoke(this, new TextBufferMutation(start, length, text.Length));
                    return;
                }
            }

            _added.Append(text);
            _pieces.Insert(si, new Piece(true, addStart, text.Length));
        }

        _length += text.Length - length;
        _prefix = null;
        Mutated?.Invoke(this, new TextBufferMutation(start, length, text.Length));
    }

    /// <inheritdoc/>
    public string GetText()
    {
        if (_length == 0) return string.Empty;
        // Fast path: an untouched freshly-loaded document is a single original-covering piece, hand back the
        // original string reference with no allocation or copy.
        if (_pieces.Count == 1)
        {
            Piece p = _pieces[0];
            if (!p.FromAdded && p.Start == 0 && p.Length == _original.Length)
                return _original;
        }
        var sb = new StringBuilder(_length);
        foreach (Piece p in _pieces)
        {
            if (p.FromAdded)
                sb.Append(_added, p.Start, p.Length);
            else
                sb.Append(_original, p.Start, p.Length);
        }
        return sb.ToString();
    }
}
