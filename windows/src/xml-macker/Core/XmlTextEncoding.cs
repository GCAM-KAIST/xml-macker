using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace XMLMacker.Core;

public enum XmlEncodingKind
{
    Utf8,
    Utf8Bom,
    Utf16LittleEndian,
    Utf16BigEndian,
    Utf32LittleEndian,
    Utf32BigEndian,
    IsoLatin1,
    Windows1252,
    Ascii,
    MacRoman,
}

/// <summary>Lossless XML decoding and save-time encoding reconciliation.</summary>
public readonly record struct XmlTextEncoding(XmlEncodingKind Kind)
{
    private static readonly Regex DeclarationRegex = new(
        "(?:^|\\s)encoding\\s*=\\s*(['\"])([A-Za-z][A-Za-z0-9._-]*)\\1",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

    static XmlTextEncoding() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    public static XmlTextEncoding Utf8 => new(XmlEncodingKind.Utf8);

    public string DisplayName => Kind switch
    {
        XmlEncodingKind.Utf8 => "UTF-8",
        XmlEncodingKind.Utf8Bom => "UTF-8 BOM",
        XmlEncodingKind.Utf16LittleEndian => "UTF-16 LE",
        XmlEncodingKind.Utf16BigEndian => "UTF-16 BE",
        XmlEncodingKind.Utf32LittleEndian => "UTF-32 LE",
        XmlEncodingKind.Utf32BigEndian => "UTF-32 BE",
        XmlEncodingKind.IsoLatin1 => "ISO-8859-1",
        XmlEncodingKind.Windows1252 => "Windows-1252",
        XmlEncodingKind.Ascii => "ASCII",
        XmlEncodingKind.MacRoman => "Mac Roman",
        _ => "Unknown",
    };

    public static (string Text, XmlTextEncoding Encoding) Decode(byte[] data)
    {
        if (StartsWith(data, 0x00, 0x00, 0xFE, 0xFF)) return DecodeBody(data, 4, new(XmlEncodingKind.Utf32BigEndian));
        if (StartsWith(data, 0xFF, 0xFE, 0x00, 0x00)) return DecodeBody(data, 4, new(XmlEncodingKind.Utf32LittleEndian));
        if (StartsWith(data, 0xEF, 0xBB, 0xBF)) return DecodeBody(data, 3, new(XmlEncodingKind.Utf8Bom));
        if (StartsWith(data, 0xFE, 0xFF)) return DecodeBody(data, 2, new(XmlEncodingKind.Utf16BigEndian));
        if (StartsWith(data, 0xFF, 0xFE)) return DecodeBody(data, 2, new(XmlEncodingKind.Utf16LittleEndian));

        string prefix = Encoding.Latin1.GetString(data, 0, Math.Min(data.Length, 4096));
        string? declared = DeclaredEncoding(prefix);
        if (declared is not null)
        {
            XmlTextEncoding selected = FromDeclaredName(declared, data)
                ?? throw new XmlDocumentException($"The XML declaration names unsupported encoding '{declared}'. xml-macker did not guess or change the document's bytes.");
            return DecodeBody(data, 0, selected);
        }

        byte[] first = data.Take(4).ToArray();
        if (first.SequenceEqual(new byte[] { 0x00, 0x00, 0x00, 0x3C })) return DecodeBody(data, 0, new(XmlEncodingKind.Utf32BigEndian));
        if (first.SequenceEqual(new byte[] { 0x3C, 0x00, 0x00, 0x00 })) return DecodeBody(data, 0, new(XmlEncodingKind.Utf32LittleEndian));
        if (StartsWith(data, 0x00, 0x3C)) return DecodeBody(data, 0, new(XmlEncodingKind.Utf16BigEndian));
        if (StartsWith(data, 0x3C, 0x00)) return DecodeBody(data, 0, new(XmlEncodingKind.Utf16LittleEndian));

        return DecodeBody(data, 0, Utf8);
    }

    public byte[] Encode(string text)
    {
        try
        {
            byte[] body = DotNetEncoding().GetBytes(text);
            byte[] mark = ByteOrderMark();
            if (mark.Length == 0) return body;
            byte[] result = new byte[mark.Length + body.Length];
            Buffer.BlockCopy(mark, 0, result, 0, mark.Length);
            Buffer.BlockCopy(body, 0, result, mark.Length, body.Length);
            return result;
        }
        catch (EncoderFallbackException)
        {
            throw new XmlDocumentException($"Some edited characters cannot be saved using the document's original {DisplayName} encoding.");
        }
    }

    public XmlTextEncoding ReconciledForSave(string text)
    {
        string? declared = DeclaredEncoding(text);
        if (declared is not null)
        {
            XmlTextEncoding? selected = FromDeclaredNameForSave(declared, this);
            return selected ?? throw new XmlDocumentException($"The XML declaration names unsupported encoding '{declared}'. xml-macker did not guess or change the document's bytes.");
        }

        if (Kind is XmlEncodingKind.IsoLatin1 or XmlEncodingKind.Windows1252 or XmlEncodingKind.MacRoman)
            throw new XmlDocumentException($"A {DisplayName} XML document must keep an encoding declaration. Restore the declaration or change it to a supported encoding before saving.");
        return this;
    }

    public static string? DeclaredEncoding(string text)
    {
        string prefix = text.Length > 4096 ? text[..4096] : text;
        if (!prefix.StartsWith("<?xml", StringComparison.Ordinal)) return null;
        if (prefix.Length == 5 || !IsXmlSpace(prefix[5])) return null;
        int end = prefix.IndexOf("?>", 5, StringComparison.Ordinal);
        if (end < 0) return null;
        Match match = DeclarationRegex.Match(prefix[..(end + 2)]);
        return match.Success ? match.Groups[2].Value : null;
    }

    private static (string Text, XmlTextEncoding Encoding) DecodeBody(byte[] data, int offset, XmlTextEncoding encoding)
    {
        try
        {
            string text = encoding.DotNetEncoding().GetString(data, offset, data.Length - offset);
            string? declared = DeclaredEncoding(text);
            if (declared is not null && FromDeclaredNameForSave(declared, encoding) is null)
                throw new XmlDocumentException($"The XML declaration names unsupported encoding '{declared}'. xml-macker did not guess or change the document's bytes.");
            return (text, encoding);
        }
        catch (DecoderFallbackException)
        {
            throw new XmlDocumentException($"The file declares {encoding.DisplayName}, but its bytes are not valid {encoding.DisplayName} text.");
        }
    }

    private Encoding DotNetEncoding() => Kind switch
    {
        XmlEncodingKind.Utf8 or XmlEncodingKind.Utf8Bom => new UTF8Encoding(false, true),
        XmlEncodingKind.Utf16LittleEndian => new UnicodeEncoding(false, false, true),
        XmlEncodingKind.Utf16BigEndian => new UnicodeEncoding(true, false, true),
        XmlEncodingKind.Utf32LittleEndian => new UTF32Encoding(false, false, true),
        XmlEncodingKind.Utf32BigEndian => new UTF32Encoding(true, false, true),
        XmlEncodingKind.IsoLatin1 => Encoding.GetEncoding(28591, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback),
        XmlEncodingKind.Windows1252 => Encoding.GetEncoding(1252, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback),
        XmlEncodingKind.Ascii => Encoding.GetEncoding(20127, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback),
        XmlEncodingKind.MacRoman => Encoding.GetEncoding(10000, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback),
        _ => throw new InvalidOperationException(),
    };

    private byte[] ByteOrderMark() => Kind switch
    {
        XmlEncodingKind.Utf8Bom => new byte[] { 0xEF, 0xBB, 0xBF },
        XmlEncodingKind.Utf16LittleEndian => new byte[] { 0xFF, 0xFE },
        XmlEncodingKind.Utf16BigEndian => new byte[] { 0xFE, 0xFF },
        XmlEncodingKind.Utf32LittleEndian => new byte[] { 0xFF, 0xFE, 0x00, 0x00 },
        XmlEncodingKind.Utf32BigEndian => new byte[] { 0x00, 0x00, 0xFE, 0xFF },
        _ => Array.Empty<byte>(),
    };

    private static XmlTextEncoding? FromDeclaredName(string raw, byte[] sample)
    {
        string name = Normalise(raw);
        if (name is "utf-16" or "utf16")
            return StartsWith(sample, 0x00, 0x3C) ? new(XmlEncodingKind.Utf16BigEndian) : new(XmlEncodingKind.Utf16LittleEndian);
        return FromDeclaredNameForSave(name, Utf8);
    }

    private static XmlTextEncoding? FromDeclaredNameForSave(string raw, XmlTextEncoding current)
    {
        string name = Normalise(raw);
        return name switch
        {
            "utf-8" or "utf8" => current.Kind is XmlEncodingKind.Utf8 or XmlEncodingKind.Utf8Bom ? current : Utf8,
            "utf-16" or "utf16" => current.Kind is XmlEncodingKind.Utf16LittleEndian or XmlEncodingKind.Utf16BigEndian ? current : new(XmlEncodingKind.Utf16LittleEndian),
            "utf-16le" or "utf16le" => new(XmlEncodingKind.Utf16LittleEndian),
            "utf-16be" or "utf16be" => new(XmlEncodingKind.Utf16BigEndian),
            "utf-32" or "utf32" => current.Kind is XmlEncodingKind.Utf32LittleEndian or XmlEncodingKind.Utf32BigEndian ? current : new(XmlEncodingKind.Utf32LittleEndian),
            "utf-32le" or "utf32le" => new(XmlEncodingKind.Utf32LittleEndian),
            "utf-32be" or "utf32be" => new(XmlEncodingKind.Utf32BigEndian),
            "iso-8859-1" or "latin1" or "latin-1" => new(XmlEncodingKind.IsoLatin1),
            "windows-1252" or "cp1252" => new(XmlEncodingKind.Windows1252),
            "us-ascii" or "ascii" => new(XmlEncodingKind.Ascii),
            "macintosh" or "macroman" or "x-mac-roman" => new(XmlEncodingKind.MacRoman),
            _ => null,
        };
    }

    private static string Normalise(string value) => value.ToLowerInvariant().Replace('_', '-');
    private static bool IsXmlSpace(char c) => c is ' ' or '\t' or '\n' or '\r';
    private static bool StartsWith(byte[] data, params byte[] prefix)
        => data.Length >= prefix.Length && data.AsSpan(0, prefix.Length).SequenceEqual(prefix);
}

public sealed class XmlDocumentException : IOException
{
    public XmlDocumentException(string message) : base(message) { }
}
