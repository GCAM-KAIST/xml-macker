using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using XMLMacker.Core;
using XMLMacker.Theme;

namespace XMLMacker.Panes;

/// <summary>
/// The horizontal ancestor-path chip bar (Swift <c>BreadcrumbBar</c>). Renders the selected element's
/// ancestor chain root→selection as pill chips separated by <c>›</c> (U+203A); the last chip (the
/// current node) is accent-tinted and bold. Clicking any chip fires <see cref="OnSegmentClicked"/> →
/// routed to <c>treeVC.select</c> (the "any click reflects everywhere" rule). It is a horizontal
/// <see cref="ScrollViewer"/> with hidden scrollbars, auto-scrolled to the end whenever the path is set.
/// </summary>
public sealed class BreadcrumbBar : ScrollViewer
{
    private readonly StackPanel _stack;
    private List<XmlTreeNode> _path = new();

    /// <summary>Fired when a chip is clicked, the owner re-selects that node (full sync).</summary>
    public event Action<XmlTreeNode>? OnSegmentClicked;

    public BreadcrumbBar()
    {
        HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden;
        VerticalScrollBarVisibility = ScrollBarVisibility.Disabled;
        Background = Brushes.Transparent;
        BorderThickness = new Thickness(0);
        Focusable = false;

        _stack = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            // Edge insets: top 2, left 12, bottom 2, right 12.
            Margin = new Thickness(12, 2, 12, 2),
        };
        Content = _stack;

        Loaded += (_, _) =>
        {
            ThemeManager.ThemeChanged += OnThemeChanged;
            MetricsScaleService.Instance.RebuildFonts += OnRebuildFonts;
            Rebuild();
        };
        Unloaded += (_, _) =>
        {
            ThemeManager.ThemeChanged -= OnThemeChanged;
            MetricsScaleService.Instance.RebuildFonts -= OnRebuildFonts;
        };
    }

    /// <summary>Set the selected node, builds the ancestor path root→node and rebuilds the chips.</summary>
    public void SetPath(XmlTreeNode? node)
    {
        var path = new List<XmlTreeNode>();
        for (XmlTreeNode? cur = node; cur is not null; cur = cur.Parent)
            path.Add(cur);
        path.Reverse();
        _path = path;
        Rebuild();
    }

    private static Color WithAlpha(Color c, double alpha)
        => Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255), c.R, c.G, c.B);

    private void Rebuild()
    {
        _stack.Children.Clear();

        if (_path.Count == 0)
        {
            var none = new TextBlock
            {
                Text = "No selection",
                FontFamily = XMFont.UiFamily,
                FontSize = XMFont.Scaled(11),
                FontWeight = FontWeights.Medium,
                VerticalAlignment = VerticalAlignment.Center,
            };
            none.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text3);
            _stack.Children.Add(none);
            return;
        }

        for (int idx = 0; idx < _path.Count; idx++)
        {
            bool isLast = idx == _path.Count - 1;
            _stack.Children.Add(MakeChip(_path[idx], isLast));

            if (!isLast)
            {
                var sep = new TextBlock
                {
                    Text = "›",
                    FontFamily = XMFont.MonoFamily,
                    FontSize = XMFont.Scaled(12),
                    FontWeight = FontWeights.Regular,
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(0, 0, 4, 0),
                };
                sep.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text3);
                _stack.Children.Add(sep);
            }
        }

        // Auto-scroll to the end so the current node is always visible.
        Dispatcher.BeginInvoke(new Action(ScrollToRightEnd), DispatcherPriority.Loaded);
    }

    private Border MakeChip(XmlTreeNode node, bool highlighted)
    {
        var text = new TextBlock
        {
            Text = node.DisplayLabel,
            FontFamily = XMFont.MonoFamily,
            FontSize = XMFont.Scaled(11),
            FontWeight = highlighted ? FontWeights.SemiBold : FontWeights.Regular,
            VerticalAlignment = VerticalAlignment.Center,
        };
        text.SetResourceReference(TextBlock.ForegroundProperty, highlighted ? XMColor.Text : XMColor.Text2);

        var chip = new Border
        {
            Child = text,
            CornerRadius = new CornerRadius(XMMetric.RadiusPill), // 10
            Padding = new Thickness(8, 3, 8, 3),                  // content edge insets: L8 T3 R8 B3
            Cursor = Cursors.Hand,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 4, 0),                   // spacing 4 between arranged items
            Tag = node,
        };

        if (highlighted)
        {
            Color accent = XMColor.Color(XMColor.Accent);
            chip.Background = new SolidColorBrush(WithAlpha(accent, 0.18));
            chip.BorderBrush = new SolidColorBrush(WithAlpha(accent, 0.45));
            chip.BorderThickness = new Thickness(XMMetric.Hairline); // 0.5
        }
        else
        {
            chip.Background = Brushes.Transparent;
        }

        chip.MouseLeftButtonUp += (_, _) => OnSegmentClicked?.Invoke(node);
        return chip;
    }

    private void OnThemeChanged(object? sender, EventArgs e) => Rebuild();
    private void OnRebuildFonts(object? sender, EventArgs e) => Rebuild();
}
