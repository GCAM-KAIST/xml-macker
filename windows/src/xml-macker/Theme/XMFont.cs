using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace XMLMacker.Theme;

/// <summary>
/// A fully-resolved font request: family, zoom-scaled size (pt≈DIU), and weight.
/// Apply it to a control or text element with <see cref="ApplyTo(Control)"/> /
/// <see cref="ApplyTo(TextBlock)"/>.
/// </summary>
public readonly record struct XMFontSpec(FontFamily Family, double Size, FontWeight Weight)
{
    public void ApplyTo(Control control)
    {
        control.FontFamily = Family;
        control.FontSize = Size;
        control.FontWeight = Weight;
    }

    public void ApplyTo(TextBlock text)
    {
        text.FontFamily = Family;
        text.FontSize = Size;
        text.FontWeight = Weight;
    }
}

/// <summary>
/// Font factory. 1:1 port of the Swift <c>XMFont</c> tokens. UI font = <b>Segoe UI</b>
/// (SF Pro Text), code font = <b>Cascadia Mono</b> with a <b>Consolas</b> fallback (SF Mono),
/// display = <b>Segoe UI</b> (SF Pro Display). All sizes flow through <see cref="Scaled"/>,
/// which multiplies by <see cref="GlobalScale"/>, clamps to 5..40 pt, and snaps to the nearest
/// 0.5 pt so glyphs stay crisp.
/// </summary>
public static class XMFont
{
    public static readonly FontFamily UiFamily = new("Segoe UI");
    public static readonly FontFamily MonoFamily = new("Cascadia Mono, Consolas");
    public static readonly FontFamily DisplayFamily = new("Segoe UI");

    private static double _globalScale = 1.0;

    /// <summary>
    /// Global zoom multiplier driven by the status-bar slider. Clamped 0.5..2.0 on assignment
    /// (the Swift clamp lived in the slider; here it is enforced at the token so callers can't
    /// exceed the range).
    /// </summary>
    public static double GlobalScale
    {
        get => _globalScale;
        set => _globalScale = Math.Clamp(value, 0.5, 2.0);
    }

    /// <summary>
    /// <c>round(clamp(size * globalScale, 5, 40) * 2) / 2</c>, scale, clamp to 5..40 pt,
    /// snap to nearest 0.5 pt.
    /// </summary>
    public static double Scaled(double size)
        => Math.Round(Math.Clamp(size * _globalScale, 5, 40) * 2) / 2;

    // ── Families × weights ─────────────────────────────────────────────────────────────
    public static XMFontSpec Ui(double size) => new(UiFamily, Scaled(size), FontWeights.Medium);
    public static XMFontSpec UiSemibold(double size) => new(UiFamily, Scaled(size), FontWeights.SemiBold);
    public static XMFontSpec UiBold(double size) => new(UiFamily, Scaled(size), FontWeights.Bold);

    public static XMFontSpec Mono(double size) => new(MonoFamily, Scaled(size), FontWeights.Regular);
    public static XMFontSpec MonoBold(double size) => new(MonoFamily, Scaled(size), FontWeights.Bold);

    public static XMFontSpec Display(double size) => new(DisplayFamily, Scaled(size), FontWeights.Bold);

    // ── Named helpers (base sizes BEFORE scaling), mirroring DesignTokens.swift ─────────
    public static XMFontSpec UiSmall => Ui(11);
    public static XMFontSpec UiBody => Ui(12);
    public static XMFontSpec UiBodyB => UiSemibold(12);
    public static XMFontSpec UiHeader => UiSemibold(13);
    public static XMFontSpec UiLarge => UiSemibold(15);
    public static XMFontSpec UiCaption => Ui(10);
    public static XMFontSpec MonoCode => Mono(12);
    public static XMFontSpec MonoSmall => Mono(11);
}
