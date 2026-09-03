using System.Globalization;

namespace XMLMacker.Shared;

/// <summary>
/// Culture-invariant number formatting for the chart / table surfaces. Three schemes, matched
/// precisely to the Swift/C-printf originals:
///
/// <list type="bullet">
/// <item><see cref="Sci"/>, <c>%.2e</c> scientific (e.g. "1.13e-02").</item>
/// <item><see cref="SigFig4"/>, 4 significant figures, trailing zeros stripped (chart labels).</item>
/// <item><see cref="G6"/>, <c>%g</c>: ≤6 significant figures, trailing zeros stripped (table cells).</item>
/// </list>
/// CSV export uses the raw round-trip <c>Double</c> string instead (not provided here).
/// </summary>
public static class NumberFmt
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    /// <summary>
    /// Scientific notation equivalent to C <c>printf("%.2e", v)</c>: two fractional digits, lowercase
    /// 'e', signed exponent with at least two digits (e.g. 0.0113 → "1.13e-02", 12345 → "1.23e+04").
    /// </summary>
    public static string Sci(double v) => v.ToString("0.00e+00", Inv);

    /// <summary>
    /// Four significant figures with trailing zeros stripped (chart min/max + point labels). Matches
    /// the AppKit NumberFormatter with <c>usesSignificantDigits</c>, max 4. Callers use this only in
    /// the mid-magnitude branch (0.001 ≤ |v| &lt; 10000), so no exponent form appears.
    /// </summary>
    public static string SigFig4(double v)
        => v.ToString("G4", Inv).Replace("E", "e");

    /// <summary>
    /// <c>%g</c>-style formatting for table cells: up to 6 significant figures with trailing zeros
    /// stripped, lowercase exponent when used (e.g. 123456 → "123456", 0.0001 → "0.0001").
    /// </summary>
    public static string G6(double v)
        => v.ToString("G6", Inv).Replace("E", "e");

    /// <summary>
    /// The full chart <c>formatNumber</c> convenience: 0 → "0"; |v|&lt;0.001 or
    /// |v|≥10000 → <see cref="Sci"/>; else <see cref="SigFig4"/>. Provided so chart code shares one
    /// authoritative implementation.
    /// </summary>
    public static string FormatNumber(double v)
    {
        if (v == 0) return "0";
        double a = Math.Abs(v);
        if (a < 0.001 || a >= 10000) return Sci(v);
        return SigFig4(v);
    }
}
