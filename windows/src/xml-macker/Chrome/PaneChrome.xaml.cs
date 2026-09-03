using System.Windows;
using System.Windows.Controls;
using XMLMacker.Theme;

namespace XMLMacker.Chrome;

/// <summary>
/// A lightweight per-pane title strip hosting the pane's content below it. Docked panes use compact,
/// right-aligned Windows caption controls: pop out, minimize, maximize/restore, and close. The content
/// sits in a hard-clipped container so it can never paint over the strip.
/// </summary>
public partial class PaneChrome : UserControl
{
    // Segoe Fluent/MDL2 caption glyphs used by Windows itself.
    private const string GlyphMinimize = "\uE921";
    private const string GlyphRestore = "\uE923";
    private const string GlyphMaximize = "\uE922";
    private const string GlyphPopOut = "\uE8A7";
    private const string GlyphPopIn = "\uE73F";

    private string _title = string.Empty;

    public PaneChrome()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        ApplyMetrics();
        ApplyTitleStyle();
    }

    // ── Events (cross-agent contract) ─────────────────────────────────────────────────────

    /// <summary>Raised when the close caption button is clicked. Controller hides the pane.</summary>
    public event EventHandler? Closed;

    /// <summary>Raised when the minimize caption button is clicked. Controller collapses to header-only.</summary>
    public event EventHandler? Minimized;

    /// <summary>Raised when the maximize caption button is clicked. Controller hides every other pane.</summary>
    public event EventHandler? Maximized;

    /// <summary>Raised when the pop-out caption button is clicked. Controller floats the pane in its own window.</summary>
    public event EventHandler? PoppedOut;

    // ── Title ─────────────────────────────────────────────────────────────────────────────

    /// <summary>
    /// The pane title. The getter returns the raw string; the setter stores it raw and renders it
    /// UPPERCASED (Swift <c>applyTitleStyle()</c>).
    /// </summary>
    public string Title
    {
        get => _title;
        set
        {
            _title = value ?? string.Empty;
            ApplyTitleStyle();
        }
    }

    private void ApplyTitleStyle()
    {
        // UI 10pt medium, XM.text2, uppercased. (WPF has no per-glyph kerning; the 0.9 kern is omitted.)
        XMFont.UiCaption.ApplyTo(TitleText);
        TitleText.Text = _title.ToUpperInvariant();
    }

    // ── State properties (with side effects) ───────────────────────────────────────────────

    private bool _isMinimized;
    private bool _isMaximized;
    private bool _isPoppedOut;
    private bool _headerHidden;

    /// <summary>Collapses content to header-only (content hidden, header stays clickable).</summary>
    public bool IsMinimized
    {
        get => _isMinimized;
        set
        {
            _isMinimized = value;
            ContentContainer.Visibility = value ? Visibility.Collapsed : Visibility.Visible;
            MinButton.Content = value ? GlyphRestore : GlyphMinimize;
            MinButton.ToolTip = value ? "Restore pane" : "Minimize pane";
        }
    }

    /// <summary>When maximized in place, the maximize button shows the Windows restore glyph.</summary>
    public bool IsMaximized
    {
        get => _isMaximized;
        set
        {
            _isMaximized = value;
            MaxButton.Content = value ? GlyphRestore : GlyphMaximize;
            MaxButton.ToolTip = value ? "Restore pane" : "Maximize pane";
        }
    }

    /// <summary>When popped out, the pop-out button becomes the Windows back-to-window glyph.</summary>
    public bool IsPoppedOut
    {
        get => _isPoppedOut;
        set
        {
            _isPoppedOut = value;
            PopOutButton.Content = value ? GlyphPopIn : GlyphPopOut;
            PopOutButton.ToolTip = value ? "Dock pane back into the main window" : "Open pane in a separate window";
        }
    }

    /// <summary>
    /// Hides the header entirely (used while the pane floats in its own window, the real window
    /// title bar takes over; two stacked title bars looked like a glitch).
    /// </summary>
    public bool HeaderHidden
    {
        get => _headerHidden;
        set
        {
            _headerHidden = value;
            Header.Visibility = value ? Visibility.Collapsed : Visibility.Visible;
        }
    }

    // ── Content ─────────────────────────────────────────────────────────────────────────────

    /// <summary>The hosted pane content (full-bleed, hard-clipped below the header strip).</summary>
    public object? PaneContent
    {
        get => PART_Content.Content;
        set => PART_Content.Content = value;
    }

    /// <summary>Swift <c>setContent(_:)</c>: plant a view in the content container (full-bleed).</summary>
    public void SetContent(UIElement view) => PART_Content.Content = view;

    public void SetHeaderAccessory(UIElement? view)
    {
        HeaderAccessory.Content = view;
        HeaderAccessory.Visibility = view is null ? Visibility.Collapsed : Visibility.Visible;
        TitleText.Visibility = view is null ? Visibility.Visible : Visibility.Collapsed;
    }

    public void SetHeaderControlsHidden(bool hidden)
    {
        PaneControls.Visibility = hidden ? Visibility.Collapsed : Visibility.Visible;
    }

    // ── Metrics / theme hooks ────────────────────────────────────────────────────────────────

    private void ApplyMetrics() => Header.Height = XMMetric.S(XMMetric.PaneHeaderH);

    /// <summary>Swift <c>rebuildFonts()</c>: re-apply title style + rescale the header height with zoom.</summary>
    public void RebuildFonts()
    {
        ApplyTitleStyle();
        ApplyMetrics();
    }

    /// <summary>Swift <c>rebuildColors()</c>: colors flow via DynamicResource; only the title re-applies.</summary>
    public void RebuildColors() => ApplyTitleStyle();

    private void OnLoaded(object sender, RoutedEventArgs e)
        => MetricsScaleService.Instance.RebuildFonts += OnRebuildFonts;

    private void OnUnloaded(object sender, RoutedEventArgs e)
        => MetricsScaleService.Instance.RebuildFonts -= OnRebuildFonts;

    private void OnRebuildFonts(object? sender, EventArgs e) => RebuildFonts();

    // ── Click handlers ───────────────────────────────────────────────────────────────────────

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Closed?.Invoke(this, EventArgs.Empty);
    private void MinButton_Click(object sender, RoutedEventArgs e) => Minimized?.Invoke(this, EventArgs.Empty);
    private void MaxButton_Click(object sender, RoutedEventArgs e) => Maximized?.Invoke(this, EventArgs.Empty);
    private void PopOut_Click(object sender, RoutedEventArgs e) => PoppedOut?.Invoke(this, EventArgs.Empty);
}
