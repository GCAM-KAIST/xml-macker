using System.Collections.Generic;
using System.Globalization;
using System.IO;
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

    private void MigrateLegacyStore(string appData)
    {
        try
        {
            if (File.Exists(_path)) return;

            string legacyDir = Path.Combine(appData, LegacyDirName);
            string legacyPath = Path.Combine(legacyDir, "settings.json");
            if (!File.Exists(legacyPath)) return;

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

            string legacyHighlights = Path.Combine(legacyDir, "highlights");
            string currentHighlights = Path.Combine(_dir, "highlights");
            if (Directory.Exists(legacyHighlights) && !Directory.Exists(currentHighlights))
                CopyDirectory(legacyHighlights, currentHighlights);
        }
        catch
        {
            // Ignore migration failures and fall back to a clean store.
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
        }
    }

    /// <summary>Invariant-culture parse helper for callers migrating legacy string values.</summary>
    internal static double ParseInvariant(string s, double def)
        => double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out double v) ? v : def;
}
