using System.Windows.Controls;
using XMLMacker.Core;
using XMLMacker.Theme;

namespace XMLMacker.Panes;

/// <summary>
/// The bottom flame-map pane wrapper (Swift <c>HierarchyBarViewController</c>). A thin host giving
/// <see cref="HierarchyMiniView"/> its own full-width pane below the SUBTAGS strip, the full window
/// width lets child boxes show real tag names instead of truncating. A quiet "HIERARCHY" caption and
/// the Mac-compatible Structure-only switch sit above the map.
/// </summary>
public partial class HierarchyBarControl : UserControl
{
    /// <summary>Pure pass-through of the flame map's navigation clicks (down into a child, or up to the parent).</summary>
    public event Action<XmlTreeNode>? OnChildClicked;

    public HierarchyBarControl()
    {
        InitializeComponent();
        Mini.OnChildClicked += n => OnChildClicked?.Invoke(n);
        StructureOnlyCheck.IsChecked = StructureFilter.Enabled;

        Loaded += (_, _) =>
        {
            MetricsScaleService.Instance.RebuildFonts += OnRebuildFonts;
            StructureFilter.Changed += OnStructureFilterChanged;
            ApplyTitleFont();
        };
        Unloaded += (_, _) =>
        {
            MetricsScaleService.Instance.RebuildFonts -= OnRebuildFonts;
            StructureFilter.Changed -= OnStructureFilterChanged;
        };

        ApplyTitleFont();
    }

    /// <summary>Forward the selected node to the flame map.</summary>
    public void SetNode(XmlTreeNode? node) => Mini.SetNode(node);

    private void ApplyTitleFont()
    {
        XMFont.UiCaption.ApplyTo(Title);
        XMFont.UiCaption.ApplyTo(StructureOnlyCheck);
    }

    private void StructureOnlyCheck_Click(object sender, System.Windows.RoutedEventArgs e)
        => StructureFilter.Enabled = StructureOnlyCheck.IsChecked == true;

    private void OnStructureFilterChanged(object? sender, EventArgs e)
        => StructureOnlyCheck.IsChecked = StructureFilter.Enabled;

    private void OnRebuildFonts(object? sender, EventArgs e)
    {
        // The mini view's intrinsic height folds in global scale and its labels use XMFont; nudge both.
        ApplyTitleFont();
        Mini.InvalidateMeasure();
        Mini.InvalidateVisual();
    }
}
