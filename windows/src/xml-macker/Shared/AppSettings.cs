using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace XMLMacker.Shared;

/// <summary>
/// JSON-backed settings store, the WPF replacement for macOS <c>UserDefaults</c>.
/// Persists to <c>%APPDATA%/xml-macker/settings.json</c> with typed get/set accessors
/// using the exact key strings from the specs.
/// Every setter persists immediately via an atomic write (temp file + File.Replace/Move).
/// All access is guarded by a lock so it is safe to touch from any thread.
/// </summary>
public sealed class AppSettings
{
    private static readonly Lazy<AppSettings> _instance = new(() => new AppSettings());
    private const string CurrentDirName = "xml-macker";
    private const string LegacyDirName = "XML" + "EDITORX";
    private const string LegacyPrefix = "XML" + "EDITORX";

    /// <summary>The process-wide settings store.</summary>
    public static AppSettings Instance => _instance.Value;

    private readonly object _gate = new();
    private readonly string _dir;
    private readonly string _path;
    private Dictionary<string, JsonElement> _data = new();
    private bool _suppressWritesUntilExit;

    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true
    };

    /// <summary>The per-account folder every store lives in (settings, highlights).</summary>
    public string StorageDirectory => _dir;

    private AppSettings()
    {
        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        _dir = Path.Combine(appData, CurrentDirName);
        _path = Path.Combine(_dir, "settings.json");
        MigrateLegacyStore(appData);
        Load();
    }

    /// <summary>
    /// Written once the rename has been carried across. The absence of
    /// settings.json cannot stand in for this: Reset All Settings deletes
    /// exactly that file and relaunches, and the fresh process would read
    /// the missing file as "first run after the rename" and quietly import
    /// the settings the reset was meant to clear.
    /// </summary>
    private const string MigrationMarker = ".migrated";

    /// <summary>
    /// Written once every folder store (marks, chat profile, unsaved
    /// documents) has arrived. It is separate from <see cref="MigrationMarker"/>
    /// because a folder can fail to copy for a while, for example the chat
    /// profile is locked while the previous build is still running, and that
    /// must not hold back the marker that closes the reset loop.
    /// </summary>
    private const string StoresMarker = ".migrated-stores";

    private void MigrateLegacyStore(string appData)
    {
        string legacyDir = Path.Combine(appData, LegacyDirName);

        // The settings file first. Its marker is what closes the reset loop, so it is written as soon
        // as the file has arrived (or there was nothing to bring over).
        if (!File.Exists(Path.Combine(_dir, MigrationMarker)) && CarrySettings(legacyDir))
            WriteMarker(MigrationMarker);

        // The folder stores next, each on its own so one failure cannot strand the others. Their marker
        // is written only when all of them arrived; until then every launch tries again, which is cheap
        // because a store that is already there is skipped.
        if (File.Exists(Path.Combine(_dir, StoresMarker))) return;

        bool carried = CarryFolder(Path.Combine(legacyDir, "highlights"), Path.Combine(_dir, "highlights"));

        // The chat profile and the unsaved documents live in the LOCAL profile now, so they are carried
        // there, not into _dir. Two possible sources for each: the previous name, and a build of this
        // name that still kept them in the roaming folder.
        string localDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), CurrentDirName);
        string roamingHere = Path.Combine(appData, CurrentDirName);

        string profile = Path.Combine(localDir, "WebView2");
        carried &= CarryFolder(Path.Combine(legacyDir, "WebView2"), profile);
        carried &= CarryFolder(Path.Combine(roamingHere, "WebView2"), profile);

        string scratch = Path.Combine(localDir, "Untitled");
        carried &= CarryFolder(Path.Combine(legacyDir, "Untitled"), scratch);
        carried &= CarryFolder(Path.Combine(roamingHere, "Untitled"), scratch);

        // Anything of OURS left in the roaming folder is removed once the local copy is in place,
        // otherwise the copy that was moved for exactly this reason keeps roaming to the file server.
        // Folders belonging to the previous name are left alone: they are not this application's to
        // delete, and an older build may still be installed.
        PurgeRoamingCopy(Path.Combine(roamingHere, "WebView2"), profile);
        PurgeRoamingCopy(Path.Combine(roamingHere, "Untitled"), scratch);

        if (carried) WriteMarker(StoresMarker);
    }

    /// <summary>
    /// Deletes a store of ours that is still sitting in the roaming profile, but only once the local copy
    /// exists and holds something, so nothing is thrown away before it has been carried.
    /// </summary>
    private static void PurgeRoamingCopy(string roaming, string local)
    {
        try
        {
            if (!Directory.Exists(roaming)) return;
            if (!Directory.Exists(local) || !Directory.EnumerateFileSystemEntries(local).Any()) return;
            Directory.Delete(roaming, recursive: true);
        }
        catch
        {
            // A file held open just means it is tried again next launch.
        }
    }

    private void WriteMarker(string name)
    {
        try
        {
            Directory.CreateDirectory(_dir);
            File.WriteAllText(Path.Combine(_dir, name), string.Empty);
        }
        catch
        {
            // Without the marker the carry is simply attempted again next time, which is harmless:
            // every step is a no-op once the destination is in place.
        }
    }

    private bool CarrySettings(string legacyDir)
    {
        try
        {
            if (File.Exists(_path)) return true;

            string legacyPath = Path.Combine(legacyDir, "settings.json");
            if (!File.Exists(legacyPath)) return true;

            Directory.CreateDirectory(_dir);
            string json = File.ReadAllText(legacyPath, Encoding.UTF8);
            var parsed = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json) ?? new();
            var migrated = new Dictionary<string, JsonElement>(parsed.Count);
            foreach ((string key, JsonElement value) in parsed)
                migrated[MigrateLegacyKey(key)] = value;

            File.WriteAllText(
                _path,
                JsonSerializer.Serialize(migrated, WriteOptions),
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            return true;
        }
        catch
        {
            // Ignore and fall back to a clean store.
            return false;
        }
    }

    /// <summary>
    /// Copies a store the app owns from the previous name, when there is
    /// one and nothing is there yet. The old copy is left in place so an
    /// older build installed beside this one keeps working.
    /// </summary>
    private static bool CarryFolder(string from, string to)
    {
        string staging = to + ".incoming";
        try
        {
            if (!Directory.Exists(from)) return true;
            // An EMPTY folder at the destination does not count as "already
            // there": a store creates its folder the first time it is
            // touched, which can happen before this runs. Only real content
            // at the destination is left alone.
            if (Directory.Exists(to))
            {
                if (Directory.EnumerateFileSystemEntries(to).Any()) return true;
                Directory.Delete(to);
            }

            // Copy into a staging folder and rename it into place only once the whole tree arrived:
            // a half-copied folder carrying the final name would look finished to every later launch.
            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
            CopyDirectory(from, staging);
            Directory.Move(staging, to);
            return true;
        }
        catch
        {
            try { if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true); }
            catch { /* leftovers are harmless, the next attempt replaces them */ }
            return false;
        }
    }

    private static string MigrateLegacyKey(string key)
    {
        if (key.StartsWith(LegacyPrefix + ".", System.StringComparison.Ordinal))
            return CurrentDirName + key[LegacyPrefix.Length..];
        if (key.StartsWith(LegacyPrefix, System.StringComparison.Ordinal))
            return CurrentDirName + key[LegacyPrefix.Length..];
        return key;
    }

    private static void CopyDirectory(string sourceDir, string targetDir)
    {
        Directory.CreateDirectory(targetDir);
        foreach (string file in Directory.GetFiles(sourceDir))
            File.Copy(file, Path.Combine(targetDir, Path.GetFileName(file)), overwrite: false);
        // The stores that matter are trees, not flat folders: the entire chat profile sits under
        // WebView2\EBWebView\..., so a copy that stops at the top level carries nothing at all.
        foreach (string dir in Directory.GetDirectories(sourceDir))
            CopyDirectory(dir, Path.Combine(targetDir, Path.GetFileName(dir)));
    }

    private void Load()
    {
        lock (_gate)
        {
            try
            {
                if (File.Exists(_path))
                {
                    string json = File.ReadAllText(_path, Encoding.UTF8);
                    var parsed = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json);
                    _data = parsed ?? new Dictionary<string, JsonElement>();
                }
                else
                {
                    _data = new Dictionary<string, JsonElement>();
                }
            }
            catch
            {
                // Corrupt / unreadable settings must never crash launch, start fresh.
                _data = new Dictionary<string, JsonElement>();
            }
        }
    }

    private void Save()
    {
        // Caller holds _gate.
        try
        {
            Directory.CreateDirectory(_dir);
            string json = JsonSerializer.Serialize(_data, WriteOptions);
            string tmp = _path + ".tmp";
            File.WriteAllText(tmp, json, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            if (File.Exists(_path))
            {
                // File.Replace is atomic on NTFS; backup arg null = no backup copy.
                File.Replace(tmp, _path, null);
            }
            else
            {
                File.Move(tmp, _path);
            }
        }
        catch
        {
            // Persistence failures are swallowed, an unwritable disk must not crash the app.
        }
    }

    private void Set(string key, JsonElement value)
    {
        lock (_gate)
        {
            if (_suppressWritesUntilExit) return;
            _data[key] = value;
            Save();
        }
    }

    private bool TryGet(string key, out JsonElement value)
    {
        lock (_gate)
        {
            return _data.TryGetValue(key, out value);
        }
    }

    // ---- String ----------------------------------------------------------

    public string GetString(string key, string def)
    {
        if (TryGet(key, out var el) && el.ValueKind == JsonValueKind.String)
            return el.GetString() ?? def;
        return def;
    }

    public void SetString(string key, string value)
        => Set(key, JsonSerializer.SerializeToElement(value));

    // ---- Double ----------------------------------------------------------

    public double GetDouble(string key, double def)
    {
        if (TryGet(key, out var el) && el.ValueKind == JsonValueKind.Number
            && el.TryGetDouble(out double d))
            return d;
        return def;
    }

    public void SetDouble(string key, double value)
        => Set(key, JsonSerializer.SerializeToElement(value));

    // ---- Bool ------------------------------------------------------------

    public bool GetBool(string key, bool def)
    {
        if (TryGet(key, out var el))
        {
            if (el.ValueKind == JsonValueKind.True) return true;
            if (el.ValueKind == JsonValueKind.False) return false;
        }
        return def;
    }

    public void SetBool(string key, bool value)
        => Set(key, JsonSerializer.SerializeToElement(value));

    // ---- Int -------------------------------------------------------------

    public int GetInt(string key, int def)
    {
        if (TryGet(key, out var el) && el.ValueKind == JsonValueKind.Number
            && el.TryGetInt32(out int i))
            return i;
        return def;
    }

    public void SetInt(string key, int value)
        => Set(key, JsonSerializer.SerializeToElement(value));

    // ---- String list -----------------------------------------------------

    public IReadOnlyList<string> GetStringList(string key, IReadOnlyList<string>? def = null)
    {
        if (TryGet(key, out var el) && el.ValueKind == JsonValueKind.Array)
        {
            var list = new List<string>(el.GetArrayLength());
            foreach (var item in el.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.String)
                    list.Add(item.GetString() ?? string.Empty);
            }
            return list;
        }
        return def ?? Array.Empty<string>();
    }

    public void SetStringList(string key, IEnumerable<string> value)
        => Set(key, JsonSerializer.SerializeToElement(new List<string>(value)));

    // ---- Reset -----------------------------------------------------------

    /// <summary>Wipes every persisted setting and deletes the JSON file (Reset All Settings).</summary>
    public void ResetAll()
    {
        lock (_gate)
        {
            // Closing the old process normally saves window placement and open tabs. Once reset
            // starts, suppress those shutdown writes so they cannot recreate the deleted file.
            _suppressWritesUntilExit = true;
            _data = new Dictionary<string, JsonElement>();
            try
            {
                if (File.Exists(_path)) File.Delete(_path);
                string tmp = _path + ".tmp";
                if (File.Exists(tmp)) File.Delete(tmp);
            }
            catch
            {
                // Ignore, the in-memory store is already cleared.
            }

            // The next launch finds no settings file and must not read that as "first run after the
            // rename" and import the old settings the reset just cleared. Leaving the marker to the
            // carry is not enough: on a machine where a store cannot be copied it is never written.
            WriteMarker(MigrationMarker);
        }
    }

    /// <summary>Invariant-culture parse helper for callers migrating legacy string values.</summary>
    internal static double ParseInvariant(string s, double def)
        => double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out double v) ? v : def;
}
