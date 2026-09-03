using System;
using System.Collections.Generic;
using XMLMacker.Editor;

namespace XMLMacker.Core;

/// <summary>
/// Per-tab parked state (Chrome-style tabs, one open file = one session = one tab). A 1:1 port of the Swift
/// <c>DocumentSession</c>.
///
/// The ACTIVE tab's canonical state lives in the live UI (the editor's text buffer and the window controller's
/// current tree/selection); a session's fields are filled by the "snapshot on switch-away" step and read back on
/// "switch-to". A freshly created session is mostly empty until its first switch-away.
///
/// Memory trade ("the Chrome trade"): a parked session keeps its full text buffer AND parsed tree alive so
/// switching back is instant (no re-read, no re-parse). N open tabs cost N documents of RAM.
///
/// Behavioral contracts the owner (session/tab manager) must honor:
/// <list type="bullet">
/// <item>Snapshot on switch-away, restore on switch-to (the session isn't canonical until snapshotted).</item>
/// <item>Refuse tab switches while any session has <see cref="IsLoading"/> == <c>true</c>.</item>
/// <item>On activation, if <see cref="NeedsReparse"/>, reparse before showing the tree.</item>
/// <item><see cref="LineStarts"/> must be maintained incrementally on edit (a full 12.6M-line rescan per keystroke is not viable).</item>
/// </list>
/// </summary>
public sealed class DocumentSession
{
    public Guid Id { get; } = Guid.NewGuid();

    /// <summary>File path. <b>Mutable</b>, "Save As…" re-points the active tab.</summary>
    public string Url { get; set; }

    /// <summary>File size in bytes.</summary>
    public long FileSize { get; set; }

    public XmlTextEncoding TextEncoding { get; set; } = XmlTextEncoding.Utf8;

    public DateTime? FileModificationDateUtc { get; set; }

    /// <summary>
    /// The tab's full editable text buffer (parked). The WPF document text model, see <see cref="ITextBuffer"/>.
    /// <c>null</c> until the tab has content.
    /// </summary>
    public ITextBuffer? Storage { get; set; }

    /// <summary>
    /// Line-offset table: <c>LineStarts[k]</c> = char offset where line <c>k+1</c> begins. Enables O(1)
    /// line↔offset mapping for a 12.6M-line file without scanning. Always starts <c>[0]</c> (line 1 begins at offset 0).
    /// </summary>
    public int[] LineStarts { get; set; } = new[] { 0 };

    /// <summary>Parsed tree root (parked). <c>null</c> until parsed.</summary>
    public XmlTreeNode? Tree { get; set; }

    /// <summary>Last full-parse errors.</summary>
    public IReadOnlyList<ParseError> ParseErrors { get; set; } = Array.Empty<ParseError>();

    /// <summary>Last selected tree node.</summary>
    public XmlTreeNode? SelectedNode { get; set; }

    /// <summary>Editor scroll position to restore (the WPF analog of <c>NSPoint</c>). Defaults to <c>(0, 0)</c>.</summary>
    public (double X, double Y) ScrollOrigin { get; set; }

    /// <summary>Unsaved-changes flag.</summary>
    public bool IsDirty { get; set; }

    public ulong EditRevision { get; set; }

    /// <summary>The marker strokes (the highlighter); the main window stores them per file.</summary>
    public TextHighlights Highlights { get; } = new();

    /// <summary>
    /// Set when the doc was edited while PARKED (e.g. a diff copy-hunk applied to a background tab): the snapshot
    /// tree is stale, so activation must trigger a reparse.
    /// </summary>
    public bool NeedsReparse { get; set; }

    /// <summary>
    /// This tab's OWN undo stack. A shared stack would replay one document's edit ranges against another, so each
    /// tab owns its own instance. Typed as <see cref="object"/> because the concrete <c>EditorUndoStack</c> lives in
    /// the editor module; the session/editor assigns it.
    /// </summary>
    public object? UndoStack { get; set; }

    /// <summary>True from load start until parse + text load complete. Tab switching is refused while this is set for any session.</summary>
    public bool IsLoading { get; set; }

    /// <summary>Creates a session for <paramref name="url"/>; all other fields keep their defaults.</summary>
    public DocumentSession(string url, long fileSize)
    {
        Url = url;
        FileSize = fileSize;
    }
}
