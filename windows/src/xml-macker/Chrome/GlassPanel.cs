using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using XMLMacker.Theme;

namespace XMLMacker.Chrome;

/// <summary>
/// Semantic tint kinds for a <see cref="GlassPanel"/>: a subtle color cast layered over the
/// neutral panel fill.
/// </summary>
public enum GlassTint
{
    /// <summary>No wash, the plain translucent panel fill.</summary>
    Neutral,
    /// <summary>Aqua-blue (accent), default informational surface.</summary>
    Cool,
    /// <summary>Violet (accent2), element-focus surfaces.</summary>
    Violet,
    /// <summary>Amber (warn), "modified" surfaces.</summary>
    Amber,
    /// <summary>Red (err), error surfaces.</summary>
    Danger,
}

/// <summary>
/// The "liquid glass" container. 1:1 port of <c>GlassPanel.swift</c>: a rounded card with a
/// translucent panel fill, an optional semantic color wash, a top-gloss inset highlight
/// (white α0.14 → 0 over the top 18%), a hard-clipped content region, and a 0.5px hairline border
/// snapped to device pixels.
/// WPF cannot blur behind a child element, so this is a <b>static</b>
/// composition (the window-level acrylic/Mica backdrop comes from <see cref="Shared.Acrylic"/>).
/// The visual tree lives in <c>GlassPanel.xaml</c>'s default style, assigned in the constructor.
/// </summary>
public class GlassPanel : ContentControl
{
    public GlassPanel()
    {
        var dict = new ResourceDictionary
        {
            Source = new Uri("/xml-macker;component/Chrome/GlassPanel.xaml", UriKind.Relative),
        };
        Style = (Style)dict["XM.GlassPanel"];

        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        UpdateTint();
    }

    // ── Corner radius ───────────────────────────────────────────────────────────────────

    /// <summary>
    /// The panel corner radius. Defaults to <see cref="XMMetric.RadiusCard"/> (14), the Swift
    /// <c>GlassConfig.radius</c> default.
    /// </summary>
    public static readonly DependencyProperty CornerRadiusProperty =
        DependencyProperty.Register(
            nameof(CornerRadius), typeof(CornerRadius), typeof(GlassPanel),
            new FrameworkPropertyMetadata(new CornerRadius(XMMetric.RadiusCard)));

    public CornerRadius CornerRadius
    {
        get => (CornerRadius)GetValue(CornerRadiusProperty);
        set => SetValue(CornerRadiusProperty, value);
    }

    /// <summary>Convenience: get/set a single uniform radius (mirrors <c>GlassConfig.radius</c>).</summary>
    public double Radius
    {
        get => CornerRadius.TopLeft;
        set => CornerRadius = new CornerRadius(value);
    }

    // ── Tint wash ───────────────────────────────────────────────────────────────────────

    /// <summary>The resolved wash brush painted over the panel fill (null when Neutral).</summary>
    public static readonly DependencyProperty TintBrushProperty =
        DependencyProperty.Register(
            nameof(TintBrush), typeof(Brush), typeof(GlassPanel),
            new FrameworkPropertyMetadata(null));

    public Brush? TintBrush
    {
        get => (Brush?)GetValue(TintBrushProperty);
        private set => SetValue(TintBrushProperty, value);
    }

    /// <summary>Which semantic wash to apply. Recomputes <see cref="TintBrush"/> on change.</summary>
    public static readonly DependencyProperty TintKindProperty =
        DependencyProperty.Register(
            nameof(TintKind), typeof(GlassTint), typeof(GlassPanel),
            new FrameworkPropertyMetadata(GlassTint.Neutral, OnTintPropertyChanged));

    public GlassTint TintKind
    {
        get => (GlassTint)GetValue(TintKindProperty);
        set => SetValue(TintKindProperty, value);
    }

    /// <summary>
    /// Wash opacity (Swift <c>GlassConfig.tintAlpha</c>). Default 0.12, a subtle cast. Only used
    /// when <see cref="TintKind"/> is non-Neutral.
    /// </summary>
    public static readonly DependencyProperty TintAlphaProperty =
        DependencyProperty.Register(
            nameof(TintAlpha), typeof(double), typeof(GlassPanel),
            new FrameworkPropertyMetadata(0.12, OnTintPropertyChanged));

    public double TintAlpha
    {
        get => (double)GetValue(TintAlphaProperty);
        set => SetValue(TintAlphaProperty, value);
    }

    private static void OnTintPropertyChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        => ((GlassPanel)d).UpdateTint();

    private void UpdateTint()
    {
        if (TintKind == GlassTint.Neutral)
        {
            TintBrush = null;
            return;
        }

        string key = TintKind switch
        {
            GlassTint.Cool => XMColor.Accent,
            GlassTint.Violet => XMColor.Accent2,
            GlassTint.Amber => XMColor.Warn,
            GlassTint.Danger => XMColor.Err,
            _ => XMColor.Accent,
        };

        Color c = XMColor.Color(key);
        byte a = (byte)Math.Clamp(TintAlpha * 255.0, 0, 255);
        var brush = new SolidColorBrush(Color.FromArgb(a, c.R, c.G, c.B));
        brush.Freeze();
        TintBrush = brush;
    }

    // ── Theme hook ──────────────────────────────────────────────────────────────────────

    private void OnLoaded(object sender, RoutedEventArgs e)
        => ThemeManager.ThemeChanged += OnThemeChanged;

    private void OnUnloaded(object sender, RoutedEventArgs e)
        => ThemeManager.ThemeChanged -= OnThemeChanged;

    private void OnThemeChanged(object? sender, EventArgs e) => UpdateTint();

    /// <summary>
    /// Theme hook (Swift <c>rebuildColors()</c>). The panel fill / hairline update automatically via
    /// DynamicResource; only the derived wash brush (which bakes in a theme color at a custom alpha)
    /// needs to be rebuilt.
    /// </summary>
    public void RebuildColors() => UpdateTint();
}
