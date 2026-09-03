using System.Globalization;
using System.Windows.Media;

namespace XMLMacker.Theme;

/// <summary>
/// Immutable palette value type. 1:1 port of the Swift <c>struct Theme</c>.
/// Holds identity (<see cref="Id"/>,
/// <see cref="DisplayName"/>, <see cref="IsDark"/>) plus the 21 color tokens that every
/// <c>XM.*</c> brush is derived from. Equality is by <see cref="Id"/> only, matching the
/// Swift <c>Equatable</c> contract.
/// </summary>
public sealed record Theme
{
    // Identity
    public required string Id { get; init; }
    public required string DisplayName { get; init; }
    public required bool IsDark { get; init; }

    // Surfaces
    public required Color Bg { get; init; }
    public required Color BgDeep { get; init; }
    public required Color Panel { get; init; }
    public required Color Hairline { get; init; }
    public required Color HairlineS { get; init; }
    public required Color GlassTop { get; init; }

    // Text
    public required Color Text { get; init; }
    public required Color Text2 { get; init; }
    public required Color Text3 { get; init; }

    // Syntax
    public required Color SyntaxTag { get; init; }
    public required Color SyntaxAttr { get; init; }
    public required Color SyntaxVal { get; init; }
    public required Color SyntaxText { get; init; }
    public required Color SyntaxPunct { get; init; }
    public required Color SyntaxCom { get; init; }

    // Accents / semantic
    public required Color Accent { get; init; }
    public required Color Accent2 { get; init; }
    public required Color Ok { get; init; }
    public required Color Warn { get; init; }
    public required Color Err { get; init; }

    // Editor
    public required Color LineHighlight { get; init; }

    /// <summary>Equality compares <see cref="Id"/> only (Swift parity).</summary>
    public bool Equals(Theme? other) => other is not null && Id == other.Id;
    public override int GetHashCode() => Id.GetHashCode();

    /// <summary>Parse a <c>#AARRGGBB</c> (or <c>#RRGGBB</c>, alpha 0xFF) sRGB hex literal.</summary>
    private static Color H(string hex)
    {
        string s = hex.StartsWith('#') ? hex[1..] : hex;
        if (s.Length == 6) s = "FF" + s;
        uint v = uint.Parse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        return Color.FromArgb((byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v);
    }

    // ── The six built-in themes (exact values from the macOS themes) ───────────────

    public static readonly Theme AuroraDark = new()
    {
        Id = "aurora-dark", DisplayName = "Aurora Dark", IsDark = true,
        Bg = H("#FF0C1016"), BgDeep = H("#FF070A10"), Panel = H("#94141A24"),
        Hairline = H("#12FFFFFF"), HairlineS = H("#24FFFFFF"), GlassTop = H("#14FFFFFF"),
        Text = H("#F0F0F4FC"), Text2 = H("#99F0F4FC"), Text3 = H("#5CF0F4FC"),
        SyntaxTag = H("#FFC4A4FF"), SyntaxAttr = H("#FF7ED6FF"), SyntaxVal = H("#FFFFC78A"),
        SyntaxText = H("#FFA8E6B6"), SyntaxPunct = H("#99FFFFFF"), SyntaxCom = H("#4DFFFFFF"),
        Accent = H("#FF64B5FF"), Accent2 = H("#FFC4A4FF"),
        Ok = H("#FF3DDC97"), Warn = H("#FFF5C469"), Err = H("#FFFF6B7A"),
        LineHighlight = H("#99264F78"),
    };

    public static readonly Theme Light = new()
    {
        Id = "light", DisplayName = "Light", IsDark = false,
        Bg = H("#FFF7F7F9"), BgDeep = H("#FFFFFFFF"), Panel = H("#D1FAFAFC"),
        Hairline = H("#1A000000"), HairlineS = H("#33000000"), GlassTop = H("#B3FFFFFF"),
        Text = H("#FF1A1A1A"), Text2 = H("#FF4D4D4D"), Text3 = H("#FF808080"),
        SyntaxTag = H("#FF6F2DBD"), SyntaxAttr = H("#FF0969DA"), SyntaxVal = H("#FFA83E1C"),
        SyntaxText = H("#FF1A7F37"), SyntaxPunct = H("#8C000000"), SyntaxCom = H("#59000000"),
        Accent = H("#FF0969DA"), Accent2 = H("#FF6F2DBD"),
        Ok = H("#FF1A7F37"), Warn = H("#FFB08800"), Err = H("#FFCF222E"),
        LineHighlight = H("#8CB3D7FF"),
    };

    public static readonly Theme OneDark = new()
    {
        Id = "one-dark", DisplayName = "One Dark", IsDark = true,
        Bg = H("#FF282C34"), BgDeep = H("#FF21252B"), Panel = H("#942D323C"),
        Hairline = H("#12FFFFFF"), HairlineS = H("#29FFFFFF"), GlassTop = H("#0FFFFFFF"),
        Text = H("#FFABB2BF"), Text2 = H("#FF828997"), Text3 = H("#FF5C6370"),
        SyntaxTag = H("#FFE06C75"), SyntaxAttr = H("#FFD19A66"), SyntaxVal = H("#FF98C379"),
        SyntaxText = H("#FF61AFEF"), SyntaxPunct = H("#FFABB2BF"), SyntaxCom = H("#FF5C6370"),
        Accent = H("#FF61AFEF"), Accent2 = H("#FFC678DD"),
        Ok = H("#FF98C379"), Warn = H("#FFE5C07B"), Err = H("#FFE06C75"),
        LineHighlight = H("#E63E4451"),
    };

    public static readonly Theme SolarizedDark = new()
    {
        Id = "solarized-dark", DisplayName = "Solarized Dark", IsDark = true,
        Bg = H("#FF002B36"), BgDeep = H("#FF001F27"), Panel = H("#94053642"),
        Hairline = H("#0FFFFFFF"), HairlineS = H("#26FFFFFF"), GlassTop = H("#0DFFFFFF"),
        Text = H("#FF93A1A1"), Text2 = H("#FF839496"), Text3 = H("#FF657B83"),
        SyntaxTag = H("#FF268BD2"), SyntaxAttr = H("#FF2AA198"), SyntaxVal = H("#FFB58900"),
        SyntaxText = H("#FF859900"), SyntaxPunct = H("#FF93A1A1"), SyntaxCom = H("#FF586E75"),
        Accent = H("#FF268BD2"), Accent2 = H("#FFD33682"),
        Ok = H("#FF859900"), Warn = H("#FFCB4B16"), Err = H("#FFDC322F"),
        LineHighlight = H("#D90A4A5A"),
    };

    public static readonly Theme Dracula = new()
    {
        Id = "dracula", DisplayName = "Dracula", IsDark = true,
        Bg = H("#FF282A36"), BgDeep = H("#FF21222C"), Panel = H("#94282A36"),
        Hairline = H("#12FFFFFF"), HairlineS = H("#29FFFFFF"), GlassTop = H("#0FFFFFFF"),
        Text = H("#FFF8F8F2"), Text2 = H("#9EF8F8F2"), Text3 = H("#FF6272A4"),
        SyntaxTag = H("#FFFF79C6"), SyntaxAttr = H("#FF50FA7B"), SyntaxVal = H("#FFF1FA8C"),
        SyntaxText = H("#FFBD93F9"), SyntaxPunct = H("#99F8F8F2"), SyntaxCom = H("#FF6272A4"),
        Accent = H("#FFBD93F9"), Accent2 = H("#FFFF79C6"),
        Ok = H("#FF50FA7B"), Warn = H("#FFFFB86C"), Err = H("#FFFF5555"),
        LineHighlight = H("#E644475A"),
    };

    public static readonly Theme Hacker = new()
    {
        Id = "hacker-green", DisplayName = "Hacker", IsDark = true,
        Bg = H("#FF020A05"), BgDeep = H("#FF000000"), Panel = H("#99001408"),
        Hairline = H("#1A00FF41"), HairlineS = H("#4000FF41"), GlassTop = H("#0D00FF41"),
        Text = H("#FFB4FFC6"), Text2 = H("#FF6BD98A"), Text3 = H("#FF3E8A54"),
        SyntaxTag = H("#FF00FF41"), SyntaxAttr = H("#FF7EE787"), SyntaxVal = H("#FFD8FFB0"),
        SyntaxText = H("#FFEFFFF2"), SyntaxPunct = H("#FF2EA043"), SyntaxCom = H("#FF1F6F35"),
        Accent = H("#FF00FF41"), Accent2 = H("#FF39FF14"),
        Ok = H("#FF00FF41"), Warn = H("#FFFFD75E"), Err = H("#FFFF4D4D"),
        LineHighlight = H("#2900FF41"),
    };

    /// <summary>Ordered list used by the Theme menu and any cycling. Matches Swift <c>Theme.all</c>.</summary>
    public static readonly IReadOnlyList<Theme> All = new[]
    {
        AuroraDark, Light, OneDark, SolarizedDark, Dracula, Hacker,
    };

    /// <summary>First theme whose <see cref="Id"/> matches, else <c>null</c> (Swift <c>Theme.byId</c>).</summary>
    public static Theme? ById(string id)
    {
        foreach (Theme t in All)
            if (t.Id == id) return t;
        return null;
    }
}
