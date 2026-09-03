using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using XMLMacker.Charts;
using XMLMacker.Chrome;
using XMLMacker.Core;
using XMLMacker.Editor;
using XMLMacker.Panes;
using XMLMacker.Shared;
using XMLMacker.Theme;
using XMLMacker.Windows;
using ThemeDef = XMLMacker.Theme.Theme;

namespace XMLMacker.App;

/// <summary>
/// The application shell, the WPF port of the Swift <c>MainWindowController</c> +
/// <c>AppDelegate</c> menu bar. Owns the
/// seven panes, the nested split layout (via <see cref="SplitLayoutManager"/>), the tab lifecycle,
/// file loading, save/diff/validation/share, global &amp; per-pane zoom, theme broadcast, workspace
/// modes, RStudio layout, and pane show/hide/minimize/maximize/pop-out. Split across partials:
/// <c>MainWindow.Files.cs</c> (load/save/tabs), <c>MainWindow.Sync.cs</c> (validation/find/context),
/// <c>MainWindow.Panes.cs</c> (layout/workspace/zoom), <c>MainWindow.Actions.cs</c> (diff/orbit/share).
/// </summary>
public partial class MainWindow : Window
{
    // ── Persisted-settings keys ────────────────────────────────────────────
    private const string WorkspaceModeKey = "xml-macker.workspaceMode";
    private const string CloseChoiceKey = "xml-macker.closeWindowChoice";
    private const string TourShownKey = "xml-macker.tourShown";
    private const string PopoutsFloatKey = "xml-macker.popoutsFloat";
    private const string LayoutTreeRightKey = "xml-macker.layout.treeOnRight";
    private const string LayoutInspectorLeftKey = "xml-macker.layout.inspectorOnLeft";
    private const string LayoutHierarchyTopKey = "xml-macker.layout.hierarchyOnTop";
    private const string LastOpenFilesKey = "xml-macker.lastOpenFiles";
    private const string ReopenLastFilesKey = "xml-macker.reopenLastFiles";
    private const string MainPlacementKey = "xml-mackerMainWindow";

    // ── Pane titles / registry keys ────────────────────────────────────────────────────────────
    private const string PaneTree = "Tree";
    private const string PaneSource = "Source";
    private const string PaneInspector = "Inspector";
    private const string PaneChart = "Chart";
    private const string PanePreview = "Preview";
    private const string PaneSubtags = "Subtags";
    private const string PaneHierarchy = "Hierarchy";
    private const string PaneLearn = "Learn";
    private const string PaneMinimap = "Minimap";
    private const string PaneDetails = "Details";
    // Chromeless nested-split container "panes" (never shown in menus except the inspector column).
    private const string ContainerRight = "__rightColumn";
    private const string ContainerTopRow = "__topRow";
    private const string ContainerInspectorCol = "__inspectorColumn";

    private static readonly string[] MenuPaneTitles =
        { PaneTree, PaneSource, PaneDetails, PaneSubtags, PaneHierarchy, PaneMinimap };

    /// <summary>Workspace modes (Swift <c>WorkspaceMode</c>).</summary>
    private enum WorkspaceMode { Edit = 0, Inspect = 1, Full = 2, Learn = 3 }

    /// <summary>Per-run remembered answer to the "unsaved changes when sharing" alert.</summary>
    private enum ShareUnsavedChoice { SaveFirst, ShareDisk }

    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    // ── Child pane controls ────────────────────────────────────────────────────────────────────
    private SourceEditorControl _source = null!;
    private TreePaneControl _tree = null!;
    private InspectorPaneControl _inspector = null!;
    private SubtagsBarControl _subtags = null!;
    private HierarchyBarControl _hierarchy = null!;
    private PreviewPaneControl _preview = null!;
    private ChartPaneControl _chart = null!;
    private ErrorsPaneControl _errors = null!;
    private DetailsRailControl _detailsRail = null!;
    private LearnPane? _learn;

    // ── Layout engine + chrome per pane ─────────────────────────────────────────────────────────
    private readonly SplitLayoutManager _split = new();
    private readonly Dictionary<string, PaneChrome> _chromes = new();
    private readonly Dictionary<string, FrameworkElement> _glasses = new();
    private Grid _mainGrid = null!, _rootVGrid = null!, _topHGrid = null!, _inspectorColGrid = null!;
    private SplitGroup _gMain = null!, _gRootV = null!, _gTopH = null!, _gInspectorCol = null!;

    // ── Status bar progress ──────────────────────────────────────────────────────────────────────
    private ProgressFill _progress = null!;

    // ── Parse / load state ─────────────────────────────────────────────────────────────────────
    private volatile XmlStreamParser? _activeParser;
    private volatile int _totalLines;
    private DocumentSession? _loadingSession;
    private DocumentSession? _pendingDiffLeft;
    private readonly Queue<(string Path, bool ForceReload)> _openQueue = new();
    private readonly HashSet<Guid> _savingSessionIds = new();
    private bool _openBusy;

    // ── File / tab state ───────────────────────────────────────────────────────────────────────
    private readonly List<DocumentSession> _sessions = new();
    private int _activeIdx = -1;
    private string? _currentFileUrl;
    private XmlTreeNode? _currentTree;
    private XmlTreeNode? _currentSelectedNode;
    private bool _docDirty;
    private ulong _activeEditRevision;
    private IReadOnlyList<ParseError> _lastParseErrors = Array.Empty<ParseError>();

    // ── Validation debounce ────────────────────────────────────────────────────────────────────
    private DispatcherTimer _validateTimer = null!;
    private long _validationRequestId;

    // ── Secondary windows / panels ──────────────────────────────────────────────────────────────
    private ValidationWindow? _validationWindow;
    private ChartPopoutWindow? _chartPopout;
    private FindPanel? _findPanel;
    private OrbitWindow? _orbitWindow;
    private TourWindow? _tourWindow;

    // ── Pop-out pane windows (keyed by pane title) ────────────────────────────────────────────────
    private readonly Dictionary<string, Window> _popouts = new();

    // ── Workspace / quick-search / share ──────────────────────────────────────────────────────────
    private WorkspaceMode _workspaceMode = WorkspaceMode.Full;
    private (int Start, int Length)? _quickSearchLast;
    private ShareUnsavedChoice? _rememberedShareChoice;

    // ── AppDelegate service + single instance ─────────────────────────────────────────────────────
    private AppDelegateService _appDelegate = null!;
    private SingleInstance? _singleInstance;

    // ── Menu item references (for CanExecute / IsChecked validation) ─────────────────────────
    private MenuItem _recentMenu = null!;
    private MenuItem _miSave = null!, _miSaveAs = null!, _miRevert = null!, _miCloseFile = null!;
    private MenuItem _miReveal = null!, _miCopyPath = null!, _miGoToLine = null!;
    private MenuItem _miUndo = null!, _miRedo = null!;
    private MenuItem _miLineNumbers = null!, _miMinimap = null!, _miPopoutsFloat = null!, _miReopenFiles = null!, _miMaxRestore = null!;
    private MenuItem _miWsEdit = null!, _miWsInspect = null!, _miWsFull = null!, _miWsLearn = null!;
    private MenuItem _miThemeAurora = null!, _miThemeLight = null!, _miThemeOneDark = null!;
    private MenuItem _miThemeSolarized = null!, _miThemeDracula = null!, _miThemeHacker = null!;
    private MenuItem _miLayTreeLeft = null!, _miLayTreeRight = null!;
    private MenuItem _miLayInspRight = null!, _miLayInspLeft = null!;
    private MenuItem _miLayHierBottom = null!, _miLayHierTop = null!;
    private readonly Dictionary<string, MenuItem> _showItems = new();
    private readonly Dictionary<string, MenuItem> _hideItems = new();

    private bool _suppressZoom;
    private bool _zoomReady;   // guards the initial XAML-driven Slider.ValueChanged (before widgets exist)

    public MainWindow()
    {
        InitializeComponent();

        // Initial size from the screen work area (max(900,visW) × max(640,visH)).
        var wa = SystemParameters.WorkArea;
        Width = Math.Max(900, wa.Width);
        Height = Math.Max(640, wa.Height);
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        _progress = new ProgressFill(ProgressRect, () => StatusBarGrid.ActualWidth);
        _appDelegate = new AppDelegateService(LoadFile);

        _validateTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(450) };
        _validateTimer.Tick += (_, _) => { _validateTimer.Stop(); Revalidate(); };

        CreateChildControls();
        BuildPaneLayout();     // MainWindow.Panes.cs
        BuildMenuBar();
        WireChrome();
        WireToolbar();
        WireTabStrip();
        WireBreadcrumb();
        InstallKeyBindings();

        ApplyProgressColor();
        ApplyChromeMetrics();
        SyncZoomWidgetToScale();
        _zoomReady = true;

        ThemeManager.ThemeChanged += OnThemeChanged;
        MetricsScaleService.Instance.RebuildFonts += OnRebuildFonts;
        // Ctrl + wheel zooms the pane under the pointer only (Ctrl +/- are the View menu shortcuts and
        // zoom the focused pane); the slider at the bottom right is the whole-app zoom.
        ZoomGestures.AttachWheel(this, src => ZoomPaneUnder(src, +1), src => ZoomPaneUnder(src, -1));
        _split.PaneStateChanged += (_, _) => ScheduleMenuRefresh();

        Title = AppTitle();

        Acrylic.Apply(this, ThemeManager.Active.IsDark);

        Loaded += OnWindowLoaded;
        SourceInitialized += (_, _) => WindowPlacement.Restore(this, MainPlacementKey);
        Closing += OnWindowClosing;
        Closed += OnWindowClosed;
        DragOver += OnDragOver;
        Drop += OnDrop;
    }

    // ── Version / titles ────────────────────────────────────────────────────────────────────────

    private static string AppVersion
    {
        get
        {
            Version? v = typeof(MainWindow).Assembly.GetName().Version;
            return v is null ? "1.0" : $"{v.Major}.{v.Minor}.{v.Build}";
        }
    }

    private static string AppTitle() => $"xml-macker v{AppVersion}";
    private static string FileTitle(string name) => $"{name}, xml-macker v{AppVersion}";

    private static string FileNameOf(string? url)
    {
        if (string.IsNullOrEmpty(url)) return "document";
        try { return System.IO.Path.GetFileName(url); }
        catch { return url!; }
    }

    // ── Child controls + callback wiring ────────────────────────────────────────────────

    private void CreateChildControls()
    {
        _source = new SourceEditorControl();
        _tree = new TreePaneControl();
        _inspector = new InspectorPaneControl();
        _subtags = new SubtagsBarControl();
        _hierarchy = new HierarchyBarControl();
        _preview = new PreviewPaneControl();
        _chart = new ChartPaneControl();
        _errors = new ErrorsPaneControl();
        _detailsRail = new DetailsRailControl(_inspector, _chart, _preview, _errors);

        _tree.OnSelectNode += HandleTreeSelection;
        _tree.OnContextAction += (action, node) => HandleTreeContext(node, action);
        _tree.ResolveLinkedFile = node => LinkedFile.Resolve(node, _currentFileUrl);
        // Dragging a tree row hands the element's XML to whatever it is dropped on (the source pane,
        // the LEARN chat page, another program); 2 million characters is the ceiling.
        _tree.DragTextForNode = node => ElementText(node, 2_000_000, announce: false)?.Text;

        _source.SourceChanged += (_, _) => HandleSourceEdited();
        _source.DocumentMutated += (_, _) =>
        {
            MarkDirty();
            ScheduleMenuRefresh();
        };
        _source.Editor.UndoRedoApplied += (_, _) =>
        {
            SetStatus("Checking XML…");
            Revalidate();
            ReparseFromEditor();
            ScheduleMenuRefresh();
        };
        _source.SelectionChanged += (_, _) => { UpdateLearnChip(); ScheduleLaneFollow(); };
        _source.FileLoaded += (_, _) => OnSourceFileLoaded();
        _source.FileLoadFailed += OnSourceFileLoadFailed;
        _source.LinkedFileRequested += path => LoadFile(path);
        _source.DefineSelectionRequested += DefineSelectionInLearn;
        _source.PrintSelectionRequested += SharePrintSelection;
        _source.SendSelectionRequested += target => ShareToLLM(target, "selection");
        _source.MinimapVisibilityChanged += visible =>
        {
            ValidateMenus();
            SetStatus(visible
                ? "Minimap shown"
                : "Minimap hidden, View menu, Show Minimap, or Ctrl+Shift+M brings it back");
        };
        _source.Editor.DragDropStatus += SetStatus;
        _source.Minimap.LineClicked += OnMinimapLineClicked;
        _source.Minimap.ExactLineClicked += line => _source.ScrollToLine(line);

        _inspector.OnAttributeEdit += HandleAttributeEdit;
        _inspector.OnTextEdit += HandleTextEdit;
        _subtags.OnSubtagPreview += n => _source.ShowElement(n);   // highlight only, no tree select
        _subtags.OnSubtagSelected += n => _tree.Select(n, expandAncestors: true);
        _subtags.OnGoUp += HandleSubtagGoUp;
        _subtags.OnAttributeEdit += HandleAttributeEdit;
        _subtags.OnTextEdit += HandleTextEdit;
        _subtags.OnTagRename += HandleTagRename;

        _hierarchy.OnChildClicked += n => _tree.Select(n, expandAncestors: true);

        _chart.ExposedTrendView.PopoutRequested += OpenChartPopout;
        _chart.ExposedTrendView.BuildRequested += OpenChartBuilder;
        _chart.SeriesChanged += series =>
        {
            if (_chartPopout is null) return;
            string path = _currentSelectedNode is not null ? TreePath(_currentSelectedNode) : "";
            _chartPopout.SetMirroredSeries(series, path, _currentSelectedNode, _currentTree);
        };

        _preview.ErrorClicked += (line, _) => _source.ScrollToLine(line);
        _preview.FixClicked += ApplyLintFix;
        _errors.ErrorClicked += (line, _) => _source.ScrollToLine(line);
        _errors.FixClicked += ApplyLintFix;
        _errors.ErrorCountChanged += _detailsRail.SetErrorCount;
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Central selection sync hub
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void HandleTreeSelection(XmlTreeNode node)
    {
        _currentSelectedNode = node;

        _source.RefreshAttributes(node);
        _source.RefreshTextValue(node);
        foreach (XmlTreeNode child in node.Children)
        {
            if (child.Kind != NodeKind.Element) continue;
            _source.RefreshAttributes(child);
            _source.RefreshTextValue(child);
        }

        _inspector.SetNode(node);
        _chart.SetNode(node);
        _subtags.SetNode(node);
        _hierarchy.SetNode(node);

        _source.Minimap.SetSnapLines(CollectLocalSnapLines(node));
        _source.ShowElement(node);                    // scroll + highlight in source editor

        Breadcrumb.SetPath(node);

        UpdatePreviewFor(node);

        if (_orbitWindow is { IsVisible: true }) _orbitWindow.SetNode(node);

        ScheduleAutoValidation();
    }

    private void UpdatePreviewFor(XmlTreeNode? node)
    {
        if (node is not null && _source.CharRangeForElement(node) is { } r)
        {
            (string text, bool truncated) = _source.Substring(r, 1_000_000);
            _preview.SetPreviewText(text, truncated);
        }
        else
        {
            _preview.SetPreviewText("", false);
        }
    }

    private void HandleSourceEdited()
    {
        if (_currentSelectedNode is not { } node) return;
        if (_inspector.IsEditingCell) return;

        _source.RefreshAttributes(node);
        _source.RefreshTextValue(node);
        foreach (XmlTreeNode child in node.Children)
        {
            if (child.Kind != NodeKind.Element) continue;
            _source.RefreshAttributes(child);
            _source.RefreshTextValue(child);
        }

        _inspector.RefreshValuesOnly();
        _subtags.RefreshValuesOnly();
        _tree.RefreshNode(node);

        UpdatePreviewFor(node);
        ScheduleAutoValidation();
    }

    /// <summary>Shared attribute-edit fan-out for inspector + subtags.</summary>
    private void HandleAttributeEdit(XmlTreeNode node, string attrName, string newValue)
    {
        if (_source.ApplyAttrEdit(node, attrName, newValue))
        {
            _tree.RefreshNode(node);
            _inspector.RefreshValuesOnly();
            _subtags.RefreshValuesOnly();
            _chart.RefreshCurrent();
            ScheduleAutoValidation();
        }
        else
        {
            NativeMethods.Beep();
        }
    }

    private void HandleTextEdit(XmlTreeNode node, string newText)
    {
        if (_source.ApplyTextEdit(node, newText))
        {
            _tree.RefreshNode(node);
            _inspector.RefreshValuesOnly();
            _subtags.RefreshValuesOnly();
            _chart.RefreshCurrent();
            ScheduleAutoValidation();
        }
        else
        {
            NativeMethods.Beep();
        }
    }

    private void HandleSubtagGoUp()
    {
        if (_currentSelectedNode?.Parent is { Kind: NodeKind.Element } parent)
            _tree.Select(parent, expandAncestors: true);
    }

    private void OnMinimapLineClicked(int line)
    {
        // Two silent no-ops used to make the left lane feel dead: a click outside the root element
        // resolved to no node at all, and a click that resolved to the ALREADY selected node assigned
        // the same ListBox row, which raises no SelectionChanged, so nothing moved. Both now scroll.
        if (_currentTree is null) { _source.ScrollToLine(line); return; }

        XmlTreeNode? hit = FindDeepestNode(line, _currentTree);
        if (hit is null) { _source.ScrollToLine(line); return; }

        bool same = ReferenceEquals(hit, _currentSelectedNode);
        _tree.Select(hit, expandAncestors: true);
        if (same) _source.ShowElement(hit);   // only when Select raised no event, no double scroll
    }

    private void MarkDirty()
    {
        _activeEditRevision++;
        if (ActiveSession is { } session) session.EditRevision = _activeEditRevision;
        if (_docDirty) return;
        _docDirty = true;
        RefreshTabStrip();
    }

    private void ScheduleAutoValidation()
    {
        _validateTimer.Stop();
        _validateTimer.Start();
    }

    // ── Minimap lane follows the caret ──────────────────────────────────────────────────────────
    // The left lane used to change level only when the TREE was clicked; clicking into the source text
    // left it on whatever level was last selected in the tree. A short debounce keeps this cheap while
    // the caret is moving, and the sync never selects in the tree, so it cannot feed back on itself.
    private DispatcherTimer? _laneFollowTimer;
    private XmlTreeNode? _laneNode;

    private void ScheduleLaneFollow()
    {
        _laneFollowTimer ??= new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(180) };
        _laneFollowTimer.Tick -= LaneFollowTick;
        _laneFollowTimer.Tick += LaneFollowTick;
        _laneFollowTimer.Stop();
        _laneFollowTimer.Start();
    }

    private void LaneFollowTick(object? sender, EventArgs e)
    {
        _laneFollowTimer?.Stop();
        if (_currentTree is null || ActiveSession is not { IsLoading: false }) return;
        int line = _source.LineNumberForOffset(_source.Editor.SelectionStart);
        XmlTreeNode? node = FastDeepestNode(line, _currentTree);
        if (node is null || node.Kind != NodeKind.Element || ReferenceEquals(node, _laneNode)) return;
        _laneNode = node;
        _source.Minimap.SetSnapLines(CollectLocalSnapLines(node));
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Window lifecycle
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void OnWindowLoaded(object sender, RoutedEventArgs e)
    {
        SetupSingleInstance();

        // A second launch forwards its file path to the running instance, then exits.
        if (_singleInstance is { IsFirstInstance: false })
        {
            string? forward = App.PendingOpenPath;
            if (!string.IsNullOrEmpty(forward)) SingleInstance.SignalFirstInstance(forward!);
            _quitting = true;
            Close();
            return;
        }

        // Give the grids a real size before the first proportional solve.
        Dispatcher.BeginInvoke(new Action(() =>
        {
            _split.LayoutAll();
            ApplyPaneLayout();
            int savedMode = AppSettings.Instance.GetInt(WorkspaceModeKey, (int)WorkspaceMode.Full);
            ApplyWorkspace((WorkspaceMode)Math.Clamp(savedMode, 0, 3), save: false);
            _split.ApplySavedMinimizedPanes();

            string? pending = _appDelegate.ConsumePendingOpenPath();
            if (!string.IsNullOrEmpty(pending)) LoadFile(pending!);
            else if (ReopenFilesAtLaunch)
            {
                List<string> previousFiles = AppSettings.Instance.GetStringList(LastOpenFilesKey)
                    .Where(u => File.Exists(u) && !IsUntitled(u))
                    .ToList();
                if (previousFiles.Count > 0) OpenFiles(previousFiles);
                else ShowEmptyState();
            }
            else ShowEmptyState();

            if (!AppSettings.Instance.GetBool(TourShownKey, false))
            {
                var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.2) };
                timer.Tick += (_, _) => { timer.Stop(); ShowTour(); };
                timer.Start();
            }
        }), DispatcherPriority.Loaded);
    }

    private void SetupSingleInstance()
    {
        try
        {
            _singleInstance = new SingleInstance();
            _singleInstance.StartServer();
            _appDelegate.WireSingleInstance(_singleInstance, Dispatcher);
        }
        catch
        {
            _singleInstance = null;   // single-instance arbitration is best-effort
        }
    }

    private void OnWindowClosed(object? sender, EventArgs e)
    {
        // A secondary process must not erase the first instance's remembered session.
        if (_singleInstance is not { IsFirstInstance: false })
        {
            IEnumerable<string> openPaths = _sessions.Select(s => s.Url).Where(u => File.Exists(u) && !IsUntitled(u));
            AppSettings.Instance.SetStringList(LastOpenFilesKey, openPaths);
            foreach (DocumentSession s in _sessions) SaveHighlights(s);
            foreach (DocumentSession s in _sessions) DeleteScratchIfUntitled(s.Url);
        }

        WindowPlacement.Save(this, MainPlacementKey);

        // Take every satellite window down with the main window.
        // Clear the registry FIRST so each Closed handler's dock-back path is skipped during shutdown.
        List<Window> satellites = _popouts.Values.ToList();
        _popouts.Clear();
        foreach (Window w in satellites)
        {
            try { w.Close(); } catch { /* ignore */ }
        }
        try { _chartPopout?.Close(); } catch { }
        try { _validationWindow?.Close(); } catch { }
        try { _findPanel?.Close(); } catch { }
        try { _orbitWindow?.Close(); } catch { }

        _singleInstance?.Dispose();
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetData(DataFormats.FileDrop) is string[] files &&
                    XmlDocumentSupport.CanonicalFiles(files).Any(XmlDocumentSupport.IsLikelyXml)
            ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files)
            OpenFiles(files);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Global zoom (status-bar slider)
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private static double ScaleForSlider(double v)
    {
        double t = Math.Clamp(v, 0, 100) / 100.0;
        return Math.Pow(2, (t - 0.5) * 2);   // 0→0.5, 50→1.0, 100→2.0
    }

    private static double SliderValueForScale(double scale)
    {
        double s = Math.Clamp(scale, 0.5, 2.0);
        return (Math.Log2(s) + 1) / 2 * 100;
    }

    private void SyncZoomWidgetToScale()
    {
        _suppressZoom = true;
        ZoomSlider.Value = SliderValueForScale(XMFont.GlobalScale);
        _suppressZoom = false;
        ZoomPercentLabel.Text = Math.Round(XMFont.GlobalScale * 100).ToString(Inv) + "%";
    }

    private void ApplyGlobalScale(double scale)
    {
        double s = Math.Clamp(scale, 0.5, 2.0);
        MetricsScaleService.Instance.Scale = s;   // sets XMFont.GlobalScale, persists, fires RebuildFonts
        ZoomPercentLabel.Text = Math.Round(s * 100).ToString(Inv) + "%";
        _split.LayoutAll();
    }

    private void ZoomSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_suppressZoom || !_zoomReady) return;
        ApplyGlobalScale(ScaleForSlider(ZoomSlider.Value));
    }

    private void ZoomMinus_Click(object sender, RoutedEventArgs e)
    {
        double next = Math.Max(0.5, XMFont.GlobalScale / 1.1);
        _suppressZoom = true; ZoomSlider.Value = SliderValueForScale(next); _suppressZoom = false;
        ApplyGlobalScale(next);
    }

    private void ZoomPlus_Click(object sender, RoutedEventArgs e)
    {
        double next = Math.Min(2.0, XMFont.GlobalScale * 1.1);
        _suppressZoom = true; ZoomSlider.Value = SliderValueForScale(next); _suppressZoom = false;
        ApplyGlobalScale(next);
    }

    private void ZoomReset_Click(object sender, RoutedEventArgs e)
    {
        _suppressZoom = true; ZoomSlider.Value = SliderValueForScale(MetricsScaleService.DefaultScale); _suppressZoom = false;
        ApplyGlobalScale(MetricsScaleService.DefaultScale);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Theme + chrome metrics broadcast
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void ApplyTheme(ThemeDef theme) => ThemeManager.Select(theme);   // fires ThemeChanged → OnThemeChanged

    private void OnThemeChanged(object? sender, EventArgs e)
    {
        IntPtr hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd != IntPtr.Zero) NativeMethods.TrySetDarkMode(hwnd, ThemeManager.Active.IsDark);

        ApplyProgressColor();
        _source.RebuildColors();
        _preview.RebuildColors();
        _chart.RebuildColors();
        _orbitWindow?.RebuildColors();
        _hierarchy.SetNode(_currentSelectedNode);   // repaint the flame map with new colors
    }

    private void OnRebuildFonts(object? sender, EventArgs e)
    {
        ApplyChromeMetrics();
        _split.LayoutAll();
        // The zoom may have been changed from any window (Ctrl + wheel in the Diff, Orbit, a pop-out...):
        // keep the slider and the percentage at the bottom right telling the truth.
        _suppressZoom = true;
        ZoomSlider.Value = SliderValueForScale(XMFont.GlobalScale);
        _suppressZoom = false;
        ZoomPercentLabel.Text = Math.Round(XMFont.GlobalScale * 100).ToString(Inv) + "%";
    }

    private void ApplyChromeMetrics()
    {
        Breadcrumb.Height = XMMetric.S(XMMetric.BreadcrumbH);
        StatusBarGrid.Height = XMMetric.S(XMMetric.StatusBarH);
    }

    private void ApplyProgressColor()
    {
        Color accent = XMColor.Color(XMColor.Accent);
        ProgressRect.Fill = new SolidColorBrush(Color.FromArgb((byte)Math.Round(0.28 * 255), accent.R, accent.G, accent.B));
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Chrome wiring (pane traffic-light callbacks)
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void WireChrome()
    {
        foreach ((string title, PaneChrome chrome) in _chromes)
        {
            string key = title;
            chrome.Closed += (_, _) => _split.TogglePane(key);
            chrome.Minimized += (_, _) => _split.ToggleMinimize(key);
            chrome.Maximized += (_, _) => _split.ToggleMaximize(key);
            chrome.PoppedOut += (_, _) => TogglePopOut(key);
        }
    }

    private void WireToolbar()
    {
        Toolbar.OpenClicked += (_, _) => _appDelegate.OpenFile(this);
        Toolbar.SaveClicked += (_, _) => MenuSave();
        Toolbar.CloseClicked += (_, _) => CloseCurrentFile();
        Toolbar.UndoClicked += (_, _) => DoUndo();
        Toolbar.RedoClicked += (_, _) => DoRedo();
        Toolbar.FindClicked += (_, _) => PresentFindReplace(null, focusReplace: false);
        Toolbar.OrbitClicked += (_, _) => OpenOrbit();
        Toolbar.DiffClicked += (_, _) => StartDiff();
        Toolbar.WorkspaceChanged += (_, mode) => ApplyWorkspace((WorkspaceMode)mode, save: true);
        Toolbar.QuickSearch += (_, text) => QuickSearch(text);
    }

    private void WireTabStrip()
    {
        TabStrip.TabSelected += (_, i) => SwitchToTab(i);
        InitHighlights();
        TabStrip.TabCloseRequested += (_, i) => CloseTab(i);
        TabStrip.TabCloseOthersRequested += (_, i) => CloseOtherTabs(i);
        TabStrip.TabRevealRequested += (_, i) =>
        {
            if (i < 0 || i >= _sessions.Count || IsUntitled(_sessions[i].Url)) { NativeMethods.Beep(); return; }
            NativeMethods.RevealInExplorer(_sessions[i].Url);
        };
        TabStrip.PlusClicked += (_, _) => NewBlankDocument();   // "+" = a new blank document (Open is Ctrl+O)
    }

    private void WireBreadcrumb()
    {
        Breadcrumb.OnSegmentClicked += n => _tree.Select(n, expandAncestors: true);
    }

    private void DoUndo()
        => _source.Editor.Undo();

    private void DoRedo()
        => _source.Editor.Redo();

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Full menu bar
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private static MenuItem MI(string header, string? gesture = null, RoutedEventHandler? click = null)
    {
        var mi = new MenuItem { Header = header };
        if (gesture is not null) mi.InputGestureText = gesture;
        if (click is not null) mi.Click += click;
        return mi;
    }

    private void BuildMenuBar()
    {
        // ── File ────────────────────────────────────────────────────────────────────────────────
        var file = MI("_File");
        file.SubmenuOpened += (_, _) => ValidateMenus();
        file.Items.Add(MI("New", "Ctrl+N", (_, _) => NewBlankDocument()));
        file.Items.Add(MI("Open…", "Ctrl+O", (_, _) => _appDelegate.OpenFile(this)));
        _recentMenu = MI("Open Recent");
        file.Items.Add(_recentMenu);
        file.Items.Add(new Separator());
        _miCloseFile = MI("Close File", "Ctrl+W", (_, _) => CloseCurrentFile());
        file.Items.Add(_miCloseFile);
        file.Items.Add(MI("Close Window", "Ctrl+Shift+W", (_, _) => Close()));
        file.Items.Add(new Separator());
        _miSave = MI("Save", "Ctrl+S", (_, _) => MenuSave());
        file.Items.Add(_miSave);
        _miSaveAs = MI("Save As…", "Ctrl+Shift+S", (_, _) => MenuSaveAs());
        file.Items.Add(_miSaveAs);
        _miRevert = MI("Revert to Saved", null, (_, _) => MenuRevert());
        file.Items.Add(_miRevert);
        file.Items.Add(new Separator());
        _miReveal = MI("Show in Explorer", "Ctrl+Shift+R", (_, _) => MenuRevealInExplorer());
        file.Items.Add(_miReveal);
        _miCopyPath = MI("Copy Path", "Ctrl+Shift+C", (_, _) => MenuCopyPath());
        file.Items.Add(_miCopyPath);
        file.Items.Add(new Separator());
        _miReopenFiles = MI("Reopen Files at Launch", null, (_, _) => ToggleReopenFilesAtLaunch());
        _miReopenFiles.IsCheckable = true;
        _miReopenFiles.ToolTip = "When xml-macker starts without a file, reopen the files from the previous session";
        file.Items.Add(_miReopenFiles);
        file.Items.Add(MI("Reset All Settings…", null, (_, _) => MenuResetAllSettings()));
        file.Items.Add(new Separator());
        file.Items.Add(MI("Exit", "Alt+F4", (_, _) => QuitApp()));
        _appDelegate.PopulateRecentMenu(_recentMenu);

        // ── Edit ────────────────────────────────────────────────────────────────────────────────
        var edit = MI("_Edit");
        edit.SubmenuOpened += (_, _) => ValidateMenus();
        _miUndo = MI("Undo", "Ctrl+Z", (_, _) => DoUndo());
        edit.Items.Add(_miUndo);
        _miRedo = MI("Redo", "Ctrl+Y", (_, _) => DoRedo());
        edit.Items.Add(_miRedo);
        edit.Items.Add(new Separator());
        edit.Items.Add(new MenuItem { Header = "Cut", Command = ApplicationCommands.Cut, InputGestureText = "Ctrl+X" });
        edit.Items.Add(new MenuItem { Header = "Copy", Command = ApplicationCommands.Copy, InputGestureText = "Ctrl+C" });
        edit.Items.Add(new MenuItem { Header = "Paste", Command = ApplicationCommands.Paste, InputGestureText = "Ctrl+V" });
        edit.Items.Add(new MenuItem { Header = "Select All", Command = ApplicationCommands.SelectAll, InputGestureText = "Ctrl+A" });
        edit.Items.Add(new Separator());
        edit.Items.Add(MI("Find and Replace…", "Ctrl+F", (_, _) => PresentFindReplace(null, focusReplace: true)));
        var highlight = new MenuItem { Header = "Highlighter" };
        highlight.Items.Add(MI("Marker On / Off", "Ctrl+H", (_, _) => ToggleMarker()));
        highlight.Items.Add(MI("Mark the Selection or This Line", "Ctrl+Alt+H", (_, _) => PaintCurrent(collapseSelection: false)));
        highlight.Items.Add(MI("Next Mark", "Ctrl+Shift+H", (_, _) => JumpToHighlight(+1)));
        highlight.Items.Add(MI("Previous Mark", "Ctrl+Shift+Alt+H", (_, _) => JumpToHighlight(-1)));
        highlight.Items.Add(new Separator());
        highlight.Items.Add(MI("Colours and Eraser…", null, (_, _) => ShowHighlightMenu()));
        highlight.Items.Add(MI("Remove All Marks in This File", null, (_, _) => RemoveAllHighlights()));
        edit.Items.Add(highlight);
        edit.Items.Add(new Separator());
        edit.Items.Add(MI("Settings…", "Ctrl+,", (_, _) => OpenSettings()));

        // ── View ────────────────────────────────────────────────────────────────────────────────
        var view = MI("_View");
        view.SubmenuOpened += (_, _) => ValidateMenus();
        _miWsEdit = MI("Layout: Simple", "Ctrl+Alt+1", (_, _) => ApplyWorkspace(WorkspaceMode.Edit, true));
        _miWsInspect = MI("Layout: Inspect", "Ctrl+Alt+2", (_, _) => ApplyWorkspace(WorkspaceMode.Inspect, true));
        _miWsFull = MI("Layout: Full", "Ctrl+Alt+3", (_, _) => ApplyWorkspace(WorkspaceMode.Full, true));
        _miWsLearn = MI("Layout: Learn", "Ctrl+Alt+4", (_, _) => ApplyWorkspace(WorkspaceMode.Learn, true));
        _miWsEdit.IsCheckable = _miWsInspect.IsCheckable = _miWsFull.IsCheckable = _miWsLearn.IsCheckable = true;
        view.Items.Add(_miWsEdit); view.Items.Add(_miWsInspect); view.Items.Add(_miWsFull); view.Items.Add(_miWsLearn);
        view.Items.Add(new Separator());
        view.Items.Add(MI("Zoom In", "Ctrl+Plus", (_, _) => XmZoomIn()));
        view.Items.Add(MI("Zoom Out", "Ctrl+Minus", (_, _) => XmZoomOut()));
        view.Items.Add(MI("Reset Zoom", "Ctrl+0", (_, _) => XmZoomReset()));
        view.Items.Add(new Separator());
        _miGoToLine = MI("Go to Line…", "Ctrl+L", (_, _) => MenuGoToLine());
        view.Items.Add(_miGoToLine);
        _miLineNumbers = MI("Show Line Numbers", "Ctrl+Shift+L", (_, _) => MenuToggleLineNumbers());
        _miLineNumbers.IsCheckable = true;
        view.Items.Add(_miLineNumbers);
        _miMinimap = MI("Show Minimap", "Ctrl+Shift+M", (_, _) => MenuToggleMinimap());
        _miMinimap.IsCheckable = true;
        view.Items.Add(_miMinimap);
        view.Items.Add(new Separator());
        view.Items.Add(MI("Show Validation", "Ctrl+Shift+E", (_, _) => ShowValidation()));
        view.Items.Add(new Separator());

        var showMenu = MI("Show");
        var hideMenu = MI("Hide");
        foreach (string title in MenuPaneTitles)
        {
            string t = title;
            var showItem = MI(title, null, (_, _) => MenuShowPane(t));
            _showItems[title] = showItem; showMenu.Items.Add(showItem);
            var hideItem = MI(title, null, (_, _) => MenuHidePane(t));
            _hideItems[title] = hideItem; hideMenu.Items.Add(hideItem);
        }
        view.Items.Add(showMenu);
        view.Items.Add(hideMenu);
        view.Items.Add(new Separator());

        var theme = MI("Theme");
        _miThemeAurora = MI("Aurora Dark", null, (_, _) => ApplyTheme(ThemeDef.AuroraDark));
        _miThemeLight = MI("Light", null, (_, _) => ApplyTheme(ThemeDef.Light));
        _miThemeOneDark = MI("One Dark", null, (_, _) => ApplyTheme(ThemeDef.OneDark));
        _miThemeSolarized = MI("Solarized Dark", null, (_, _) => ApplyTheme(ThemeDef.SolarizedDark));
        _miThemeDracula = MI("Dracula", null, (_, _) => ApplyTheme(ThemeDef.Dracula));
        _miThemeHacker = MI("Hacker", null, (_, _) => ApplyTheme(ThemeDef.Hacker));
        foreach (var mi in new[] { _miThemeAurora, _miThemeLight, _miThemeOneDark, _miThemeSolarized, _miThemeDracula, _miThemeHacker })
        { mi.IsCheckable = true; theme.Items.Add(mi); }
        view.Items.Add(theme);
        view.Items.Add(new Separator());

        _miPopoutsFloat = MI("Pop-outs Stay on Top", null, (_, _) => TogglePopoutsFloat());
        _miPopoutsFloat.IsCheckable = true;
        view.Items.Add(_miPopoutsFloat);

        var layout = MI("Layout");
        _miLayTreeLeft = MI("Tree on Left", null, (_, _) => SetLayout(LayoutTreeRightKey, false));
        _miLayTreeRight = MI("Tree on Right", null, (_, _) => SetLayout(LayoutTreeRightKey, true));
        _miLayInspRight = MI("Inspector Column on Right", null, (_, _) => SetLayout(LayoutInspectorLeftKey, false));
        _miLayInspLeft = MI("Inspector Column on Left", null, (_, _) => SetLayout(LayoutInspectorLeftKey, true));
        _miLayHierBottom = MI("Hierarchy at Bottom", null, (_, _) => SetLayout(LayoutHierarchyTopKey, false));
        _miLayHierTop = MI("Hierarchy on Top", null, (_, _) => SetLayout(LayoutHierarchyTopKey, true));
        foreach (var mi in new[] { _miLayTreeLeft, _miLayTreeRight, _miLayInspRight, _miLayInspLeft, _miLayHierBottom, _miLayHierTop })
            mi.IsCheckable = true;
        layout.Items.Add(_miLayTreeLeft); layout.Items.Add(_miLayTreeRight);
        layout.Items.Add(new Separator());
        layout.Items.Add(_miLayInspRight); layout.Items.Add(_miLayInspLeft);
        layout.Items.Add(new Separator());
        layout.Items.Add(_miLayHierBottom); layout.Items.Add(_miLayHierTop);
        layout.Items.Add(new Separator());
        layout.Items.Add(MI("Reset Layout", null, (_, _) => ResetLayout()));
        view.Items.Add(layout);

        // ── Share ─────────────────────────────────────────────────────────────────────────────────
        var share = MI("_Share");
        share.SubmenuOpened += (_, _) => ValidateMenus();
        share.Items.Add(MI("Print Selection…", null, (_, _) => SharePrintSelection()));
        share.Items.Add(MI("Copy Selection in Full", null, (_, _) => ShareCopySelectionInFull()));
        share.Items.Add(MI("Print Current Element…", "Ctrl+P", (_, _) => SharePrintCurrentElement()));
        share.Items.Add(MI("Print Other Element…", null, (_, _) => SharePrintPickElement()));
        share.Items.Add(new Separator());
        // Only the element route is offered here; the editor's context menu still has a selection
        // send for the rare case.
        var sendEl = MI("Send Current Element to");
        foreach (LLMTarget target in LLMTargets.All)
        {
            LLMTarget t = target;
            sendEl.Items.Add(MI(t.DisplayName(), null, (_, _) => ShareToLLM(t, "element")));
        }
        share.Items.Add(sendEl);
        share.Items.Add(new Separator());
        share.Items.Add(MI("Locate File in Explorer", null, (_, _) => MenuRevealInExplorer()));
        share.Items.Add(MI("Export Current Element as XML…", null, (_, _) => ShareExportElement()));

        // ── Window ─────────────────────────────────────────────────────────────────────────────────
        var window = MI("_Window");
        window.SubmenuOpened += (_, _) => ValidateMenus();
        window.Items.Add(MI("Minimize", null, (_, _) => WindowState = WindowState.Minimized));
        _miMaxRestore = MI("Maximize", null, (_, _) =>
            WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized);
        window.Items.Add(_miMaxRestore);
        window.Items.Add(new Separator());
        window.Items.Add(MI("Show All Windows", null, (_, _) => BringAllToFront()));

        var help = MI("_Help");
        help.Items.Add(MI("Show Tour…", null, (_, _) => ShowTour()));
        help.Items.Add(new Separator());
        help.Items.Add(MI("About xml-macker", null, (_, _) => ShowAbout()));

        MenuBar.Items.Add(file);
        MenuBar.Items.Add(edit);
        MenuBar.Items.Add(view);
        MenuBar.Items.Add(share);
        MenuBar.Items.Add(window);
        MenuBar.Items.Add(help);
    }

    private IReadOnlyList<FrameworkElement> TourAnchors(string name)
    {
        if (name is "workspace" or "diff" or "search" or "find" or "orbit" or "highlight")
            return Toolbar.TourAnchors(name);
        return name switch
        {
            "minimap" => new FrameworkElement[] { _source.Minimap },
            // The rail's tab strip lives in the Inspector pane header and is visible in every workspace
            // that shows the rail; the rail body alone is collapsed in Edit, which left the card with no
            // target and dropped it in the middle of the screen.
            "details" => new FrameworkElement[] { _detailsRail.HeaderAccessory as FrameworkElement ?? _detailsRail, _detailsRail },
            // The zoom CONTROLS, not the whole status bar: spotlighting the full-width bar centred the
            // card across the window instead of beside the slider at the bottom right.
            "zoom" => new FrameworkElement[] { ZoomMinusButton, ZoomSlider, ZoomPlusButton, ZoomResetButton },
            _ => Array.Empty<FrameworkElement>(),
        };
    }

    // ── Menu validation ──────────────────────────────────────────────────────────────

    private void ScheduleMenuRefresh()
        => Dispatcher.BeginInvoke(new Action(ValidateMenus), DispatcherPriority.Background);

    private bool PopoutsFloat => AppSettings.Instance.GetBool(PopoutsFloatKey, false);
    private bool ReopenFilesAtLaunch => AppSettings.Instance.GetBool(ReopenLastFilesKey, true);
    private bool MinimapVisible => _source.IsMinimapVisible;

    private void ToggleReopenFilesAtLaunch()
    {
        AppSettings.Instance.SetBool(ReopenLastFilesKey, !ReopenFilesAtLaunch);
        ValidateMenus();
    }

    private void ValidateMenus()
    {
        bool hasFile = _currentFileUrl is not null;
        bool documentReady = hasFile && ActiveSession is { IsLoading: false }
            && !_openBusy && _openQueue.Count == 0 && _savingSessionIds.Count == 0;
        _miSave.IsEnabled = _miSaveAs.IsEnabled = _miRevert.IsEnabled = _miCloseFile.IsEnabled = documentReady;
        _miReveal.IsEnabled = _miCopyPath.IsEnabled = _miGoToLine.IsEnabled = hasFile;

        var undo = _source.Editor.UndoStack;
        bool canUndo = documentReady && (undo?.CanUndo ?? false);
        bool canRedo = documentReady && (undo?.CanRedo ?? false);
        _miUndo.IsEnabled = canUndo;
        _miRedo.IsEnabled = canRedo;
        Toolbar.SetDocumentCommandState(documentReady, canUndo, canRedo);

        _miLineNumbers.IsChecked = _source.IsLineNumbersVisible;
        _miMinimap.IsChecked = MinimapVisible;
        _miPopoutsFloat.IsChecked = PopoutsFloat;
        _miReopenFiles.IsChecked = ReopenFilesAtLaunch;
        _miMaxRestore.Header = WindowState == WindowState.Maximized ? "Restore" : "Maximize";

        string themeId = ThemeManager.Active.Id;
        _miThemeAurora.IsChecked = themeId == "aurora-dark";
        _miThemeLight.IsChecked = themeId == "light";
        _miThemeOneDark.IsChecked = themeId == "one-dark";
        _miThemeSolarized.IsChecked = themeId == "solarized-dark";
        _miThemeDracula.IsChecked = themeId == "dracula";
        _miThemeHacker.IsChecked = themeId == "hacker-green";

        _miWsEdit.IsChecked = _workspaceMode == WorkspaceMode.Edit;
        _miWsInspect.IsChecked = _workspaceMode == WorkspaceMode.Inspect;
        _miWsFull.IsChecked = _workspaceMode == WorkspaceMode.Full;
        _miWsLearn.IsChecked = _workspaceMode == WorkspaceMode.Learn;

        bool treeRight = AppSettings.Instance.GetBool(LayoutTreeRightKey, false);
        _miLayTreeLeft.IsChecked = !treeRight; _miLayTreeRight.IsChecked = treeRight;
        bool inspLeft = AppSettings.Instance.GetBool(LayoutInspectorLeftKey, false);
        _miLayInspRight.IsChecked = !inspLeft; _miLayInspLeft.IsChecked = inspLeft;
        bool hierTop = AppSettings.Instance.GetBool(LayoutHierarchyTopKey, false);
        _miLayHierBottom.IsChecked = !hierTop; _miLayHierTop.IsChecked = hierTop;

        foreach ((string title, MenuItem item) in _showItems)
            item.IsEnabled = ShowEnabled(title);
        foreach ((string title, MenuItem item) in _hideItems)
            item.IsEnabled = HideEnabled(title);
    }

    private bool ShowEnabled(string title)
        => title == PaneMinimap
            ? !MinimapVisible
            : _split.IsClosedOrMinimized(MenuPaneTarget(title));

    private bool HideEnabled(string title)
        => title == PaneMinimap
            ? MinimapVisible
            : (_split.HasPane(MenuPaneTarget(title))
               && !_split.IsHidden(MenuPaneTarget(title))
               && !_split.IsPoppedOut(MenuPaneTarget(title)));

    // ── Key bindings ──────────────────────────────────────────────────────────

    private void InstallKeyBindings()
    {
        void Bind(Key key, ModifierKeys mods, Action action)
            => InputBindings.Add(new KeyBinding(new RelayCommand(action), key, mods));

        Bind(Key.O, ModifierKeys.Control, () => _appDelegate.OpenFile(this));
        Bind(Key.N, ModifierKeys.Control, NewBlankDocument);
        Bind(Key.OemComma, ModifierKeys.Control, OpenSettings);
        Bind(Key.W, ModifierKeys.Control, CloseCurrentFile);
        Bind(Key.W, ModifierKeys.Control | ModifierKeys.Shift, Close);
        Bind(Key.S, ModifierKeys.Control, MenuSave);
        Bind(Key.S, ModifierKeys.Control | ModifierKeys.Shift, MenuSaveAs);
        Bind(Key.R, ModifierKeys.Control | ModifierKeys.Shift, MenuRevealInExplorer);
        Bind(Key.C, ModifierKeys.Control | ModifierKeys.Shift, MenuCopyPath);
        Bind(Key.F, ModifierKeys.Control, () => PresentFindReplace(null, focusReplace: true));
        Bind(Key.H, ModifierKeys.Control, ToggleMarker);
        Bind(Key.H, ModifierKeys.Control | ModifierKeys.Alt, () => PaintCurrent(collapseSelection: false));
        Bind(Key.H, ModifierKeys.Control | ModifierKeys.Shift, () => JumpToHighlight(+1));
        Bind(Key.H, ModifierKeys.Control | ModifierKeys.Shift | ModifierKeys.Alt, () => JumpToHighlight(-1));
        Bind(Key.L, ModifierKeys.Control, MenuGoToLine);
        Bind(Key.L, ModifierKeys.Control | ModifierKeys.Shift, MenuToggleLineNumbers);
        Bind(Key.M, ModifierKeys.Control | ModifierKeys.Shift, MenuToggleMinimap);
        Bind(Key.E, ModifierKeys.Control | ModifierKeys.Shift, ShowValidation);
        Bind(Key.P, ModifierKeys.Control, SharePrintCurrentElement);
        Bind(Key.D1, ModifierKeys.Control | ModifierKeys.Alt, () => ApplyWorkspace(WorkspaceMode.Edit, true));
        Bind(Key.D2, ModifierKeys.Control | ModifierKeys.Alt, () => ApplyWorkspace(WorkspaceMode.Inspect, true));
        Bind(Key.D3, ModifierKeys.Control | ModifierKeys.Alt, () => ApplyWorkspace(WorkspaceMode.Full, true));
        Bind(Key.D4, ModifierKeys.Control | ModifierKeys.Alt, () => ApplyWorkspace(WorkspaceMode.Learn, true));

        Bind(Key.OemPlus, ModifierKeys.Control, XmZoomIn);
        Bind(Key.Add, ModifierKeys.Control, XmZoomIn);
        Bind(Key.OemMinus, ModifierKeys.Control, XmZoomOut);
        Bind(Key.Subtract, ModifierKeys.Control, XmZoomOut);
        Bind(Key.D0, ModifierKeys.Control, XmZoomReset);
        Bind(Key.NumPad0, ModifierKeys.Control, XmZoomReset);
    }

    /// <summary>Minimal ICommand for keyboard/menu dispatch.</summary>
    private sealed class RelayCommand : ICommand
    {
        private readonly Action _run;
        public RelayCommand(Action run) => _run = run;
        public event EventHandler? CanExecuteChanged { add { } remove { } }
        public bool CanExecute(object? parameter) => true;
        public void Execute(object? parameter) => _run();
    }
}
