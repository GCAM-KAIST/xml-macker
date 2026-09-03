using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Xml;

namespace XMLMacker.Core;

/// <summary>
/// A streaming DOM builder, a 1:1 port of the Swift <c>XMLStreamParser</c>. Drives a
/// <see cref="System.Xml.XmlReader"/> as a pull loop that emits the same start/end/characters/error events as the
/// Swift <c>XMLParserDelegate</c>, assembling an <see cref="XmlTreeNode"/> tree while enforcing truncation/safety caps.
///
/// Streams from disk, <see cref="ParseFile"/> feeds a <see cref="FileStream"/> to <see cref="XmlReader"/> and never
/// loads the whole file as one string.
///
/// The class is <b>single-use</b>: internal accumulators (<c>stack</c>, <c>errors</c>, <c>nextId</c>) are not reset
/// between parses, so <b>create a fresh instance per parse</b>. <see cref="ParseFragment"/> constructs a new instance
/// for exactly this reason.
/// </summary>
public sealed class XmlStreamParser
{
    // ---- Truncation / safety caps (public mutable fields, exact defaults) --------------------------------------

    /// <summary>Maximum nesting depth. Elements deeper than this are dropped (a <c>null</c> sentinel is pushed to keep start/end balance). Enforced by default.</summary>
    public int MaxDepth = 64;

    /// <summary>Max children recorded per parent. Effectively unbounded by default (a virtualizing tree makes caps unnecessary).</summary>
    public int ChildrenPerParentCap = int.MaxValue;

    /// <summary>Max total nodes. Effectively unbounded by default.</summary>
    public int HardNodeCap = int.MaxValue;

    /// <summary>Most attributes recorded for one element. A DOCTYPE can declare hundreds of defaulted attributes that the reader then reports on every element.</summary>
    private const int MaxAttributesPerElement = 256;

    /// <summary>Most text collected for one element (4 MB). Nothing on screen shows more, and it stops one element's text growing without limit.</summary>
    private const int TextValueCap = 4 * 1024 * 1024;

    // ---- Internal state ----------------------------------------------------------------------------------------

    private readonly Dictionary<XmlTreeNode, StringBuilder> _pendingText = new();   // text gathered per open element
    private int _nextId;                                   // monotonically increasing node id; also the element node count
    private readonly bool _buildsTree;
    private readonly XmlTreeNode _document;                // the sentinel root, created at init
    private readonly List<XmlTreeNode?> _stack = new();    // open-element stack; holds nulls for capped/too-deep elements
    private readonly List<ParseError> _errors = new();
    private int _truncatedCount;                           // count of dropped/placeholder nodes (internal only)

    // Cross-thread progress: written on the parse thread, read lock-free on the UI thread.
    private volatile int _currentLineNumber;

    /// <summary>
    /// Live parse progress (1-based current line). Read from the UI thread while <see cref="ParseFile"/> runs on a
    /// background thread to drive a progress indicator. Returns <c>0</c> before parsing starts and after it finishes.
    /// </summary>
    public int CurrentLineNumber => _currentLineNumber;

    /// <summary>Creates a fresh single-use parser. Pushes the <c>#document</c> sentinel onto the stack.</summary>
    public XmlStreamParser()
        : this(true)
    {
    }

    private XmlStreamParser(bool buildsTree)
    {
        _buildsTree = buildsTree;
        _document = new XmlTreeNode(0, NodeKind.Document, "#document");
        _stack.Add(_document);
    }

    public static IReadOnlyList<ParseError> ValidateFile(string path) =>
        new XmlStreamParser(false).ParseFile(path).Errors;

    public static IReadOnlyList<ParseError> ValidateText(string text) =>
        new XmlStreamParser(false).ParseText(text).Errors;

    // ---- Public methods ----------------------------------------------------------------------------------------

    /// <summary>
    /// Full-file structural parse. Streams from a <see cref="FileStream"/> (never loads the whole file as a string).
    /// If the file cannot be opened, returns immediately with a single <c>"Cannot open file"</c> error.
    /// </summary>
    public ParseResult ParseFile(string path)
    {
        FileStream stream;
        try
        {
            stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 1 << 16, FileOptions.SequentialScan);
        }
        catch
        {
            return new ParseResult(_document, new List<ParseError> { new ParseError(1, 1, "Cannot open file") }, 0);
        }

        try
        {
            using var reader = XmlReader.Create(stream, CreateSettings());
            return RunParse(reader);
        }
        finally
        {
            stream.Dispose();
        }
    }

    /// <summary>
    /// Parses an in-memory string (the live re-validation flow, so errors reflect the on-screen editor text rather than
    /// stale disk contents).
    /// </summary>
    public ParseResult ParseText(string text)
    {
        using var stringReader = new StringReader(text);
        using var reader = XmlReader.Create(stringReader, CreateSettings());
        return RunParse(reader);
    }

    /// <summary>
    /// Parses a FRAGMENT of the document (a single element's bytes) and shifts all error line numbers into absolute
    /// whole-file coordinates. Creates a fresh instance (state cannot be reused). The attached fix-its are dropped on
    /// this path, the primary live validator uses <see cref="XmlFragmentLinter.Lint"/> instead.
    /// </summary>
    public static ParseResult ParseFragment(string text, int baseLine)
    {
        var raw = new XmlStreamParser().ParseText(text);
        int offset = Math.Max(0, baseLine - 1);
        var shifted = new List<ParseError>(raw.Errors.Count);
        foreach (var err in raw.Errors)
        {
            shifted.Add(new ParseError(err.Line + offset, err.Column, err.Message));
        }
        return new ParseResult(raw.Root, shifted, raw.NodeCount);
    }

    // ---- Reader settings ---------------------------------------------------------------------------------------

    private static XmlReaderSettings CreateSettings() => new()
    {
        // Security: never fetch external DTD/entities.
        DtdProcessing = DtdProcessing.Parse,
        XmlResolver = null,
        // A few hundred bytes of nested entity definitions expand into gigabytes and take the app down.
        // Real documents never come close to ten million characters of entity text.
        MaxCharactersFromEntities = 10_000_000,
        // The Swift XMLParser tolerates any character; matching that leniency.
        CheckCharacters = false,
        // Deliver PIs/comments (no tree nodes are built for them, matching the Swift delegate).
        IgnoreProcessingInstructions = false,
        IgnoreComments = false,
        // Whitespace-only runs are discarded (memory). Insignificant whitespace between tags is dropped by the reader;
        // any text that does arrive is trimmed and skipped if empty (see HandleCharacters).
        IgnoreWhitespace = true,
        CloseInput = false
    };

    // ---- The pull loop (equivalent to Swift runParse + the delegate callbacks) ----------------------------------

    private ParseResult RunParse(XmlReader reader)
    {
        var lineInfo = reader as IXmlLineInfo;
        try
        {
            while (reader.Read())
            {
                if (lineInfo != null) _currentLineNumber = lineInfo.LineNumber;

                switch (reader.NodeType)
                {
                    case XmlNodeType.Element:
                        if (!_buildsTree) break;
                        HandleStartElement(reader, lineInfo);
                        // XmlReader emits no separate EndElement for an empty element (<a/>): balance the stack here.
                        if (reader.IsEmptyElement) HandleEndElement(lineInfo);
                        break;

                    case XmlNodeType.EndElement:
                        if (!_buildsTree) break;
                        HandleEndElement(lineInfo);
                        break;

                    case XmlNodeType.Text:
                    case XmlNodeType.CDATA:
                    case XmlNodeType.SignificantWhitespace:
                        if (!_buildsTree) break;
                        HandleCharacters(reader.Value);
                        break;
                }
            }
        }
        catch (Exception ex)
        {
            // parseErrorOccurred + the post-parse parserError sweep collapse to one delivery point here (XmlReader
            // aborts on the first well-formedness error). Reproduce the de-dup guard: append only if no existing error
            // has the same message AND same line.
            int line = 1, col = 1;
            if (ex is XmlException xex)
            {
                if (xex.LineNumber > 0) line = xex.LineNumber;
                if (xex.LinePosition > 0) col = xex.LinePosition;
            }
            else if (lineInfo != null)
            {
                line = Math.Max(1, lineInfo.LineNumber);
                col = Math.Max(1, lineInfo.LinePosition);
            }

            string msg = ex.Message;
            if (!_errors.Any(e => e.Message == msg && e.Line == line))
            {
                _errors.Add(new ParseError(line, col, msg));
            }
        }

        if (lineInfo is not null)
            _currentLineNumber = Math.Max(_currentLineNumber, lineInfo.LineNumber);
        FlushAllText();
        return new ParseResult(_document, _errors.ToList(), _nextId);
    }

    // ---- didStartElement ---------------------------------------------------------------------------------------

    private void HandleStartElement(XmlReader reader, IXmlLineInfo? lineInfo)
    {
        int lineNo = lineInfo?.LineNumber ?? 1;

        if (_nextId >= HardNodeCap)          // over hard cap
        {
            _stack.Add(null);
            _truncatedCount++;
            return;
        }
        if ((_stack.Count - 1) >= MaxDepth)  // depth = number of open elements
        {
            _stack.Add(null);
            _truncatedCount++;
            return;
        }

        XmlTreeNode? parent = CurrentParent();
        if (parent != null && parent.Children.Count >= ChildrenPerParentCap)
        {
            if (parent.Children.Count == ChildrenPerParentCap)   // exactly at cap → insert ONE placeholder
            {
                _nextId++;
                var placeholder = new XmlTreeNode(_nextId, NodeKind.Comment, "#truncated")
                {
                    TextValue = "(more elements not shown, branch too large)",
                    IsTruncationPlaceholder = true,
                    Parent = parent
                };
                parent.Children.Add(placeholder);
                _truncatedCount++;
            }
            _stack.Add(null);
            return;
        }

        // normal element
        _nextId++;
        var node = new XmlTreeNode(_nextId, NodeKind.Element, reader.Name);

        if (reader.HasAttributes)
        {
            // Two guards. Attributes the document did not write, invented for every element by a
            // DOCTYPE default, are skipped: a few hundred such declarations otherwise attach hundreds of
            // pairs to every element in the file and a small file allocates gigabytes. And the list is
            // bounded, because nothing displays more attributes than this.
            int total = reader.AttributeCount;
            var attrs = new List<(string Name, string Value)>(Math.Min(total, MaxAttributesPerElement));
            for (int a = 0; a < total && attrs.Count < MaxAttributesPerElement; a++)
            {
                reader.MoveToAttribute(a);
                if (reader.IsDefault) continue;
                attrs.Add((reader.Name, reader.Value));
            }
            reader.MoveToElement();
            // Alphabetical (ascending, ordinal) by attribute name at build time, so display order matches.
            attrs.Sort((x, y) => string.CompareOrdinal(x.Name, y.Name));
            if (attrs.Count > 0) node.Attributes = attrs;
        }

        node.StartLine = lineNo;
        node.StartOffset = 0;   // XmlReader gives no byte offsets

        if (parent != null)
        {
            node.Parent = parent;
            parent.Children.Add(node);
        }
        _stack.Add(node);
    }

    // ---- didEndElement -----------------------------------------------------------------------------------------

    private void HandleEndElement(IXmlLineInfo? lineInfo)
    {
        if (_stack.Count <= 1) return;   // NEVER pop the sentinel document node (malformed fragments over-deliver ends)

        XmlTreeNode? top = _stack[^1];
        _stack.RemoveAt(_stack.Count - 1);
        if (top != null)
        {
            top.EndLine = lineInfo?.LineNumber ?? top.EndLine;
            FlushText(top);
            top.TextValue = top.TextValue.Trim();
        }
    }

    // ---- foundCharacters ---------------------------------------------------------------------------------------

    private void HandleCharacters(string value)
    {
        if (value.Trim().Length == 0) return;   // skip whitespace-only runs (memory)

        XmlTreeNode? parent = CurrentParent();
        if (parent == null) return;

        // Collected in a builder, not by string addition. A comment, a processing instruction or a CDATA
        // section splits the text of one element into separate runs, and adding each run to the string
        // copies everything gathered so far: a few megabytes of such runs would copy billions of
        // characters. The cap stops one element's text growing without limit; nothing on screen shows
        // anywhere near this much.
        if (!_pendingText.TryGetValue(parent, out StringBuilder? builder))
        {
            builder = new StringBuilder(parent.TextValue);
            _pendingText[parent] = builder;
        }
        if (builder.Length >= TextValueCap) return;
        builder.Append(value);
    }

    /// <summary>Moves the collected text of <paramref name="node"/> onto the node itself.</summary>
    private void FlushText(XmlTreeNode node)
    {
        if (_pendingText.Remove(node, out StringBuilder? builder)) node.TextValue = builder.ToString();
    }

    /// <summary>Moves whatever is still collected onto its nodes (a document that ends unclosed).</summary>
    private void FlushAllText()
    {
        foreach ((XmlTreeNode node, StringBuilder builder) in _pendingText)
            node.TextValue = builder.ToString().Trim();
        _pendingText.Clear();
    }

    // ---- currentParent -----------------------------------------------------------------------------------------

    private XmlTreeNode? CurrentParent()
    {
        for (int k = _stack.Count - 1; k >= 0; k--)
        {
            if (_stack[k] != null) return _stack[k];
        }
        return null;
    }
}
