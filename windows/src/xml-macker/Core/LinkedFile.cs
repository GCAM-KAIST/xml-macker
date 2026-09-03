using System;
using System.Collections.Generic;
using System.IO;

namespace XMLMacker.Core;

public static class LinkedFile
{
    public static string? Resolve(string raw, string? documentPath)
    {
        string text = (raw ?? string.Empty).Trim();
        if (text.Length == 0 || text.Length >= 1024 || text.Contains('\n') || text.Contains('\r')) return null;
        if (!text.Contains('/') && !text.Contains('\\') && !text.EndsWith(".xml", StringComparison.OrdinalIgnoreCase)) return null;

        var candidates = new List<string>();
        try
        {
            if (Path.IsPathRooted(text)) candidates.Add(Path.GetFullPath(text));
            else if (!string.IsNullOrEmpty(documentPath))
            {
                string? directory = Path.GetDirectoryName(documentPath);
                if (directory is not null)
                {
                    candidates.Add(Path.GetFullPath(Path.Combine(directory, text)));
                    string? parent = Directory.GetParent(directory)?.FullName;
                    if (parent is not null) candidates.Add(Path.GetFullPath(Path.Combine(parent, text)));
                }
            }
        }
        catch { return null; }

        foreach (string candidate in candidates)
            if (File.Exists(candidate)) return candidate;
        return null;
    }

    public static string? Resolve(XmlTreeNode node, string? documentPath)
    {
        string? found = Resolve(node.TextValue, documentPath);
        if (found is not null) return found;
        foreach ((string _, string value) in node.Attributes)
        {
            found = Resolve(value, documentPath);
            if (found is not null) return found;
        }
        return null;
    }
}
