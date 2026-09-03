using System.Collections.Generic;
using System.IO;

namespace XMLMacker.Shared;

/// <summary>
/// The self-managed "Open Recent" list, the WPF port of AppDelegate's hand-rolled recents.
/// Most-recent-first, capped at 10, persisted to <c>xml-macker.recentFiles</c> in <see cref="AppSettings"/>.
///
/// Rationale (from AppDelegate.swift): the system recent-documents mechanism is unreliable for
/// non-document apps, so the app keeps its own list.
/// </summary>
public static class RecentFiles
{
    /// <summary>Persistence key (matches the macOS UserDefaults key verbatim).</summary>
    public const string Key = "xml-macker.recentFiles";

    /// <summary>Maximum number of entries retained.</summary>
    public const int Cap = 10;

    private static readonly object Gate = new();

    /// <summary>Current list, most-recent-first.</summary>
    public static IReadOnlyList<string> All
    {
        get
        {
            lock (Gate)
            {
                return AppSettings.Instance.GetStringList(Key);
            }
        }
    }

    /// <summary>
    /// Records <paramref name="path"/> as the newest entry: drops any existing entry for the same
    /// path, inserts at the front, and truncates the tail beyond <see cref="Cap"/>.
    /// </summary>
    public static void Add(string path)
    {
        if (string.IsNullOrEmpty(path)) return;
        lock (Gate)
        {
            var list = new List<string>(AppSettings.Instance.GetStringList(Key));
            list.RemoveAll(p => string.Equals(p, path, StringComparison.OrdinalIgnoreCase));
            list.Insert(0, path);
            if (list.Count > Cap)
                list.RemoveRange(Cap, list.Count - Cap);
            AppSettings.Instance.SetStringList(Key, list);
        }
    }

    /// <summary>Removes <paramref name="path"/> from the list if present.</summary>
    public static void Remove(string path)
    {
        if (string.IsNullOrEmpty(path)) return;
        lock (Gate)
        {
            var list = new List<string>(AppSettings.Instance.GetStringList(Key));
            int before = list.Count;
            list.RemoveAll(p => string.Equals(p, path, StringComparison.OrdinalIgnoreCase));
            if (list.Count != before)
                AppSettings.Instance.SetStringList(Key, list);
        }
    }

    /// <summary>Clears the entire list ("Clear Menu").</summary>
    public static void Clear()
    {
        lock (Gate)
        {
            AppSettings.Instance.SetStringList(Key, Array.Empty<string>());
        }
    }

    /// <summary>
    /// Called when a recent entry is clicked. If the file no longer exists, this beeps
    /// (matching <c>NSSound.beep()</c>), drops the entry, and returns <c>false</c> so the caller
    /// must NOT try to open it. Returns <c>true</c> when the file is present and openable.
    /// </summary>
    public static bool PruneMissing(string clickedPath)
    {
        if (string.IsNullOrEmpty(clickedPath) || !File.Exists(clickedPath))
        {
            NativeMethods.Beep();
            Remove(clickedPath);
            return false;
        }
        return true;
    }
}
