using System;

namespace XMLMacker.Editor;

/// <summary>
/// Describes a mutation applied to an <see cref="ITextBuffer"/>: at <see cref="Start"/>,
/// <see cref="RemovedLength"/> UTF-16 chars were removed and <see cref="AddedLength"/> UTF-16 chars inserted.
/// All values are UTF-16 char counts/indices.
/// </summary>
public readonly record struct TextBufferMutation(int Start, int RemovedLength, int AddedLength);

/// <summary>
/// The editable text model behind the source editor (WPF analog of <c>NSTextStorage</c>). A production
/// implementation is a piece-table / rope so a 655 MB buffer is not copied on every edit.
///
/// All offsets and lengths are <b>UTF-16 char</b> indices (.NET <c>char</c> = UTF-16 code unit), the single
/// offset contract shared by <c>lineStarts</c>, fix-it ranges, find/diff ranges and highlight rects. Never
/// convert to runes/code points on the offset path.
/// </summary>
public interface ITextBuffer
{
    /// <summary>Total length in UTF-16 chars.</summary>
    int Length { get; }

    /// <summary>Returns the UTF-16 code unit at <paramref name="index"/>.</summary>
    char CharAt(int index);

    /// <summary>Returns <paramref name="length"/> UTF-16 chars starting at <paramref name="start"/>.</summary>
    string Substring(int start, int length);

    /// <summary>
    /// Replaces <paramref name="length"/> chars at <paramref name="start"/> with <paramref name="text"/>.
    /// A zero <paramref name="length"/> inserts; an empty <paramref name="text"/> deletes. Raises <see cref="Mutated"/>.
    /// </summary>
    void Replace(int start, int length, string text);

    /// <summary>Materializes the entire buffer as a single string. Potentially very large, avoid on the hot path.</summary>
    string GetText();

    /// <summary>Raised after every mutation, carrying the (start, removedLen, addedLen) delta.</summary>
    event EventHandler<TextBufferMutation>? Mutated;
}
