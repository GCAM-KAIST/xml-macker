using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace XMLMacker.Core;

public static class XmlDocumentSupport
{
    public static readonly HashSet<string> KnownExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".xml", ".xsd", ".xsl", ".xslt", ".svg", ".plist", ".gpx", ".kml",
        ".rss", ".atom", ".wsdl", ".xhtml", ".opf", ".ncx", ".mathml",
    };

    public static IReadOnlyList<string> CanonicalFiles(IEnumerable<string> paths)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<string>();
        foreach (string raw in paths)
        {
            if (string.IsNullOrWhiteSpace(raw)) continue;
            try
            {
                string full = Path.GetFullPath(raw);
                if (File.Exists(full) && seen.Add(full)) result.Add(full);
            }
            catch { }
        }
        return result;
    }

    public static bool IsLikelyXml(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            byte[] prefix = new byte[Math.Min(4096, (int)Math.Min(int.MaxValue, stream.Length))];
            int count = stream.Read(prefix, 0, prefix.Length);
            prefix = prefix.Take(count).ToArray();
            if (prefix.AsSpan().StartsWith("bplist00"u8)) return false;
            if (KnownExtensions.Contains(Path.GetExtension(path))) return true;
            if (HasXmlEncodingSignature(prefix)) return true;
            string text = new System.Text.UTF8Encoding(false, true).GetString(prefix);
            return text.TrimStart().StartsWith('<');
        }
        catch { return false; }
    }

    private static bool HasXmlEncodingSignature(byte[] b)
        => b.AsSpan().StartsWith(new byte[] { 0xEF, 0xBB, 0xBF })
        || b.AsSpan().StartsWith(new byte[] { 0xFE, 0xFF })
        || b.AsSpan().StartsWith(new byte[] { 0xFF, 0xFE })
        || b.AsSpan().StartsWith(new byte[] { 0x00, 0x00, 0xFE, 0xFF })
        || b.AsSpan().StartsWith(new byte[] { 0xFF, 0xFE, 0x00, 0x00 })
        || b.AsSpan().StartsWith(new byte[] { 0x00, 0x3C })
        || b.AsSpan().StartsWith(new byte[] { 0x3C, 0x00 })
        || b.AsSpan().StartsWith(new byte[] { 0x00, 0x00, 0x00, 0x3C })
        || b.AsSpan().StartsWith(new byte[] { 0x3C, 0x00, 0x00, 0x00 });
}
