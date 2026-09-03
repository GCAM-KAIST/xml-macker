using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using XMLMacker.Theme;

namespace XMLMacker.Chrome;

/// <summary>
/// The multi-document tab strip. 1:1 port of <c>TabStripView.swift</c>: a horizontal row of
/// <see cref="TabChip"/>s that <b>scroll horizontally</b> (never crush below their min width) with a
/// trailing ＋ button. The mouse wheel scrolls horizontally. Height is <see cref="XMMetric.TabStripH"/>
/// (32) scaled by zoom.
/// </summary>
public partial class TabStripControl : UserControl
{
    private readonly Button _plusButton;

    /// <summary>Raised when a tab is clicked; carries the tab's index.</summary>
    public event EventHandler<int>? TabSelected;

    /// <summary>Raised when a tab's × is clicked; carries the tab's index.</summary>
    public event EventHandler<int>? TabCloseRequested;

    /// <summary>Right-click menu: close every tab except this one.</summary>
    public event EventHandler<int>? TabCloseOthersRequested;

    /// <summary>Right-click menu: show the file in Explorer.</summary>
    public event EventHandler<int>? TabRevealRequested;

    /// <summary>Raised when the trailing ＋ button is clicked.</summary>
    public event EventHandler? PlusClicked;

    public TabStripControl()
    {
        InitializeComponent();
        _plusButton = BuildPlusButton();

        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        ApplyMetrics();

        // Start empty (No file + plus).
        SetTabs(Array.Empty<string>(), -1, null);
    }

    // ── Public API ─────────────────────────────────────────────────────────────────────────

    /// <summary>
    /// Rebuild the strip. 1:1 with Swift <c>setTabs(_:activeIndex:)</c> plus per-tab dirty flags.
    /// When <paramref name="paths"/> is empty, shows a "No file" label. The ＋ button is always last.
    /// </summary>
    // The chips resolve their brushes when they are built, so a theme switch left them in the OLD
    // theme's colours (white names on the Light theme's white strip: invisible). Remember the last
    // contents and rebuild on every theme change.
    private IReadOnlyList<string> _lastPaths = System.Array.Empty<string>();
    private int _lastActive = -1;
    private IReadOnlyList<bool>? _lastDirty;
    private bool _themeHooked;

    /// <summary>The right-click menu of one tab. Items are plain words; the file name is in the title row.</summary>
    private ContextMenu BuildTabMenu(int index, string path, int tabCount)
    {
        var menu = new ContextMenu();
        string name = System.IO.Path.GetFileName(path);
        bool onDisk = System.IO.File.Exists(path);

        var title = new MenuItem { Header = name, IsEnabled = false, FontWeight = FontWeights.SemiBold };
        menu.Items.Add(title);
        menu.Items.Add(new Separator());

        var close = new MenuItem { Header = "Close", InputGestureText = "Ctrl+W" };
        close.Click += (_, _) => TabCloseRequested?.Invoke(this, index);
        menu.Items.Add(close);

        var others = new MenuItem { Header = "Close Other Tabs", IsEnabled = tabCount > 1 };
        others.Click += (_, _) => TabCloseOthersRequested?.Invoke(this, index);
        menu.Items.Add(others);
        menu.Items.Add(new Separator());

        var copy = new MenuItem { Header = "Copy Full Path" };
        copy.Click += (_, _) => { try { Clipboard.SetText(path); } catch { /* clipboard busy */ } };
        menu.Items.Add(copy);

        var reveal = new MenuItem { Header = "Show in Explorer", IsEnabled = onDisk };
        reveal.Click += (_, _) => TabRevealRequested?.Invoke(this, index);
        menu.Items.Add(reveal);
        return menu;
    }

    public void SetTabs(IReadOnlyList<string> paths, int activeIndex, IReadOnlyList<bool>? dirtyFlags)
    {
        _lastPaths = paths; _lastActive = activeIndex; _lastDirty = dirtyFlags;
        if (!_themeHooked)
        {
            _themeHooked = true;
            ThemeManager.ThemeChanged += (_, _) => SetTabs(_lastPaths, _lastActive, _lastDirty);
        }
        Strip.Children.Clear();

        if (paths is null || paths.Count == 0)
        {
            var empty = new TextBlock
            {
                Text = "No file",
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 8, 0),
                Foreground = XMColor.Brush(XMColor.Text3),
            };
            XMFont.UiSmall.ApplyTo(empty);
            Strip.Children.Add(empty);
        }
        else
        {
            for (int i = 0; i < paths.Count; i++)
            {
                int index = i; // capture
                var chip = new TabChip(paths[i], i == activeIndex)
                {
                    Margin = new Thickness(0, 0, 4, 0), // stack spacing 4
                    Dirty = dirtyFlags is not null && i < dirtyFlags.Count && dirtyFlags[i],
                };
                chip.SelectRequested += (_, _) => TabSelected?.Invoke(this, index);
                chip.CloseRequested += (_, _) => TabCloseRequested?.Invoke(this, index);
                chip.ContextMenu = BuildTabMenu(index, paths[i], paths.Count);
                Strip.Children.Add(chip);
            }
        }

        Strip.Children.Add(_plusButton);
    }

    /// <summary>Legacy single-file API (Swift <c>setFile(_:)</c>).</summary>
    public void SetFile(string? path)
    {
        if (path is null) SetTabs(Array.Empty<string>(), -1, null);
        else SetTabs(new[] { path }, 0, null);
    }

    // ── Wheel → horizontal scroll ────────────────────────────────────────────────────────────

    private void Scroller_PreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        Scroller.ScrollToHorizontalOffset(Scroller.HorizontalOffset - e.Delta);
        e.Handled = true;
    }

    // ── Metrics / theme ──────────────────────────────────────────────────────────────────────

    private void ApplyMetrics() => Root.Height = XMMetric.S(XMMetric.TabStripH);

    private void OnLoaded(object sender, RoutedEventArgs e)
        => MetricsScaleService.Instance.RebuildFonts += OnRebuildFonts;

    private void OnUnloaded(object sender, RoutedEventArgs e)
        => MetricsScaleService.Instance.RebuildFonts -= OnRebuildFonts;

    private void OnRebuildFonts(object? sender, EventArgs e) => ApplyMetrics();

    // ── ＋ button ─────────────────────────────────────────────────────────────────────────────

    private Button BuildPlusButton()
    {
        var btn = new Button
        {
            Content = "＋", // fullwidth plus ＋
            Width = 22,
            Height = 22,
            Focusable = false,
            Cursor = Cursors.Hand,
            VerticalAlignment = VerticalAlignment.Center,
            ToolTip = "Open another file in a new tab",
            Foreground = XMColor.Brush(XMColor.Text2),
        };
        XMFont.UiSemibold(15).ApplyTo(btn);
        btn.Template = BuildPlusTemplate();
        btn.Click += (_, _) => PlusClicked?.Invoke(this, EventArgs.Empty);
        return btn;
    }

    private static ControlTemplate BuildPlusTemplate()
    {
        var t = new ControlTemplate(typeof(Button));
        var border = new FrameworkElementFactory(typeof(Border));
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(11));
        border.SetResourceReference(Border.BackgroundProperty, XMColor.GlassTop);
        border.SetResourceReference(Border.BorderBrushProperty, XMColor.HairlineS);
        border.SetValue(Border.BorderThicknessProperty, new Thickness(XMMetric.Hairline)); // 0.5
        border.SetValue(Border.SnapsToDevicePixelsProperty, true);

        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(presenter);

        t.VisualTree = border;

        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(UIElement.OpacityProperty, 0.85));
        t.Triggers.Add(hover);
        return t;
    }
}
