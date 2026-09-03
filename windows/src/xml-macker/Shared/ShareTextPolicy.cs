using System;
using System.Globalization;
using System.Text;

namespace XMLMacker.Shared;

public readonly record struct ShareTextExcerpt(string Text, int TotalUtf8Bytes, int IncludedUtf8Bytes)
{
    public int OmittedUtf8Bytes => TotalUtf8Bytes - IncludedUtf8Bytes;
    public bool IsTruncated => OmittedUtf8Bytes > 0;
}

public static class ShareTextPolicy
{
    public const int CompatibilityUtf8ByteLimit = 128 * 1024;

    public static ShareTextExcerpt Excerpt(string source, int maximumUtf8Bytes = CompatibilityUtf8ByteLimit)
    {
        int limit = Math.Max(0, maximumUtf8Bytes);
        int total = Encoding.UTF8.GetByteCount(source);
        if (total <= limit) return new(source, total, total);

        var enumerator = StringInfo.GetTextElementEnumerator(source);
        int chars = 0;
        int bytes = 0;
        while (enumerator.MoveNext())
        {
            string element = enumerator.GetTextElement();
            int elementBytes = Encoding.UTF8.GetByteCount(element);
            if (bytes + elementBytes > limit) break;
            bytes += elementBytes;
            chars = enumerator.ElementIndex + element.Length;
        }
        return new(source[..chars], total, bytes);
    }
}
