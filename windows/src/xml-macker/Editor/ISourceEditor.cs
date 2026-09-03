using System;
using System.Collections.Generic;
using XMLMacker.Core;

namespace XMLMacker.Editor;

/// <summary>
/// The full public surface of the source editor, the union of the Swift <c>SourceViewController</c> API. Every
/// consumer (main window, panes, find panel, diff window, validation) talks to the editor through this interface so
/// the Phase-0 AvalonEdit adapter and the production <c>HugeTextEditor</c> are swappable with zero caller changes.
///
/// <b>All offsets and lengths are UTF-16 char indices</b> (.NET <c>char</c> = UTF-16 code unit). Ranges are
/// <c>(int Start, int Length)</c>, the same shape as <see cref="FixIt"/>.<c>Range</c>.
///
/// Every far jump (<see cref="ShowElement"/>, <see cref="ScrollToLine"/>, <see cref="RevealMatch"/>,
/// <c>ApplyFix</c>, <see cref="AttachSession"/>) must realize the viewport at the target BEFORE scrolling,
/// or a far-down jump silently clamps to the already-laid-out region.
/// </summary>
public interface ISourceEditor
{
    // ---- File / session ----------------------------------------------------------------------------------------

    /// <summary>
    /// Loads a file into the editor. Reads and decodes off the UI thread, builds <c>lineStarts</c>, shows a
    /// "loading…" header + spinner, and locks editing until done. Fires <see cref="FileLoaded"/> when the text and
    /// <c>lineStarts</c> are populated.
    /// </summary>
    void LoadFile(string url, long fileSize);

    /// <summary>
    /// Swaps the editor onto a parked tab's document (multi-tab switch): rebinds the mutation observer and syntax
    /// highlighter to <paramref name="storage"/>, updates url/size/lineStarts, resets highlights, realizes layout at
    /// doc start, and restores <paramref name="scrollOrigin"/>.
    /// </summary>
    void AttachSession(string url, long fileSize, ITextBuffer storage, int[] lineStarts,
                       (double X, double Y) scrollOrigin, XmlTextEncoding textEncoding);

    /// <summary>
    /// Attaches a fresh empty buffer (<c>/untitled.xml</c>, size 0, lineStarts <c>[0]</c>) so a new tab's empty text
    /// cannot wipe a parked document; then clears url/header and locks editing.
    /// </summary>
    void DetachToFreshStorage();

    /// <summary>
    /// File &gt; Close File, resets to the empty no-file state (clear text with mutations suppressed, lock editing,
    /// clear highlights, empty header, stop spinner, reset the ruler to <c>[0]</c>).
    /// </summary>
    void Clear();

    /// <summary>Returns the current editor scroll origin so the caller can park it in the session.</summary>
    (double X, double Y) SnapshotScroll();

    /// <summary>Restores a previously snapshotted scroll origin.</summary>
    void RestoreScroll((double X, double Y) origin);

    /// <summary>The editor's current text buffer, or <c>null</c> when nothing is loaded.</summary>
    ITextBuffer? CurrentStorage { get; }

    /// <summary>
    /// The active tab's undo stack, so <c>Ctrl+Z</c>/<c>Ctrl+Y</c> route to it alone (per-tab isolation). Typed
    /// <see cref="object"/> because the concrete stack type lives in the editor module.
    /// </summary>
    object? SessionUndoStack { get; set; }

    // ---- Highlight / navigation --------------------------------------------------------------------------------

    /// <summary>
    /// Called on tree selection: realizes layout at the element's opening-tag line, scrolls it into view, places the
    /// caret there, paints the landing-line band, and (when the element spans a range) paints the whole-element box wash.
    /// </summary>
    void ShowElement(XmlTreeNode node);

    /// <summary>
    /// The char range from the start of the element's opening-tag line to the end of its closing-tag line, or
    /// <c>null</c> when it cannot be resolved / has zero length.
    /// </summary>
    (int Start, int Length)? CharRangeForElement(XmlTreeNode node);

    /// <summary>
    /// The char offset of the element's opening-tag line, or <c>null</c> if past the document end. (Start lines
    /// survive edits made inside/below the element; only newline edits ABOVE shift them until the next full parse.)
    /// </summary>
    int? ElementStartOffset(XmlTreeNode node);

    /// <summary>
    /// Scrolls to (1-based) <paramref name="line"/>: clamp, realize layout at the target (required, same reason as
    /// <see cref="ShowElement"/>), caret to line start, scroll into view, paint the landing band. Used by Go-to-Line and error-row jumps.
    /// </summary>
    void ScrollToLine(int line);

    /// <summary>Realizes layout, selects <paramref name="range"/>, scrolls it into view, and paints the landing band (find navigation).</summary>
    void RevealMatch((int Start, int Length) range);

    /// <summary>1-based line number for a char offset (binary search over <c>lineStarts</c>).</summary>
    int LineNumberForOffset(int offset);

    /// <summary>The trimmed text of (1-based) <paramref name="line"/>, capped at <paramref name="cap"/> chars.</summary>
    string LineText(int line, int cap = 300);

    // ---- Bounded substrings ------------------------------------------------------------------------------------

    /// <summary>
    /// A bounded substring of the document for preview windows / validators: clamps <paramref name="range"/> to the
    /// document, caps the length at <paramref name="cap"/>, and reports whether it was truncated. Prevents copying
    /// 655 MB when a huge element is clicked.
    /// </summary>
    (string Text, bool Truncated) Substring((int Start, int Length) range, int cap = 1_000_000);

    /// <summary>
    /// An open-ended window from <paramref name="fromOffset"/> to <c>min(fromOffset + cap, docLen)</c>.
    /// <c>ReachedDocEnd</c> tells the scoped validator whether "still-open elements at window end" is a real error or
    /// merely the cut point (feeds <c>XmlFragmentLinter.Lint</c>'s <c>reachedDocEnd</c> gate).
    /// </summary>
    (string Text, bool ReachedDocEnd) Substring(int fromOffset, int cap);

    // ---- Programmatic edits ------------------------------------------------------------------------------------

    /// <summary>
    /// Sets attribute <paramref name="attrName"/> of <paramref name="node"/> to <paramref name="newValue"/>
    /// (XML-escaping <c>&amp;</c>/<c>&lt;</c>/<c>"</c>), updates the node, and delta-shifts <c>lineStarts</c> from the
    /// edited line (attribute values never contain newlines). Returns <c>false</c> if the value range cannot be found.
    /// </summary>
    bool ApplyAttrEdit(XmlTreeNode node, string attrName, string newValue);

    /// <summary>
    /// Renames both the opening and closing tags of <paramref name="node"/> as ONE undoable edit (a single Ctrl+Z
    /// restores both). Refuses on empty name, a stale tree (recorded position no longer starts with <c>&lt;oldName</c>),
    /// or minified same-name ambiguity. Handles self-closing tags (one rename).
    /// </summary>
    bool ApplyTagRename(XmlTreeNode node, string newName);

    /// <summary>
    /// Replaces <paramref name="node"/>'s text content with <paramref name="newText"/> (XML-escaping
    /// <c>&amp;</c>/<c>&lt;</c>), updates <see cref="XmlTreeNode.TextValue"/>, and delta-shifts <c>lineStarts</c> only
    /// when the new text has no newline. Returns <c>false</c> for self-closing elements / when the content range cannot be found.
    /// </summary>
    bool ApplyTextEdit(XmlTreeNode node, string newText);

    /// <summary>
    /// Re-reads the node's text value from source. Early-out: if the node has any child ELEMENT, sets
    /// <see cref="XmlTreeNode.TextValue"/> to <c>""</c> and returns without scanning; otherwise reads the content
    /// range, decodes entities, and trims.
    /// </summary>
    void RefreshTextValue(XmlTreeNode node);

    /// <summary>
    /// Re-parses the node's tag from current source: picks up the tag name (updating <see cref="XmlTreeNode.Name"/> so
    /// a source-edit rename propagates), then re-parses all attributes (decoding entities) into
    /// <see cref="XmlTreeNode.Attributes"/>.
    /// </summary>
    void RefreshAttributes(XmlTreeNode node);

    /// <summary>
    /// Applies a one-click linter fix. Bounds-checks <paramref name="range"/>; if it is non-empty and the current text
    /// there differs from <paramref name="original"/> (the text changed between lint and click), the fix is REFUSED to
    /// avoid corrupting an unrelated spot. Otherwise it edits undoably, delta-shifts <c>lineStarts</c> when neither side
    /// has a newline, moves the caret past the replacement, scrolls, and paints the landing band. Returns success.
    /// </summary>
    bool ApplyFix((int Start, int Length) range, string original, string replacement);

    /// <summary>
    /// Convenience overload that applies a <see cref="FixIt"/>: verifies the document text at <see cref="FixIt.Range"/>
    /// still equals <see cref="FixIt.Original"/> before replacing it with <see cref="FixIt.Replacement"/>
    /// (<c>""</c> deletes; a zero-length range inserts). Returns success.
    /// </summary>
    bool ApplyFix(FixIt fix);

    /// <summary>
    /// An undo-friendly raw edit that replaces <paramref name="range"/> with <paramref name="replacement"/>. Used by the
    /// tree context menu (cut/duplicate/delete). Returns success.
    /// </summary>
    bool PerformEdit((int Start, int Length) range, string replacement);

    /// <summary>
    /// Replaces every occurrence of <paramref name="find"/> with <paramref name="with"/> inside <paramref name="range"/>.
    /// Returns the occurrence count (0 if none), or the sentinel <b><c>-1</c></b> when <paramref name="range"/> exceeds
    /// 100,000,000 chars (too large to copy on a 655 MB file). <paramref name="wholeWord"/> checks XML word boundaries.
    /// </summary>
    int ReplaceAll(string find, string with, bool caseSensitive, bool wholeWord, (int Start, int Length) range);

    // ---- Search ------------------------------------------------------------------------------------------------

    /// <summary>
    /// The next (<paramref name="forward"/>) or previous occurrence of <paramref name="needle"/> from
    /// <paramref name="fromPosition"/>, WRAPPING within <paramref name="scope"/>, or <c>null</c> if none. Honors
    /// <paramref name="caseSensitive"/> and <paramref name="wholeWord"/>.
    /// </summary>
    (int Start, int Length)? MatchRange(string needle, int fromPosition, bool forward, bool caseSensitive, bool wholeWord, (int Start, int Length) scope);

    /// <summary>Every occurrence of <paramref name="needle"/> within <paramref name="scope"/>, up to <paramref name="cap"/> (default 5000; Find-All results table).</summary>
    IReadOnlyList<(int Start, int Length)> AllMatchRanges(string needle, bool caseSensitive, bool wholeWord, (int Start, int Length) scope, int cap = 5000);

    /// <summary>The whole-document range <c>(0, docLen)</c>.</summary>
    (int Start, int Length) FullDocumentRange { get; }

    /// <summary>The entire document as a string. Potentially very large, avoid on the hot path.</summary>
    string DocumentText { get; }

    // ---- Zoom / theme ------------------------------------------------------------------------------------------

    /// <summary>Per-pane zoom in (mutates <c>zoomStep</c> then re-applies the font). Clamped 5…40 pt.</summary>
    void ZoomIn();

    /// <summary>Per-pane zoom out. Clamped 5…40 pt.</summary>
    void ZoomOut();

    /// <summary>Resets per-pane zoom (<c>zoomStep</c> to 0).</summary>
    void ZoomReset();

    /// <summary>Rebuilds fonts after a global-zoom change (header, editor, ruler digit font, ruler thickness) and redraws.</summary>
    void RebuildFonts();

    /// <summary>Re-applies theme colors that were captured once and don't auto-update (editor bg/text/insertion/selection, header, ruler, highlighter caches).</summary>
    void RebuildColors();

    /// <summary>Rebuilds <c>lineStarts</c> from the current buffer (used after bulk edits that shift everything).</summary>
    void RefreshLineStarts();

    // ---- Line numbers ------------------------------------------------------------------------------------------

    /// <summary>Shows/hides the line-number gutter and persists the choice to <c>XMLMacker.showLineNumbers</c>.</summary>
    void SetLineNumbersVisible(bool visible);

    /// <summary>Whether the gutter is currently visible.</summary>
    bool IsLineNumbersVisible { get; }

    /// <summary>The persisted gutter-visibility preference; <b>default ON</b> when the key is absent (first run).</summary>
    bool IsLineNumberVisibilityPersistedOn { get; }

    // ---- Minimap -----------------------------------------------------------------------------------------------

    /// <summary>Shows/hides the minimap column and persists the choice to <c>XMLMacker.showMinimap</c>.</summary>
    void SetMinimapVisible(bool visible);

    /// <summary>Whether the minimap column is currently on screen.</summary>
    bool IsMinimapVisible { get; }

    /// <summary>The persisted minimap preference; <b>default ON</b> when the key is absent (first run).</summary>
    bool IsMinimapVisibilityPersistedOn { get; }

    /// <summary>The shared UTF-16 line-offset table, exposed for the ruler and minimap.</summary>
    int[] CurrentLineStarts { get; }

    // ---- Events ------------------------------------------------------------------------------------------------

    /// <summary>Fired ~0.40 s after typing stops (source → inspector live sync).</summary>
    event EventHandler? SourceChanged;

    /// <summary>Fired after a load completes and <c>lineStarts</c> is populated (the minimap waits on this).</summary>
    event EventHandler? FileLoaded;

    /// <summary>Fired on every real mutation (typed or programmatic; loads excluded) → drives the dirty flag.</summary>
    event EventHandler? DocumentMutated;

    /// <summary>Fired on selection change.</summary>
    event EventHandler? SelectionChanged;
}
