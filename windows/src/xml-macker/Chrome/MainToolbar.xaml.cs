using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using XMLMacker.Theme;

namespace XMLMacker.Chrome;

/// <summary>
/// The top toolbar. Windows-labelled document actions sit beside compact Fluent icon buttons, a
/// 4-segment capsule Workspace switcher
/// (Edit/Inspect/Full/Learn, default <b>Full</b>), a DIFF text button, and a quick-search box
/// ("Search file…", fires on Enter). Every action raises a public event; the host wires them.
/// </summary>
public partial class MainToolbar : UserControl
{
    public IReadOnlyList<FrameworkElement> TourAnchors(string name) => name switch
    {
        "workspace" => new FrameworkElement[] { WsEdit, WsInspect, WsFull, WsLearn },
        "diff" => new FrameworkElement[] { DiffBtn },
        "search" => new FrameworkElement[] { SearchBox },
        "find" => new FrameworkElement[] { FindBtn },
        "highlight" => new FrameworkElement[] { HighlightBtn, HighlightMenuBtn, HighlightJumpBtn },
        "orbit" => new FrameworkElement[] { OrbitBtn },
        _ => Array.Empty<FrameworkElement>(),
    };
    private ToggleButton[] _segments = Array.Empty<ToggleButton>();

    // ── Events ─────────────────────────────────────────────────────────────────────────────
    public event EventHandler? OpenClicked;
    public event EventHandler? SaveClicked;
    public event EventHandler? CloseClicked;
    public event EventHandler? UndoClicked;
    public event EventHandler? RedoClicked;
    public event EventHandler? FindClicked;
    public event EventHandler? OrbitClicked;

    /// <summary>The highlighter button: marker on/off.</summary>
    public event EventHandler? HighlightClicked;

    /// <summary>The chevron beside it (or a right-click on the button): the colour menu.</summary>
    public event EventHandler? HighlightMenuRequested;

    /// <summary>The arrow beside it: +1 next mark, −1 previous (Shift+click).</summary>
    public event EventHandler<int>? HighlightJumpClicked;
    public event EventHandler? DiffClicked;

    /// <summary>Raised when a Workspace segment is chosen; carries 0=Edit,1=Inspect,2=Full,3=Learn.</summary>
    public event EventHandler<int>? WorkspaceChanged;

    /// <summary>Raised on Enter in the quick-search box; carries the current query text.</summary>
    public event EventHandler<string>? QuickSearch;

    public MainToolbar()
    {
        InitializeComponent();
        _segments = new[] { WsEdit, WsInspect, WsFull, WsLearn };
        SetSegmentChecked(2); // default: Full
        UpdateSearchHint();
        SetDocumentCommandState(documentReady: false, canUndo: false, canRedo: false);
    }

    /// <summary>
    /// Updates every command whose availability depends on an open document. Disabled buttons use
    /// the toolbar's gray Windows state instead of appearing clickable and then doing nothing.
    /// </summary>
    public void SetDocumentCommandState(bool documentReady, bool canUndo, bool canRedo)
    {
        SaveBtn.IsEnabled = documentReady;
        CloseBtn.IsEnabled = documentReady;
        UndoBtn.IsEnabled = documentReady && canUndo;
        RedoBtn.IsEnabled = documentReady && canRedo;
        FindBtn.IsEnabled = documentReady;
        HighlightBtn.IsEnabled = HighlightMenuBtn.IsEnabled = HighlightJumpBtn.IsEnabled = documentReady;
        SearchBox.IsEnabled = documentReady;
        OrbitBtn.IsEnabled = documentReady;
        DiffBtn.IsEnabled = true;   // the comparison picker works with nothing open (Browse on both sides)
    }

    // ── Workspace segment sync ───────────────────────────────────────────────────────────────

    /// <summary>
    /// The selected Workspace segment (0..3). Assignment updates the capsule without raising
    /// <see cref="WorkspaceChanged"/> (external sync path).
    /// </summary>
    public int WorkspaceSegment
    {
        get
        {
            for (int i = 0; i < _segments.Length; i++)
                if (_segments[i].IsChecked == true) return i;
            return 2;
        }
        set => SetSegmentChecked(value);
    }

    private void SetSegmentChecked(int index)
    {
        for (int i = 0; i < _segments.Length; i++)
            _segments[i].IsChecked = i == index;
    }

    private void Workspace_Click(object sender, RoutedEventArgs e)
    {
        int index = Array.IndexOf(_segments, (ToggleButton)sender);
        if (index < 0) index = 2;
        SetSegmentChecked(index); // selectOne: keep exactly one checked (can't un-check the active one)
        WorkspaceChanged?.Invoke(this, index);
    }

    // ── Quick search ─────────────────────────────────────────────────────────────────────────

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e) => UpdateSearchHint();

    private void UpdateSearchHint()
        => SearchHint.Visibility = string.IsNullOrEmpty(SearchBox.Text)
            ? Visibility.Visible
            : Visibility.Collapsed;

    private void SearchBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            QuickSearch?.Invoke(this, SearchBox.Text);
            e.Handled = true;
        }
    }

    // ── Icon button click handlers ───────────────────────────────────────────────────────────
    private void Open_Click(object sender, RoutedEventArgs e) => OpenClicked?.Invoke(this, EventArgs.Empty);
    private void Save_Click(object sender, RoutedEventArgs e) => SaveClicked?.Invoke(this, EventArgs.Empty);
    private void Close_Click(object sender, RoutedEventArgs e) => CloseClicked?.Invoke(this, EventArgs.Empty);
    private void Undo_Click(object sender, RoutedEventArgs e) => UndoClicked?.Invoke(this, EventArgs.Empty);
    private void Redo_Click(object sender, RoutedEventArgs e) => RedoClicked?.Invoke(this, EventArgs.Empty);
    private void Find_Click(object sender, RoutedEventArgs e) => FindClicked?.Invoke(this, EventArgs.Empty);
    private void Orbit_Click(object sender, RoutedEventArgs e) => OrbitClicked?.Invoke(this, EventArgs.Empty);
    private void Highlight_Click(object sender, RoutedEventArgs e) => HighlightClicked?.Invoke(this, EventArgs.Empty);
    private void HighlightMenu_Click(object sender, RoutedEventArgs e) { HighlightMenuRequested?.Invoke(this, EventArgs.Empty); e.Handled = true; }

    /// <summary>Lights the highlighter button while the marker is on.</summary>
    public void SetHighlighterActive(bool on)
    {
        if (on)
        {
            Color accent = XMColor.Color(XMColor.Accent);
            HighlightBtn.Background = new SolidColorBrush(Color.FromArgb(0x3C, accent.R, accent.G, accent.B));
        }
        else HighlightBtn.Background = Brushes.Transparent;
    }
    private void HighlightJump_Click(object sender, RoutedEventArgs e)
        => HighlightJumpClicked?.Invoke(this, (Keyboard.Modifiers & ModifierKeys.Shift) != 0 ? -1 : +1);

    /// <summary>Colours the highlighter icon with the colour Ctrl+H will use (null = plain icon).</summary>
    public void SetHighlightSwatch(Color? colour)
    {
        if (colour is { } c) HighlightBtn.Foreground = new SolidColorBrush(c);
        else HighlightBtn.SetResourceReference(Control.ForegroundProperty, "XM.text2");
    }

    /// <summary>Where the colour menu opens from.</summary>
    public FrameworkElement HighlightAnchor => HighlightBtn;
    private void Diff_Click(object sender, RoutedEventArgs e) => DiffClicked?.Invoke(this, EventArgs.Empty);
}
