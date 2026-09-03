using System.Collections.Generic;
using System.IO;
using System.Text;

namespace XMLMacker.Shared;

/// <summary>
/// RFC-4180 CSV helpers, the single shared implementation used by FindPanel and ChartPopout
/// (dedupes the copies flagged in ENGINEERING_NOTES).
/// </summary>
public static class Csv
{
    /// <summary>
    /// Escapes one field per RFC-4180: if it contains a comma, double-quote, CR or LF, it is wrapped
    /// in double-quotes and any embedded double-quote is doubled. Otherwise returned unchanged.
    /// </summary>
    public static string Escape(string? s)
    {
        s ??= string.Empty;
        bool mustQuote = s.IndexOf(',') >= 0
                      || s.IndexOf('"') >= 0
                      || s.IndexOf('\n') >= 0
                      || s.IndexOf('\r') >= 0;
        if (!mustQuote) return s;
        return "\"" + s.Replace("\"", "\"\"") + "\"";
    }

    /// <summary>Builds a full CSV document string (CRLF line endings) from rows of fields.</summary>
    public static string Build(IEnumerable<IEnumerable<string>> rows)
    {
        var sb = new StringBuilder();
        foreach (var row in rows)
        {
            bool first = true;
            foreach (var field in row)
            {
                if (!first) sb.Append(',');
                sb.Append(Escape(field));
                first = false;
            }
            sb.Append("\r\n");
        }
        return sb.ToString();
    }

    /// <summary>
    /// UTF-8 <b>with</b> a byte-order mark, the three bytes EF BB BF that start the file and announce
    /// "the text below is UTF-8".
    /// <para>Excel on Windows opens a <c>.csv</c> that has no such mark using the system ANSI code page
    /// (Windows-1252 here), not UTF-8. Every non-ASCII character then renders as mojibake: the path
    /// separator <c>›</c> (U+203A) came out as <c>â€º</c> in the exported find results. Writing the mark
    /// makes Excel, Notepad and every modern reader decode the file correctly. Readers that do not care
    /// about the mark (this app's own importers, pandas, R's read.csv with encoding="UTF-8-BOM") are
    /// unaffected, the mark is a zero-width no-op character.</para>
    /// </summary>
    private static readonly UTF8Encoding Utf8WithBom = new(encoderShouldEmitUTF8Identifier: true);

    /// <summary>Writes rows to <paramref name="path"/> as UTF-8 CSV (RFC-4180 quoting, CRLF rows, BOM).</summary>
    public static void Write(IEnumerable<IEnumerable<string>> rows, string path)
    {
        File.WriteAllText(path, Build(rows), Utf8WithBom);
    }
}
