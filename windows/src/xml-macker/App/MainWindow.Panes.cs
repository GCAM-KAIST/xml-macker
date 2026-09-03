using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using XMLMacker.Chrome;
using XMLMacker.Shared;
using XMLMacker.Theme;
using XMLMacker.Windows;

namespace XMLMacker.App;

/// <summary>
/// Pane registry &amp; the nested split layout, show/hide/minimize/maximize via
/// <see cref="SplitLayoutManager"/>, pop-out to a floating window with re-dock, workspace modes
/// (Edit/Inspect/Full/Learn), RStudio-style layout reordering, and per-pane zoom routing.
/// </summary>
public partial class MainWindow
{
    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Layout construction
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void BuildPaneLayout()
    {
        _mainGrid = new Grid();
        _rootVGrid = new Grid();
        _topHGrid = new Grid();
        _inspectorColGrid = new Grid();

        _gMain = _split.AddGroup("main", _mainGrid, SplitOrientation.Columns);
        _gRootV = _split.AddGroup("rootV", _rootVGrid, SplitOrientation.Rows);
        _gTopH = _split.AddGroup("topH", _topHGrid, SplitOrientation.Columns);
        _gInspectorCol = _split.AddGroup("inspectorCol", _inspectorColGrid, SplitOrientation.Rows, autoCollapsible: true);

        (FrameworkElement treeGlass, PaneChrome treeChrome) = Wrap(PaneTree, _tree);
        (FrameworkElement sourceGlass, PaneChrome sourceChrome) = Wrap(PaneSource, _source);
        (FrameworkElement inspGlass, PaneChrome inspChrome) = Wrap(PaneInspector, _detailsRail);
        inspChrome.SetHeaderAccessory(_detailsRail.HeaderAccessory);
        inspChrome.SetHeaderControlsHidden(true);
        (FrameworkElement subGlass, PaneChrome subChrome) = Wrap(PaneSubtags, _subtags);
        (FrameworkElement hierGlass, PaneChrome hierChrome) = Wrap(PaneHierarchy, _hierarchy);

        // mainSplit (columns): tree | rightColumn(rootVGrid)
        _split.Register(PaneTree, _gMain, 0, treeGlass, treeChrome, XMMetric.TreePaneMin, XMMetric.TreePaneDefault);
        _split.Register(ContainerRight, _gMain, 1, _rootVGrid, DummyChrome(), XMMetric.InspectorPaneMin, 760);

        // rootVSplit (rows): topRow(topHGrid) / subtags / hierarchy
        _split.Register(ContainerTopRow, _gRootV, 0, _topHGrid, DummyChrome(), 160, 600);
        _split.Register(PaneSubtags, _gRootV, 1, subGlass, subChrome, XMMetric.DefaultFloor, 160);
        _split.Register(PaneHierarchy, _gRootV, 2, hierGlass, hierChrome, XMMetric.DefaultFloor, 140);

        // topHSplit (columns): source | inspectorColumn(inspectorColGrid)
        _split.Register(PaneSource, _gTopH, 0, sourceGlass, sourceChrome, XMMetric.InspectorPaneMin, 720);
        _split.Register(ContainerInspectorCol, _gTopH, 1, _inspectorColGrid, DummyChrome(), XMMetric.InspectorFloor, 340);

        // Focused detail rail: Inspector, Chart, Preview and Errors share one conventional column.
        _split.Register(PaneInspector, _gInspectorCol, 0, inspGlass, inspChrome, XMMetric.InspectorFloor, 600);

        _split.Build();
        PaneHost.Child = _mainGrid;
    }

    /// <summary>Wrap a pane's content in a <see cref="PaneChrome"/> inside a <see cref="GlassPanel"/>.</summary>
    private (FrameworkElement glass, PaneChrome chrome) Wrap(string title, UIElement content)
    {
        var chrome = new PaneChrome { Title = title };
        chrome.SetContent(content);

        var glass = new GlassPanel
        {
            Radius = XMMetric.RadiusCard,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
            Content = chrome,
        };

        _chromes[title] = chrome;
        _glasses[title] = glass;
        return (glass, chrome);
    }

    // A throwaway chrome to satisfy the non-null contract for chromeless nested-split containers.
    private static PaneChrome DummyChrome() => new();

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  RStudio-style layout
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void ApplyPaneLayout()
    {
        bool treeRight = AppSettings.Instance.GetBool(LayoutTreeRightKey, false);
        bool inspLeft = AppSettings.Instance.GetBool(LayoutInspectorLeftKey, false);
        bool hierTop = AppSettings.Instance.GetBool(LayoutHierarchyTopKey, false);

        _split.SetOrder(_gMain, treeRight
            ? new[] { ContainerRight, PaneTree }
            : new[] { PaneTree, ContainerRight });

        _split.SetOrder(_gTopH, inspLeft
            ? new[] { ContainerInspectorCol, PaneSource }
            : new[] { PaneSource, ContainerInspectorCol });

        _split.SetOrder(_gRootV, hierTop
            ? new[] { PaneHierarchy, ContainerTopRow, PaneSubtags }
            : new[] { ContainerTopRow, PaneSubtags, PaneHierarchy });
    }

    private void SetLayout(string key, bool value)
    {
        AppSettings.Instance.SetBool(key, value);
        ApplyPaneLayout();
    }

    private void ResetLayout()
    {
        AppSettings.Instance.SetBool(LayoutTreeRightKey, false);
        AppSettings.Instance.SetBool(LayoutInspectorLeftKey, false);
        AppSettings.Instance.SetBool(LayoutHierarchyTopKey, false);
        ApplyPaneLayout();
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Workspace modes
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void ApplyWorkspace(WorkspaceMode mode, bool save)
    {
        if (mode != WorkspaceMode.Learn)
        {
            if (_learn is not null && _split.HasPane(PaneLearn) && !_split.IsHidden(PaneLearn))
                _split.SetVisible(PaneLearn, false);
            RemoveLearnChip();
        }

        switch (mode)
        {
            case WorkspaceMode.Edit:
                _split.SetVisible(PaneTree, true);
                _split.SetVisible(ContainerInspectorCol, false);
                _split.SetVisible(PaneSubtags, true);
                _split.SetVisible(PaneHierarchy, false);
                break;

            case WorkspaceMode.Inspect:
                _split.SetVisible(PaneTree, true);
                _split.SetVisible(ContainerInspectorCol, true);
                _split.SetVisible(PaneSubtags, false);
                _split.SetVisible(PaneHierarchy, false);
                break;

            case WorkspaceMode.Full:
                DockAllPopouts();
                _split.SetVisible(PaneTree, true);
                _split.SetVisible(ContainerInspectorCol, true);
                _split.SetVisible(PaneInspector, true);
                _split.SetVisible(PaneSubtags, true);
                _split.SetVisible(PaneHierarchy, true);
                _split.UnminimizeAll();
                ApplyPaneLayout();
                break;

            case WorkspaceMode.Learn:
                DockAllPopouts();
                _split.SetVisible(PaneTree, true);
                _split.SetVisible(ContainerInspectorCol, false);
                _split.SetVisible(PaneSubtags, false);
                _split.SetVisible(PaneHierarchy, false);
                EnsureLearnPane();
                _split.SetVisible(PaneLearn, true);
                break;
        }

        _workspaceMode = mode;
        Toolbar.WorkspaceSegment = (int)mode;
        _source.SetLearnMode(mode == WorkspaceMode.Learn);
        if (save) AppSettings.Instance.SetInt(WorkspaceModeKey, (int)mode);
        ValidateMenus();
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Pane visibility menu glue
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void MenuShowPane(string title)
    {
        if (title == PaneMinimap) { SetMinimapVisible(true); return; }
        string target = MenuPaneTarget(title);
        if (target == ContainerInspectorCol)
            _split.Show(PaneInspector);
        _split.Show(target);
        ValidateMenus();
    }

    private void MenuHidePane(string title)
    {
        if (title == PaneMinimap) { SetMinimapVisible(false); return; }
        string target = MenuPaneTarget(title);
        if (!_split.IsHidden(target)) _split.Hide(target);
        ValidateMenus();
    }

    private static string MenuPaneTarget(string title)
        => title == PaneDetails ? ContainerInspectorCol : title;

    private void SetMinimapVisible(bool visible)
    {
        _source.SetMinimapVisible(visible);   // the source pane owns the column and remembers the choice
        ValidateMenus();
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Per-pane zoom
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private enum ZoomTarget { Source, Tree, Subtags, Attributes, Preview }

    private ZoomTarget CurrentZoomTarget()
        => ZoomTargetOf(Keyboard.FocusedElement) ?? ZoomTarget.Source;   // default matches VS Code

    /// <summary>The pane that contains <paramref name="element"/>, or null when it is outside every pane.</summary>
    private ZoomTarget? ZoomTargetOf(IInputElement? element)
    {
        if (IsInside(element, _tree)) return ZoomTarget.Tree;
        if (IsInside(element, _subtags)) return ZoomTarget.Subtags;
        if (IsInside(element, _inspector)) return ZoomTarget.Attributes;
        if (IsInside(element, _preview)) return ZoomTarget.Preview;
        if (IsInside(element, _source)) return ZoomTarget.Source;
        return null;
    }

    /// <summary>Ctrl + wheel: zoom only the pane under the pointer (falls back to the focused pane).</summary>
    private void ZoomPaneUnder(object? source, int direction)
        => ZoomPane(ZoomTargetOf(source as IInputElement) ?? CurrentZoomTarget(), direction);

    /// <summary>+1 bigger, −1 smaller, 0 back to normal, for one pane only.</summary>
    private void ZoomPane(ZoomTarget target, int direction)
    {
        switch (target)
        {
            case ZoomTarget.Tree: if (direction > 0) _tree.ZoomIn(); else if (direction < 0) _tree.ZoomOut(); else _tree.ZoomReset(); break;
            case ZoomTarget.Subtags: if (direction > 0) _subtags.ZoomIn(); else if (direction < 0) _subtags.ZoomOut(); else _subtags.ZoomReset(); break;
            case ZoomTarget.Attributes: if (direction > 0) _inspector.ZoomIn(); else if (direction < 0) _inspector.ZoomOut(); else _inspector.ZoomReset(); break;
            case ZoomTarget.Preview: if (direction > 0) _preview.ZoomIn(); else if (direction < 0) _preview.ZoomOut(); else _preview.ZoomReset(); break;
            default: if (direction > 0) _source.ZoomIn(); else if (direction < 0) _source.ZoomOut(); else _source.ZoomReset(); break;
        }
    }

    /// <summary>The zoom of whichever pane lives inside <paramref name="glass"/> (a popped-out pane window).</summary>
    private (Action ZoomIn, Action ZoomOut, Action Reset) ZoomActionsInside(FrameworkElement glass)
    {
        if (IsInside(_tree, glass)) return (_tree.ZoomIn, _tree.ZoomOut, _tree.ZoomReset);
        if (IsInside(_subtags, glass)) return (_subtags.ZoomIn, _subtags.ZoomOut, _subtags.ZoomReset);
        if (IsInside(_inspector, glass)) return (_inspector.ZoomIn, _inspector.ZoomOut, _inspector.ZoomReset);
        if (IsInside(_preview, glass)) return (_preview.ZoomIn, _preview.ZoomOut, _preview.ZoomReset);
        return (_source.ZoomIn, _source.ZoomOut, _source.ZoomReset);
    }

    private static bool IsInside(IInputElement? focused, DependencyObject ancestor)
    {
        if (focused is not DependencyObject start) return false;
        DependencyObject? cur = start;
        while (cur is not null)
        {
            if (ReferenceEquals(cur, ancestor)) return true;
            DependencyObject? next = null;
            if (cur is Visual or System.Windows.Media.Media3D.Visual3D)
                next = VisualTreeHelper.GetParent(cur);
            next ??= LogicalTreeHelper.GetParent(cur);
            cur = next;
        }
        return false;
    }

    private void XmZoomIn() => ZoomPane(CurrentZoomTarget(), +1);
    private void XmZoomOut() => ZoomPane(CurrentZoomTarget(), -1);
    private void XmZoomReset() => ZoomPane(CurrentZoomTarget(), 0);

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Pop-out to a floating window + float toggle
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void TogglePopOut(string key)
    {
        if (_popouts.TryGetValue(key, out Window? existing))
        {
            existing.Close();   // Closed handler docks the pane back
            return;
        }

        FrameworkElement? glass = _split.DetachForPopOut(key);
        if (glass is null) return;
        SplitLayoutManager.DetachFromParent(glass);   // defensive: single owner before re-parenting

        var host = new Border { Padding = new Thickness(8), Child = glass };
        host.SetResourceReference(Border.BackgroundProperty, XMColor.Bg);

        Rect vis = SystemParameters.WorkArea;
        var win = new Window
        {
            Title = key,
            Content = host,
            Width = Math.Clamp(vis.Width * 0.45, 480, 860),
            Height = Math.Clamp(vis.Height * 0.55, 380, 640),
            MinWidth = 380,
            MinHeight = 300,
            Owner = this,
            ShowInTaskbar = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
        };
        win.SetResourceReference(BackgroundProperty, XMColor.Bg);
        Acrylic.Apply(win, ThemeManager.Active.IsDark);
        (Action zoomIn, Action zoomOut, Action zoomReset) = ZoomActionsInside(glass);
        ZoomGestures.Attach(win, zoomIn, zoomOut, zoomReset);   // Ctrl + wheel / Ctrl +/- zoom THIS pane only
        if (PopoutsFloat) win.Topmost = true;

        win.SourceInitialized += (_, _) => WindowPlacement.Restore(win, WindowPlacement.PopoutKey(key));
        win.Closed += (_, _) =>
        {
            WindowPlacement.Save(win, WindowPlacement.PopoutKey(key));
            OnPopoutClosed(key, host);
        };

        _popouts[key] = win;
        win.Show();
    }

    private void OnPopoutClosed(string key, Border host)
    {
        if (!_popouts.ContainsKey(key)) return;   // re-entry guard (the docking set behaves the same way)
        _popouts.Remove(key);

        host.Child = null;          // release the glass so it can be re-parented into its grid
        _split.DockFromPopOut(key); // re-inserts at canonical slot, fully open
    }

    private void DockAllPopouts()
    {
        foreach (string key in new System.Collections.Generic.List<string>(_popouts.Keys))
        {
            if (_popouts.TryGetValue(key, out Window? w)) w.Close();
        }
    }

    private void TogglePopoutsFloat() => SetPopoutsFloat(!PopoutsFloat);

    internal void SetPopoutsFloat(bool next)
    {
        AppSettings.Instance.SetBool(PopoutsFloatKey, next);
        foreach (Window w in _popouts.Values) w.Topmost = next;
        if (_chartPopout is not null) _chartPopout.Topmost = next;
        ValidateMenus();
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════════
    //  Learn pane (lazy, kept alive across mode switches so login + chat survive)
    // ══════════════════════════════════════════════════════════════════════════════════════════════

    private void EnsureLearnPane()
    {
        if (_learn is not null) return;

        _learn = new LearnPane();
        _learn.OnStatus += SetStatus;
        _learn.RequestSelectionPrompt = LearnSelectionPrompt;
        _learn.RequestElementPrompt = LearnElementPrompt;
        _learn.OpenFolderRequested = LearnOpenFileFolder;
        _learn.CopyWholeFileRequested = LearnCopyWholeFile;

        (FrameworkElement glass, PaneChrome chrome) = Wrap(PaneLearn, _learn);
        _split.Register(PaneLearn, _gTopH, 5, glass, chrome, 300, 560);
        _split.Hide(PaneLearn);   // starts hidden; Learn mode reveals it

        chrome.Closed += (_, _) => _split.TogglePane(PaneLearn);
        chrome.Minimized += (_, _) => _split.ToggleMinimize(PaneLearn);
        chrome.Maximized += (_, _) => _split.ToggleMaximize(PaneLearn);
        chrome.PoppedOut += (_, _) => TogglePopOut(PaneLearn);
    }
}
