using System.Windows.Controls;
using XMLMacker.Core;
using XMLMacker.Theme;

namespace XMLMacker.Charts;

/// <summary>
/// The inline chart pane, 1:1 port of the Swift <c>ChartPaneViewController</c>.
/// Hosts a <see cref="TrendView"/> plus a "Variable:" dropdown. The chart fills whatever space the
/// pane has; the dropdown appears only when ≥2 chartable variables exist and preserves the
/// previously selected variable while navigating between similar elements.
/// </summary>
public partial class ChartPaneControl : UserControl
{
    private XmlTreeNode? _currentNode;
    private bool _suppressSelection;

    public ChartPaneControl()
    {
        InitializeComponent();
        ApplyFonts();

        ThemeManager.ThemeChanged += (_, _) => RebuildColors();
        MetricsScaleService.Instance.RebuildFonts += (_, _) => RebuildFonts();
    }

    /// <summary>Read-only access to the inline chart (host wires <c>PopoutRequested</c>).</summary>
    public TrendView ExposedTrendView => Trend;

    /// <summary>Alias for <see cref="ExposedTrendView"/> (cross-agent name contract "exposes TrendView").</summary>
    public TrendView TrendView => Trend;

    /// <summary>The current series the chart is showing (host reads it to feed the pop-out).</summary>
    public TrendSeries? CurrentTrendSeries => Trend.Series;

    /// <summary>Fired whenever tree navigation or the variable picker changes the displayed series.</summary>
    public event Action<TrendSeries?>? SeriesChanged;

    /// <summary>
    /// Main entry, called by the host on every tree-selection change. Recomputes the chart while
    /// preserving the previously selected variable so the chart's "mode" stays stable.
    /// </summary>
    public void SetNode(XmlTreeNode? node)
    {
        _currentNode = node;
        var options = TrendComputer.AvailableTargets(node);

        Trend.PlaceholderText = "No repeating numbers under this element";

        string? previouslySelected = VarPopup.SelectedItem as string;

        _suppressSelection = true;
        VarPopup.ItemsSource = options;
        string? chosen = (previouslySelected is not null && options.Contains(previouslySelected))
            ? previouslySelected
            : options.FirstOrDefault();
        VarPopup.SelectedItem = chosen;
        _suppressSelection = false;

        bool showPicker = options.Count >= 2;
        VarRow.Visibility = showPicker
            ? System.Windows.Visibility.Visible
            : System.Windows.Visibility.Collapsed;
        if (showPicker) VarPopup.Height = XMMetric.S(22);

        Trend.Series = TrendComputer.Compute(node, chosen);
        SeriesChanged?.Invoke(Trend.Series);
    }

    private void VarPopup_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelection) return;
        if (_currentNode is null) return;
        if (VarPopup.SelectedItem is not string chosen) return;

        var series = TrendComputer.Compute(_currentNode, chosen);
        if (series is not null)
        {
            Trend.Series = series;
        }
        else
        {
            // Honest empty state, never keep a different variable's series.
            Trend.Series = null;
            Trend.PlaceholderText = $"No comparison available for '{chosen}' here";
        }
        SeriesChanged?.Invoke(Trend.Series);
    }

    /// <summary>Re-run <see cref="SetNode"/> for the current node (host calls on document mutation / theme).</summary>
    public void RefreshCurrent()
    {
        if (_currentNode is not null) SetNode(_currentNode);
    }

    /// <summary>Global-zoom hook: reset fonts / picker height and redraw the chart.</summary>
    public void RebuildFonts()
    {
        ApplyFonts();
        if (VarRow.Visibility == System.Windows.Visibility.Visible)
            VarPopup.Height = XMMetric.S(22);
        Trend.InvalidateVisual();
    }

    /// <summary>Theme hook: refresh the label color and redraw the chart.</summary>
    public void RebuildColors()
    {
        VarLabel.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text3);
        Trend.InvalidateVisual();
    }

    private void ApplyFonts()
    {
        XMFont.UiCaption.ApplyTo(VarLabel);
        var popupFont = XMFont.Ui(11);
        VarPopup.FontFamily = popupFont.Family;
        VarPopup.FontSize = popupFont.Size;
        VarPopup.FontWeight = popupFont.Weight;
    }
}
