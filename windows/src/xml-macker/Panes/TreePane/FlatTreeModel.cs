using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using XMLMacker.Core;

namespace XMLMacker.Panes;

/// <summary>
/// An <see cref="ObservableCollection{T}"/> that can splice a whole range in or out with a single
/// <see cref="NotifyCollectionChangedAction.Reset"/> notification, instead of one event per item.
/// Essential for the tree: expanding an element with thousands of children must not fire thousands
/// of <c>CollectionChanged</c> events at a virtualizing <c>ListBox</c>.
/// </summary>
public sealed class RangeObservableCollection<T> : ObservableCollection<T>
{
    /// <summary>Insert <paramref name="items"/> starting at <paramref name="index"/>; one Reset raised.</summary>
    public void InsertRange(int index, IList<T> items)
    {
        if (items.Count == 0) return;
        CheckReentrancy();
        // One block move. Inserting one at a time shifts every row below the insertion point once per
        // child, so expanding an element with many children costs children x rows-below moves: measured
        // at half a minute for 300,000 children, against milliseconds for the single move.
        if (Items is List<T> backing) backing.InsertRange(index, items);
        else for (int i = 0; i < items.Count; i++) Items.Insert(index + i, items[i]);
        RaiseReset();
    }

    /// <summary>Remove <paramref name="count"/> items starting at <paramref name="index"/>; one Reset raised.</summary>
    public void RemoveRange(int index, int count)
    {
        if (count <= 0) return;
        CheckReentrancy();
        if (Items is List<T> backing) backing.RemoveRange(index, count);
        else for (int i = 0; i < count; i++) Items.RemoveAt(index);
        RaiseReset();
    }

    /// <summary>Replace the entire contents; one Reset raised.</summary>
    public void ReplaceAll(IList<T> items)
    {
        CheckReentrancy();
        Items.Clear();
        for (int i = 0; i < items.Count; i++)
            Items.Add(items[i]);
        RaiseReset();
    }

    private void RaiseReset()
    {
        OnPropertyChanged(new PropertyChangedEventArgs(nameof(Count)));
        OnPropertyChanged(new PropertyChangedEventArgs("Item[]"));
        OnCollectionChanged(new NotifyCollectionChangedEventArgs(NotifyCollectionChangedAction.Reset));
    }
}

/// <summary>
/// The <b>flattened, virtualized</b> outline model over an <see cref="XmlTreeNode"/> tree, the WPF
/// answer to <c>NSOutlineView</c>'s constant-memory virtualization. Rather
/// than binding a WPF <c>TreeView</c> (which nests virtualizing panels and leaks at millions of
/// nodes), a single flat <see cref="Rows"/> collection is kept, containing <b>only expanded-visible
/// rows</b>. Expand/collapse splice contiguous child ranges into/out of that list; the
/// <c>ListBox</c> virtualizes the flat list so only on-screen rows realize containers.
/// Nothing here ever walks the whole tree: expansion materializes only the rows that become visible,
/// bounded by the parser's <c>MaxDepth</c> and by what is expanded. Safe on a 12.6M-node tree.
/// </summary>
public sealed class FlatTreeModel
{
    /// <summary>The flat list of currently-visible rows, bound to the virtualizing <c>ListBox</c>.</summary>
    public RangeObservableCollection<TreeRow> Rows { get; } = new();

    /// <summary>
    /// The set of expanded nodes. Uses default reference identity (the node type defines
    /// no value equality), so a node collapsed then re-expanded restores its descendants' expansion.
    /// </summary>
    private readonly HashSet<XmlTreeNode> _expanded = new();

    /// <summary>The current root node, or null when no document is loaded.</summary>
    public XmlTreeNode? Root { get; private set; }

    private TreeRow CreateRow(XmlTreeNode node, int depth)
        => new(node, depth, _expanded.Contains(node), node.Children.Count > 0);

    /// <summary>Replace the tree. Collapses everything; the single root row (if any) becomes the sole visible row.</summary>
    public void SetRoot(XmlTreeNode? root)
    {
        Root = root;
        _expanded.Clear();
        var initial = new List<TreeRow>();
        if (root is not null)
            initial.Add(CreateRow(root, 0));
        Rows.ReplaceAll(initial);
    }

    /// <summary>Is <paramref name="node"/> currently expanded?</summary>
    public bool IsExpanded(XmlTreeNode node) => _expanded.Contains(node);

    /// <summary>
    /// Build the flat, pre-order list of visible descendants of <paramref name="node"/> at the given
    /// parent depth. Iterative (explicit stack) so it never recurses; only descends into nodes that are
    /// in <see cref="_expanded"/>, so the produced list is bounded by the visible-row count.
    /// </summary>
    private List<TreeRow> MaterializeVisibleChildren(XmlTreeNode node, int depth)
    {
        var outRows = new List<TreeRow>();
        var stack = new Stack<(XmlTreeNode node, int depth)>();
        var kids = node.Children;
        for (int i = kids.Count - 1; i >= 0; i--)
            stack.Push((kids[i], depth + 1));

        while (stack.Count > 0)
        {
            var (n, d) = stack.Pop();
            outRows.Add(CreateRow(n, d));
            if (_expanded.Contains(n) && n.Children.Count > 0)
            {
                for (int i = n.Children.Count - 1; i >= 0; i--)
                    stack.Push((n.Children[i], d + 1));
            }
        }
        return outRows;
    }

    /// <summary>Expand the row at <paramref name="index"/>, splicing its (recursively-visible) children in below it.</summary>
    public void Expand(int index)
    {
        if (index < 0 || index >= Rows.Count) return;
        TreeRow row = Rows[index];
        if (!row.HasChildren) return;
        if (_expanded.Contains(row.Node)) return;

        _expanded.Add(row.Node);
        row.SetExpanded(true);
        List<TreeRow> newRows = MaterializeVisibleChildren(row.Node, row.Depth);
        Rows.InsertRange(index + 1, newRows);
    }

    /// <summary>Collapse the row at <paramref name="index"/>, removing its contiguous descendant block.</summary>
    public void Collapse(int index)
    {
        if (index < 0 || index >= Rows.Count) return;
        TreeRow row = Rows[index];
        if (!_expanded.Contains(row.Node)) return;

        _expanded.Remove(row.Node);
        row.SetExpanded(false);

        int removeCount = 0;
        for (int i = index + 1; i < Rows.Count && Rows[i].Depth > row.Depth; i++)
            removeCount++;
        if (removeCount > 0)
            Rows.RemoveRange(index + 1, removeCount);
    }

    /// <summary>Toggle the row at <paramref name="index"/> (double-click / disclosure triangle).</summary>
    public void Toggle(int index)
    {
        if (index < 0 || index >= Rows.Count) return;
        if (_expanded.Contains(Rows[index].Node)) Collapse(index);
        else Expand(index);
    }

    /// <summary>Index of the visible row for <paramref name="node"/>, or -1 if not currently visible.</summary>
    public int RowIndexForNode(XmlTreeNode node)
    {
        for (int i = 0; i < Rows.Count; i++)
            if (ReferenceEquals(Rows[i].Node, node)) return i;
        return -1;
    }

    /// <summary>The visible <see cref="TreeRow"/> for <paramref name="node"/>, or null.</summary>
    public TreeRow? RowForNode(XmlTreeNode node)
    {
        int idx = RowIndexForNode(node);
        return idx >= 0 ? Rows[idx] : null;
    }

    /// <summary>
    /// Expand the ancestor chain of <paramref name="node"/> top-down so the node becomes visible.
    /// Bounded by the tree depth (≤ the parser's MaxDepth); never a broad walk.
    /// </summary>
    public void ExpandAncestors(XmlTreeNode node)
    {
        var chain = new List<XmlTreeNode>();
        XmlTreeNode? p = node.Parent;
        while (p is not null)
        {
            chain.Add(p);
            p = p.Parent;
        }
        chain.Reverse(); // top-down

        foreach (XmlTreeNode a in chain)
        {
            if (_expanded.Contains(a) || a.Children.Count == 0) continue;
            int idx = RowIndexForNode(a);
            if (idx >= 0) Expand(idx);
        }
    }
}
