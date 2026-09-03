using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using XMLMacker.Core;

namespace XMLMacker.Shared;

/// <summary>
/// Keeps each file's marker strokes in the settings folder (one small JSON file per document path), so
/// they are back when the file is opened again. Every stroke stores the text it covers as well: when
/// the file changed outside the app, a stroke whose text is no longer at its place is moved to the
/// nearest line where that text is found, so it stays on the words it was put on.
/// </summary>
public static class HighlightStore
{
    private const int TextKeep = 200;      // characters of stroke text kept
    private const int SearchRadius = 400;  // lines searched up and down when a stroke no longer matches

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
    };

    private sealed class Mark
    {
        public int Line { get; set; }          // 1-based line of the stroke start
        public int Column { get; set; }        // 0-based column of the stroke start
        public int Length { get; set; }
        public string Color { get; set; } = "";
        public string Text { get; set; } = ""; // the covered text (first 200 characters)
    }
    private sealed class Doc { public string Path { get; set; } = ""; public List<Mark> Marks { get; set; } = new(); }

    private static string Folder => Path.Combine(AppSettings.Instance.StorageDirectory, "highlights");

    private static string FileFor(string path)
    {
        byte[] hash = SHA1.HashData(Encoding.UTF8.GetBytes(path.Trim().ToLowerInvariant()));
        return Path.Combine(Folder, Convert.ToHexString(hash) + ".json");
    }

    /// <summary>
    /// Loads the strokes saved for <paramref name="path"/> into <paramref name="into"/>.
    /// <paramref name="textAt"/>(offset, length) returns document text; <paramref name="lineStarts"/> is the line table.
    /// </summary>
    public static void Load(string path, TextHighlights into, int[] lineStarts, int docLength, Func<int, int, string> textAt)
    {
        try
        {
            string file = FileFor(path);
            if (!File.Exists(file)) return;
            Doc? doc = JsonSerializer.Deserialize<Doc>(File.ReadAllText(file, Encoding.UTF8), Options);
            if (doc is null || doc.Marks.Count == 0 || lineStarts.Length == 0) return;

            var ranges = new List<HighlightRange>();
            foreach (Mark m in doc.Marks)
            {
                if (!Enum.TryParse(m.Color, ignoreCase: true, out HighlightColor color) || color == HighlightColor.None || m.Length <= 0) continue;
                int line = m.Line - 1;
                string want = m.Text ?? "";
                int probe = Math.Min(m.Length, TextKeep);
                int offset = -1;
                if (line >= 0 && line < lineStarts.Length)
                {
                    int at = lineStarts[line] + Math.Max(0, m.Column);
                    if (at + probe <= docLength && (want.Length == 0 || textAt(at, probe) == want)) offset = at;
                }
                if (offset < 0 && want.Length > 0)
                {
                    // Not where it was: look for the same text on the nearest lines.
                    for (int d = 0; d <= SearchRadius && offset < 0; d++)
                    {
                        foreach (int candidate in d == 0 ? new[] { line } : new[] { line - d, line + d })
                        {
                            if (candidate < 0 || candidate >= lineStarts.Length) continue;
                            int ls = lineStarts[candidate];
                            int le = candidate + 1 < lineStarts.Length ? lineStarts[candidate + 1] : docLength;
                            string lineText = textAt(ls, Math.Min(le - ls, 4000));
                            int idx = lineText.IndexOf(want.Length > 80 ? want.Substring(0, 80) : want, StringComparison.Ordinal);
                            if (idx >= 0) { offset = ls + idx; break; }
                        }
                    }
                }
                if (offset < 0) continue;
                int length = Math.Min(m.Length, Math.Max(0, docLength - offset));
                if (length > 0) ranges.Add(new HighlightRange(offset, length, color));
            }
            into.ReplaceAll(ranges);
        }
        catch
        {
            // A damaged store must never stop a file from opening.
        }
    }

    /// <summary>Saves the strokes of <paramref name="path"/>; no strokes → the store file is removed.</summary>
    public static void Save(string path, TextHighlights highlights, int[] lineStarts, Func<int, int, string> textAt)
    {
        try
        {
            string file = FileFor(path);
            if (highlights.IsEmpty)
            {
                if (File.Exists(file)) File.Delete(file);
                return;
            }
            var doc = new Doc { Path = path };
            foreach (HighlightRange r in highlights.All)
            {
                int line = LineFor(lineStarts, r.Start);
                doc.Marks.Add(new Mark
                {
                    Line = line + 1,
                    Column = r.Start - lineStarts[line],
                    Length = r.Length,
                    Color = r.Color.ToString(),
                    Text = textAt(r.Start, Math.Min(r.Length, TextKeep)),
                });
            }
            Directory.CreateDirectory(Folder);
            File.WriteAllText(file, JsonSerializer.Serialize(doc, Options), Encoding.UTF8);
        }
        catch
        {
            // Best effort: the strokes are still on screen; the next change tries again.
        }
    }

    private static int LineFor(int[] starts, int offset)
    {
        int lo = 0, hi = starts.Length - 1;
        while (lo < hi)
        {
            int mid = (lo + hi + 1) >> 1;
            if (starts[mid] <= offset) lo = mid; else hi = mid - 1;
        }
        return lo;
    }
}
