using System.Collections.Generic;

namespace XMLMacker.Core;

/// <summary>
/// A concrete one-click repair for a lint error (Swift <c>FixIt</c>). Immutable value type, shared app-wide.
/// </summary>
/// <param name="Range">
/// Absolute UTF-16 character range <c>(Start, Length)</c> in the <b>live document</b> to be replaced.
/// A zero-length range means <b>insert</b> at <c>Start</c>.
/// </param>
/// <param name="Original">
/// The exact text currently expected at <paramref name="Range"/>. The apply step must read the current text at
/// <paramref name="Range"/> and compare it to this; if they differ (text was typed between lint and click, so
/// offsets shifted), the fix must be refused rather than corrupt an unrelated location. Empty when the range is zero-length.
/// </param>
/// <param name="Replacement">Text to substitute. An empty string <c>""</c> means <b>delete</b> the range.</param>
/// <param name="Title">Human-facing wording shown in the fix-it UI, e.g. <c>Change to &lt;/period&gt;</c>.</param>
public sealed record FixIt((int Start, int Length) Range, string Original, string Replacement, string Title);

/// <summary>
/// A single validation/parse error (Swift <c>ParseError</c>). Shared app-wide.
/// </summary>
/// <param name="Line">1-based line number in absolute / whole-file coordinates (after any offsetting).</param>
/// <param name="Column">1-based column.</param>
/// <param name="Message">Human-facing message.</param>
/// <param name="Fix">Optional attached repair; defaults to <c>null</c>.</param>
public sealed record ParseError(int Line, int Column, string Message, FixIt? Fix = null);

/// <summary>
/// The result of a full-file or in-memory parse (Swift <c>Result</c>). Shared app-wide.
/// </summary>
/// <param name="Root">The document root node, always non-null; the sentinel <c>#document</c> node even on failure.</param>
/// <param name="Errors">All parse errors.</param>
/// <param name="NodeCount">Number of element nodes created (the parser's <c>nextId</c> high-water mark).</param>
public sealed record ParseResult(XmlTreeNode Root, IReadOnlyList<ParseError> Errors, int NodeCount);
