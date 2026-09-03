using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using XMLMacker.Theme;

namespace XMLMacker.Chrome;

/// <summary>
/// One document tab in the <see cref="TabStripControl"/>. 1:1 port of the Swift <c>TabChip</c>:
/// a radius-10 pill, the filename in Cascadia Mono <b>middle-truncated</b>, a hover-visible ×
/// close button, a dirty-dot indicator, min width 120, height 24, a hand cursor, and a full-path
/// tooltip. Active tabs get the glassTop fill + hairline border.
/// </summary>
public sealed class TabChip : Border
{
    private readonly TextBlock _name;
    private readonly Button _close;
    private readonly Ellipse _dirtyDot;
    private bool _active;
    private bool _dirty;
    private bool _hover;

    /// <summary>Raised when the pill body is clicked (select this tab).</summary>
    public event EventHandler? SelectRequested;

    /// <summary>Raised when the × close button is clicked.</summary>
    public event EventHandler? CloseRequested;

    /// <summary>The full path this chip represents (also its tooltip).</summary>
    public string Path { get; }

    public TabChip(string path, bool active)
    {
        Path = path ?? string.Empty;
        _active = active;

        Height = 24;
        MinWidth = 120;
        CornerRadius = new CornerRadius(XMMetric.RadiusPill); // 10
        Cursor = Cursors.Hand;
        SnapsToDevicePixels = true;
        UseLayoutRounding = true;
        ToolTip = Path;
        Background = Brushes.Transparent;

        var grid = new DockPanel { LastChildFill = true };

        // Trailing cluster: dirty dot + close button occupy the same slot on the right.
        var right = new Grid { Margin = new Thickness(8, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };

        _dirtyDot = new Ellipse
        {
            Width = 6,
            Height = 6,
            Fill = XMColor.Brush(XMColor.Accent),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };

        _close = new Button
        {
            Content = "×",
            Focusable = false,
            Cursor = Cursors.Hand,
            Visibility = Visibility.Collapsed,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        XMFont.UiBodyB.ApplyTo(_close); // UI 12 semibold
        _close.Foreground = XMColor.Brush(XMColor.Text3);
        _close.Template = BuildTransparentButtonTemplate();
        _close.Click += (_, e) => { e.Handled = true; CloseRequested?.Invoke(this, EventArgs.Empty); };

        right.Children.Add(_dirtyDot);
        right.Children.Add(_close);
        DockPanel.SetDock(right, Dock.Right);

        _name = new TextBlock
        {
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(10, 0, 0, 0),
            TextWrapping = TextWrapping.NoWrap,
        };

        grid.Children.Add(right);
        grid.Children.Add(_name);
        Child = grid;

        ApplyActiveStyle();

        MouseEnter += (_, _) => { _hover = true; UpdateTrailing(); };
        MouseLeave += (_, _) => { _hover = false; UpdateTrailing(); };
        MouseLeftButtonUp += OnBodyClick;
        SizeChanged += (_, _) => UpdateTruncation();

        UpdateTrailing();
    }

    /// <summary>Whether this is the active (selected) tab.</summary>
    public bool Active
    {
        get => _active;
        set { _active = value; ApplyActiveStyle(); UpdateTruncation(); }
    }

    /// <summary>Whether the document has unsaved edits (shows the dirty dot when not hovered).</summary>
    public bool Dirty
    {
        get => _dirty;
        set { _dirty = value; UpdateTrailing(); }
    }

    private void OnBodyClick(object sender, MouseButtonEventArgs e)
    {
        // The × handles its own click (and marks it handled); this fires for the rest of the pill.
        if (e.Handled) return;
        SelectRequested?.Invoke(this, EventArgs.Empty);
    }

    private void ApplyActiveStyle()
    {
        if (_active)
        {
            Background = XMColor.Brush(XMColor.GlassTop);
            BorderBrush = XMColor.Brush(XMColor.Hairline);
            BorderThickness = new Thickness(XMMetric.Hairline); // 0.5
        }
        else
        {
            Background = Brushes.Transparent;
            BorderBrush = Brushes.Transparent;
            BorderThickness = new Thickness(0);
        }

        // Name: mono 11, medium when active; XM.text / XM.text2.
        (_active ? XMFont.Mono(11) with { Weight = FontWeights.Medium } : XMFont.Mono(11)).ApplyTo(_name);
        _name.Foreground = XMColor.Brush(_active ? XMColor.Text : XMColor.Text2);
    }

    private void UpdateTrailing()
    {
        // Hover → show ×; otherwise show the dirty dot only when dirty.
        _close.Visibility = _hover ? Visibility.Visible : Visibility.Collapsed;
        _dirtyDot.Visibility = (!_hover && _dirty) ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>Rebuild the middle-truncated filename to fit the current chip width.</summary>
    private void UpdateTruncation()
    {
        string full = string.IsNullOrEmpty(Path) ? string.Empty : System.IO.Path.GetFileName(Path);
        if (full.Length == 0) full = Path;

        // Available width = chip width − leading margin(10) − trailing cluster(~24) − border, capped at 220.
        double avail = Math.Min(220, ActualWidth - 10 - 24 - BorderThickness.Left * 2);
        if (double.IsNaN(avail) || avail <= 0)
        {
            _name.Text = full;
            return;
        }

        _name.Text = MiddleTruncate(full, avail);
    }

    private string MiddleTruncate(string s, double maxWidth)
    {
        if (Measure(s) <= maxWidth) return s;

        const string ellipsis = "…";
        for (int keep = s.Length - 1; keep > 0; keep--)
        {
            int left = (keep + 1) / 2;
            int right = keep / 2;
            string cand = s.Substring(0, left) + ellipsis + s.Substring(s.Length - right);
            if (Measure(cand) <= maxWidth) return cand;
        }
        return ellipsis;
    }

    private double Measure(string s)
    {
        var tf = new Typeface(_name.FontFamily, _name.FontStyle, _name.FontWeight, _name.FontStretch);
        double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var ft = new FormattedText(
            s, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, tf,
            _name.FontSize, Brushes.Black, dpi);
        return ft.WidthIncludingTrailingWhitespace;
    }

    private static ControlTemplate BuildTransparentButtonTemplate()
    {
        var t = new ControlTemplate(typeof(Button));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        var root = new FrameworkElementFactory(typeof(Border));
        root.SetValue(Border.BackgroundProperty, Brushes.Transparent);
        root.AppendChild(presenter);
        t.VisualTree = root;
        return t;
    }
}
