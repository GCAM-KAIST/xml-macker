using System.Collections.Generic;

namespace XMLMacker.Core;

/// <summary>
/// Every element's start line, bucketed by <b>level</b>, where a level is "this tag name at this depth"
/// (for example <c>supplysector</c> at depth 3, or <c>region</c> at depth 2).
///
/// <para>Built once per parse and reused for every selection, so the minimap's left lane can offer the
/// current element's own level as magnets: on a region it jumps between regions, on a supplysector it
/// jumps between supplysectors across the whole file, and so on. Depth is the number of element
/// ancestors; the document root's direct child (<c>&lt;scenario&gt;</c>) is depth 0.</para>
/// </summary>
public sealed class ElementLevelIndex
{
    private readonly Dictionary<(int Depth, string Name), List<int>> _lines = new();

    /// <summary>The tree this index was built from, compare by reference to know when it is stale.</summary>
    public XmlTreeNode Root { get; }

    /// <summary>Number of elements indexed.</summary>
    public int ElementCount { get; private set; }

    public ElementLevelIndex(XmlTreeNode root)
    {
        Root = root;

        // Iterative walk: the tree can hold a few million elements on a large GCAM file and a recursive
        // walk that deep is unnecessary risk. Children are pushed in reverse so lines come out ascending.
        var stack = new Stack<(XmlTreeNode Node, int Depth)>();
        foreach (XmlTreeNode c in root.Children)
            if (c.Kind == NodeKind.Element) stack.Push((c, 0));

        while (stack.Count > 0)
        {
            (XmlTreeNode node, int depth) = stack.Pop();
            var key = (depth, node.Name);
            if (!_lines.TryGetValue(key, out List<int>? list))
            {
                list = new List<int>();
                _lines[key] = list;
            }
            list.Add(node.StartLine);
            ElementCount++;

            for (int i = node.Children.Count - 1; i >= 0; i--)
            {
                XmlTreeNode c = node.Children[i];
                if (c.Kind == NodeKind.Element) stack.Push((c, depth + 1));
            }
        }

        foreach (List<int> list in _lines.Values) list.Sort();
    }

    /// <summary>All start lines of elements named <paramref name="name"/> at <paramref name="depth"/>, ascending.</summary>
    public IReadOnlyList<int> LinesAt(int depth, string name)
        => _lines.TryGetValue((depth, name), out List<int>? list) ? list : System.Array.Empty<int>();

    /// <summary>Depth of <paramref name="node"/>: how many ELEMENT ancestors it has.</summary>
    public static int DepthOf(XmlTreeNode node)
    {
        int depth = 0;
        for (XmlTreeNode? a = node.Parent; a is { Kind: NodeKind.Element }; a = a.Parent) depth++;
        return depth;
    }
}
