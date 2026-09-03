using System;
using System.Collections.Generic;
using System.Linq;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using XMLMacker.Shared;
using XMLMacker.Theme;

namespace XMLMacker.Windows;

/// <summary>
/// LEARN mode's embedded browser pane. A real Chromium browser
/// (<c>WebView2</c>) pinned to the nine chat/LLM sites that work when embedded. Logins persist
/// across relaunches via a fixed <c>UserDataFolder</c> under <c>%APPDATA%</c>. "Selection" /
/// "Element" TYPE a host-supplied prompt into the site's chat box via injected JavaScript
/// (never auto-sent) and ALWAYS copy the prompt to the clipboard as a fallback. "Folder" shows the
/// open file in File Explorer (to drag it into a chat) and "Copy File" copies the whole file. Selected chat + zoom
/// persist to settings; a graceful fallback UI shows if the WebView2 runtime is missing.
/// </summary>
public partial class LearnPane : UserControl
{
    // Settings keys.
    private const string ChatKey = "xml-macker.learnChat";
    private const string ZoomKey = "xml-macker.learnZoom";

    private const double ZoomMin = 0.5;
    private const double ZoomMax = 2.0;
    private const double ZoomStep = 0.1;

    // The nine embeddable chats, in picker order (rawValue == index).
    private static readonly (string Title, string Home)[] Chats =
    {
        ("ChatGPT",     "https://chatgpt.com/"),
        ("Claude",      "https://claude.ai/new"),
        ("Perplexity",  "https://www.perplexity.ai/"),
        ("Grok",        "https://grok.com/"),
        ("DeepSeek",    "https://chat.deepseek.com/"),
        ("Qwen",        "https://chat.qwen.ai/"),
        ("GLM (Z.ai)",  "https://chat.z.ai/"),
        ("Kimi",        "https://www.kimi.com/"),
        ("Manus",       "https://manus.im/"),
    };

    // The JS injected to TYPE the prompt (React native-setter + input event; execCommand fallback for
    // ProseMirror contenteditable). The {0} placeholder is the JSON array arg.
    private const string InjectTemplate =
        @"(function(arr){
    var t = arr[0];
    var el = document.querySelector('#prompt-textarea')
          || document.querySelector('div[contenteditable=""true""]')
          || document.querySelector('textarea');
    if (!el) return 'nofield';
    el.focus();
    if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
       var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
       var setter = Object.getOwnPropertyDescriptor(proto,'value').set;
       setter.call(el, (el.value ? el.value + '\n\n' : '') + t);
       el.dispatchEvent(new Event('input', {bubbles:true}));
    } else {
       document.execCommand('insertText', false, t);
    }
    return 'ok';
})({0})";

    /// <summary>The picker titles, in picker order (for the Settings window).</summary>
    public static IReadOnlyList<string> ChatTitles { get; } = Chats.Select(c => c.Title).ToArray();

    /// <summary>Selects a chat site as if it had been picked in the list (persists and navigates).</summary>
    public void SelectChat(int index)
    {
        if (index < 0 || index >= Chats.Length || Picker.SelectedIndex == index) return;
        Picker.SelectedIndex = index;   // OnChatChanged persists the choice and navigates
    }

    /// <summary>Index of the chat whose picker title equals <paramref name="title"/>, or -1 (e.g. Gemini is not embeddable).</summary>
    public static int ChatIndexFor(string title)
    {
        for (int i = 0; i < Chats.Length; i++)
            if (string.Equals(Chats[i].Title, title, StringComparison.OrdinalIgnoreCase)) return i;
        return -1;
    }

    private int _currentChat;
    private double _zoom = 1.0;
    private string? _pendingPrompt;
    private bool _initStarted;
    private bool _ready;
    private bool _isLoading;

    /// <summary>Status-bar messages (host shows in the main status line).</summary>
    public event Action<string>? OnStatus;

    /// <summary>Host builds the prompt from the current source selection (null + host beep if none).</summary>
    public Func<string?>? RequestSelectionPrompt { get; set; }

    /// <summary>Host builds the prompt from the selected tree element's XML.</summary>
    public Func<string?>? RequestElementPrompt { get; set; }

    /// <summary>Host shows the open file in File Explorer (ready to be dragged into the chat).</summary>
    public Action? OpenFolderRequested { get; set; }

    /// <summary>Host copies the whole open file to the clipboard.</summary>
    public Action? CopyWholeFileRequested { get; set; }

    public LearnPane()
    {
        InitializeComponent();

        Web.AllowExternalDrop = true;   // text dragged from the tree or the source pane lands in the chat box

        foreach (var c in Chats) Picker.Items.Add(c.Title);
        _currentChat = Math.Clamp(AppSettings.Instance.GetInt(ChatKey, 0), 0, Chats.Length - 1);
        Picker.SelectedIndex = _currentChat;

        Picker.SelectionChanged += OnChatChanged;
        BackBtn.Click += (_, _) => { if (_ready) Web.CoreWebView2?.GoBack(); };
        ForwardBtn.Click += (_, _) => { if (_ready) Web.CoreWebView2?.GoForward(); };
        ReloadBtn.Click += (_, _) => { if (_ready) Web.CoreWebView2?.Reload(); };
        ZoomInBtn.Click += (_, _) => ApplyZoom(_zoom + ZoomStep);
        ZoomOutBtn.Click += (_, _) => ApplyZoom(_zoom - ZoomStep);
        DefineSelectionBtn.Click += (_, _) => DefineFrom(RequestSelectionPrompt);
        DefineElementBtn.Click += (_, _) => DefineFrom(RequestElementPrompt);
        OpenFolderBtn.Click += (_, _) => OpenFolderRequested?.Invoke();
        CopyFileBtn.Click += (_, _) => CopyWholeFileRequested?.Invoke();

        ThemeManager.ThemeChanged += (_, _) => RebuildColors();

        Loaded += OnLoaded;
    }

    // ================= WebView2 init =================

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_initStarted) return;
        _initStarted = true;

        try
        {
            string udf = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "xml-macker", "WebView2");
            Directory.CreateDirectory(udf);

            var env = await CoreWebView2Environment.CreateAsync(null, udf);
            await Web.EnsureCoreWebView2Async(env);
        }
        catch
        {
            ShowFallback();
            return;
        }

        var core = Web.CoreWebView2;
        if (core == null) { ShowFallback(); return; }

        core.NavigationStarting += (_, _) => _isLoading = true;
        core.NavigationCompleted += OnNavigationCompleted;

        _zoom = Math.Clamp(AppSettings.Instance.GetDouble(ZoomKey, 1.0), ZoomMin, ZoomMax);
        if (_zoom > 0) Web.ZoomFactor = _zoom;

        _ready = true;
        Navigate(Chats[_currentChat].Home);
    }

    private void ShowFallback()
    {
        Web.Visibility = Visibility.Collapsed;
        FallbackPanel.Visibility = Visibility.Visible;
        OnStatus?.Invoke("WebView2 runtime is not installed, the embedded chat pane is unavailable.");
    }

    // ================= behaviors =================

    private void OnChatChanged(object sender, SelectionChangedEventArgs e)
    {
        int idx = Picker.SelectedIndex;
        if (idx < 0) return;
        _currentChat = idx;
        AppSettings.Instance.SetInt(ChatKey, idx);
        if (_ready) Navigate(Chats[idx].Home);
    }

    private void Navigate(string url)
    {
        try
        {
            _isLoading = true;
            Web.CoreWebView2?.Navigate(url);
        }
        catch
        {
            // Navigation is best-effort; the site itself surfaces any load error.
        }
    }

    private void ApplyZoom(double z)
    {
        _zoom = Math.Clamp(z, ZoomMin, ZoomMax);
        if (_ready) Web.ZoomFactor = _zoom;
        AppSettings.Instance.SetDouble(ZoomKey, _zoom);
    }

    private void DefineFrom(Func<string?>? provider)
    {
        string? prompt = provider?.Invoke();
        if (string.IsNullOrEmpty(prompt)) return;   // host already beeped when nothing is usable
        _ = InsertPrompt(prompt);
    }

    /// <summary>
    /// Share-menu entry point: switch to <paramref name="chat"/> and type <paramref name="prompt"/>.
    /// If the pane is not on that chat yet (or not mounted), navigate and defer the insert; if the
    /// page is still loading, defer; otherwise insert now.
    /// </summary>
    public void OpenAndInsert(int chat, string prompt)
    {
        chat = Math.Clamp(chat, 0, Chats.Length - 1);
        if (_currentChat != chat || !_ready)
        {
            _currentChat = chat;
            Picker.SelectedIndex = chat;
            _pendingPrompt = prompt;
            AppSettings.Instance.SetInt(ChatKey, chat);
            if (_ready) Navigate(Chats[chat].Home);
            return;
        }

        if (_isLoading) _pendingPrompt = prompt;
        else _ = InsertPrompt(prompt);
    }

    private void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        _isLoading = false;
        if (_pendingPrompt == null) return;

        // Chat SPAs render their input box late, wait 1.5 s before injecting.
        string p = _pendingPrompt;
        _pendingPrompt = null;
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
        t.Tick += (_, _) => { t.Stop(); _ = InsertPrompt(p); };
        t.Start();
    }

    // ================= JS injection =================

    /// <summary>
    /// Types <paramref name="prompt"/> into the site's chat box (never sends it) and always copies it
    /// to the clipboard as a fallback.
    /// </summary>
    public async Task InsertPrompt(string prompt)
    {
        // Always the fallback: clear + set the clipboard first.
        try { Clipboard.SetText(prompt); } catch { /* clipboard may be locked, non-fatal */ }

        string chatName = Chats[_currentChat].Title;

        string json;
        try { json = JsonSerializer.Serialize(new[] { prompt }); }
        catch
        {
            OnStatus?.Invoke("Copied, click the chat box and press Ctrl+V");
            return;
        }

        var core = Web.CoreWebView2;
        if (core == null)
        {
            OnStatus?.Invoke($"Couldn't find {chatName}'s chat box, click it and press Ctrl+V (text is copied)");
            return;
        }

        string js = InjectTemplate.Replace("{0}", json);
        try
        {
            string result = await core.ExecuteScriptAsync(js);
            // ExecuteScriptAsync returns a JSON-encoded value, e.g. "\"ok\"".
            string r = (result ?? "").Trim().Trim('"');
            if (r == "ok")
                OnStatus?.Invoke($"Typed into {chatName}, add your question, then press Enter");
            else
                OnStatus?.Invoke($"Couldn't find {chatName}'s chat box, click it and press Ctrl+V (text is copied)");
        }
        catch
        {
            OnStatus?.Invoke($"Couldn't find {chatName}'s chat box, click it and press Ctrl+V (text is copied)");
        }
    }

    // ================= theme =================

    /// <summary>Theme hook: only the LEARN title tint is code-owned (the web page owns its own colors).</summary>
    public void RebuildColors()
    {
        TitleLabel.Foreground = XMColor.Brush(XMColor.Text3);
    }
}
