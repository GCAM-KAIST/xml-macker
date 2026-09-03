using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using XMLMacker.Core;
using XMLMacker.Theme;

namespace XMLMacker.Panes;

/// <summary>
/// The right-column inspector host (Swift <c>InspectorViewController</c>): a two-tone title line over
/// the <see cref="AttributesBarControl"/>. The title composes the element tag in <c>syntaxTag</c>
/// (mono semibold) with a quiet metadata suffix ("N attrs · M children"). Attribute/text edits pass
/// straight through from the hosted attributes panel.
/// </summary>
public partial class InspectorPaneControl : UserControl
{
    private XmlTreeNode? _node;

    /// <summary>Pass-through: (node, attrName, newValue).</summary>
    public event Action<XmlTreeNode, string, string>? OnAttributeEdit;

    /// <summary>Pass-through: (node, newText).</summary>
    public event Action<XmlTreeNode, string>? OnTextEdit;

    /// <summary>Declared inspector contract; wired by the owner (the subtags table lives elsewhere).</summary>

    public InspectorPaneControl()
    {
        InitializeComponent();
        Attrs.OnAttributeEdit += (n, name, v) => OnAttributeEdit?.Invoke(n, name, v);
        Attrs.OnTextEdit += (n, t) => OnTextEdit?.Invoke(n, t);

        Loaded += (_, _) => MetricsScaleService.Instance.RebuildFonts += OnRebuildFonts;
        Unloaded += (_, _) => MetricsScaleService.Instance.RebuildFonts -= OnRebuildFonts;

        ApplyTitle();
    }

    /// <summary>True while the hosted attributes table (or its text field) is being edited.</summary>
    public bool IsEditingCell => Attrs.IsEditingCell;

    /// <summary>Set the current node: re-title and forward to the attributes panel.</summary>
    public void SetNode(XmlTreeNode? node)
    {
        _node = node;
        ApplyTitle();
        Attrs.SetNode(node);
    }

    /// <summary>Re-run <see cref="SetNode"/> with the stored node.</summary>
    public void RefreshCurrent() => SetNode(_node);

    /// <summary>Re-run only if a node is set and no cell edit is in progress (delegated to the panel).</summary>
    public void RefreshValuesOnly()
    {
        if (_node is not null && !IsEditingCell)
            SetNode(_node);
    }

    /// <summary>Per-pane zoom is routed to the attributes table (it owns the zoomable content).</summary>
    public void ZoomIn() => Attrs.ZoomIn();
    public void ZoomOut() => Attrs.ZoomOut();
    public void ZoomReset() => Attrs.ZoomReset();

    private void OnRebuildFonts(object? sender, EventArgs e) => ApplyTitle();

    private void ApplyTitle()
    {
        Title.Inlines.Clear();

        if (_node is null)
        {
            var none = new Run("No selection")
            {
                FontFamily = XMFont.UiFamily,
                FontSize = XMFont.Scaled(11),
                FontWeight = FontWeights.Medium,
            };
            none.SetResourceReference(TextElement.ForegroundProperty, XMColor.Text3);
            Title.Inlines.Add(none);
            return;
        }

        var tag = new Run($"<{_node.DisplayLabel}>")
        {
            FontFamily = XMFont.MonoFamily,
            FontSize = XMFont.Scaled(13),
            FontWeight = FontWeights.SemiBold,
        };
        tag.SetResourceReference(TextElement.ForegroundProperty, XMColor.SyntaxTag);
        Title.Inlines.Add(tag);

        int attrCount = _node.Attributes.Count;
        int childEl = 0;
        foreach (XmlTreeNode c in _node.Children)
            if (c.Kind == NodeKind.Element) childEl++;

        string attrWord = attrCount == 1 ? "attr" : "attrs";
        string childWord = childEl == 1 ? "child" : "children";
        var meta = new Run($"   {attrCount} {attrWord} · {childEl} {childWord}")
        {
            FontFamily = XMFont.UiFamily,
            FontSize = XMFont.Scaled(11),
            FontWeight = FontWeights.Normal,
        };
        meta.SetResourceReference(TextElement.ForegroundProperty, XMColor.Text3);
        Title.Inlines.Add(meta);
    }
}
