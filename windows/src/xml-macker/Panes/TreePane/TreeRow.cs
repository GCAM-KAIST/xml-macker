using System.ComponentModel;
using System.Runtime.CompilerServices;
using XMLMacker.Core;

namespace XMLMacker.Panes;

/// <summary>
/// Row view-model for one visible outline row in <see cref="FlatTreeModel"/>. Wraps an
/// <see cref="XmlTreeNode"/> plus its flattened-outline presentation state (indent depth, expansion,
/// whether it has a disclosure triangle). 1:1 port of the data the Swift <c>AuroraTreeCell</c> read
/// off each node, adapted to the flattened virtualized <c>ListBox</c> strategy.
/// Implements <see cref="INotifyPropertyChanged"/> so a single-row refresh after an in-place edit
/// (<c>refreshNode</c>) re-pulls label/detail without rebuilding the whole list.
/// </summary>
public sealed class TreeRow : INotifyPropertyChanged
{
    /// <summary>The underlying tree node (reference identity, never compared by value).</summary>
    public XmlTreeNode Node { get; }

    /// <summary>Indent depth (0 = root row). Multiplied by <c>treeIndent</c> to produce the left margin.</summary>
    public int Depth { get; }

    public TreeRow(XmlTreeNode node, int depth, bool isExpanded, bool hasChildren)
    {
        Node = node;
        Depth = depth;
        _isExpanded = isExpanded;
        _hasChildren = hasChildren;
    }

    private bool _isExpanded;
    /// <summary>Whether this row's disclosure is open (its children are spliced in below it).</summary>
    public bool IsExpanded
    {
        get => _isExpanded;
        private set { if (_isExpanded != value) { _isExpanded = value; OnPropertyChanged(); } }
    }

    private bool _hasChildren;
    /// <summary>Whether this row shows a disclosure triangle (the node has children).</summary>
    public bool HasChildren
    {
        get => _hasChildren;
        private set { if (_hasChildren != value) { _hasChildren = value; OnPropertyChanged(); } }
    }

    /// <summary>The node kind, drives the 10×10 glyph shape/colour (element diamond, text dot, …).</summary>
    public NodeKind Kind => Node.Kind;

    /// <summary>
    /// The bold name label. Reproduces the Swift <c>node.displayLabel</c> contract, except the
    /// truncation placeholder ("…more elements not shown") surfaces its message text instead of the
    /// literal "#comment" its <c>Kind == Comment</c> would otherwise yield.
    /// </summary>
    public string Label => Node.IsTruncationPlaceholder && Node.TextValue.Length > 0
        ? Node.TextValue
        : Node.DisplayLabel;

    /// <summary>The quiet attribute-preview detail (<c>node.displayDetail</c>; empty for non-elements).</summary>
    public string Detail => Node.DisplayDetail;

    /// <summary>Called by the model when this row's expansion state changes.</summary>
    internal void SetExpanded(bool value) => IsExpanded = value;

    /// <summary>Re-pull label/detail/children after an in-place edit (single-row <c>refreshNode</c>).</summary>
    public void Refresh()
    {
        HasChildren = Node.Children.Count > 0;
        OnPropertyChanged(nameof(Kind));
        OnPropertyChanged(nameof(Label));
        OnPropertyChanged(nameof(Detail));
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
