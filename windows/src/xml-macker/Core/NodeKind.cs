namespace XMLMacker.Core;

/// <summary>
/// The kind of an <see cref="XmlTreeNode"/>. Ported 1:1 from the Swift
/// <c>XMLTreeNode.Kind</c> enum (<c>document</c>, <c>element</c>, <c>text</c>, <c>comment</c>).
/// </summary>
public enum NodeKind
{
    /// <summary>The synthetic <c>#document</c> sentinel root.</summary>
    Document,

    /// <summary>An XML element (tag).</summary>
    Element,

    /// <summary>A text node (kind label <c>#text</c>).</summary>
    Text,

    /// <summary>A comment node (kind label <c>#comment</c>); also used for the truncation placeholder.</summary>
    Comment
}
