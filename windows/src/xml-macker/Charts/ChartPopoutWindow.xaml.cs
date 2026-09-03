using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using XMLMacker.Shared;
using XMLMacker.Theme;
using XMLMacker.Core;

namespace XMLMacker.Charts;

/// <summary>
/// The standalone chart pop-out window, 1:1 port of the Swift <c>ChartPopoutWindowController</c>
///. A native resizable Windows frame hosting a bigger
/// <see cref="TrendView"/> (fontScale 1.5), a toggleable data table, and the Labels / Table /
/// Save Image… / Copy / Export CSV… pill toolbar. Opened by the inline chart's ↗ button.
/// </summary>
public partial class ChartPopoutWindow : Window
{
    private const double TableHeight = 240;
    private const double TableGrowthDelta = TableHeight + 10; // 250
    private const double MinimumBarSlot = 46;
    private const double ChartHorizontalPadding = 60;

    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    private TrendSeries? _currentSeries;
    private bool _tableVisible;
    private bool _builderVisible;
    private bool _rebuildingBuilderControls;
    private ChartPathBuilder? _builder;
    private XmlTreeNode? _builderRoot;
    private XmlTreeNode? _contextNode;
    private TrendSeries? _mirroredSeries;
    private string _mirroredPath = "";

    /// <summary>Row shape for the data table (Value shown with <c>%g</c> / G6 formatting).</summary>
    public sealed record Row(string Label, string ValueText);

    /// <summary>Fired when the window closes so the host can drop its reference.</summary>
    public event Action? PopoutClosed;
    public event Action<XmlTreeNode>? RevealNodeRequested;

    public ChartPopoutWindow()
    {
        InitializeComponent();
        // Ctrl + wheel / Ctrl +/- change THIS chart's text size only; Ctrl 0 puts it back.
        ZoomGestures.Attach(this, () => ZoomChart(ZoomGestures.Step), () => ZoomChart(1 / ZoomGestures.Step), () => ZoomChart(0));

        Chart.FontScale = PopoutFontScale;

        ApplyTheme();
        ApplyFonts();

        // Always-on-top per the persisted popouts-float preference (default FALSE when unset, so a
        // chart window behaves like every other Windows window until it is switched on from the menu).
        Topmost = AppSettings.Instance.GetBool("xml-macker.popoutsFloat", false);

        ThemeManager.ThemeChanged += OnThemeChanged;
        MetricsScaleService.Instance.RebuildFonts += OnRebuildFonts;

        // ScrollChanged fires from the same deferred pass that publishes ViewportWidth, so it covers the
        // cases SizeChanged misses, notably the horizontal scrollbar appearing or disappearing.
        ChartScroll.ScrollChanged += (_, e) =>
        {
            if (e.ViewportWidthChange != 0 || e.ViewportHeightChange != 0) UpdateChartWidth();
        };
        ChartScroll.SizeChanged += (_, _) => UpdateChartWidth();

        // Maximize / restore: re-check at Loaded priority, i.e. after layout has settled.
        StateChanged += (_, _) => Dispatcher.BeginInvoke(
            System.Windows.Threading.DispatcherPriority.Loaded, new Action(UpdateChartWidth));

        Loaded += (_, _) =>
        {
            bool restored = WindowPlacement.Restore(this, WindowPlacement.PopoutKey("Chart"));

            // Open large. A chart is a reading surface: 840x480 in the middle of a big screen had to be
            // resized by hand every time. Take most of the WORK AREA (the screen minus the
            // taskbar) unless a previous session saved a deliberate size for this window.
            if (!restored)
            {
                var work = SystemParameters.WorkArea;
                Width = Math.Max(MinWidth, work.Width * 0.86);
                Height = Math.Max(MinHeight, work.Height * 0.86);
                Left = work.Left + (work.Width - Width) / 2;
                Top = work.Top + (work.Height - Height) / 2;
            }

            UpdateChartWidth();
        };
    }

    /// <summary>
    /// Sets the series and breadcrumb path. Updates the chart, table, toolbar labels and the (hidden)
    /// window title that still feeds the taskbar entry.
    /// </summary>
    public void SetSeries(TrendSeries series, string path = "")
    {
        _currentSeries = series;
        Chart.Series = series;
        UpdateChartWidth();

        var rows = new List<Row>(series.Values.Count);
        for (int i = 0; i < series.Values.Count; i++)
            rows.Add(new Row(series.XLabels[i], NumberFmt.G6(series.Values[i])));
        DataTable.ItemsSource = rows;

        TitleLabel.Text = series.Title;
        PathLabel.Text = path;
        PathLabel.ToolTip = string.IsNullOrEmpty(path) ? null : path;
        Title = string.IsNullOrEmpty(path) ? series.Title : $"{series.Title}, {path}";
    }

    // ── Toolbar actions ─────────────────────────────────────────────────────────────────

    public void SetMirroredSeries(TrendSeries? series, string path, XmlTreeNode? node,
        XmlTreeNode? documentRoot)
    {
        _mirroredSeries = series;
        _mirroredPath = path;
        _contextNode = node;
        if (!ReferenceEquals(_builderRoot, documentRoot))
        {
            _builderRoot = documentRoot;
            _builder = documentRoot is null ? null : new ChartPathBuilder(documentRoot);
        }

        if (_builderVisible)
        {
            if (FollowTreeBtn.IsChecked == true && node is not null) SeedBuilder(node);
            else RecomputeBuilder();
        }
        else if (series is not null)
        {
            SetSeries(series, path);
        }
        else
        {
            ClearSeries("No comparable numeric values under this element");
        }
    }

    public void ShowBuilder(XmlTreeNode? seed, XmlTreeNode? documentRoot)
    {
        SetMirroredSeries(_mirroredSeries, _mirroredPath, seed, documentRoot);
        BuildBtn.IsChecked = true;
    }

    private void LabelsBtn_Toggled(object sender, RoutedEventArgs e)
        => Chart.ShowLabels = LabelsBtn.IsChecked == true;

    private void BuildBtn_Toggled(object sender, RoutedEventArgs e)
    {
        _builderVisible = BuildBtn.IsChecked == true;
        BuilderBar.Visibility = _builderVisible ? Visibility.Visible : Visibility.Collapsed;
        BuilderBar.Height = _builderVisible ? 72 : 0;
        BuilderBar.Margin = _builderVisible ? new Thickness(0, 0, 0, 10) : new Thickness(0);
        if (_builderVisible)
        {
            if (_builder is null && _builderRoot is not null)
                _builder = new ChartPathBuilder(_builderRoot);
            if (_contextNode is not null) SeedBuilder(_contextNode);
            else { RebuildBuilderControls(); RecomputeBuilder(); }
        }
        else if (_mirroredSeries is not null)
        {
            SetSeries(_mirroredSeries, _mirroredPath);
        }
        else
        {
            ClearSeries("No comparable numeric values under this element");
        }
    }

    private sealed record LevelChoice(string Text, int OptionIndex, bool IsAxis)
    {
        public override string ToString() => Text;
    }

    private void SeedBuilder(XmlTreeNode node)
    {
        if (_builder is null) { RebuildBuilderControls(); RecomputeBuilder(); return; }
        string? keepValue = _builder.ValueName;
        _builder.Rebuild(node);
        if (keepValue is not null && _builder.ValueNames.Contains(keepValue, StringComparer.Ordinal))
            _builder.ValueName = keepValue;
        RebuildBuilderControls();
        RecomputeBuilder();
    }

    private void RebuildBuilderControls()
    {
        _rebuildingBuilderControls = true;
        PathStack.Children.Clear();
        if (_builder is null)
        {
            PathStack.Children.Add(BuilderCaption("Open a file first"));
            ValuePopup.ItemsSource = null;
            BuilderNote.Text = "";
            _rebuildingBuilderControls = false;
            return;
        }

        for (int i = 0; i < _builder.Levels.Count; i++)
        {
            ChartPathBuilder.Level level = _builder.Levels[i];
            PathStack.Children.Add(BuilderCaption(i == 0 ? level.Tag : $"› {level.Tag}"));
            var choices = new List<LevelChoice>
            {
                new($"across all {level.Members.Count} {level.Tag}s", -1, true)
            };
            for (int j = 0; j < level.Options.Count; j++)
            {
                ChartPathBuilder.Option option = level.Options[j];
                choices.Add(new LevelChoice(level.MixedTags ? option.Label : option.Key, j, false));
            }
            var popup = new ComboBox
            {
                ItemsSource = choices,
                SelectedIndex = level.IsAxis ? 0 : level.Choice + 1,
                MinWidth = 90,
                MaxWidth = 200,
                Margin = new Thickness(5, 0, 7, 0),
                Tag = i
            };
            popup.SelectionChanged += LevelPopup_SelectionChanged;
            PathStack.Children.Add(popup);
        }

        ValuePopup.ItemsSource = _builder.ValueNames;
        ValuePopup.SelectedItem = _builder.ValueName;
        BuilderNote.Text = _builder.ValueScanTruncated
            ? "value scan stopped at the safety limit"
            : (_builder.ValueNames.Count == 0 ? "nothing numeric under this choice" : "");
        _rebuildingBuilderControls = false;
    }

    private TextBlock BuilderCaption(string text)
    {
        var label = new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center };
        label.SetResourceReference(TextBlock.ForegroundProperty, XMColor.Text3);
        XMFont.UiCaption.ApplyTo(label);
        return label;
    }

    private void LevelPopup_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_rebuildingBuilderControls || _builder is null || sender is not ComboBox popup ||
            popup.Tag is not int levelIndex || popup.SelectedItem is not LevelChoice choice) return;
        if (choice.IsAxis) _builder.SetAxis(levelIndex);
        else _builder.SetChoice(levelIndex, choice.OptionIndex);
        RebuildBuilderControls();
        RecomputeBuilder();
    }

    private void ValuePopup_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_rebuildingBuilderControls || _builder is null) return;
        _builder.ValueName = ValuePopup.SelectedItem as string;
        RecomputeBuilder();
    }

    private void RevealBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_builder?.DeepestPinnedNode is { } node) RevealNodeRequested?.Invoke(node);
    }

    private void RecomputeBuilder()
    {
        if (!_builderVisible) return;
        if (_builder is null) { ClearSeries("Open a file first"); return; }
        if (_builder.AxisIndex is null) { ClearSeries("Pick an across-all choice in one path list"); return; }
        if (_builder.ValueName is null) { ClearSeries("Nothing numeric under this choice"); return; }
        if (_builder.Compute() is { } series) SetSeries(series, _builder.LastPathSummary);
        else ClearSeries($"No {_builder.ValueName} values along this path");
    }

    private void ClearSeries(string message)
    {
        _currentSeries = null;
        Chart.Series = null;
        UpdateChartWidth();
        Chart.PlaceholderText = message;
        DataTable.ItemsSource = null;
        TitleLabel.Text = "Chart";
        PathLabel.Text = message;
        Title = "Chart";
    }

    /// <summary>
    /// Gives categorical bars the same minimum horizontal slot as the Mac chart. The chart fills the
    /// viewport for short series and grows inside its horizontal scroller for longer series.
    /// </summary>
    private void UpdateChartWidth()
    {
        // Express the bar-chart requirement as a MINIMUM and let layout supply the rest.
        // The old code read ChartScroll.ViewportWidth and wrote that number into Chart.Width. WPF raises
        // SizeChanged BEFORE the ScrollViewer publishes its new ViewportWidth, so the reading was always
        // one layout pass stale; on maximize the stale value was non-zero, the fresh-ActualWidth fallback
        // never fired, and the half-pixel guard then suppressed the write, which is why the chart kept
        // its old geometry inside a maximized window.
        // With MinWidth instead, MeasureCore clamps the desired size up, so a 32-bar chart still asks for
        // 32 slots and scrolls horizontally exactly as before, while a line chart asks for nothing and is
        // stretched to the viewport. ViewportWidth is never read again, the failure is removed, not patched.
        double min = 0;
        if (_currentSeries is { Kind: TrendKind.Bar } series)
            min = series.Values.Count * MinimumBarSlot + ChartHorizontalPadding;

        if (Math.Abs(Chart.MinWidth - min) > 0.5) Chart.MinWidth = min;
        if (!double.IsNaN(Chart.Width)) Chart.Width = double.NaN;   // clear the width the old code pinned
        Chart.InvalidateVisual();
    }

    private void TableBtn_Toggled(object sender, RoutedEventArgs e)
        => SetTableVisible(TableBtn.IsChecked == true);

    private void SaveBtn_Click(object sender, RoutedEventArgs e) => SaveImage();

    private void CopyBtn_Click(object sender, RoutedEventArgs e) => CopyImage();

    private void CsvBtn_Click(object sender, RoutedEventArgs e) => ExportCsv();

    /// <summary>
    /// Grows the window downward by 250 (rather than shrinking the chart) when the table shows, so
    /// the chart keeps its height and the table is never clipped. WPF grows down,
    /// so Top stays fixed and Height animates.
    /// </summary>
    private void SetTableVisible(bool visible)
    {
        if (_tableVisible == visible) return;
        _tableVisible = visible;

        TableCard.Height = visible ? TableHeight : 0;
        double target = Height + (visible ? 1 : -1) * TableGrowthDelta;

        var anim = new DoubleAnimation(Height, target, TimeSpan.FromMilliseconds(180))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut }
        };
        anim.Completed += (_, _) =>
        {
            BeginAnimation(HeightProperty, null);
            Height = target;
        };
        BeginAnimation(HeightProperty, anim);
    }

    /// <summary>Save the chart as a PNG (default name "chart.png"), then auto-open it.</summary>
    private void SaveImage()
    {
        var dlg = new SaveFileDialog
        {
            FileName = "chart.png",
            Filter = "PNG Image (*.png)|*.png",
            Title = "Save chart as image"
        };
        if (dlg.ShowDialog(this) != true) return;

        var rtb = Chart.RenderToBitmap();
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(rtb));
        using (var fs = File.Create(dlg.FileName))
            enc.Save(fs);

        try { Process.Start(new ProcessStartInfo(dlg.FileName) { UseShellExecute = true }); }
        catch { /* auto-open is best-effort */ }
    }

    /// <summary>Copy the chart to the clipboard as an image (opaque background flag on).</summary>
    private void CopyImage()
    {
        var rtb = Chart.RenderToBitmap();
        Clipboard.SetImage(rtb);
    }

    /// <summary>
    /// Export the chart's data as CSV (default name "chart-data.csv"), then auto-open it. Header
    /// row <c>Label,Value</c>; labels RFC-4180 quoted; values at full Double precision.
    /// </summary>
    private void ExportCsv()
    {
        if (_currentSeries is null) return;
        var dlg = new SaveFileDialog
        {
            FileName = "chart-data.csv",
            Filter = "CSV (*.csv)|*.csv",
            Title = "Export the chart's data as CSV"
        };
        if (dlg.ShowDialog(this) != true) return;

        var rows = new List<IEnumerable<string>> { new[] { "Label", "Value" } };
        for (int i = 0; i < _currentSeries.Values.Count; i++)
            rows.Add(new[] { _currentSeries.XLabels[i], _currentSeries.Values[i].ToString("R", Inv) });

        Csv.Write(rows, dlg.FileName);
        try { Process.Start(new ProcessStartInfo(dlg.FileName) { UseShellExecute = true }); }
        catch { /* auto-open is best-effort */ }
    }

    // ── Window chrome behavior ──────────────────────────────────────────────────────────

    // ── Theme / fonts ───────────────────────────────────────────────────────────────────

    private void OnThemeChanged(object? sender, EventArgs e) => ApplyTheme();
    private void OnRebuildFonts(object? sender, EventArgs e) => ApplyFonts();

    private void ApplyTheme()
    {
        Background = XMColor.Brush(XMColor.BgDeep);
        Acrylic.Apply(this, ThemeManager.Active.IsDark);
        Root.Background = new SolidColorBrush(Acrylic.TintFor(ThemeManager.Active.IsDark));
        var cardBrush = new SolidColorBrush(WithA(XMColor.Color(XMColor.BgDeep), 0.35));
        ChartCard.Background = cardBrush;
        TableCard.Background = cardBrush;
        BuilderBar.Background = cardBrush;
    }

    /// <summary>The pop-out's normal text scale (bigger than the in-pane chart).</summary>
    private const double PopoutFontScale = 1.5;

    /// <summary>Window-local zoom of the chart text and its margins; 0 means back to normal.</summary>
    private void ZoomChart(double factor)
        => Chart.FontScale = factor <= 0 ? PopoutFontScale : Math.Clamp(Chart.FontScale * factor, 0.75, 4.0);

    private void ApplyFonts()
    {
        XMFont.UiHeader.ApplyTo(TitleLabel);
        XMFont.Ui(11).ApplyTo(PathLabel);

        double pillSize = XMFont.Scaled(12);
        foreach (var pill in new FrameworkElement[] { BuildBtn, LabelsBtn, TableBtn, SaveBtn, CopyBtn,
                     CsvBtn, FollowTreeBtn, RevealBtn })
            ((System.Windows.Controls.Control)pill).FontSize = pillSize;
        XMFont.UiCaption.ApplyTo(ValueCaption);
        XMFont.UiCaption.ApplyTo(BuilderNote);
    }

    protected override void OnClosed(EventArgs e)
    {
        WindowPlacement.Save(this, WindowPlacement.PopoutKey("Chart"));
        ThemeManager.ThemeChanged -= OnThemeChanged;
        MetricsScaleService.Instance.RebuildFonts -= OnRebuildFonts;
        PopoutClosed?.Invoke();
        base.OnClosed(e);
    }

    private static Color WithA(Color c, double alpha)
        => Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255), c.R, c.G, c.B);
}
