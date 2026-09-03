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

        // A network path named by the document is refused before anything touches the disk. Windows opens
        // an authenticated session to answer File.Exists for \\host\share, so a document that merely names
        // a host would hand the reader's account details to whoever owns it, just by being scrolled into
        // view, and would freeze the window for the connection timeout while doing it.
        if (IsNetworkPath(text)) return null;

        var candidates = new List<string>();
        try
        {
            if (Path.IsPathRooted(text)) AddCandidate(candidates, Path.GetFullPath(text), documentPath);
            else if (!string.IsNullOrEmpty(documentPath))
            {
                string? directory = Path.GetDirectoryName(documentPath);
                if (directory is not null)
                {
                    AddCandidate(candidates, Path.GetFullPath(Path.Combine(directory, text)), documentPath);
                    string? parent = Directory.GetParent(directory)?.FullName;
                    if (parent is not null)
                        AddCandidate(candidates, Path.GetFullPath(Path.Combine(parent, text)), documentPath);
                }
            }
        }
        catch { return null; }

        foreach (string candidate in candidates)
            if (File.Exists(candidate)) return candidate;
        return null;
    }

    /// <summary>
    /// True for a path that lives on another machine: <c>\\host\share\...</c> in either slash, and the
    /// device forms of the same thing. A mapped drive letter is NOT one of these: that share was mounted
    /// and authenticated by the user, so following it is their own choice.
    /// </summary>
    private static bool IsNetworkPath(string path)
    {
        if (string.IsNullOrEmpty(path)) return false;
        if (path.StartsWith(@"\\", StringComparison.Ordinal)) return true;   // \\host\share and \\?\UNC\...
        if (path.StartsWith("//", StringComparison.Ordinal)) return true;
        if (!Path.IsPathRooted(path)) return false;                        // judged again once combined
        try { return new Uri(path).IsUnc; }
        catch { return true; }                                             // unreadable as a path: do not touch it
    }

    /// <summary>
    /// Keeps a resolved candidate unless it reaches onto another machine. The one exception is a document
    /// that is ITSELF open from a network share: its neighbours live on that same share, the user is
    /// already authenticated there, and refusing them would break linked files for everyone working off a
    /// shared drive.
    /// </summary>
    private static void AddCandidate(List<string> candidates, string candidate, string? documentPath)
    {
        if (!IsNetworkPath(candidate)) { candidates.Add(candidate); return; }
        if (documentPath is not null && IsNetworkPath(documentPath) && SameShare(candidate, documentPath))
            candidates.Add(candidate);
    }

    /// <summary>True when two network paths name the same host and the same share.</summary>
    private static bool SameShare(string a, string b)
    {
        static string[] Head(string p)
        {
            string[] parts = p.Replace('/', '\\').Trim('\\').Split('\\', StringSplitOptions.RemoveEmptyEntries);
            return parts.Length >= 2 ? new[] { parts[0], parts[1] } : Array.Empty<string>();
        }
        string[] x = Head(a), y = Head(b);
        return x.Length == 2 && y.Length == 2
            && string.Equals(x[0], y[0], StringComparison.OrdinalIgnoreCase)
            && string.Equals(x[1], y[1], StringComparison.OrdinalIgnoreCase);
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
