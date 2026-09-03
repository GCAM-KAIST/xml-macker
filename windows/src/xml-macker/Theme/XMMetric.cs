namespace XMLMacker.Theme;

/// <summary>
/// Fixed layout constants + the zoom-aware <see cref="S(double)"/> scaler. 1:1 port of the Swift
/// <c>XMMetric</c> tokens (DesignTokens.swift) plus the split-view floors/widths named across the
/// specs. Corner radii and the hairline stroke are deliberately NOT scaled; layout dimensions are
/// typically wrapped in <see cref="S(double)"/> so a single zoom knob compresses the whole UI.
/// </summary>
public static class XMMetric
{
    // Corners (fixed, not scaled)
    public const double RadiusWindow = 18;
    public const double RadiusCard = 14;
    public const double RadiusPill = 10;
    public const double RadiusGlass = 12;

    // Strokes
    public const double Hairline = 0.5;

    // Layout (fixed base values; callers typically wrap in S())
    public const double TreeRowH = 22;
    public const double TreeIndent = 14;
    public const double SourceLineH = 18;
    public const double LineGutterW = 42;
    public const double MinimapW = 68;
    public const double TabStripH = 32;
    public const double BreadcrumbH = 32;
    public const double PaneGap = 8;

    // Chrome extents named across the specs
    public const double PaneHeaderH = 22;
    public const double MinimizedExtent = 26;
    public const double StatusBarH = 26;

    // Inspector cards
    public const double InspectorPadding = 10;
    public const double InspectorGap = 10;

    // Split-view default / minimum widths (tuned for a 1280-wide 14" display)
    public const double TreePaneDefault = 260;
    public const double InspectorPaneDefault = 320;
    public const double TreePaneMin = 140;
    public const double InspectorPaneMin = 220;

    // Split-view collapse floors (effectiveMin per pane kind)
    public const double InspectorFloor = 210;
    public const double ChartFloor = 110;
    public const double PreviewFloor = 120;
    public const double DefaultFloor = 90;

    /// <summary>
    /// <c>round(max(4, base * globalScale) * 2) / 2</c>, scale a base metric by the same global
    /// zoom multiplier as the fonts, floor at 4 pt, snap to nearest 0.5 pt. So a 73% slider shrinks
    /// BOTH type and layout.
    /// </summary>
    public static double S(double b)
        => Math.Round(Math.Max(4, b * XMFont.GlobalScale) * 2) / 2;
}
