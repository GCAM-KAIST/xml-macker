using System;
using System.IO;
using System.Linq;
using System.Text;
using XMLMacker.Core;
using XMLMacker.Shared;

namespace XMLMacker.App;

/// <summary>
/// Documents that exist before they have a home: File › New, the "+" tab button, and "Export Current
/// Element" (which opens the element alone as a new document instead of asking where to save it).
///
/// <para>Every tab in this app is a file that is loaded, parsed and watched by path, so an untitled document
/// is a real file in a private scratch folder under the app's settings folder. It behaves like any tab,
/// except that Save asks where to save it, it never appears in Recent Files or the reopen-at-launch list,
/// and its scratch copy is removed once it has been saved somewhere real.</para>
/// </summary>
public partial class MainWindow
{
    private const string BlankDocument = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root>\n    \n</root>\n";

    // LOCAL application data: this folder holds whole documents that were never saved. In the roaming
    // profile they would be copied to a file server at logoff and onto every machine the account uses.
    private static string ScratchFolder => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "xml-macker", "Untitled");

    /// <summary>True for a document that lives in the scratch folder (never saved to disk yet).</summary>
    private static bool IsUntitled(string? url)
    {
        if (string.IsNullOrEmpty(url)) return false;
        try { return Path.GetFullPath(url).StartsWith(ScratchFolder, StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }

    /// <summary>File › New and the "+" button: a minimal, well-formed document to start typing in.</summary>
    private void NewBlankDocument() => NewDocument(BlankDocument, "Untitled");

    /// <summary>Share › Export Current Element: the element alone, as its own document, in a new tab.</summary>
    private void ExportElementToNewTab(XmlTreeNode node)
    {
        if (ElementText(node) is not { } et) return;
        string body = et.Text.TrimStart();
        string text = body.StartsWith("<?xml", StringComparison.OrdinalIgnoreCase)
            ? body
            : "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + body;
        if (!text.EndsWith('\n')) text += "\n";

        string? key = node.Attributes.FirstOrDefault(a => a.Name is "name" or "year" or "id" or "key" or "type").Value;
        string stem = string.IsNullOrEmpty(key) ? node.DisplayLabel : $"{node.DisplayLabel}_{key}";
        NewDocument(text, stem);
        SetStatus($"{node.DisplayLabel} opened as its own document, Save As… to keep it");
    }

    /// <summary>
    /// Writes <paramref name="text"/> to a fresh scratch file named after <paramref name="stem"/> and opens
    /// it through the normal file path, so parsing, the tree, the minimap and everything else just work.
    /// </summary>
    private void NewDocument(string text, string stem)
    {
        if (FileWorkIsActive()) { ShowFileWorkInProgress(); return; }
        string path;
        try
        {
            Directory.CreateDirectory(ScratchFolder);
            string safe = string.Concat(stem.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c)).Trim();
            if (safe.Length == 0) safe = "Untitled";
            path = Path.Combine(ScratchFolder, safe + ".xml");
            for (int n = 2; File.Exists(path) || _sessions.Any(s => PathEquals(s.Url, path)); n++)
                path = Path.Combine(ScratchFolder, $"{safe} {n}.xml");
            File.WriteAllText(path, text, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        }
        catch (Exception ex)
        {
            NativeMethods.Beep();
            SetStatus($"Couldn't create the document: {ex.Message}");
            return;
        }
        LoadFile(path);
    }

    /// <summary>After a Save As away from the scratch folder, the scratch copy is not needed any more.</summary>
    private static void DeleteScratchIfUntitled(string? url)
    {
        if (!IsUntitled(url)) return;
        try { File.Delete(url!); } catch { /* best effort */ }
    }
}
