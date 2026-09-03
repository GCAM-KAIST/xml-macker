using System.Collections.Generic;
using System.Linq;

namespace XMLMacker.Core;

/// <summary>
/// The in-memory XML tree node, a 1:1 port of the Swift <c>XMLTreeNode</c> class.
///
/// This is deliberately a <b>reference type (class)</b>, never a struct/record: the outline view
/// compares nodes by pointer identity (or the stable <see cref="Id"/>), never by value equality,
/// and the parser builds cheap parent back-references while streaming. Do not add value equality.
/// </summary>
public sealed class XmlTreeNode
{
    /// <summary>Stable unique id; <c>0</c> for the <c>#document</c> sentinel. Also serves as the element node count high-water mark in the parser.</summary>
    public int Id { get; }

    /// <summary>The node kind.</summary>
    public NodeKind Kind { get; }

    /// <summary>Element/tag name; <c>#document</c> for the root; <c>#truncated</c> for the placeholder. Mutable so a source-edit rename can propagate.</summary>
    public string Name { get; set; }

    /// <summary>Concatenated, trimmed text content (multiple runs concatenated with no separator). Defaults to <c>""</c>.</summary>
    public string TextValue { get; set; } = "";

    /// <summary>
    /// Ordered attribute list of (name, value) pairs, <b>NOT a dictionary</b>: order is significant
    /// and duplicates can exist. Sorted ascending by name at build time. Mutated in place by attribute edits.
    /// </summary>
    public List<(string Name, string Value)> Attributes { get; set; } = new();

    /// <summary>
    /// Plain back-reference to the parent (NOT a <c>WeakReference</c>: the GC collects cycles, so a plain
    /// reference is correct, a weak parent would be collected while children live). <c>null</c> for the root.
    /// </summary>
    public XmlTreeNode? Parent { get; set; }

    /// <summary>Child nodes in document order.</summary>
    public List<XmlTreeNode> Children { get; set; } = new();

    /// <summary>Char offset in the original file. Often <c>0</c>, the streaming parser exposes no byte offsets.</summary>
    public int StartOffset { get; set; }

    /// <summary>Char offset in the original file. Often <c>0</c>.</summary>
    public int EndOffset { get; set; }

    /// <summary>1-based line where the element opened. Defaults to <c>1</c>.</summary>
    public int StartLine { get; set; } = 1;

    /// <summary>1-based line where the element closed. Defaults to <c>1</c>.</summary>
    public int EndLine { get; set; } = 1;

    /// <summary>True for the "…more elements not shown" marker node.</summary>
    public bool IsTruncationPlaceholder { get; set; }

    /// <summary>Constructs a node with the given id, kind and name. All other fields keep their defaults.</summary>
    public XmlTreeNode(int id, NodeKind kind, string name)
    {
        Id = id;
        Kind = kind;
        Name = name;
    }

    /// <summary>
    /// Outline row label (display contract, reproduced verbatim):
    /// <list type="bullet">
    /// <item><c>Document</c> → <see cref="Name"/> (the loader renames the document node to the file name;
    /// <c>#document</c> means nothing on screen).</item>
    /// <item><c>Element</c> → <see cref="Name"/>.</item>
    /// <item><c>Text</c> → literal <c>"#text"</c>.</item>
    /// <item><c>Comment</c> → literal <c>"#comment"</c>.</item>
    /// </list>
    /// </summary>
    public string DisplayLabel => Kind switch
    {
        NodeKind.Document => Name,
        NodeKind.Element => Name,
        NodeKind.Text => "#text",
        NodeKind.Comment => "#comment",
        _ => Name
    };

    /// <summary>
    /// Outline row detail (display contract, reproduced verbatim):
    /// empty unless the node is an element with attributes; otherwise the first <b>3</b> attributes
    /// formatted as <c>name="value"</c> joined by a single space, with <c> …</c> (space + U+2026 horizontal
    /// ellipsis) appended when there are more than 3. Example: <c>year="1975" fillout="1" name="foo" …</c>.
    /// </summary>
    public string DisplayDetail
    {
        get
        {
            if (Kind != NodeKind.Element) return "";
            if (Attributes.Count == 0) return "";
            string joined = string.Join(" ", Attributes.Take(3).Select(a => $"{a.Name}=\"{a.Value}\""));
            if (Attributes.Count > 3) joined += " …";
            return joined;
        }
    }

    /// <summary>
    /// Whether the outline row is a leaf (no disclosure triangle): <see cref="Children"/> is empty.
    /// A node with no children is a leaf even if it has text/attributes.
    /// </summary>
    public bool IsLeafForOutline => Children.Count == 0;
}
