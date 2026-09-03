using System.Windows;
using System.Windows.Media;

namespace XMLMacker.Theme;

/// <summary>
/// The <c>XM.*</c> DynamicResource key names (1:1 with the <see cref="Theme"/> color fields and
/// the Swift <c>XMColor</c> tokens) plus code-behind lookup helpers. XAML should bind via
/// <c>{DynamicResource XM.bg}</c>; code-behind that must resolve a brush/color imperatively uses
/// <see cref="Brush(string)"/> / <see cref="Color(string)"/>.
/// </summary>
public static class XMColor
{
    // Surfaces
    public const string Bg = "XM.bg";
    public const string BgDeep = "XM.bgDeep";
    public const string Panel = "XM.panel";
    public const string Hairline = "XM.hairline";
    public const string HairlineS = "XM.hairlineS";
    public const string GlassTop = "XM.glassTop";

    // Text
    public const string Text = "XM.text";
    public const string Text2 = "XM.text2";
    public const string Text3 = "XM.text3";

    // Syntax
    public const string SyntaxTag = "XM.syntaxTag";
    public const string SyntaxAttr = "XM.syntaxAttr";
    public const string SyntaxVal = "XM.syntaxVal";
    public const string SyntaxText = "XM.syntaxText";
    public const string SyntaxPunct = "XM.syntaxPunct";
    public const string SyntaxCom = "XM.syntaxCom";

    // Accents / semantic
    public const string Accent = "XM.accent";
    public const string Accent2 = "XM.accent2";
    public const string Ok = "XM.ok";
    public const string Warn = "XM.warn";
    public const string Err = "XM.err";

    // Editor
    public const string LineHighlight = "XM.lineHighlight";

    /// <summary>Every <c>XM.*</c> key, in Theme-field order. Every theme dictionary defines all of these.</summary>
    public static readonly IReadOnlyList<string> AllKeys = new[]
    {
        Bg, BgDeep, Panel, Hairline, HairlineS, GlassTop,
        Text, Text2, Text3,
        SyntaxTag, SyntaxAttr, SyntaxVal, SyntaxText, SyntaxPunct, SyntaxCom,
        Accent, Accent2, Ok, Warn, Err,
        LineHighlight,
    };

    /// <summary>
    /// Resolve a live <see cref="System.Windows.Media.Brush"/> for an <c>XM.*</c> key from the
    /// application resources. Returns <see cref="Brushes.Magenta"/> if the key is missing (a loud
    /// sentinel that surfaces theming mistakes rather than silently rendering transparent).
    /// </summary>
    public static Brush Brush(string key)
    {
        object? res = System.Windows.Application.Current?.TryFindResource(key);
        return res as Brush ?? Brushes.Magenta;
    }

    /// <summary>Resolve the underlying <see cref="System.Windows.Media.Color"/> for an <c>XM.*</c> key.</summary>
    public static Color Color(string key)
        => Brush(key) is SolidColorBrush scb ? scb.Color : Colors.Magenta;
}
