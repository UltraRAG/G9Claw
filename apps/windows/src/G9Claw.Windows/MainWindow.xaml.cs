using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using G9Claw.Windows.Core;
using Microsoft.UI.Windowing;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.Storage.Streams;
using WinRT.Interop;

namespace G9Claw.Windows;

public sealed partial class MainWindow : Window
{
    private const double MinimumWindowWidth = V2LayoutMetrics.MinimumWindowWidth;
    private const double MinimumWindowHeight = V2LayoutMetrics.MinimumWindowHeight;
    private const uint WindowSubclassId = 9;
    private const uint WmGetMinMaxInfo = 0x0024;
    private const uint WmNcHitTest = 0x0084;
    private const int GcsCompStr = 0x0008;
    private const double ChatBottomStickThreshold = 48;
    private static readonly IntPtr HtCaption = new(2);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MinMaxInfo
    {
        public NativePoint Reserved;
        public NativePoint MaxSize;
        public NativePoint MaxPosition;
        public NativePoint MinTrackSize;
        public NativePoint MaxTrackSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    private delegate IntPtr WindowSubclassProc(
        IntPtr hWnd,
        uint message,
        UIntPtr wParam,
        IntPtr lParam,
        UIntPtr subclassId,
        UIntPtr referenceData);

    private enum SettingsOverlayPage
    {
        Main,
        Behavior,
        CodeEditor,
        Permissions,
        Config,
        Mcp,
    }

    private enum MemoryToolTab
    {
        ProjectMemory,
        Profile,
        Trace,
    }

    private enum MemoryTraceToolTab
    {
        Recall,
        Index,
        Dream,
    }

    private enum AlwaysOnToolTab
    {
        Dashboard,
        Items,
        History,
    }

    [DllImport("comctl32.dll", SetLastError = true)]
    private static extern bool SetWindowSubclass(IntPtr hWnd, WindowSubclassProc callback, UIntPtr subclassId, UIntPtr referenceData);

    [DllImport("comctl32.dll", SetLastError = true)]
    private static extern bool RemoveWindowSubclass(IntPtr hWnd, WindowSubclassProc callback, UIntPtr subclassId);

    [DllImport("comctl32.dll", SetLastError = true)]
    private static extern IntPtr DefSubclassProc(IntPtr hWnd, uint message, UIntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr hWnd, out NativeRect rect);

    [DllImport("imm32.dll")]
    private static extern IntPtr ImmGetContext(IntPtr hWnd);

    [DllImport("imm32.dll")]
    private static extern bool ImmReleaseContext(IntPtr hWnd, IntPtr hIMC);

    [DllImport("imm32.dll", CharSet = CharSet.Unicode)]
    private static extern int ImmGetCompositionStringW(IntPtr hIMC, int dwIndex, IntPtr lpBuf, int dwBufLen);

    private readonly AppSettingsStore _settingsStore;
    private readonly HashSet<string> _expandedProjectNames = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _collapsedSessionProjectNames = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _processingSessionIds = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _unreadSessionIds = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _expandedFileDirectories = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<Guid> _expandedPermissionInputIds = [];
    private readonly Dictionary<Guid, TaskCompletionSource<PermissionRecord>> _pendingPermissionCompletions = [];
    private readonly Dictionary<Guid, int> _askQuestionIndexes = [];
    private readonly Dictionary<Guid, Dictionary<string, HashSet<string>>> _askQuestionSelections = [];
    private readonly Dictionary<Guid, Dictionary<string, string>> _askQuestionOtherAnswers = [];
    private readonly Dictionary<Guid, HashSet<string>> _askQuestionOtherActiveQuestions = [];
    private readonly HashSet<string> _askQuestionValidationErrors = new(StringComparer.Ordinal);
    private readonly Dictionary<Guid, string> _exitPlanFeedback = [];
    private readonly HashSet<Guid> _exitPlanFeedbackErrors = [];
    private readonly ICredentialStore _credentialStore;
    private readonly NativeAgentRunner _agentRunner;
    private readonly NativeRunStore _runStore;
    private readonly GitService _gitService;
    private readonly TerminalService _terminalService;
    private readonly MemoryService _memoryService;
    private readonly SkillService _skillService;
    private readonly PluginService _pluginService;
    private readonly AlwaysOnStore _alwaysOnStore;
    private readonly TaskPlanStore _taskPlanStore;
    private readonly TaskMasterService _taskMasterService;
    private readonly NativeUIPreferencesStore _uiPreferencesStore;
    private readonly ComposerPermissionModeStore _permissionModeStore;

    private WorkspaceService _workspaceService;
    private V2UiSettings _uiSettings;
    private StringCatalog _strings;
    private AppWindow? _appWindow;
    private CancellationTokenSource? _agentRunCts;
    private bool _isAgentRunning;
    private bool _isAgentSubmitting;
    private string? _selectedFilePath;
    private string _fileSearchText = "";
    private string? _previewDraftText;
    private bool _isMarkdownPreviewing;
    private bool _isCodePreviewing;
    private bool _isFileEditorExpanded;
    private bool _isSidebarVisible = true;
    private bool _isDraggingSidebar;
    private double _dragStartX;
    private double _dragStartWidth;
    private bool _hasAppliedInitialWindowSize;
    private WindowSubclassProc? _windowSubclassProc;
    private IntPtr _hwnd;
    private InteractiveTerminalSession? _shellSession;
    private string _shellInputText = "pwd";
    private string? _shellStatus;
    private string? _gitDiffText;
    private string? _toolStatus;
    private string _taskTitleText = "";
    private string _taskPromptText = "";
    private MemoryToolTab _memoryToolTab = MemoryToolTab.ProjectMemory;
    private MemoryTraceToolTab _memoryTraceToolTab = MemoryTraceToolTab.Recall;
    private AlwaysOnToolTab _alwaysOnToolTab = AlwaysOnToolTab.Dashboard;
    private bool _routingShowsTotalDashboard;
    private readonly HashSet<string> _expandedRoutingSessions = new(StringComparer.OrdinalIgnoreCase);
    private string? _selectedSkillKey;
    private string? _skillEditorKey;
    private string _skillEditorContent = "";
    private string _skillEditorOriginalContent = "";
    private string _skillFilterText = "";
    private string _memoryFilterText = "";
    private ProviderPreflightResult? _lastProviderPreflight;
    private TextBox? _composerTextBox;
    private bool _suppressComposerTextChanged;
    private bool _ignoreNextEnterKeyUp;
    private bool _headerMetricsPending;
    private bool? _lastToolSwitcherIconOnly;
    private bool _chatRenderPending;
    private Guid? _selectedMemoryRecordId;
    private string? _selectedMemoryTraceId;
    private string? _selectedAlwaysOnPlanId;
    private string? _selectedAlwaysOnCronJobId;
    private string? _selectedAlwaysOnRunId;
    private ScrollViewer? _chatScrollViewer;
    private bool _chatStickToBottom = true;
    private double _chatScrollOffset;
    private bool _suppressChatScrollTracking;
    private string? _lastContextStage;
    private int _contextCompactCount;
    private Dictionary<string, string> _permissionModeValues = new(StringComparer.Ordinal);
    public AppState State { get; private set; }
    public ObservableCollection<ChatLine> ChatLines { get; } = [];

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        SystemBackdrop = new MicaBackdrop();
        ConfigureWindow();
        Closed += async (_, _) => await DisposeShellSessionAsync();

        _settingsStore = new AppSettingsStore();
        _credentialStore = new DpapiCredentialStore();
        _runStore = new NativeRunStore();
        _terminalService = new TerminalService();
        _agentRunner = new NativeAgentRunner(
            toolExecutor: new AgentToolExecutor(terminalService: _terminalService, runStore: _runStore),
            runStore: _runStore);
        _gitService = new GitService();
        _memoryService = new MemoryService();
        _skillService = new SkillService();
        _pluginService = new PluginService();
        _alwaysOnStore = new AlwaysOnStore();
        _taskPlanStore = new TaskPlanStore();
        _taskMasterService = new TaskMasterService();
        _uiPreferencesStore = new NativeUIPreferencesStore();
        _permissionModeStore = new ComposerPermissionModeStore();
        State = AppState.CreateDefault();
        _uiSettings = State.Settings.UiSettings.Normalize();
        _strings = new StringCatalog(State.Settings.Language);
        _workspaceService = new WorkspaceService(State.Settings.WorkspacesRoot);

        RootGrid.ActualThemeChanged += (_, _) => UpdateLogo();
        RootGrid.Loaded += (_, _) =>
        {
            ApplyInitialWindowSize();
        };
        RootGrid.SizeChanged += OnRootGridSizeChanged;
        HeaderRoot.SizeChanged += (_, _) => ScheduleApplyHeaderMetrics();
        InitializeStaticIcons();
        ApplyUiSettings();
        RenderAll();
        _ = LoadSettingsAsync();
    }

    private void ConfigureWindow()
    {
        _hwnd = WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(_hwnd);
        _appWindow = AppWindow.GetFromWindowId(windowId);
        _appWindow.Changed += (_, _) => ScheduleApplyHeaderMetrics();
        InstallMinimumWindowSizeHandler();
        Closed += (_, _) => RemoveMinimumWindowSizeHandler();
    }

    private void ApplyInitialWindowSize()
    {
        if (_hasAppliedInitialWindowSize || _appWindow is null || _hwnd == IntPtr.Zero) return;
        _hasAppliedInitialWindowSize = true;
        var scale = WindowRasterizationScale();
        _appWindow.Resize(new SizeInt32(
            (int)Math.Ceiling(V2LayoutMetrics.DefaultWindowWidth * scale),
            (int)Math.Ceiling(V2LayoutMetrics.DefaultWindowHeight * scale)));
    }

    private double WindowRasterizationScale()
    {
        if (RootGrid.XamlRoot?.RasterizationScale is double xamlScale && xamlScale > 0)
        {
            return xamlScale;
        }

        if (_hwnd != IntPtr.Zero)
        {
            var dpi = GetDpiForWindow(_hwnd);
            if (dpi > 0)
            {
                return dpi / 96d;
            }
        }

        return 1;
    }

    private void OnRootGridSizeChanged(object sender, SizeChangedEventArgs e)
    {
        ScheduleApplyHeaderMetrics();
    }

    private void ScheduleApplyHeaderMetrics()
    {
        if (_headerMetricsPending) return;
        _headerMetricsPending = true;
        DispatcherQueue.TryEnqueue(() =>
        {
            _headerMetricsPending = false;
            ApplyHeaderMetrics();
        });
    }

    private void InstallMinimumWindowSizeHandler()
    {
        if (_hwnd == IntPtr.Zero || _windowSubclassProc is not null) return;
        _windowSubclassProc = MinimumWindowSizeSubclass;
        SetWindowSubclass(_hwnd, _windowSubclassProc, (UIntPtr)WindowSubclassId, UIntPtr.Zero);
    }

    private void RemoveMinimumWindowSizeHandler()
    {
        if (_hwnd == IntPtr.Zero || _windowSubclassProc is null) return;
        RemoveWindowSubclass(_hwnd, _windowSubclassProc, (UIntPtr)WindowSubclassId);
        _windowSubclassProc = null;
    }

    private IntPtr MinimumWindowSizeSubclass(
        IntPtr hWnd,
        uint message,
        UIntPtr wParam,
        IntPtr lParam,
        UIntPtr subclassId,
        UIntPtr referenceData)
    {
        if (message == WmGetMinMaxInfo)
        {
            var scale = WindowRasterizationScale();
            var minMax = Marshal.PtrToStructure<MinMaxInfo>(lParam);
            minMax.MinTrackSize.X = (int)Math.Ceiling(MinimumWindowWidth * scale);
            minMax.MinTrackSize.Y = (int)Math.Ceiling(MinimumWindowHeight * scale);
            Marshal.StructureToPtr(minMax, lParam, false);
        }
        else if (message == WmNcHitTest && IsPointInCustomDragRegion(lParam))
        {
            return HtCaption;
        }

        return DefSubclassProc(hWnd, message, wParam, lParam);
    }

    private bool IsPointInCustomDragRegion(IntPtr lParam)
    {
        if (_hwnd == IntPtr.Zero ||
            RootGrid.XamlRoot is null ||
            SettingsOverlayRoot.Visibility == Visibility.Visible ||
            !GetWindowRect(_hwnd, out var windowRect))
        {
            return false;
        }

        var scale = Math.Max(0.1, RootGrid.XamlRoot.RasterizationScale);
        var screenX = SignedLowWord(lParam);
        var screenY = SignedHighWord(lParam);
        var point = new global::Windows.Foundation.Point(
            (screenX - windowRect.Left) / scale,
            (screenY - windowRect.Top) / scale);

        if (IsInElement(point, HeaderRoot))
        {
            return !IsInElement(point, OpenSidebarButton) &&
                   !IsInElement(point, ToolTabsScroll);
        }

        if (IsInElement(point, AppTitleBar))
        {
            return !IsInElement(point, LogoButton) &&
                   !IsInElement(point, CollapseSidebarButton);
        }

        return false;
    }

    private static short SignedLowWord(IntPtr value) => unchecked((short)((long)value & 0xffff));

    private static short SignedHighWord(IntPtr value) => unchecked((short)(((long)value >> 16) & 0xffff));

    private bool IsInElement(global::Windows.Foundation.Point rootPoint, FrameworkElement element)
    {
        if (element.Visibility != Visibility.Visible || element.ActualWidth <= 0 || element.ActualHeight <= 0)
        {
            return false;
        }

        try
        {
            var origin = element.TransformToVisual(RootGrid).TransformPoint(new global::Windows.Foundation.Point(0, 0));
            return rootPoint.X >= origin.X &&
                   rootPoint.X <= origin.X + element.ActualWidth &&
                   rootPoint.Y >= origin.Y &&
                   rootPoint.Y <= origin.Y + element.ActualHeight;
        }
        catch
        {
            return false;
        }
    }

    private void ApplyHeaderMetrics()
    {
        if (HeaderRoot.ActualWidth <= 0) return;

        var headerWidth = HeaderRoot.ActualWidth;
        var horizontalPadding = headerWidth < 760 ? 12 : 18;
        var leadingTitlebarReserve = _isSidebarVisible ? 0 : 120;
        var controlGap = headerWidth < 1080 ? 6 : 10;
        var captionInset = HeaderLayoutMetrics.CaptionInsetToDips(
            _appWindow?.TitleBar.RightInset ?? 0,
            HeaderRoot.XamlRoot?.RasterizationScale ?? 1);
        var metrics = new HeaderLayoutMetrics(headerWidth, captionInset);
        HeaderRoot.Padding = new Thickness(horizontalPadding + leadingTitlebarReserve, 0, horizontalPadding, 0);
        HeaderRoot.ColumnSpacing = controlGap;
        HeaderCaptionSpacer.Width = new GridLength(metrics.EffectiveRightPadding);
        ToolTabsScroll.Margin = new Thickness(0);

        var availableToolSwitcherWidth = ResolveHeaderAvailableToolSwitcherWidth(metrics);
        var showsToolSwitcher = State.SelectedProject is not null;
        var layout = showsToolSwitcher ? ResolveHeaderToolSwitcherLayout(availableToolSwitcherWidth) : null;

        if (!showsToolSwitcher || layout is null || _lastToolSwitcherIconOnly != layout.IconOnly)
        {
            RenderHeader(metrics, availableToolSwitcherWidth);
            return;
        }

        ApplyToolSwitcherLayout(layout, metrics);
    }

    private double ResolveHeaderAvailableToolSwitcherWidth(HeaderLayoutMetrics? metrics = null)
    {
        var headerWidth = HeaderRoot.ActualWidth;
        if (headerWidth <= 0)
        {
            return V2LayoutMetrics.DefaultWindowWidth;
        }

        var resolvedMetrics = metrics ?? new HeaderLayoutMetrics(
            headerWidth,
            HeaderLayoutMetrics.CaptionInsetToDips(_appWindow?.TitleBar.RightInset ?? 0, HeaderRoot.XamlRoot?.RasterizationScale ?? 1));
        var horizontalPadding = headerWidth < 760 ? 12 : 18;
        var leadingTitlebarReserve = _isSidebarVisible ? 0 : 120;
        var trailingPadding = horizontalPadding;
        return Math.Max(0, headerWidth - (horizontalPadding + leadingTitlebarReserve + trailingPadding + resolvedMetrics.EffectiveRightPadding));
    }

    private async Task LoadSettingsAsync()
    {
        var settings = await _settingsStore.LoadAsync();
        var configText = NativeConfigService.ReadDefaultConfigText();
        if (settings is not null)
        {
            State.Settings = AppState.NormalizeSettings(settings);
        }

        if (!string.IsNullOrWhiteSpace(configText))
        {
            try
            {
                var parsed = NativeConfigYamlCodec.ApplyYaml(State.Settings, configText);
                foreach (var secret in parsed.Secrets)
                {
                    await _credentialStore.WriteSecretAsync(secret.Key, secret.Value);
                }

                State.Settings = parsed.Settings;
            }
            catch
            {
                var nativeConfig = NativeConfigService.LoadDefaultConfig();
                if (settings is null && nativeConfig is not null)
                {
                    State.Settings = State.Settings with
                    {
                        ProviderConfig = nativeConfig.ProviderConfig,
                        WorkspacesRoot = nativeConfig.WorkspacesRoot ?? State.Settings.WorkspacesRoot,
                        GeneralWorkspacePath = AppState.NormalizeGeneralWorkspacePath(nativeConfig.GeneralWorkspacePath ?? State.Settings.GeneralWorkspacePath),
                        ApiTimeoutMs = nativeConfig.ApiTimeoutMs,
                        ContextWindow = nativeConfig.ContextWindow,
                    };
                }
            }

            await _settingsStore.SaveAsync(State.Settings);
        }
        else if (settings is null)
        {
            NativeConfigService.WriteDefaultConfigText(NativeConfigYamlCodec.ToYaml(State.Settings));
            await _settingsStore.SaveAsync(State.Settings);
        }

        _uiSettings = State.Settings.UiSettings.NormalizeForStartup();
        State.UiPreferences = await _uiPreferencesStore.LoadAsync() ?? State.UiPreferences;
        _permissionModeValues = await _permissionModeStore.LoadAsync();
        _isSidebarVisible = State.UiPreferences.SidebarVisible;
        State.IsSidebarVisible = _isSidebarVisible;
        _strings = new StringCatalog(State.Settings.Language);
        _expandedProjectNames.Clear();
        foreach (var name in _uiSettings.ExpandedProjectNames)
        {
            _expandedProjectNames.Add(name);
        }

        _collapsedSessionProjectNames.Clear();
        foreach (var name in _uiSettings.CollapsedSessionProjectNames)
        {
            _collapsedSessionProjectNames.Add(name);
        }

        _workspaceService = new WorkspaceService(State.Settings.WorkspacesRoot);
        ApplyStartupSidebarSelection();
        if (!Equals(_uiSettings, State.Settings.UiSettings))
        {
            State.Settings = State.Settings with { UiSettings = _uiSettings };
            await _settingsStore.SaveAsync(State.Settings);
        }
        RefreshNativeStores();
        RestoreComposerPermissionMode(State.SelectedSessionId);
        await RefreshProviderPreflightAsync();
        ApplyUiSettings();
        RenderAll();
    }

    private async Task DisposeShellSessionAsync()
    {
        if (_shellSession is null) return;
        await _shellSession.DisposeAsync();
        _shellSession = null;
    }

    private void RefreshNativeStores()
    {
        State.MemoryRecords.Clear();
        State.MemoryRecords.AddRange(_memoryService.Load());

        State.Skills.Clear();
        State.Skills.AddRange(_skillService.Load(State.SelectedProject?.RootPath));

        State.PluginManifests.Clear();
        State.PluginManifests.AddRange(_pluginService.Load());

        State.TaskPlans.Clear();
        State.TaskPlans.AddRange(_taskPlanStore.Load());
        if (State.SelectedProject is { } project)
        {
            foreach (var plan in _taskMasterService.Detect(project.RootPath).Tasks)
            {
                if (State.TaskPlans.All(existing => existing.Id != plan.Id))
                {
                    State.TaskPlans.Add(plan);
                }
            }
        }

        State.AlwaysOnPlans.Clear();
        State.AlwaysOnPlans.AddRange(_alwaysOnStore.Load());
    }

    private void ApplyUiSettings()
    {
        RootGrid.RequestedTheme = State.Settings.ColorScheme switch
        {
            AppColorScheme.Light => ElementTheme.Light,
            AppColorScheme.Dark => ElementTheme.Dark,
            _ => ElementTheme.Default,
        };
        SidebarColumn.Width = new GridLength(_uiSettings.SidebarWidth);
        ProjectsSectionButton.Content = T("sidebar.projects");
        GeneralSectionButton.Content = T("sidebar.general");
        ProjectsSectionButton.Background = _uiSettings.SidebarSection == SidebarSection.Projects ? Brush("V2SidebarControlActiveBrush") : Transparent;
        ProjectsSectionButton.Foreground = _uiSettings.SidebarSection == SidebarSection.Projects ? Brush("V2ForegroundBrush") : Brush("V2SecondaryForegroundBrush");
        ProjectsSectionButton.BorderBrush = Transparent;
        ProjectsSectionButton.FontWeight = _uiSettings.SidebarSection == SidebarSection.Projects ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Medium;
        GeneralSectionButton.Background = _uiSettings.SidebarSection == SidebarSection.General ? Brush("V2SidebarControlActiveBrush") : Transparent;
        GeneralSectionButton.Foreground = _uiSettings.SidebarSection == SidebarSection.General ? Brush("V2ForegroundBrush") : Brush("V2SecondaryForegroundBrush");
        GeneralSectionButton.BorderBrush = Transparent;
        GeneralSectionButton.FontWeight = _uiSettings.SidebarSection == SidebarSection.General ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Medium;

        SidebarRoot.Visibility = _isSidebarVisible ? Visibility.Visible : Visibility.Collapsed;
        SidebarDivider.Visibility = _isSidebarVisible ? Visibility.Visible : Visibility.Collapsed;
        SidebarColumn.Width = _isSidebarVisible ? new GridLength(_uiSettings.SidebarWidth) : new GridLength(0);
        OpenSidebarButton.Visibility = _isSidebarVisible ? Visibility.Collapsed : Visibility.Visible;
        ToolTipService.SetToolTip(CollapseSidebarButton, T("sidebar.hide"));
        ToolTipService.SetToolTip(OpenSidebarButton, T("sidebar.show"));
        InitializeStaticIcons();
        ScheduleApplyHeaderMetrics();
        UpdateLogo();
    }

    private void RenderAll()
    {
        ApplyUiSettings();
        RenderSidebar();
        RenderHeader();
        RenderContent();
    }

    private void ScheduleChatRender()
    {
        if (_chatRenderPending) return;
        _chatRenderPending = true;
        _ = Task.Delay(75).ContinueWith(_ =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                _chatRenderPending = false;
                RenderContent();
            });
        }, TaskScheduler.Default);
    }

    private void CaptureChatScrollState()
    {
        if (State.ActiveTab != AppTab.Chat || _chatScrollViewer is null || _suppressChatScrollTracking)
        {
            return;
        }

        UpdateChatScrollState(_chatScrollViewer);
    }

    private void UpdateChatScrollState(ScrollViewer scroll)
    {
        if (_suppressChatScrollTracking) return;
        var snapshot = ChatScrollPresenter.Capture(
            scroll.VerticalOffset,
            scroll.ExtentHeight,
            scroll.ViewportHeight,
            ChatBottomStickThreshold);
        _chatStickToBottom = snapshot.StickToBottom;
        _chatScrollOffset = snapshot.Offset;
    }

    private void RestoreChatScrollState(ScrollViewer scroll)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            var target = ChatScrollPresenter.TargetOffset(
                new ChatScrollSnapshot(_chatStickToBottom, _chatScrollOffset),
                scroll.ExtentHeight,
                scroll.ViewportHeight,
                State.UiPreferences.AutoScrollToBottom);
            _suppressChatScrollTracking = true;
            scroll.ChangeView(null, target, null, disableAnimation: true);
            DispatcherQueue.TryEnqueue(() =>
            {
                _suppressChatScrollTracking = false;
                UpdateChatScrollState(scroll);
            });
        });
    }

    private void RenderSidebar()
    {
        SidebarItemsPanel.Children.Clear();
        var projects = State.Projects.ToList();
        var general = V2SidebarProjection.GeneralProject(projects);

        if (_uiSettings.SidebarSection == SidebarSection.Projects)
        {
            SidebarItemsPanel.Children.Add(SectionHeader(
                T("sidebar.projects"),
                ("Chevrons", ToggleAllProjects),
                ("Plus", OnCreateProjectRequested)));

            var visibleProjects = V2SidebarProjection.ProjectSection(projects, State.Settings.ProjectSortOrder);
            if (visibleProjects.Count == 0)
            {
                SidebarItemsPanel.Children.Add(MutedText(T("sidebar.noProjects"), 11, new Thickness(12, 4, 12, 4)));
            }
            else
            {
                foreach (var project in visibleProjects)
                {
                    SidebarItemsPanel.Children.Add(ProjectGroup(project, isGeneral: false));
                }
            }
        }
        else
        {
            SidebarItemsPanel.Children.Add(SectionHeader(
                T("sidebar.general"),
                null,
                general is null ? null : ("MessageSquarePlus", () => StartSession(general))));

            if (general is null)
            {
                SidebarItemsPanel.Children.Add(MutedText(T("sidebar.noGeneralWorkspaceFound"), 11, new Thickness(12, 4, 12, 4)));
            }
            else
            {
                SidebarItemsPanel.Children.Add(FlatGeneralSessionList(general));
            }
        }

    }

    private FrameworkElement FlatGeneralSessionList(WorkspaceProject general)
    {
        var panel = new StackPanel { Spacing = 2 };
        var rows = V2SidebarProjection.SessionRows(general);
        var hasDraft = false;
        if (State.SelectedProjectId == general.Id && State.SelectedSessionId is null && State.ActiveTab == AppTab.Chat)
        {
            panel.Children.Add(DraftSessionRow());
            hasDraft = true;
        }

        if (rows.Count == 0)
        {
            if (!hasDraft)
            {
                panel.Children.Add(MutedText(T("sidebar.noSessions"), 11, new Thickness(8, 4, 8, 4)));
            }
        }
        else
        {
            var collapsed = _collapsedSessionProjectNames.Contains(general.Name);
            var visible = collapsed ? rows.Take(5).ToList() : rows;
            foreach (var session in visible)
            {
                panel.Children.Add(SessionRow(general, session.Session));
            }

            if (rows.Count > 5)
            {
                var more = new Button
                {
                    Content = collapsed ? Tf("sidebar.showMore", rows.Count - 5) : T("sidebar.showLess"),
                    Background = Transparent,
                    BorderBrush = Transparent,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    FontSize = 11,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Left,
                    Padding = new Thickness(8, 2, 8, 2),
                    CornerRadius = new CornerRadius(6),
                };
                more.Click += (_, _) =>
                {
                    if (collapsed)
                    {
                        _collapsedSessionProjectNames.Remove(general.Name);
                    }
                    else
                    {
                        _collapsedSessionProjectNames.Add(general.Name);
                    }

                    PersistUiSettings();
                    RenderSidebar();
                };
                panel.Children.Add(more);
            }
        }

        return panel;
    }

    private FrameworkElement SectionHeader(string title, (string Icon, Action Action)? left, (string Icon, Action Action)? right)
    {
        var grid = new Grid
        {
            Margin = new Thickness(12, 8, 2, 4),
            ColumnSpacing = 2,
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new TextBlock
        {
            Text = title.ToUpperInvariant(),
            FontSize = 11,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            Foreground = Brush("V2MutedForegroundBrush"),
            CharacterSpacing = 40,
            VerticalAlignment = VerticalAlignment.Center,
        });

        if (left is { } leftAction)
        {
            var button = TinyIconButton(leftAction.Icon, (_, _) => leftAction.Action());
            Grid.SetColumn(button, 1);
            grid.Children.Add(button);
        }

        if (right is { } rightAction)
        {
            var button = TinyIconButton(rightAction.Icon, (_, _) => rightAction.Action());
            Grid.SetColumn(button, 2);
            grid.Children.Add(button);
        }

        return grid;
    }

    private FrameworkElement ProjectGroup(WorkspaceProject project, bool isGeneral, bool flatSessions = false)
    {
        var panel = new StackPanel { Spacing = 2 };
        var isSelected = State.SelectedProjectId == project.Id;
        var isExpanded = flatSessions || _expandedProjectNames.Contains(project.Name);

        var rowBorder = new Border
        {
            Height = 32,
            CornerRadius = new CornerRadius(8),
            Background = isSelected ? Brush("V2SelectedBrush") : Transparent,
            Padding = new Thickness(0),
        };
        var row = new Grid
        {
            ColumnSpacing = 0,
        };
        rowBorder.Child = row;
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var projectButton = new Button
        {
            Background = Transparent,
            BorderBrush = Transparent,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(6, 0, 4, 0),
            CornerRadius = new CornerRadius(8, 0, 0, 8),
            Tag = project,
        };
        projectButton.Click += (_, _) => ToggleOrSelectProject(project, flatSessions);
        projectButton.Content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Children =
            {
                Icon(isExpanded ? "ChevronDown" : "ChevronRight", 14, Brush("V2MutedForegroundBrush")),
                Icon("Folder", 14, isSelected ? Brush("V2ForegroundBrush") : Brush("V2MutedForegroundBrush")),
                new TextBlock
                {
                    Text = isGeneral ? T("sidebar.general") : project.DisplayName,
                    FontSize = 13,
                    Foreground = isSelected ? Brush("V2ForegroundBrush") : Brush("V2SecondaryForegroundBrush"),
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            },
        };
        row.Children.Add(projectButton);

        var addButton = TinyIconButton("MessageSquarePlus", (_, _) => StartSession(project));
        addButton.Opacity = isSelected ? 1 : 0.55;
        Grid.SetColumn(addButton, 1);
        row.Children.Add(addButton);

        if (!isGeneral)
        {
            rowBorder.ContextFlyout = ProjectContextFlyout(project);
        }

        panel.Children.Add(rowBorder);

        if (isExpanded)
        {
            var sessionPanel = new StackPanel
            {
                Spacing = 2,
                Margin = flatSessions ? new Thickness(0) : new Thickness(24, 0, 0, 0),
            };
            var rows = V2SidebarProjection.SessionRows(project);
            if (State.SelectedProjectId == project.Id && State.SelectedSessionId is null && State.ActiveTab == AppTab.Chat)
            {
                sessionPanel.Children.Add(DraftSessionRow());
            }

            if (rows.Count == 0)
            {
                sessionPanel.Children.Add(MutedText(T("sidebar.noSessions"), 11, new Thickness(8, 4, 8, 4)));
            }
            else
            {
                var collapsed = _collapsedSessionProjectNames.Contains(project.Name);
                var visible = collapsed ? rows.Take(5).ToList() : rows;
                foreach (var session in visible)
                {
                    sessionPanel.Children.Add(SessionRow(project, session.Session));
                }

                if (rows.Count > 5)
                {
                    var more = new Button
                    {
                        Content = collapsed ? Tf("sidebar.showMore", rows.Count - 5) : T("sidebar.showLess"),
                        Background = Transparent,
                        BorderBrush = Transparent,
                        Foreground = Brush("V2MutedForegroundBrush"),
                        FontSize = 11,
                        HorizontalAlignment = HorizontalAlignment.Stretch,
                        HorizontalContentAlignment = HorizontalAlignment.Left,
                        Padding = new Thickness(8, 2, 8, 2),
                        CornerRadius = new CornerRadius(6),
                    };
                    more.Click += (_, _) =>
                    {
                        if (collapsed)
                        {
                            _collapsedSessionProjectNames.Remove(project.Name);
                        }
                        else
                        {
                            _collapsedSessionProjectNames.Add(project.Name);
                        }

                        PersistUiSettings();
                        RenderSidebar();
                    };
                    sessionPanel.Children.Add(more);
                }
            }

            panel.Children.Add(sessionPanel);
        }

        return panel;
    }

    private FrameworkElement DraftSessionRow() => new Button
    {
        Background = Brush("V2SelectedBrush"),
        BorderBrush = Transparent,
        CornerRadius = new CornerRadius(6),
        HorizontalAlignment = HorizontalAlignment.Stretch,
        HorizontalContentAlignment = HorizontalAlignment.Left,
        Padding = new Thickness(8, 4, 8, 4),
        Content = new StackPanel
        {
            Children =
            {
                new TextBlock { Text = T("sidebar.newSession"), FontSize = 12.5, Foreground = Brush("V2ForegroundBrush") },
                new TextBlock { Text = T("sidebar.notSavedYet"), FontSize = 11, Foreground = Brush("V2MutedForegroundBrush") },
            },
        },
    };

    private FrameworkElement SessionRow(WorkspaceProject project, ProjectSession session)
    {
        var isSelected = State.SelectedProjectId == project.Id && State.SelectedSessionId == session.Id && State.ActiveTab == AppTab.Chat;
        var state = V2SidebarProjection.SessionIndicatorState(session, _processingSessionIds, _unreadSessionIds);
        var row = new Button
        {
            Background = isSelected ? Brush("V2SelectedBrush") : Transparent,
            BorderBrush = Transparent,
            CornerRadius = new CornerRadius(6),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(8, 4, 8, 4),
            Tag = session,
        };
        row.Click += (_, _) =>
        {
            State.SelectProject(project);
            SyncSidebarSectionWithProject(project);
            State.SelectSession(session);
            RestoreComposerPermissionMode(session.Id);
            _unreadSessionIds.Remove(session.Id);
            RenderAll();
        };
        row.ContextFlyout = SessionContextFlyout(project, session);

        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(SessionDot(state));
        var labels = new StackPanel { Spacing = 1 };
        labels.Children.Add(new TextBlock
        {
            Text = session.DisplayTitle,
            FontSize = 12.5,
            Foreground = Brush("V2ForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        labels.Children.Add(new TextBlock
        {
            Text = FormatRelative(session.ActivityDate),
            FontSize = 11,
            Foreground = Brush("V2MutedForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        Grid.SetColumn(labels, 1);
        grid.Children.Add(labels);
        row.Content = grid;
        return row;
    }

    private FrameworkElement SessionDot(SessionState state)
    {
        if (state == SessionState.Processing)
        {
            return new ProgressRing
            {
                IsActive = true,
                Width = 12,
                Height = 12,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 3, 0, 0),
            };
        }

        return new Microsoft.UI.Xaml.Shapes.Ellipse
        {
            Width = 6,
            Height = 6,
            Fill = state switch
            {
                SessionState.Unread => Brush("V2BlueBrush"),
                SessionState.Failed => Brush("V2RedBrush"),
                _ => Brush("V2BorderBrush"),
            },
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(3, 6, 0, 0),
        };
    }

    private MenuFlyout ProjectContextFlyout(WorkspaceProject project)
    {
        var flyout = new MenuFlyout();
        var rename = new MenuFlyoutItem { Text = T("common.rename") };
        rename.Click += async (_, _) => await RenameProjectAsync(project);
        var delete = new MenuFlyoutItem { Text = T("common.delete") };
        delete.Click += async (_, _) => await DeleteProjectAsync(project);
        flyout.Items.Add(rename);
        flyout.Items.Add(delete);
        return flyout;
    }

    private MenuFlyout SessionContextFlyout(WorkspaceProject project, ProjectSession session)
    {
        var flyout = new MenuFlyout();
        var rename = new MenuFlyoutItem { Text = T("common.rename") };
        rename.Click += async (_, _) => await RenameSessionAsync(project, session);
        var delete = new MenuFlyoutItem { Text = T("common.delete") };
        delete.Click += async (_, _) => await DeleteSessionAsync(project, session);
        flyout.Items.Add(rename);
        flyout.Items.Add(delete);
        return flyout;
    }

    private void RenderHeader(HeaderLayoutMetrics? metrics = null, double availableToolSwitcherWidth = 0)
    {
        BreadcrumbProjectText.Text = State.SelectedProject is { } selectedProject
            ? IsGeneralProject(selectedProject) ? T("sidebar.general") : selectedProject.DisplayName
            : T("sidebar.general");
        BreadcrumbTabText.Text = ActiveTabLabel();
        BreadcrumbSessionText.Text = State.SelectedSession?.DisplayTitle ?? "";

        var showsToolSwitcher = State.SelectedProject is not null;
        var showSessionTitle = HeaderRoot.ActualWidth >= 1160 && State.SelectedSession is not null;
        BreadcrumbTabText.Visibility = showsToolSwitcher ? Visibility.Visible : Visibility.Collapsed;
        BreadcrumbDividerText.Visibility = showsToolSwitcher ? Visibility.Visible : Visibility.Collapsed;
        BreadcrumbSessionText.Visibility = showSessionTitle ? Visibility.Visible : Visibility.Collapsed;
        BreadcrumbSessionText.Margin = showSessionTitle ? new Thickness(6, 0, 0, 0) : new Thickness(0);
        BreadcrumbSessionText.MaxWidth = showSessionTitle ? 240 : 0;

        ToolTabsPanel.Children.Clear();
        if (!showsToolSwitcher)
        {
            _lastToolSwitcherIconOnly = false;
            ToolTabsScroll.Visibility = Visibility.Collapsed;
            ToolTabsChrome.Visibility = Visibility.Collapsed;
            ToolTabsScroll.Width = 0;
            ToolTabsChrome.Width = 0;
            return;
        }

        ToolTabsScroll.Visibility = Visibility.Visible;
        ToolTabsChrome.Visibility = Visibility.Visible;

        var layout = ResolveHeaderToolSwitcherLayout(
            availableToolSwitcherWidth > 0 ? availableToolSwitcherWidth : ResolveHeaderAvailableToolSwitcherWidth(metrics));
        _lastToolSwitcherIconOnly = layout.IconOnly;
        ApplyToolSwitcherLayout(layout, metrics);

        ToolTabsPanel.Children.Clear();
        foreach (var visibleTab in layout.VisibleTabs)
        {
            var isActive = IsActiveHeaderTab(visibleTab);
            var foreground = isActive ? Brush("V2ForegroundBrush") : Brush("V2MutedForegroundBrush");
            var hasUnread = visibleTab.Tab == AppTab.AlwaysOn && HasUnreadSession();
            var content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
            };
            var icon = Icon(visibleTab.IconKey, 13, foreground);
            content.Children.Add(icon);
            if (!layout.IconOnly)
            {
                content.Children.Add(
                    new TextBlock
                    {
                        Text = TabLabel(visibleTab),
                        FontSize = 12.5,
                        FontWeight = isActive ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Medium,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                        VerticalAlignment = VerticalAlignment.Center,
                    });
            }

            var contentGrid = new Grid();
            contentGrid.Children.Add(content);
            if (hasUnread)
            {
                contentGrid.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse
                {
                    Width = 8,
                    Height = 8,
                    Fill = Brush("V2BlueBrush"),
                    Stroke = Brush("V2BackgroundBrush"),
                    StrokeThickness = 2,
                    HorizontalAlignment = HorizontalAlignment.Right,
                    VerticalAlignment = VerticalAlignment.Top,
                    Margin = new Thickness(0, -2, -2, 0),
                });
            }

            var button = new Button
            {
                Width = MainHeaderToolSwitcherLayout.ButtonWidth(visibleTab, layout.IconOnly),
                Height = MainHeaderToolSwitcherLayout.ButtonHeight,
                MinWidth = 0,
                Padding = layout.IconOnly ? new Thickness(0) : new Thickness(6, 0, 6, 0),
                CornerRadius = new CornerRadius(13),
                Background = isActive ? Brush("V2TitlebarSwitchActiveSurfaceBrush") : Transparent,
                BorderBrush = isActive ? Brush("V2TitlebarSwitchActiveBorderBrush") : Transparent,
                BorderThickness = isActive ? new Thickness(1) : new Thickness(0),
                Foreground = foreground,
                UseSystemFocusVisuals = false,
                Tag = visibleTab,
                Content = contentGrid,
            };
            ToolTipService.SetToolTip(button, TabLabel(visibleTab));
            button.Click += OnTabClick;
            ToolTabsPanel.Children.Add(button);
        }
    }

    private MainHeaderToolSwitcherLayout ResolveHeaderToolSwitcherLayout(double availableWidth)
    {
        var tabs = ResolveHeaderToolSwitcherTabs();
        return MainHeaderToolSwitcherLayout.Resolve(availableWidth, State.ActiveTab, tabs, State.ActivePluginTabId);
    }

    private bool HasUnreadSession()
    {
        return State.Projects.Any(project => project.AllSessions.Any(session =>
            session.State == SessionState.Unread || _unreadSessionIds.Contains(session.Id)));
    }

    private IReadOnlyList<V2TabDescriptor> ResolveHeaderToolSwitcherTabs()
    {
        if (State.SelectedProject is null)
        {
            return [AppTabCatalog.Descriptor(AppTab.Chat)];
        }

        if (State.SelectedProject is { } selected && IsGeneralProject(selected))
        {
            return
            [
                AppTabCatalog.Descriptor(AppTab.Chat),
                AppTabCatalog.Descriptor(AppTab.Skills),
            ];
        }

        return AppTabCatalog.PrimaryTabDescriptors;
    }

    private bool IsActiveHeaderTab(V2TabDescriptor tab)
    {
        if (tab.Tab == AppTab.Preview && State.ActiveTab == AppTab.Preview)
        {
            return string.Equals(tab.Id, State.ActivePluginTabId, StringComparison.OrdinalIgnoreCase);
        }

        return State.ActiveTab == tab.Tab;
    }

    private void ApplyToolSwitcherLayout(MainHeaderToolSwitcherLayout layout, HeaderLayoutMetrics? metrics)
    {
        var tabMaxWidth = metrics?.TabMaxWidth ?? layout.EstimatedWidth;
        var targetWidth = Math.Min(layout.EstimatedWidth, Math.Max(0, tabMaxWidth));
        ToolTabsScroll.Height = MainHeaderToolSwitcherLayout.ContainerHeight;
        ToolTabsScroll.Width = targetWidth;
        ToolTabsScroll.MaxWidth = tabMaxWidth;
        ToolTabsChrome.Width = layout.EstimatedWidth;
        ToolTabsChrome.Height = MainHeaderToolSwitcherLayout.ContainerHeight;
        ToolTabsChrome.Padding = new Thickness(
            MainHeaderToolSwitcherLayout.ContainerPadding,
            MainHeaderToolSwitcherLayout.ContainerVerticalPadding,
            MainHeaderToolSwitcherLayout.ContainerPadding,
            MainHeaderToolSwitcherLayout.ContainerVerticalPadding);
        ToolTabsChrome.CornerRadius = new CornerRadius(MainHeaderToolSwitcherLayout.ContainerCornerRadius);
        ToolTabsPanel.Spacing = MainHeaderToolSwitcherLayout.ItemSpacing;
    }

    private string ActiveTabLabel()
    {
        if (State.ActiveTab == AppTab.Preview &&
            State.ActivePluginTabId is { } pluginId &&
            State.PluginManifests.FirstOrDefault(plugin => string.Equals(plugin.Id, pluginId, StringComparison.OrdinalIgnoreCase)) is { } plugin)
        {
            return plugin.Name;
        }

        return TabLabel(State.ActiveTab);
    }

    private string TabLabel(AppTab tab) => tab switch
    {
        AppTab.Chat => T("tabs.chat"),
        AppTab.Files => T("tabs.files"),
        AppTab.Skills => T("tabs.skills"),
        AppTab.Dashboard => T("tabs.dashboard"),
        AppTab.Memory => T("tabs.memory"),
        AppTab.AlwaysOn => T("tabs.alwaysOn"),
        _ => AppTabCatalog.Label(tab),
    };

    private string TabLabel(V2TabDescriptor tab) => tab.Tab == AppTab.Preview ? tab.Label : TabLabel(tab.Tab);

    private void RenderContent()
    {
        CaptureChatScrollState();
        var shouldRefreshHeader = false;
        if (!AppTabCatalog.IsPrimary(State.ActiveTab) && State.ActiveTab != AppTab.Preview)
        {
            State.ActiveTab = AppTab.Chat;
            State.ActivePluginTabId = null;
            shouldRefreshHeader = true;
        }

        var activePlugin = State.ActiveTab == AppTab.Preview
            ? State.PluginManifests.FirstOrDefault(plugin => string.Equals(plugin.Id, State.ActivePluginTabId, StringComparison.OrdinalIgnoreCase))
            : null;
        if (State.ActiveTab == AppTab.Preview && activePlugin is null)
        {
            State.ActiveTab = AppTab.Chat;
            State.ActivePluginTabId = null;
            activePlugin = null;
            shouldRefreshHeader = true;
        }

        if (shouldRefreshHeader)
        {
            RenderHeader();
        }

        ContentHost.Children.Clear();
        FrameworkElement content;
        try
        {
            content = State.ActiveTab switch
            {
                AppTab.Chat => ChatPage(),
                AppTab.Files => FilesPage(),
                AppTab.Skills => SkillsPage(),
                AppTab.Dashboard => RoutingPage(),
                AppTab.Memory => MemoryPage(),
                AppTab.AlwaysOn => AlwaysOnPage(),
                AppTab.Preview when activePlugin is not null => PluginPlaceholder(activePlugin),
                _ => ToolPlaceholder(T("tabs.preview"), T("preview.detail"), "eye"),
            };
        }
        catch (Exception ex)
        {
            content = PageErrorFallback(ex);
        }

        if (State.ActiveTab != AppTab.Chat)
        {
            _chatScrollViewer = null;
        }

        ContentHost.Children.Add(content);
    }

    private FrameworkElement PageErrorFallback(Exception ex) => new Grid
    {
        Background = Brush("V2BackgroundBrush"),
        Padding = new Thickness(24),
        Children =
        {
            ErrorState(ex.Message),
        },
    };

    private FrameworkElement ChatPage()
    {
        var root = new Grid { Background = Brush("V2BackgroundBrush") };
        var widthBoundElements = new List<FrameworkElement>();
        void TrackChatColumnWidth(FrameworkElement element)
        {
            widthBoundElements.Add(element);
            element.Width = V2LayoutMetrics.ChatColumnMaxWidth;
        }

        void ApplyChatColumnWidth()
        {
            if (root.ActualWidth <= 0) return;
            var available = Math.Max(320, root.ActualWidth - V2LayoutMetrics.ChatColumnHorizontalPadding * 2);
            var width = Math.Min(V2LayoutMetrics.ChatColumnMaxWidth, available);
            foreach (var element in widthBoundElements)
            {
                element.Width = width;
            }
        }

        root.SizeChanged += (_, _) => ApplyChatColumnWidth();

        var processTracePresentation = ProcessTracePresentation.Make(
            AgentActivity.ProcessTraceActivities(State.CurrentActivities),
            IsChineseUi());
        var composerRunningStatus = ComposerRunningStatusPresentation.Make(State.CurrentActivities, IsChineseUi());
        var inlinePermissionRequests = InlinePendingPermissions();
        var footerReserve = V2LayoutMetrics.ComposerMinHeight +
            (composerRunningStatus.ShouldRender ? 34 : 0) +
            (inlinePermissionRequests.Count == 0
            ? 66
            : inlinePermissionRequests.Any(request => request.Kind is PermissionRequestKind.AskUserQuestion or PermissionRequestKind.ExitPlanMode or PermissionRequestKind.DestructivePlanApproval) ? 620 : 214);
        var hasMessages = processTracePresentation.ShouldRender ||
            State.CurrentMessages.Count > 0 ||
            (State.SelectedSessionId is { } currentSessionId &&
             State.TurnsBySession.TryGetValue(currentSessionId, out var currentTurns) &&
             currentTurns.Count > 0);
        var isReadOnlyBackgroundSession = State.IsSelectedSessionReadOnlyBackground;

        StackPanel? welcomePanel = null;
        var showGeneralProjectEntry = false;
        if (!hasMessages)
        {
            _chatScrollViewer = null;
            var detail = isReadOnlyBackgroundSession
                ? T("chat.readOnlyBackground.description")
                : !IsAgentModelConfigured()
                ? T("chat.empty.configureProvider")
                : "";
            welcomePanel = new StackPanel
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(24, 0, 24, 0),
                MaxWidth = V2LayoutMetrics.ComposerMaxWidth,
                Spacing = 0,
            };
            TrackChatColumnWidth(welcomePanel);
            welcomePanel.Loaded += (_, _) => ApplyChatColumnWidth();
            var title = isReadOnlyBackgroundSession
                ? T("chat.readOnlyBackground.title")
                : ChatEmptyStateTitle();
            welcomePanel.Children.Add(ChatEmptyPrompt(title, detail));
            showGeneralProjectEntry = !isReadOnlyBackgroundSession && GeneralProjectEntryPresentation.ShouldRender(State.SelectedProject);
            root.Children.Add(welcomePanel);
        }
        else
        {
            var scroll = new ScrollViewer
            {
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            };
            _chatScrollViewer = scroll;
            scroll.ViewChanged += (_, _) => UpdateChatScrollState(scroll);
            scroll.Loaded += (_, _) => RestoreChatScrollState(scroll);
            var messages = new StackPanel
            {
                MaxWidth = V2LayoutMetrics.ChatColumnMaxWidth,
                HorizontalAlignment = HorizontalAlignment.Center,
                Padding = new Thickness(0, 20, 0, footerReserve),
                Spacing = 18,
            };
            TrackChatColumnWidth(messages);

            if (processTracePresentation.ShouldRender)
            {
                messages.Children.Add(ProcessLiveStatusRow(processTracePresentation));
            }

            foreach (var message in State.CurrentMessages)
            {
                messages.Children.Add(MessageRow(message));
            }

            scroll.Content = messages;
            root.Children.Add(scroll);
        }

        var composerFooter = new StackPanel
        {
            MaxWidth = V2LayoutMetrics.ComposerMaxWidth,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, V2LayoutMetrics.ComposerBottomPadding),
            Spacing = 8,
        };
        TrackChatColumnWidth(composerFooter);
        if (composerRunningStatus.ShouldRender)
        {
            composerFooter.Children.Add(ComposerRunningStatusRow(composerRunningStatus));
        }
        if (inlinePermissionRequests.Count > 0)
        {
            composerFooter.Children.Add(PermissionBanner(inlinePermissionRequests));
        }

        if (isReadOnlyBackgroundSession)
        {
            if (hasMessages)
            {
                composerFooter.Children.Add(ReadOnlyBackgroundFooter());
                root.Children.Add(composerFooter);
            }

            return root;
        }

        var composerShell = new Border
        {
            MaxWidth = V2LayoutMetrics.ComposerMaxWidth,
            MinHeight = V2LayoutMetrics.ComposerMinHeight,
            BorderBrush = Brush("V2ComposerBorderBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(18),
            Background = Brush("V2ComposerSurfaceBrush"),
            Padding = new Thickness(10, 9, 10, 9),
        };
        TrackChatColumnWidth(composerShell);
        var composerStack = new StackPanel { Spacing = 8 };
        composerShell.Child = composerStack;
        Button? sendButton = null;
        void RefreshSubmitState()
        {
            if (sendButton is not null && !_isAgentRunning && !_isAgentSubmitting)
            {
                sendButton.IsEnabled = ComposerCanSubmit();
            }
        }

        var attachmentTray = ComposerAttachmentTray();
        if (attachmentTray is not null)
        {
            composerStack.Children.Add(attachmentTray);
        }

        var composer = new TextBox
        {
            Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
            AcceptsReturn = true,
            MinHeight = V2LayoutMetrics.ComposerTextBoxMinHeight,
            MaxHeight = V2LayoutMetrics.ComposerTextBoxMaxHeight,
            TextWrapping = TextWrapping.Wrap,
            PlaceholderText = T("chat.composer.placeholder"),
            Padding = new Thickness(8, 8, 8, 8),
            Text = State.ComposerText,
            IsEnabled = !_isAgentRunning && !_isAgentSubmitting,
            Background = Transparent,
            BorderBrush = Transparent,
            BorderThickness = new Thickness(0),
        };
        _composerTextBox = composer;
        composer.Paste += OnComposerPaste;
        composer.TextChanged += (_, _) =>
        {
            if (_suppressComposerTextChanged) return;
            State.ComposerText = composer.Text;
            RefreshSubmitState();
        };
        composer.KeyUp += OnComposerKeyUp;
        composer.PreviewKeyDown += OnComposerKeyDown;
        composerStack.Children.Add(composer);

        var controlsRow = new Grid { ColumnSpacing = 8 };
        controlsRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        controlsRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var leftControls = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 2,
        };
        var attachmentButton = ComposerIconButton("Paperclip", T("chat.composer.attach"));
        var attachmentFlyout = new MenuFlyout();
        var attachFiles = new MenuFlyoutItem { Text = T("chat.composer.attach") };
        attachFiles.Click += async (_, _) => await AttachComposerFilesAsync();
        attachmentFlyout.Items.Add(attachFiles);
        var attachFolder = new MenuFlyoutItem { Text = IsChineseUi() ? "\u6dfb\u52a0\u6587\u4ef6\u5939" : "Attach folder" };
        attachFolder.Click += async (_, _) => await AttachComposerFolderAsync();
        attachmentFlyout.Items.Add(attachFolder);
        attachmentButton.Flyout = attachmentFlyout;
        leftControls.Children.Add(attachmentButton);
        var modeButton = ComposerPillButton(
            ComposerRunModeIcon(State.ComposerRunMode),
            State.ComposerRunMode.Label());
        modeButton.Flyout = ComposerRunModeFlyout();
        leftControls.Children.Add(modeButton);
        var permissionButton = ComposerPillButton(
            ComposerPermissionModeIcon(State.ComposerPermissionMode),
            State.ComposerPermissionMode.Label());
        permissionButton.Flyout = ComposerPermissionFlyout();
        leftControls.Children.Add(permissionButton);
        controlsRow.Children.Add(leftControls);

        var rightControls = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 4,
            VerticalAlignment = VerticalAlignment.Center,
        };
        rightControls.Children.Add(ContextGaugeButton());
        var send = ComposerSendButton();
        sendButton = send;
        send.Click += _isAgentRunning || _isAgentSubmitting ? OnStopAgentClick : OnSendClick;
        rightControls.Children.Add(send);
        Grid.SetColumn(rightControls, 1);
        controlsRow.Children.Add(rightControls);
        composerStack.Children.Add(controlsRow);

        if (welcomePanel is not null)
        {
            welcomePanel.Children.Add(composerShell);
            if (showGeneralProjectEntry)
            {
                welcomePanel.Children.Add(GeneralProjectEntryButton());
            }
        }
        else
        {
            composerFooter.Children.Add(composerShell);
            root.Children.Add(composerFooter);
        }
        composerShell.Loaded += (_, _) => ApplyChatColumnWidth();

        return root;
    }

    private FrameworkElement ComposerRunningStatusRow(ComposerRunningStatusPresentation presentation)
    {
        var row = new Grid
        {
            Height = 22,
            Margin = new Thickness(24, 0, 24, 0),
            ColumnSpacing = 7,
            MaxWidth = V2LayoutMetrics.ComposerMaxWidth,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
            },
        };
        row.Children.Add(new ProgressRing
        {
            IsActive = presentation.ShouldShimmer,
            Width = 12,
            Height = 12,
            VerticalAlignment = VerticalAlignment.Center,
        });

        var summary = new TextBlock
        {
            Text = presentation.SummaryText,
            FontSize = 12.5,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            Foreground = Brush("V2SecondaryForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 360,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(summary, 1);
        row.Children.Add(summary);

        if (!string.IsNullOrWhiteSpace(presentation.DetailText))
        {
            var detail = new TextBlock
            {
                Text = presentation.DetailText,
                FontSize = 11.5,
                Foreground = Brush("V2MutedForegroundBrush"),
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxWidth = 280,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(detail, 2);
            row.Children.Add(detail);
        }

        return row;
    }

    private IReadOnlyList<PermissionRequest> InlinePendingPermissions() =>
        State.PendingPermissions
            .Where(request => _pendingPermissionCompletions.ContainsKey(request.Id))
            .OrderBy(request => request.CreatedAt)
            .ToList();

    private FrameworkElement PermissionCardFor(PermissionRequest request) => request.Kind switch
    {
        PermissionRequestKind.AskUserQuestion => AskUserQuestionPanel(request),
        PermissionRequestKind.ExitPlanMode => ExitPlanModePermissionCard(request),
        PermissionRequestKind.DestructivePlanApproval => DestructivePlanPermissionCard(request),
        _ => GenericPermissionCard(request),
    };

    private FrameworkElement PermissionBanner(IReadOnlyList<PermissionRequest> requests)
    {
        var stack = new StackPanel
        {
            Spacing = 10,
            MaxWidth = V2LayoutMetrics.ComposerMaxWidth,
        };
        foreach (var request in requests)
        {
            stack.Children.Add(PermissionCardFor(request));
        }

        if (requests.Count <= 1) return stack;
        return new ScrollViewer
        {
            MaxHeight = 132,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = stack,
        };
    }

    private FrameworkElement GenericPermissionCard(PermissionRequest request)
    {
        var isChinese = IsChineseUi();
        var showingInput = _expandedPermissionInputIds.Contains(request.Id);
        var stack = new StackPanel { Spacing = 10 };

        var header = new Grid { ColumnSpacing = 10 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        header.Children.Add(Icon("AlertCircle", 15, Brush("V2AmberBrush")));

        var copy = new StackPanel { Spacing = 4 };
        copy.Children.Add(new TextBlock
        {
            Text = isChinese ? "\u9700\u8981\u6743\u9650\u786e\u8ba4" : "Permission required",
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
        });
        copy.Children.Add(new TextBlock
        {
            Text = request.Reason,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Foreground = Brush("V2SecondaryForegroundBrush"),
        });
        var toolRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        toolRow.Children.Add(new TextBlock
        {
            Text = isChinese ? "\u5de5\u5177:" : "Tool:",
            FontSize = 11,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            Foreground = Brush("V2MutedForegroundBrush"),
        });
        toolRow.Children.Add(new TextBlock
        {
            Text = request.ToolName,
            FontSize = 11,
            FontFamily = new FontFamily("Consolas"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2SecondaryForegroundBrush"),
        });
        copy.Children.Add(toolRow);
        Grid.SetColumn(copy, 1);
        header.Children.Add(copy);

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Top,
        };
        actions.Children.Add(PermissionActionButton(
            isChinese ? "\u62d2\u7edd" : "Deny",
            Brush("V2RedBrush"),
            Transparent,
            async () => await ResolveInlinePermissionRequestAsync(request, PermissionDecision.Denied, null, null)));
        actions.Children.Add(PermissionActionButton(
            isChinese ? "\u5141\u8bb8\u4e00\u6b21" : "Allow once",
            Brush("V2AmberBrush"),
            new SolidColorBrush(global::Windows.UI.Color.FromArgb(24, 245, 158, 11)),
            async () => await ResolveInlinePermissionRequestAsync(request, PermissionDecision.Allowed, PermissionScope.Session, null)));
        actions.Children.Add(PermissionActionButton(
            isChinese ? "\u59cb\u7ec8\u5141\u8bb8" : "Always allow",
            Brush("V2InverseForegroundBrush"),
            Brush("V2InverseBrush"),
            async () => await ResolveInlinePermissionRequestAsync(request, PermissionDecision.Allowed, PermissionScope.Project, null, remember: true)));
        Grid.SetColumn(actions, 2);
        header.Children.Add(actions);
        stack.Children.Add(header);

        if (!string.IsNullOrWhiteSpace(request.InputJson))
        {
            var inputToggle = new Button
            {
                MinWidth = 0,
                MinHeight = 0,
                HorizontalAlignment = HorizontalAlignment.Left,
                Background = Transparent,
                BorderBrush = Transparent,
                Padding = new Thickness(0, 3, 0, 3),
                Content = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 6,
                    Children =
                    {
                        Icon(showingInput ? "ChevronDown" : "ChevronRight", 10, Brush("V2AmberBrush")),
                        new TextBlock
                        {
                            Text = isChinese ? "\u67e5\u770b\u5de5\u5177\u8f93\u5165" : "View tool input",
                            FontSize = 11,
                            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                            Foreground = Brush("V2AmberBrush"),
                            VerticalAlignment = VerticalAlignment.Center,
                        },
                    },
                },
            };
            inputToggle.Click += (_, _) =>
            {
                if (!_expandedPermissionInputIds.Remove(request.Id))
                {
                    _expandedPermissionInputIds.Add(request.Id);
                }
                RenderContent();
            };
            stack.Children.Add(inputToggle);

            if (showingInput)
            {
                stack.Children.Add(new Border
                {
                    Padding = new Thickness(10),
                    CornerRadius = new CornerRadius(6),
                    BorderThickness = new Thickness(1),
                    BorderBrush = Brush("V2BorderBrush"),
                    Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(18, 245, 158, 11)),
                    Child = new TextBlock
                    {
                        Text = request.InputJson,
                        FontSize = 10,
                        FontFamily = new FontFamily("Consolas"),
                        Foreground = Brush("V2SecondaryForegroundBrush"),
                        TextWrapping = TextWrapping.Wrap,
                        MaxHeight = 168,
                    },
                });
            }
        }

        return new Border
        {
            Padding = new Thickness(12),
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            BorderBrush = Brush("V2AmberBrush"),
            Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(20, 245, 158, 11)),
            Child = stack,
        };
    }

    private FrameworkElement AskUserQuestionPanel(PermissionRequest request)
    {
        var payload = request.InteractivePayload is { Questions.Count: > 0 }
            ? request.InteractivePayload
            : new AgentInteractivePayload([new AgentQuestion("Question", request.Reason, [], false)]);
        var isChinese = IsChineseUi();
        var currentIndex = Math.Clamp(_askQuestionIndexes.GetValueOrDefault(request.Id), 0, Math.Max(0, payload.Questions.Count - 1));
        _askQuestionIndexes[request.Id] = currentIndex;
        var question = payload.Questions[currentIndex];

        var stack = new StackPanel { Spacing = 0 };
        stack.Children.Add(new Border
        {
            Height = 3,
            Background = Brush("V2BlueBrush"),
        });

        var body = new StackPanel
        {
            Spacing = 14,
            Padding = new Thickness(14),
        };

        var header = new Grid { ColumnSpacing = 10 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new Border
        {
            Width = 30,
            Height = 30,
            CornerRadius = new CornerRadius(15),
            Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(44, 59, 130, 246)),
            Child = Icon("MessageSquarePlus", 15, Brush("V2BlueBrush")),
        });

        var headerCopy = new StackPanel { Spacing = 3 };
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        titleRow.Children.Add(new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(question.Header) ? "AskQuestion" : question.Header,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2BlueBrush"),
        });
        if (payload.Questions.Count > 1)
        {
            titleRow.Children.Add(new TextBlock
            {
                Text = $"{currentIndex + 1} / {payload.Questions.Count}",
                FontSize = 11,
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                Foreground = Brush("V2MutedForegroundBrush"),
            });
        }
        headerCopy.Children.Add(titleRow);
        headerCopy.Children.Add(new TextBlock
        {
            Text = question.Question,
            FontSize = 14,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            Foreground = Brush("V2ForegroundBrush"),
        });
        Grid.SetColumn(headerCopy, 1);
        header.Children.Add(headerCopy);

        var close = new Button
        {
            MinWidth = 0,
            MinHeight = 0,
            Width = 28,
            Height = 28,
            Padding = new Thickness(0),
            Background = Transparent,
            BorderBrush = Transparent,
            Content = Icon("X", 12, Brush("V2MutedForegroundBrush")),
        };
        close.Click += async (_, _) => await ResolveInlinePermissionRequestAsync(request, PermissionDecision.Denied, null, null);
        Grid.SetColumn(close, 2);
        header.Children.Add(close);
        body.Children.Add(header);

        if (payload.Questions.Count > 1)
        {
            body.Children.Add(AskQuestionProgress(payload.Questions.Count, currentIndex));
        }

        var options = new StackPanel { Spacing = 8 };
        for (var index = 0; index < question.Options.Count; index++)
        {
            options.Children.Add(AskQuestionOptionButton(request, question, question.Options[index], index));
        }
        options.Children.Add(AskQuestionOtherButton(request, question));
        if (AskQuestionOtherActive(request.Id, question) || question.Options.Count == 0)
        {
            options.Children.Add(AskQuestionOtherInput(request, question));
        }
        body.Children.Add(options);

        if (_askQuestionValidationErrors.Contains(AskQuestionValidationKey(request.Id, question)))
        {
            body.Children.Add(new TextBlock
            {
                Text = isChinese ? "\u8bf7\u5148\u9009\u62e9\u6216\u8f93\u5165\u7b54\u6848\u3002" : "Choose or type an answer before continuing.",
                FontSize = 12,
                Foreground = Brush("V2RedBrush"),
                TextWrapping = TextWrapping.Wrap,
            });
        }

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Spacing = 8,
        };
        if (currentIndex > 0)
        {
            actions.Children.Add(AskQuestionNavButton(isChinese ? "\u4e0a\u4e00\u6b65" : "Back", Brush("V2SecondaryForegroundBrush"), () =>
            {
                _askQuestionIndexes[request.Id] = Math.Max(0, currentIndex - 1);
                RenderContent();
            }));
        }

        var primary = AskQuestionNavButton(
            currentIndex == payload.Questions.Count - 1 ? (isChinese ? "\u63d0\u4ea4" : "Submit") : (isChinese ? "\u4e0b\u4e00\u6b65" : "Next"),
            Brush("V2BlueBrush"),
            async () =>
            {
                if (!AskQuestionHasAnswer(request.Id, question))
                {
                    _askQuestionValidationErrors.Add(AskQuestionValidationKey(request.Id, question));
                    RenderContent();
                    return;
                }
                if (currentIndex == payload.Questions.Count - 1)
                {
                    await SubmitAskQuestionAsync(request, payload);
                    return;
                }

                _askQuestionIndexes[request.Id] = Math.Min(payload.Questions.Count - 1, currentIndex + 1);
                RenderContent();
            });
        actions.Children.Add(primary);
        body.Children.Add(actions);

        stack.Children.Add(body);
        return new Border
        {
            MaxWidth = V2LayoutMetrics.ComposerMaxWidth,
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            BorderBrush = Brush("V2BorderBrush"),
            Background = Brush("V2CardBrush"),
            Child = stack,
        };
    }

    private FrameworkElement AskQuestionProgress(int count, int currentIndex)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
        for (var index = 0; index < count; index++)
        {
            row.Children.Add(new Border
            {
                Width = index == currentIndex ? 18 : 6,
                Height = 6,
                CornerRadius = new CornerRadius(3),
                Background = index == currentIndex ? Brush("V2BlueBrush") : Brush("V2BorderBrush"),
            });
        }

        return row;
    }

    private Button AskQuestionOptionButton(PermissionRequest request, AgentQuestion question, AgentQuestionOption option, int index)
    {
        var selected = AskQuestionSelection(request.Id, question).Contains(option.Label);
        var content = new Grid { ColumnSpacing = 10 };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        content.Children.Add(new Border
        {
            Width = 20,
            Height = 20,
            CornerRadius = new CornerRadius(5),
            Background = selected ? Brush("V2BlueBrush") : Brush("V2MutedBrush"),
            Child = new TextBlock
            {
                Text = $"{index + 1}",
                FontSize = 11,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Foreground = selected ? Brush("V2InverseForegroundBrush") : Brush("V2MutedForegroundBrush"),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        });

        var copy = new StackPanel { Spacing = 2 };
        copy.Children.Add(new TextBlock
        {
            Text = option.Label,
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            TextWrapping = TextWrapping.Wrap,
            Foreground = Brush("V2ForegroundBrush"),
        });
        if (!string.IsNullOrWhiteSpace(option.Description))
        {
            copy.Children.Add(new TextBlock
            {
                Text = option.Description,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                Foreground = Brush("V2MutedForegroundBrush"),
            });
        }
        Grid.SetColumn(copy, 1);
        content.Children.Add(copy);

        if (selected)
        {
            var check = Icon("CheckCircle", 14, Brush("V2BlueBrush"));
            Grid.SetColumn(check, 2);
            content.Children.Add(check);
        }

        return AskQuestionChoiceButton(content, selected, () =>
        {
            ToggleAskQuestionOption(request.Id, question, option.Label);
            RenderContent();
        });
    }

    private Button AskQuestionOtherButton(PermissionRequest request, AgentQuestion question)
    {
        var selected = AskQuestionOtherActive(request.Id, question) || question.Options.Count == 0;
        var isChinese = IsChineseUi();
        var content = new Grid { ColumnSpacing = 10 };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.Children.Add(Icon(selected ? "CheckCircle" : "CircleGauge", 16, selected ? Brush("V2BlueBrush") : Brush("V2MutedForegroundBrush")));
        var copy = new StackPanel { Spacing = 2 };
        copy.Children.Add(new TextBlock
        {
            Text = isChinese ? "\u5176\u4ed6" : "Other",
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            Foreground = Brush("V2ForegroundBrush"),
        });
        copy.Children.Add(new TextBlock
        {
            Text = isChinese ? "\u9009\u62e9\u540e\u586b\u5199\u81ea\u5b9a\u4e49\u7b54\u6848" : "Select to type a custom answer",
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Foreground = Brush("V2MutedForegroundBrush"),
        });
        Grid.SetColumn(copy, 1);
        content.Children.Add(copy);

        var button = AskQuestionChoiceButton(content, selected, () =>
        {
            ToggleAskQuestionOther(request.Id, question);
            RenderContent();
        });
        button.IsEnabled = question.Options.Count > 0;
        return button;
    }

    private FrameworkElement AskQuestionOtherInput(PermissionRequest request, AgentQuestion question)
    {
        var isChinese = IsChineseUi();
        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(new TextBlock
        {
            Text = isChinese ? "\u8865\u5145" : "Custom",
            Width = 44,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2MutedForegroundBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        });
        var input = new TextBox
        {
            Text = AskQuestionOtherAnswer(request.Id, question),
            PlaceholderText = isChinese ? "\u8f93\u5165\u81ea\u5b9a\u4e49\u7b54\u6848" : "Type a custom answer",
            Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
            BorderThickness = new Thickness(0),
            Background = Transparent,
            FontSize = 13,
        };
        input.TextChanged += (_, _) => SetAskQuestionOtherAnswer(request.Id, question, input.Text);
        Grid.SetColumn(input, 1);
        row.Children.Add(input);
        return new Border
        {
            Padding = new Thickness(10),
            CornerRadius = new CornerRadius(6),
            BorderThickness = new Thickness(1),
            BorderBrush = Brush("V2BorderBrush"),
            Background = Brush("V2MutedBrush"),
            Child = row,
        };
    }

    private Button AskQuestionChoiceButton(UIElement content, bool selected, Action onClick)
    {
        var button = new Button
        {
            MinWidth = 0,
            MinHeight = 0,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = selected ? new SolidColorBrush(global::Windows.UI.Color.FromArgb(18, 59, 130, 246)) : Brush("V2MutedBrush"),
            BorderBrush = selected ? Brush("V2BlueBrush") : Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10),
            Content = content,
        };
        button.Click += (_, _) => onClick();
        return button;
    }

    private Button AskQuestionNavButton(string label, Brush foreground, Func<Task> onClick)
    {
        var button = PermissionActionButton(label, foreground, Transparent, onClick);
        button.MinWidth = 74;
        return button;
    }

    private Button AskQuestionNavButton(string label, Brush foreground, Action onClick) =>
        AskQuestionNavButton(label, foreground, () =>
        {
            onClick();
            return Task.CompletedTask;
        });

    private Dictionary<string, HashSet<string>> AskQuestionSelections(Guid requestId)
    {
        if (!_askQuestionSelections.TryGetValue(requestId, out var selections))
        {
            selections = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
            _askQuestionSelections[requestId] = selections;
        }

        return selections;
    }

    private HashSet<string> AskQuestionSelection(Guid requestId, AgentQuestion question)
    {
        var selections = AskQuestionSelections(requestId);
        if (!selections.TryGetValue(question.Question, out var values))
        {
            values = new HashSet<string>(StringComparer.Ordinal);
            selections[question.Question] = values;
        }

        return values;
    }

    private Dictionary<string, string> AskQuestionOtherAnswers(Guid requestId)
    {
        if (!_askQuestionOtherAnswers.TryGetValue(requestId, out var answers))
        {
            answers = new Dictionary<string, string>(StringComparer.Ordinal);
            _askQuestionOtherAnswers[requestId] = answers;
        }

        return answers;
    }

    private HashSet<string> AskQuestionOtherActiveQuestions(Guid requestId)
    {
        if (!_askQuestionOtherActiveQuestions.TryGetValue(requestId, out var questions))
        {
            questions = new HashSet<string>(StringComparer.Ordinal);
            _askQuestionOtherActiveQuestions[requestId] = questions;
        }

        return questions;
    }

    private bool AskQuestionOtherActive(Guid requestId, AgentQuestion question) =>
        AskQuestionOtherActiveQuestions(requestId).Contains(question.Question);

    private string AskQuestionOtherAnswer(Guid requestId, AgentQuestion question) =>
        AskQuestionOtherAnswers(requestId).GetValueOrDefault(question.Question, "");

    private string AskQuestionValidationKey(Guid requestId, AgentQuestion question) =>
        $"{requestId:N}:{question.Question}";

    private void SetAskQuestionOtherAnswer(Guid requestId, AgentQuestion question, string value)
    {
        AskQuestionOtherAnswers(requestId)[question.Question] = value;
        if (!string.IsNullOrWhiteSpace(value))
        {
            _askQuestionValidationErrors.Remove(AskQuestionValidationKey(requestId, question));
        }
    }

    private void ToggleAskQuestionOption(Guid requestId, AgentQuestion question, string option)
    {
        _askQuestionValidationErrors.Remove(AskQuestionValidationKey(requestId, question));
        var values = AskQuestionSelection(requestId, question);
        if (question.MultiSelect)
        {
            if (!values.Remove(option))
            {
                values.Add(option);
            }
            return;
        }

        if (values.Contains(option))
        {
            values.Clear();
            return;
        }

        values.Clear();
        values.Add(option);
        AskQuestionOtherActiveQuestions(requestId).Remove(question.Question);
    }

    private void ToggleAskQuestionOther(Guid requestId, AgentQuestion question)
    {
        _askQuestionValidationErrors.Remove(AskQuestionValidationKey(requestId, question));
        var active = AskQuestionOtherActiveQuestions(requestId);
        if (!active.Remove(question.Question))
        {
            if (!question.MultiSelect)
            {
                AskQuestionSelection(requestId, question).Clear();
            }
            active.Add(question.Question);
        }
    }

    private bool AskQuestionHasAnswer(Guid requestId, AgentQuestion question)
    {
        if (AskQuestionSelection(requestId, question).Count > 0) return true;
        return (AskQuestionOtherActive(requestId, question) || question.Options.Count == 0) &&
               !string.IsNullOrWhiteSpace(AskQuestionOtherAnswer(requestId, question));
    }

    private string AskQuestionAnswer(Guid requestId, AgentQuestion question)
    {
        var values = AskQuestionSelection(requestId, question)
            .OrderBy(value => value, StringComparer.Ordinal)
            .ToList();
        var other = AskQuestionOtherAnswer(requestId, question).Trim();
        if ((AskQuestionOtherActive(requestId, question) || question.Options.Count == 0) && !string.IsNullOrWhiteSpace(other))
        {
            values.Add(other);
        }

        return string.Join(", ", values);
    }

    private async Task SubmitAskQuestionAsync(PermissionRequest request, AgentInteractivePayload payload)
    {
        var answers = payload.Questions.ToDictionary(
            question => question.Question,
            question => AskQuestionAnswer(request.Id, question),
            StringComparer.Ordinal);
        var updated = AskQuestionAnswerCodec.UpdatedInputJson(request.InputJson, answers);
        await ResolveInlinePermissionRequestAsync(request, PermissionDecision.Allowed, PermissionScope.Session, updated);
    }

    private void ClearInlinePermissionState(Guid requestId)
    {
        _expandedPermissionInputIds.Remove(requestId);
        _askQuestionIndexes.Remove(requestId);
        _askQuestionSelections.Remove(requestId);
        _askQuestionOtherAnswers.Remove(requestId);
        _askQuestionOtherActiveQuestions.Remove(requestId);
        _askQuestionValidationErrors.RemoveWhere(key => key.StartsWith($"{requestId:N}:", StringComparison.Ordinal));
        _exitPlanFeedback.Remove(requestId);
        _exitPlanFeedbackErrors.Remove(requestId);
    }

    private FrameworkElement ExitPlanModePermissionCard(PermissionRequest request)
    {
        var isChinese = IsChineseUi();
        var feedback = _exitPlanFeedback.GetValueOrDefault(request.Id, "");
        var stack = new StackPanel { Spacing = 0 };

        var header = new Grid
        {
            ColumnSpacing = 12,
            Padding = new Thickness(12),
            Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(14, 59, 130, 246)),
        };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.Children.Add(new Border
        {
            Width = 34,
            Height = 34,
            CornerRadius = new CornerRadius(10),
            Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(30, 59, 130, 246)),
            Child = Icon("ListChecks", 16, Brush("V2BlueBrush")),
        });
        var headerCopy = new StackPanel { Spacing = 4 };
        headerCopy.Children.Add(new TextBlock
        {
            Text = isChinese ? "\u8ba1\u5212\u5df2\u51c6\u5907\u597d" : "Plan is ready",
            FontSize = 14,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
        });
        headerCopy.Children.Add(new TextBlock
        {
            Text = isChinese
                ? "\u786e\u8ba4\u540e\u4f1a\u9000\u51fa Plan \u6a21\u5f0f\uff0c\u5e76\u8ba9\u4ee3\u7406\u5f00\u59cb\u6309\u8ba1\u5212\u6267\u884c\u3002"
                : "Confirm to leave Plan mode and let the agent execute this plan.",
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Foreground = Brush("V2SecondaryForegroundBrush"),
        });
        Grid.SetColumn(headerCopy, 1);
        header.Children.Add(headerCopy);
        stack.Children.Add(header);

        var planPanel = new StackPanel
        {
            Spacing = 8,
            Padding = new Thickness(12, 10, 12, 10),
        };
        planPanel.Children.Add(new Border
        {
            MinHeight = PlanConfirmationCardMetrics.PlanMinHeight,
            MaxHeight = PlanConfirmationCardMetrics.PlanMaxHeight,
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            BorderBrush = Brush("V2BorderBrush"),
            Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(14, 59, 130, 246)),
            Child = new Grid
            {
                Children =
                {
                    new ScrollViewer
                    {
                        MinHeight = PlanConfirmationCardMetrics.PlanMinHeight,
                        MaxHeight = PlanConfirmationCardMetrics.PlanMaxHeight,
                        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                        Padding = new Thickness(14),
                        Content = MarkdownContent(ExitPlanModeInputCodec.ExtractPlanMarkdown(request.InputJson, isChinese)),
                    },
                    new Border
                    {
                        HorizontalAlignment = HorizontalAlignment.Left,
                        VerticalAlignment = VerticalAlignment.Top,
                        Margin = new Thickness(8),
                        Padding = new Thickness(10, 5, 10, 5),
                        CornerRadius = new CornerRadius(12),
                        Background = Brush("V2CardBrush"),
                        Child = new TextBlock
                        {
                            Text = isChinese ? "\u8ba1\u5212" : "Plan",
                            FontSize = 11,
                            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                            Foreground = Brush("V2BlueBrush"),
                        },
                    },
                },
            },
        });
        stack.Children.Add(planPanel);

        var footer = new StackPanel
        {
            Spacing = 8,
            Padding = new Thickness(12),
            Background = Brush("V2BackgroundBrush"),
        };
        var executeDirect = PermissionActionButton(
            isChinese ? "\u662f\uff0c\u76f4\u63a5\u6267\u884c\u8ba1\u5212" : "Yes, execute the plan",
            Brush("V2BlueBrush"),
            new SolidColorBrush(global::Windows.UI.Color.FromArgb(18, 59, 130, 246)),
            async () => await ResolveExitPlanModeAsync(request, "agent", null));
        executeDirect.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        executeDirect.Content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children =
            {
                Icon("CheckCircle", 13, Brush("V2BlueBrush")),
                new TextBlock
                {
                    Text = isChinese ? "\u662f\uff0c\u76f4\u63a5\u6267\u884c\u8ba1\u5212" : "Yes, execute the plan",
                    FontSize = 12,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Foreground = Brush("V2BlueBrush"),
                    VerticalAlignment = VerticalAlignment.Center,
                },
            },
        };
        footer.Children.Add(executeDirect);

        var feedbackBox = new TextBox
        {
            Text = feedback,
            PlaceholderText = isChinese ? "\u5426\uff0c\u8865\u5145\u8981\u6c42" : "No, add requirements",
            Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
            BorderThickness = new Thickness(1),
            BorderBrush = Brush("V2BorderBrush"),
            Background = Brush("V2CardBrush"),
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            MinHeight = PlanConfirmationCardMetrics.ActionRowHeight,
        };
        feedbackBox.TextChanged += (_, _) =>
        {
            _exitPlanFeedback[request.Id] = feedbackBox.Text;
            if (!string.IsNullOrWhiteSpace(feedbackBox.Text))
            {
                _exitPlanFeedbackErrors.Remove(request.Id);
            }
        };
        feedbackBox.KeyDown += async (_, args) =>
        {
            if (args.Key == global::Windows.System.VirtualKey.Enter)
            {
                args.Handled = true;
                await SubmitExitPlanFeedbackAsync(request);
            }
        };
        footer.Children.Add(feedbackBox);
        if (_exitPlanFeedbackErrors.Contains(request.Id))
        {
            footer.Children.Add(new TextBlock
            {
                Text = isChinese ? "\u8bf7\u8f93\u5165\u9700\u8981\u7ee7\u7eed\u5b8c\u5584\u7684\u8981\u6c42\u3002" : "Add feedback before keeping the plan in Plan mode.",
                FontSize = 12,
                Foreground = Brush("V2RedBrush"),
                TextWrapping = TextWrapping.Wrap,
            });
        }

        var footerActions = new Grid { ColumnSpacing = 8 };
        footerActions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footerActions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var cancel = PermissionActionButton(
            isChinese ? "\u53d6\u6d88\u8ba1\u5212" : "Cancel plan",
            Brush("V2SecondaryForegroundBrush"),
            new SolidColorBrush(global::Windows.UI.Color.FromArgb(12, 115, 115, 115)),
            async () => await ResolveInlinePermissionRequestAsync(request, PermissionDecision.Denied, null, null));
        cancel.HorizontalAlignment = HorizontalAlignment.Stretch;
        footerActions.Children.Add(cancel);

        var execute = PermissionActionButton(
            isChinese ? "\u6267\u884c\u8ba1\u5212" : "Execute plan",
            Brush("V2BlueBrush"),
            new SolidColorBrush(global::Windows.UI.Color.FromArgb(18, 59, 130, 246)),
            async () => await ResolveExitPlanModeAsync(request, "agent", null));
        execute.HorizontalAlignment = HorizontalAlignment.Stretch;
        Grid.SetColumn(execute, 1);
        footerActions.Children.Add(execute);
        footer.Children.Add(footerActions);
        stack.Children.Add(footer);

        return new Border
        {
            MaxWidth = V2LayoutMetrics.ComposerMaxWidth,
            CornerRadius = new CornerRadius(16),
            BorderThickness = new Thickness(1),
            BorderBrush = Brush("V2BorderBrush"),
            Background = Brush("V2CardBrush"),
            Child = stack,
        };
    }

    private async Task ResolveExitPlanModeAsync(PermissionRequest request, string mode, string? feedback)
    {
        await ResolveInlinePermissionRequestAsync(
            request,
            PermissionDecision.Allowed,
            PermissionScope.Session,
            ExitPlanModeInputCodec.UpdatedInputJson(request.InputJson, mode, feedback));
    }

    private async Task SubmitExitPlanFeedbackAsync(PermissionRequest request)
    {
        var feedback = _exitPlanFeedback.GetValueOrDefault(request.Id, "").Trim();
        if (string.IsNullOrWhiteSpace(feedback))
        {
            _exitPlanFeedbackErrors.Add(request.Id);
            RenderContent();
            return;
        }

        await ResolveExitPlanModeAsync(request, "plan", feedback);
    }

    private FrameworkElement DestructivePlanPermissionCard(PermissionRequest request)
    {
        var isChinese = IsChineseUi();
        var toolName = DestructivePlanInputCodec.ToolName(request.InputJson, request.ToolName);
        var target = DestructivePlanInputCodec.Target(request.InputJson, isChinese);
        var stack = new StackPanel { Spacing = 0 };

        var header = new Grid
        {
            ColumnSpacing = 11,
            Padding = new Thickness(12),
            Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(14, 239, 68, 68)),
        };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new Border
        {
            Width = 32,
            Height = 32,
            CornerRadius = new CornerRadius(9),
            Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(30, 239, 68, 68)),
            Child = Icon("Trash", 15, Brush("V2RedBrush")),
        });

        var copy = new StackPanel { Spacing = 4 };
        copy.Children.Add(new TextBlock
        {
            Text = isChinese ? "\u786e\u8ba4\u5220\u9664\u8ba1\u5212" : "Confirm deletion plan",
            FontSize = 14,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
        });
        copy.Children.Add(new TextBlock
        {
            Text = $"{toolName} - {target}",
            FontSize = 11.5,
            FontFamily = new FontFamily("Consolas"),
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = Brush("V2SecondaryForegroundBrush"),
        });
        Grid.SetColumn(copy, 1);
        header.Children.Add(copy);

        var close = new Button
        {
            MinWidth = 0,
            MinHeight = 0,
            Width = 28,
            Height = 28,
            Padding = new Thickness(0),
            Background = Transparent,
            BorderBrush = Transparent,
            Content = Icon("X", 12, Brush("V2MutedForegroundBrush")),
        };
        close.Click += async (_, _) => await ResolveInlinePermissionRequestAsync(request, PermissionDecision.Denied, null, null);
        Grid.SetColumn(close, 2);
        header.Children.Add(close);
        stack.Children.Add(header);

        stack.Children.Add(new Border
        {
            Padding = new Thickness(12, 10, 12, 10),
            Child = MarkdownContent(DestructivePlanInputCodec.PlanMarkdown(request.InputJson, isChinese)),
        });

        var footer = new Grid
        {
            ColumnSpacing = 8,
            Padding = new Thickness(12),
            Background = Brush("V2BackgroundBrush"),
        };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var cancel = PermissionActionButton(
            isChinese ? "\u53d6\u6d88" : "Cancel",
            Brush("V2SecondaryForegroundBrush"),
            Brush("V2CardBrush"),
            async () => await ResolveInlinePermissionRequestAsync(request, PermissionDecision.Denied, null, null));
        footer.Children.Add(cancel);

        var execute = PermissionActionButton(
            isChinese ? "\u6267\u884c\u8ba1\u5212" : "Execute plan",
            Brush("V2InverseForegroundBrush"),
            Brush("V2RedBrush"),
            async () => await ResolveInlinePermissionRequestAsync(request, PermissionDecision.Allowed, PermissionScope.Session, null));
        execute.Content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Children =
            {
                Icon("CheckCircle", 13, Brush("V2InverseForegroundBrush")),
                new TextBlock
                {
                    Text = isChinese ? "\u6267\u884c\u8ba1\u5212" : "Execute plan",
                    FontSize = 12,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Foreground = Brush("V2InverseForegroundBrush"),
                    VerticalAlignment = VerticalAlignment.Center,
                },
            },
        };
        Grid.SetColumn(execute, 2);
        footer.Children.Add(execute);
        stack.Children.Add(footer);

        return new Border
        {
            MaxWidth = V2LayoutMetrics.ComposerMaxWidth,
            CornerRadius = new CornerRadius(16),
            BorderThickness = new Thickness(1),
            BorderBrush = Brush("V2RedBrush"),
            Background = Brush("V2CardBrush"),
            Child = stack,
        };
    }

    private Button PermissionActionButton(string label, Brush foreground, Brush background, Func<Task> onClick)
    {
        var button = new Button
        {
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(10, 6, 10, 6),
            Background = background,
            BorderBrush = foreground,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Foreground = foreground,
            Content = new TextBlock
            {
                Text = label,
                FontSize = 12,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.NoWrap,
            },
        };
        button.Click += async (_, _) => await onClick();
        return button;
    }

    private FrameworkElement ProcessLiveStatusRow(ProcessTracePresentation presentation)
    {
        var key = $"process-live:{State.SelectedSessionId ?? "draft"}";
        var expanded = presentation.CanExpand && IsToolRowExpanded(key);
        var stack = new StackPanel { Spacing = 7, Margin = new Thickness(0, 0, 0, 2) };
        var button = new Button
        {
            MinWidth = 0,
            MinHeight = 0,
            HorizontalAlignment = HorizontalAlignment.Left,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = Transparent,
            BorderBrush = Transparent,
            Padding = new Thickness(0, 2, 0, 2),
            UseSystemFocusVisuals = false,
            Content = new Grid
            {
                ColumnSpacing = 8,
                ColumnDefinitions =
                {
                    new ColumnDefinition { Width = new GridLength(18) },
                    new ColumnDefinition { Width = GridLength.Auto },
                    new ColumnDefinition { Width = GridLength.Auto },
                    new ColumnDefinition { Width = GridLength.Auto },
                },
                Children =
                {
                    Icon(presentation.IconName, 15, Brush("V2MutedForegroundBrush")),
                    new TextBlock
                    {
                        Text = presentation.SummaryText,
                        FontSize = 13,
                        FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                        Foreground = Brush("V2MutedForegroundBrush"),
                        VerticalAlignment = VerticalAlignment.Center,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                        MaxWidth = 560,
                    },
                    new ProgressRing
                    {
                        IsActive = presentation.ShouldShimmer,
                        Width = 12,
                        Height = 12,
                        Visibility = presentation.ShouldShimmer ? Visibility.Visible : Visibility.Collapsed,
                        VerticalAlignment = VerticalAlignment.Center,
                    },
                    Icon(expanded ? "ChevronDown" : "ChevronRight", 12, Brush("V2MutedForegroundBrush")),
                },
            },
        };
        if (button.Content is Grid grid)
        {
            Grid.SetColumn((FrameworkElement)grid.Children[1], 1);
            Grid.SetColumn((FrameworkElement)grid.Children[2], 2);
            Grid.SetColumn((FrameworkElement)grid.Children[3], 3);
            grid.Children[3].Visibility = presentation.CanExpand ? Visibility.Visible : Visibility.Collapsed;
        }

        if (presentation.CanExpand)
        {
            button.Click += (_, _) =>
            {
                ToggleToolRow(key);
                RenderContent();
            };
        }

        stack.Children.Add(button);
        if (expanded)
        {
            var detailPanel = new StackPanel { Spacing = 7, Margin = new Thickness(26, 0, 0, 0) };
            foreach (var row in presentation.DetailRows)
            {
                detailPanel.Children.Add(new StackPanel
                {
                    Spacing = 3,
                    Children =
                    {
                        new TextBlock
                        {
                            Text = row.Title,
                            FontSize = 12,
                            Foreground = Brush("V2SecondaryForegroundBrush"),
                            TextWrapping = TextWrapping.Wrap,
                            MaxWidth = 620,
                        },
                        new TextBlock
                        {
                            Text = row.Detail,
                            FontSize = 11,
                            FontFamily = new FontFamily("Consolas"),
                            Foreground = Brush("V2MutedForegroundBrush"),
                            TextWrapping = TextWrapping.Wrap,
                            MaxWidth = 620,
                            Visibility = string.IsNullOrWhiteSpace(row.Detail) ? Visibility.Collapsed : Visibility.Visible,
                        },
                    },
                });
            }

            stack.Children.Add(detailPanel);
        }

        if (presentation.Compacting)
        {
            var compactingRow = new Grid
            {
                HorizontalAlignment = HorizontalAlignment.Left,
                MaxWidth = 620,
                ColumnSpacing = 16,
                ColumnDefinitions =
                {
                    new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                    new ColumnDefinition { Width = GridLength.Auto },
                    new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                },
                Children =
                {
                    new Border
                    {
                        Height = 1,
                        Background = Brush("V2BorderBrush"),
                        VerticalAlignment = VerticalAlignment.Center,
                        MinWidth = 80,
                    },
                    new TextBlock
                    {
                        Text = IsChineseUi() ? "\u6b63\u5728\u81ea\u52a8\u538b\u7f29\u4e0a\u4e0b\u6587" : "Automatically compacting context",
                        FontSize = 12,
                        FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                        Foreground = Brush("V2SecondaryForegroundBrush"),
                        VerticalAlignment = VerticalAlignment.Center,
                        TextWrapping = TextWrapping.NoWrap,
                    },
                    new Border
                    {
                        Height = 1,
                        Background = Brush("V2BorderBrush"),
                        VerticalAlignment = VerticalAlignment.Center,
                        MinWidth = 80,
                    },
                },
            };
            Grid.SetColumn((FrameworkElement)compactingRow.Children[1], 1);
            Grid.SetColumn((FrameworkElement)compactingRow.Children[2], 2);
            stack.Children.Add(compactingRow);
        }

        return stack;
    }

    private async void OnComposerKeyDown(object sender, KeyRoutedEventArgs args)
    {
        var shiftDown = IsShiftDown();
        var controlDown = IsControlDown();
        var action = ComposerKeyPolicy.Decide(
            ComposerKeyFromVirtualKey(args.Key),
            shiftDown,
            controlDown,
            IsImeComposing(),
            State.UiPreferences.SendByCtrlEnter);
        if (action == ComposerKeyAction.ToggleRunMode)
        {
            args.Handled = true;
            ToggleComposerRunMode(refocusComposer: true);
            return;
        }

        if (action == ComposerKeyAction.Send)
        {
            args.Handled = true;
            _ignoreNextEnterKeyUp = true;
            if (ComposerCanSubmit())
            {
                await SendComposerAsync();
            }
        }
        else if (action == ComposerKeyAction.InsertNewLine)
        {
            args.Handled = true;
            _ignoreNextEnterKeyUp = true;
            InsertComposerNewline(sender as TextBox);
        }
    }

    private async void OnComposerKeyUp(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key != global::Windows.System.VirtualKey.Enter) return;

        if (_ignoreNextEnterKeyUp)
        {
            _ignoreNextEnterKeyUp = false;
            args.Handled = true;
            return;
        }

        await Task.CompletedTask;
    }

    private static ComposerKey ComposerKeyFromVirtualKey(global::Windows.System.VirtualKey key) => key switch
    {
        global::Windows.System.VirtualKey.Enter => ComposerKey.Enter,
        global::Windows.System.VirtualKey.Tab => ComposerKey.Tab,
        _ => ComposerKey.Other,
    };

    private static string ComposerRunModeIcon(ChatRunMode mode) => mode.SystemImage() switch
    {
        "checklist" => "ListChecks",
        "sparkles" => "Sparkles",
        _ => "Bot",
    };

    private static string ComposerPermissionModeIcon(ComposerPermissionMode mode) => mode.SystemImage() switch
    {
        "hand.raised" => "Hand",
        "shield.lefthalf.filled" => "Shield",
        _ => "Shield",
    };

    private bool IsImeComposing()
    {
        if (_hwnd == IntPtr.Zero)
        {
            return false;
        }

        var context = ImmGetContext(_hwnd);
        if (context == IntPtr.Zero)
        {
            return false;
        }

        try
        {
            return ImmGetCompositionStringW(context, GcsCompStr, IntPtr.Zero, 0) > 0;
        }
        finally
        {
            ImmReleaseContext(_hwnd, context);
        }
    }

    private void InsertComposerNewline(TextBox? composer)
    {
        composer ??= _composerTextBox;
        InsertComposerText(Environment.NewLine, composer);
    }

    private void InsertComposerText(string text, bool refocus = false) =>
        InsertComposerText(text, _composerTextBox, refocus);

    private void InsertComposerText(string text, TextBox? composer, bool refocus = false)
    {
        if (composer is null) return;
        var start = Math.Clamp(composer.SelectionStart, 0, composer.Text.Length);
        var length = Math.Clamp(composer.SelectionLength, 0, composer.Text.Length - start);
        var next = composer.Text.Remove(start, length).Insert(start, text);
        composer.Text = next;
        composer.SelectionStart = start + text.Length;
        State.ComposerText = next;
        if (refocus)
        {
            composer.Focus(FocusState.Programmatic);
        }
    }

    private MenuFlyout ComposerRunModeFlyout()
    {
        var flyout = new MenuFlyout();
        foreach (var descriptor in ChatRunModeCatalog.All)
        {
            var item = new MenuFlyoutItem
            {
                Text = descriptor.Label,
            };
            item.Click += (_, _) =>
            {
                State.ComposerRunMode = descriptor.Mode;
                RenderContent();
                FocusComposerSoon();
            };
            flyout.Items.Add(item);
        }

        return flyout;
    }

    private MenuFlyout ComposerPermissionFlyout()
    {
        var flyout = new MenuFlyout();
        foreach (var descriptor in ComposerPermissionModeCatalog.All)
        {
            var item = new MenuFlyoutItem
            {
                Text = descriptor.Label,
            };
            item.Click += (_, _) =>
            {
                SetComposerPermissionMode(descriptor.Mode);
                RenderContent();
                FocusComposerSoon();
            };
            flyout.Items.Add(item);
        }

        return flyout;
    }

    private void ToggleComposerRunMode(bool refocusComposer = false)
    {
        State.ComposerRunMode = State.ComposerRunMode == ChatRunMode.Plan ? ChatRunMode.Agent : ChatRunMode.Plan;
        RenderContent();
        if (refocusComposer) FocusComposerSoon();
    }

    private void FocusComposerSoon()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_composerTextBox is null) return;
            _composerTextBox.Focus(FocusState.Programmatic);
            _composerTextBox.SelectionStart = _composerTextBox.Text.Length;
        });
    }

    private void ClearVisibleComposerText()
    {
        if (_composerTextBox is null) return;
        try
        {
            _suppressComposerTextChanged = true;
            _composerTextBox.Text = "";
        }
        finally
        {
            _suppressComposerTextChanged = false;
        }
    }

    private FrameworkElement? ComposerAttachmentTray()
    {
        if (State.PendingAttachments.Count == 0) return null;

        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 10,
        };

        foreach (var attachment in State.PendingAttachments.ToList())
        {
            row.Children.Add(ComposerPendingAttachmentPreview(attachment));
        }

        return new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = row,
        };
    }

    private FrameworkElement ComposerPendingAttachmentPreview(FileAttachment attachment)
    {
        var model = ComposerAttachmentPreviewModel.Make(attachment);
        var preview = model.IsImage ? ComposerImageAttachmentPreview(attachment) : null;
        preview ??= ComposerFileAttachmentPreview(attachment, model);

        var remove = new Button
        {
            Width = 24,
            Height = 24,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(12),
            Background = Brush("V2InverseBrush"),
            BorderBrush = Transparent,
            Content = Icon("X", 11, Brush("V2InverseForegroundBrush")),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, -7, -7, 0),
        };
        ToolTipService.SetToolTip(remove, "Remove attachment");
        remove.Click += (_, _) =>
        {
            State.PendingAttachments.Remove(attachment);
            RenderContent();
            FocusComposerSoon();
        };

        var root = new Grid
        {
            Margin = new Thickness(0, 7, 7, 0),
        };
        root.Children.Add(preview);
        root.Children.Add(remove);
        return root;
    }

    private FrameworkElement? ComposerImageAttachmentPreview(FileAttachment attachment)
    {
        var imagePath = string.IsNullOrWhiteSpace(attachment.PreviewPath)
            ? attachment.Path
            : attachment.PreviewPath!;
        if (!File.Exists(imagePath)) return null;

        try
        {
            return new Border
            {
                Width = 104,
                Height = 104,
                CornerRadius = new CornerRadius(14),
                BorderBrush = Brush("V2BorderBrush"),
                BorderThickness = new Thickness(1),
                Background = Brush("V2MutedBrush"),
                Child = new Image
                {
                    Width = 104,
                    Height = 104,
                    Stretch = Stretch.UniformToFill,
                    Source = new BitmapImage(new Uri(imagePath, UriKind.Absolute)),
                },
            };
        }
        catch (Exception)
        {
            return null;
        }
    }

    private FrameworkElement ComposerFileAttachmentPreview(FileAttachment attachment, ComposerAttachmentPreviewModel model)
    {
        return new Border
        {
            Width = 192,
            Height = 64,
            CornerRadius = new CornerRadius(14),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2CardBrush"),
            Padding = new Thickness(10, 0, 10, 0),
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 10,
                VerticalAlignment = VerticalAlignment.Center,
                Children =
                {
                    new Border
                    {
                        Width = 42,
                        Height = 42,
                        CornerRadius = new CornerRadius(10),
                        Background = AttachmentAccentBackgroundBrush(model.AccentKind),
                        Child = Icon(AttachmentPreviewIcon(model), 18, AttachmentAccentBrush(model.AccentKind)),
                    },
                    new StackPanel
                    {
                        VerticalAlignment = VerticalAlignment.Center,
                        Spacing = 3,
                        MaxWidth = 116,
                        Children =
                        {
                            new TextBlock
                            {
                                Text = attachment.FileName,
                                FontSize = 12.5,
                                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                                Foreground = Brush("V2ForegroundBrush"),
                                TextTrimming = TextTrimming.CharacterEllipsis,
                            },
                            new TextBlock
                            {
                                Text = model.TypeLabel,
                                FontSize = 10.5,
                                FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                                Foreground = Brush("V2MutedForegroundBrush"),
                            },
                        },
                    },
                },
            },
        };
    }

    private string AttachmentPreviewIcon(ComposerAttachmentPreviewModel model) => model.AccentKind switch
    {
        "image" => "Image",
        "code" => "Code",
        "spreadsheet" => "BarChart3",
        "presentation" => "LayoutList",
        "pdf" or "document" => "Document",
        _ => "File",
    };

    private Brush AttachmentAccentBrush(string accentKind) => accentKind switch
    {
        "pdf" => Brush("V2RedBrush"),
        "document" => Brush("V2BlueBrush"),
        "spreadsheet" => Brush("V2GreenBrush"),
        "presentation" => Brush("V2AmberBrush"),
        "code" => Brush("V2ForegroundBrush"),
        _ => Brush("V2MutedForegroundBrush"),
    };

    private Brush AttachmentAccentBackgroundBrush(string accentKind)
    {
        if (AttachmentAccentBrush(accentKind) is SolidColorBrush solid)
        {
            return new SolidColorBrush(solid.Color) { Opacity = 0.14 };
        }

        return Brush("V2MutedBrush");
    }

    private void AddPendingAttachments(IEnumerable<FileAttachment> attachments)
    {
        var merged = ComposerAttachmentDeduper.Merged(State.PendingAttachments, attachments);
        State.PendingAttachments.Clear();
        State.PendingAttachments.AddRange(merged);
    }

    private void AppendPastedComposerText(string text, TextBox? composer)
    {
        composer ??= _composerTextBox;
        var existing = composer?.Text ?? State.ComposerText;
        var next = ComposerPasteTextPolicy.AppendText(existing, text);
        State.ComposerText = next;
        if (composer is not null)
        {
            composer.Text = next;
            composer.SelectionStart = next.Length;
            composer.SelectionLength = 0;
        }
    }

    private Button ComposerSendButton()
    {
        var canSubmit = ComposerCanSubmit();
        var isBusy = _isAgentSubmitting || _isAgentRunning;
        var background = _isAgentRunning
            ? Brush("V2RedBrush")
            : _isAgentSubmitting || canSubmit
                ? Brush("V2InverseBrush")
                : Brush("V2MutedBrush");
        var foreground = _isAgentRunning || _isAgentSubmitting || canSubmit
            ? Brush("V2InverseForegroundBrush")
            : Brush("V2MutedForegroundBrush");
        FrameworkElement content = _isAgentSubmitting
            ? new ProgressRing
            {
                Width = 17,
                Height = 17,
                IsIndeterminate = true,
                Foreground = foreground,
            }
            : _isAgentRunning
                ? Icon("Stop", 14, foreground)
                : Icon("ArrowUp", 15, foreground);

        var button = new Button
        {
            Width = 32,
            Height = 32,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(8),
            Background = background,
            BorderBrush = background,
            Foreground = foreground,
            Content = content,
            IsEnabled = isBusy || canSubmit,
        };
        ToolTipService.SetToolTip(button, isBusy ? T("chat.status.streaming") : AgentComposerStatus());
        return button;
    }

    private async Task AttachComposerFilesAsync()
    {
        var picker = new FileOpenPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add("*");
        var files = await picker.PickMultipleFilesAsync();
        var attachments = new List<FileAttachment>();
        foreach (var file in files)
        {
            attachments.Add(await AttachmentFromStorageFileAsync(file, AttachmentSourceKind.Picker));
        }

        if (files.Count > 0)
        {
            AddPendingAttachments(attachments);
            RenderContent();
            FocusComposerSoon();
        }
    }

    private async Task AttachComposerFolderAsync()
    {
        var picker = new FolderPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add("*");
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;

        AddPendingAttachments([AttachmentFromStorageFolder(folder, AttachmentSourceKind.Picker)]);
        RenderContent();
        FocusComposerSoon();
    }

    private async void OnComposerPaste(object sender, TextControlPasteEventArgs args)
    {
        var (attachments, textPayload) = await ReadClipboardPasteAsync();
        if (attachments.Count == 0) return;

        args.Handled = true;
        if (!string.IsNullOrEmpty(textPayload))
        {
            AppendPastedComposerText(textPayload, sender as TextBox);
        }
        AddPendingAttachments(attachments);
        RenderContent();
        FocusComposerSoon();
    }

    private async Task<(List<FileAttachment> Attachments, string? TextPayload)> ReadClipboardPasteAsync()
    {
        DataPackageView data;
        try
        {
            data = Clipboard.GetContent();
        }
        catch
        {
            return ([], null);
        }

        var attachments = await ReadClipboardAttachmentsAsync(data);
        var text = await ReadClipboardTextAsync(data);
        if (attachments.Count == 0)
        {
            attachments = ComposerPasteTextPolicy.AttachmentsFromFileUris(
                await ReadClipboardFileUrisAsync(data),
                ResolvePlainPathAttachment);
        }

        if (attachments.Count == 0)
        {
            attachments = ComposerPasteTextPolicy.AttachmentsFromPlainFilePathText(
                text,
                ResolvePlainPathAttachment);
        }

        return (attachments, ComposerPasteTextPolicy.TextPayload(text, attachments));
    }

    private async Task<List<FileAttachment>> ReadClipboardAttachmentsAsync(DataPackageView data)
    {
        var result = new List<FileAttachment>();

        if (data.Contains(StandardDataFormats.StorageItems))
        {
            try
            {
                var items = await data.GetStorageItemsAsync();
                foreach (var file in items.OfType<StorageFile>())
                {
                    result.Add(await AttachmentFromStorageFileAsync(file, AttachmentSourceKind.ClipboardFile));
                }
            }
            catch
            {
                // Fall through to bitmap extraction if storage item reading fails.
            }
        }

        if (data.Contains(StandardDataFormats.Bitmap))
        {
            try
            {
                var bitmap = await data.GetBitmapAsync();
                result.Add(await SaveClipboardBitmapAsync(bitmap));
            }
            catch
            {
                // Ignore unsupported clipboard image payloads.
            }
        }

        return result;
    }

    private static async Task<List<Uri>> ReadClipboardFileUrisAsync(DataPackageView data)
    {
        var uris = new List<Uri>();
        if (!data.Contains(StandardDataFormats.Uri)) return uris;

        try
        {
            var uri = await data.GetUriAsync();
            if (uri is not null)
            {
                uris.Add(uri);
            }
        }
        catch
        {
            // Ignore non-file URI payloads and malformed clipboard URI data.
        }

        return uris;
    }

    private static async Task<string?> ReadClipboardTextAsync(DataPackageView data)
    {
        if (!data.Contains(StandardDataFormats.Text)) return null;

        try
        {
            return await data.GetTextAsync();
        }
        catch
        {
            return null;
        }
    }

    private static ComposerPasteTextPolicy.PlainPathAttachmentInfo? ResolvePlainPathAttachment(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;

        var candidate = value.Trim();
        string fullPath;
        try
        {
            fullPath = Path.GetFullPath(candidate);
        }
        catch
        {
            return null;
        }

        if (Directory.Exists(fullPath))
        {
            return new ComposerPasteTextPolicy.PlainPathAttachmentInfo(
                fullPath,
                true,
                0,
                "inode/directory");
        }

        if (!File.Exists(fullPath)) return null;

        long bytes;
        try
        {
            bytes = new FileInfo(fullPath).Length;
        }
        catch
        {
            bytes = 0;
        }

        return new ComposerPasteTextPolicy.PlainPathAttachmentInfo(
            fullPath,
            false,
            bytes,
            MimeTypeForPlainAttachmentPath(fullPath));
    }

    private static string? MimeTypeForPlainAttachmentPath(string path)
    {
        var extension = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        return extension switch
        {
            "md" or "markdown" => "text/markdown",
            "html" or "htm" => "text/html",
            "json" or "jsonl" => "application/json",
            "yaml" or "yml" => "application/yaml",
            "toml" => "application/toml",
            "xml" => "application/xml",
            "csv" => "text/csv",
            "txt" or "log" or "swift" or "js" or "ts" or "tsx" or "jsx" or "py" or "rb" or "go" or "rs" or "css" or "scss" or "sql" or "sh" or "ps1" => "text/plain",
            "pdf" => "application/pdf",
            "png" => "image/png",
            "jpg" or "jpeg" => "image/jpeg",
            "gif" => "image/gif",
            "webp" => "image/webp",
            "heic" => "image/heic",
            "tiff" or "tif" => "image/tiff",
            "bmp" => "image/bmp",
            _ => null,
        };
    }

    private async Task<FileAttachment> AttachmentFromStorageFileAsync(StorageFile file, AttachmentSourceKind sourceKind)
    {
        var path = file.Path;
        if (string.IsNullOrWhiteSpace(path))
        {
            path = await CopyStorageFileToAttachmentCacheAsync(file);
        }

        var properties = await file.GetBasicPropertiesAsync();
        return new FileAttachment(
            path,
            file.Name,
            string.IsNullOrWhiteSpace(file.ContentType) ? null : file.ContentType,
            (long)properties.Size,
            sourceKind,
            path);
    }

    private static FileAttachment AttachmentFromStorageFolder(StorageFolder folder, AttachmentSourceKind sourceKind)
    {
        var path = folder.Path;
        return new FileAttachment(
            path,
            string.IsNullOrWhiteSpace(folder.Name) ? path : folder.Name,
            "inode/directory",
            0,
            sourceKind);
    }

    private async Task<string> CopyStorageFileToAttachmentCacheAsync(StorageFile file)
    {
        var folder = await AttachmentCacheFolderAsync();
        var copied = await file.CopyAsync(folder, file.Name, NameCollisionOption.GenerateUniqueName);
        return copied.Path;
    }

    private async Task<FileAttachment> SaveClipboardBitmapAsync(RandomAccessStreamReference bitmap)
    {
        var folder = await AttachmentCacheFolderAsync();
        var file = await folder.CreateFileAsync($"pasted-{DateTimeOffset.UtcNow:yyyyMMdd-HHmmss-fff}.png", CreationCollisionOption.GenerateUniqueName);
        using var input = await bitmap.OpenReadAsync();
        using var output = await file.OpenAsync(FileAccessMode.ReadWrite);
        await RandomAccessStream.CopyAsync(input, output);
        return new FileAttachment(
            file.Path,
            file.Name,
            "image/png",
            (long)input.Size,
            AttachmentSourceKind.ClipboardImage,
            file.Path);
    }

    private async Task<StorageFolder> AttachmentCacheFolderAsync()
    {
        var session = State.SelectedSessionId ?? "draft";
        var path = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "G9Claw",
            "attachments",
            session);
        Directory.CreateDirectory(path);
        return await StorageFolder.GetFolderFromPathAsync(path);
    }

    private bool ComposerCanSubmit() =>
        AppState.CanSendComposerMessage(
            State.SelectedSession,
            State.SelectedProject is not null,
            State.ComposerText,
            State.PendingAttachments.Count,
            _isAgentRunning || _isAgentSubmitting,
            IsAgentModelConfigured());

    private Button ContextGaugeButton()
    {
        var budget = State.SelectedSessionId is { } sessionId &&
                     State.TokenBudgetBySession.TryGetValue(sessionId, out var bySession)
            ? bySession
            : State.CurrentMessages.AsEnumerable().Reverse().Select(message => message.TokenBudget).FirstOrDefault(value => value is not null);
        var snapshot = ContextBudgetPresenter.FromBudget(budget, _lastContextStage, _contextCompactCount);
        var foreground = snapshot.Level switch
        {
            ContextBudgetLevel.Recovering => Brush("V2RedBrush"),
            ContextBudgetLevel.Compacting or ContextBudgetLevel.Warning => Brush("V2AmberBrush"),
            ContextBudgetLevel.Attention => Brush("V2BlueBrush"),
            ContextBudgetLevel.Normal => Brush("V2SecondaryForegroundBrush"),
            _ => Brush("V2MutedForegroundBrush"),
        };
        var button = new Button
        {
            Height = 28,
            MinWidth = snapshot.Percent is null ? 44 : 58,
            Padding = new Thickness(6, 0, 6, 0),
            CornerRadius = new CornerRadius(6),
            Background = snapshot.Percent is null ? Transparent : Brush("V2MutedBrush"),
            BorderBrush = Transparent,
            Foreground = foreground,
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 5,
                Children =
                {
                    Icon("CircleGauge", 16, foreground),
                    new TextBlock
                    {
                        Text = snapshot.Percent is null ? "--" : $"{snapshot.Percent}%",
                        FontSize = 12,
                        FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                        VerticalAlignment = VerticalAlignment.Center,
                    },
                },
            },
        };
        button.Flyout = new Flyout
        {
            Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.Top,
            Content = ContextGaugePopover(snapshot, foreground),
        };
        ToolTipService.SetToolTip(button, snapshot.Detail);
        return button;
    }

    private FrameworkElement ContextGaugePopover(ContextBudgetSnapshot snapshot, Brush tone)
    {
        var panel = new StackPanel
        {
            Width = 300,
            Spacing = 10,
            Padding = new Thickness(16),
        };

        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock
        {
            Text = T("chat.context.title"),
            FontSize = 14,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (snapshot.Percent is not null)
        {
            var pill = new Border
            {
                CornerRadius = new CornerRadius(999),
                Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(30, 115, 115, 115)),
                Padding = new Thickness(9, 4, 9, 4),
                Child = new TextBlock
                {
                    Text = $"{ContextBudgetPresenter.LevelLabel(snapshot.Level)} · {snapshot.Percent}%",
                    FontSize = 12,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Foreground = tone,
                },
            };
            Grid.SetColumn(pill, 1);
            header.Children.Add(pill);
        }

        panel.Children.Add(header);
        panel.Children.Add(new TextBlock
        {
            Text = snapshot.Detail,
            FontSize = 13,
            Foreground = Brush("V2MutedForegroundBrush"),
            TextWrapping = TextWrapping.Wrap,
        });

        if (snapshot.Percent is not null)
        {
            var progress = new ProgressBar
            {
                Minimum = 0,
                Maximum = 100,
                Value = Math.Min(100, snapshot.Percent.Value),
                Height = 5,
                Foreground = tone,
                Background = Brush("V2MutedBrush"),
            };
            panel.Children.Add(progress);
        }

        if (!string.IsNullOrWhiteSpace(snapshot.CompactStage))
        {
            panel.Children.Add(new TextBlock
            {
                Text = $"Recent compaction stage: {snapshot.CompactStage}",
                FontSize = 12,
                Foreground = Brush("V2MutedForegroundBrush"),
                TextWrapping = TextWrapping.Wrap,
            });
        }

        if (snapshot.CompactCount > 0)
        {
            panel.Children.Add(new TextBlock
            {
                Text = $"Compaction levels completed: {snapshot.CompactCount}",
                FontSize = 12,
                Foreground = Brush("V2MutedForegroundBrush"),
                TextWrapping = TextWrapping.Wrap,
            });
        }

        panel.Children.Add(new TextBlock
        {
            Text = T("chat.context.autoCompact"),
            FontSize = 12,
            Foreground = Brush("V2MutedForegroundBrush"),
            TextWrapping = TextWrapping.Wrap,
        });

        return panel;
    }

    private static bool IsShiftDown()
    {
        var state = global::Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(global::Windows.System.VirtualKey.Shift);
        return (state & global::Windows.UI.Core.CoreVirtualKeyStates.Down) == global::Windows.UI.Core.CoreVirtualKeyStates.Down;
    }

    private static bool IsControlDown()
    {
        var state = global::Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(global::Windows.System.VirtualKey.Control);
        return (state & global::Windows.UI.Core.CoreVirtualKeyStates.Down) == global::Windows.UI.Core.CoreVirtualKeyStates.Down;
    }

    private FrameworkElement MessageRow(ChatMessage message)
    {
        var isUser = message.Role == ChatRole.User;
        var row = new Grid
        {
            HorizontalAlignment = isUser ? HorizontalAlignment.Right : HorizontalAlignment.Stretch,
            MaxWidth = isUser ? 600 : double.PositiveInfinity,
        };

        if (isUser)
        {
            var stack = new StackPanel { Spacing = 7 };
            foreach (var block in message.Blocks)
            {
                if (block.Kind == ChatBlockKind.Text && !string.IsNullOrWhiteSpace(block.Text))
                {
                    stack.Children.Add(new TextBlock
                    {
                        Text = block.Text,
                        TextWrapping = TextWrapping.Wrap,
                        FontSize = 14,
                        LineHeight = 21,
                        Foreground = Brush("V2ForegroundBrush"),
                        IsTextSelectionEnabled = true,
                    });
                }
                else if (block.Kind == ChatBlockKind.Attachment && block.Attachment is { } attachment)
                {
                    stack.Children.Add(AttachmentChip(attachment));
                }
            }

            row.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                VerticalAlignment = VerticalAlignment.Top,
                Children =
                {
                    CopyTextButton(message.PlainText, T("chat.copy.user")),
                    new Border
                    {
                        CornerRadius = new CornerRadius(18),
                        Background = Brush("V2MutedBrush"),
                        Padding = new Thickness(14, 10, 14, 10),
                        Child = stack,
                    },
                },
            });
            return row;
        }

        if (message.Role == ChatRole.Assistant)
        {
            var panel = new Grid { ColumnSpacing = 8 };
            panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            panel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            panel.Children.Add(AssistantMessageContent(message));
            if (!string.IsNullOrWhiteSpace(message.PlainText))
            {
                var copy = CopyTextButton(message.PlainText, T("chat.copy.assistant"));
                Grid.SetColumn(copy, 1);
                panel.Children.Add(copy);
            }

            row.Children.Add(panel);
            return row;
        }

        var bubble = new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = Brush("V2MutedBrush"),
            Padding = new Thickness(10, 8, 10, 8),
            Child = new TextBlock
            {
                Text = message.PlainText,
                TextWrapping = TextWrapping.Wrap,
                FontSize = 12,
                Foreground = Brush("V2MutedForegroundBrush"),
                IsTextSelectionEnabled = true,
            },
        };
        row.Children.Add(bubble);
        return row;
    }

    private FrameworkElement AssistantMessageContent(ChatMessage message)
    {
        var panel = new StackPanel
        {
            Spacing = 8,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };

        var pairedResults = message.Blocks
            .Where(block => block.Kind == ChatBlockKind.ToolResult && block.ToolResult is not null)
            .Select(block => block.ToolResult!)
            .GroupBy(result => result.CallId, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(group => group.Key, group => group.Last(), StringComparer.OrdinalIgnoreCase);
        var pairedCallIds = message.Blocks
            .Where(block => block.Kind == ChatBlockKind.ToolCall && block.ToolCall is not null)
            .Select(block => block.ToolCall!.Id)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var consumedResults = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var toolGroup = new List<(AgentToolCall Call, AgentToolResult? Result)>();

        void FlushToolGroup()
        {
            if (toolGroup.Count == 0) return;
            panel.Children.Add(toolGroup.Count == 1
                ? ToolPairRow(toolGroup[0].Call, toolGroup[0].Result)
                : ToolGroupRow(toolGroup.ToList()));
            toolGroup.Clear();
        }

        foreach (var block in message.Blocks)
        {
            switch (block.Kind)
            {
                case ChatBlockKind.Reasoning
                    when ChatBlockVisibilityPolicy.IsVisible(block, State.UiPreferences.ShowThinking) &&
                         !string.IsNullOrWhiteSpace(block.Text):
                    FlushToolGroup();
                    panel.Children.Add(ReasoningBlock(block.Text));
                    break;
                case ChatBlockKind.Text when !string.IsNullOrWhiteSpace(block.Text):
                    FlushToolGroup();
                    panel.Children.Add(MarkdownContent(block.Text));
                    break;
                case ChatBlockKind.Attachment when block.Attachment is { } attachment:
                    FlushToolGroup();
                    panel.Children.Add(AttachmentChip(attachment));
                    break;
                case ChatBlockKind.ProviderError when block.ProviderError is { } providerError:
                    FlushToolGroup();
                    panel.Children.Add(ProviderErrorCard(providerError));
                    break;
                case ChatBlockKind.ToolCall when block.ToolCall is { } call:
                    if (string.Equals(call.Name, "AskQuestion", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(call.Name, "SwitchMode", StringComparison.OrdinalIgnoreCase))
                    {
                        break;
                    }

                    pairedResults.TryGetValue(call.Id, out var result);
                    if (result is not null)
                    {
                        consumedResults.Add(call.Id);
                    }

                    if (IsBoundaryTool(call.Name))
                    {
                        FlushToolGroup();
                        panel.Children.Add(ToolPairRow(call, result));
                    }
                    else
                    {
                        toolGroup.Add((call, result));
                    }
                    break;
                case ChatBlockKind.ToolResult when block.ToolResult is { } orphanResult:
                    if (!pairedCallIds.Contains(orphanResult.CallId) && !consumedResults.Contains(orphanResult.CallId))
                    {
                        FlushToolGroup();
                        panel.Children.Add(ToolResultRow(orphanResult));
                    }
                    break;
            }
        }

        FlushToolGroup();
        if (message.IsStreaming && panel.Children.Count == 0)
        {
            panel.Children.Add(new TextBlock
            {
                Text = T("chat.turn.working"),
                FontSize = 13,
                Foreground = Brush("V2MutedForegroundBrush"),
            });
        }

        return panel;
    }

    private FrameworkElement ReasoningBlock(string text)
    {
        var body = new StackPanel
        {
            Spacing = 6,
            Children =
            {
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 6,
                    Children =
                    {
                        Icon("Sparkles", 13, Brush("V2MutedForegroundBrush")),
                        new TextBlock
                        {
                            Text = "Thinking",
                            FontSize = 11,
                            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                            Foreground = Brush("V2MutedForegroundBrush"),
                        },
                    },
                },
                new TextBlock
                {
                    Text = text,
                    FontSize = 12,
                    LineHeight = 18,
                    TextWrapping = TextWrapping.Wrap,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    IsTextSelectionEnabled = true,
                },
            },
        };

        return new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2MutedBrush"),
            Padding = new Thickness(10, 8, 10, 8),
            Child = body,
        };
    }

    private FrameworkElement AttachmentChip(FileAttachment attachment)
    {
        var imagePath = string.IsNullOrWhiteSpace(attachment.PreviewPath)
            ? attachment.Path
            : attachment.PreviewPath!;
        if (attachment.IsImage && File.Exists(imagePath))
        {
            try
            {
                return new Border
                {
                    MaxWidth = 280,
                    MaxHeight = 180,
                    CornerRadius = new CornerRadius(8),
                    BorderBrush = Brush("V2BorderBrush"),
                    BorderThickness = new Thickness(1),
                    Background = Brush("V2MutedBrush"),
                    Child = new Image
                    {
                        MaxWidth = 280,
                        MaxHeight = 180,
                        Stretch = Stretch.Uniform,
                        Source = new BitmapImage(new Uri(imagePath, UriKind.Absolute)),
                    },
                };
            }
            catch
            {
                // Fall back to the file chip when WinUI cannot decode a copied image path.
            }
        }

        var model = ComposerAttachmentPreviewModel.Make(attachment);
        return new Border
        {
            MinWidth = 168,
            MaxWidth = 320,
            CornerRadius = new CornerRadius(12),
            Background = Brush("V2CardBrush"),
            Padding = new Thickness(8),
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 10,
                Children =
                {
                    new Border
                    {
                        Width = 40,
                        Height = 40,
                        CornerRadius = new CornerRadius(8),
                        Background = AttachmentAccentBrush(model.AccentKind),
                        Child = Icon(AttachmentPreviewIcon(model), 18, Brush("V2InverseForegroundBrush")),
                    },
                    new StackPanel
                    {
                        VerticalAlignment = VerticalAlignment.Center,
                        Spacing = 2,
                        MaxWidth = 220,
                        Children =
                        {
                            new TextBlock
                            {
                                Text = attachment.FileName,
                                FontSize = 13,
                                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                                Foreground = Brush("V2ForegroundBrush"),
                                TextTrimming = TextTrimming.CharacterEllipsis,
                            },
                            new TextBlock
                            {
                                Text = model.TypeLabel,
                                FontSize = 10,
                                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                                Foreground = Brush("V2MutedForegroundBrush"),
                            },
                        },
                    },
                },
            },
        };
    }

    private FrameworkElement MarkdownContent(string markdown)
    {
        var blocks = MarkdownPresentation.Parse(markdown);
        if (blocks.Count == 0)
        {
            return new TextBlock
            {
                Text = markdown,
                TextWrapping = TextWrapping.Wrap,
                FontSize = 14,
                LineHeight = 22,
                Foreground = Brush("V2ForegroundBrush"),
                IsTextSelectionEnabled = true,
            };
        }

        var panel = new StackPanel { Spacing = 8 };
        foreach (var block in blocks)
        {
            panel.Children.Add(MarkdownBlockElement(block));
        }

        return panel;
    }

    private FrameworkElement MarkdownBlockElement(MarkdownBlockPresentation block)
    {
        return block.Kind switch
        {
            MarkdownBlockKind.Heading => MarkdownTextBlock(
                block.Inlines,
                block.HeadingLevel <= 2 ? 16 : 14,
                Microsoft.UI.Text.FontWeights.SemiBold),
            MarkdownBlockKind.CodeBlock => MarkdownCodeBlock(block.Code ?? "", block.Language),
            MarkdownBlockKind.List => MarkdownList(block),
            MarkdownBlockKind.Quote => MarkdownQuote(block),
            MarkdownBlockKind.Table when block.Table is not null => MarkdownTable(block.Table),
            _ => MarkdownTextBlock(block.Inlines, 14, Microsoft.UI.Text.FontWeights.Normal),
        };
    }

    private RichTextBlock MarkdownTextBlock(
        IReadOnlyList<MarkdownInlinePresentation> inlines,
        double fontSize,
        global::Windows.UI.Text.FontWeight weight)
    {
        var rich = new RichTextBlock
        {
            FontSize = fontSize,
            FontWeight = weight,
            Foreground = Brush("V2ForegroundBrush"),
            TextWrapping = TextWrapping.Wrap,
            LineHeight = fontSize + 8,
        };
        var paragraph = new Microsoft.UI.Xaml.Documents.Paragraph();
        AddMarkdownInlines(paragraph.Inlines, inlines);
        rich.Blocks.Add(paragraph);
        return rich;
    }

    private void AddMarkdownInlines(InlineCollection target, IReadOnlyList<MarkdownInlinePresentation> inlines)
    {
        foreach (var inline in inlines)
        {
            if (inline.Kind == MarkdownInlineKind.LineBreak)
            {
                target.Add(new LineBreak());
                continue;
            }

            var run = new Run { Text = inline.Text };
            switch (inline.Kind)
            {
                case MarkdownInlineKind.Strong:
                    run.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
                    break;
                case MarkdownInlineKind.Emphasis:
                    run.FontStyle = global::Windows.UI.Text.FontStyle.Italic;
                    break;
                case MarkdownInlineKind.Code:
                    run.FontFamily = new FontFamily("Consolas");
                    run.Foreground = Brush("V2SecondaryForegroundBrush");
                    break;
                case MarkdownInlineKind.Link:
                    run.Foreground = Brush("V2BlueBrush");
                    break;
            }

            target.Add(run);
        }
    }

    private FrameworkElement MarkdownCodeBlock(string code, string? language)
    {
        var grid = new Grid
        {
            ColumnSpacing = 8,
        };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        if (!string.IsNullOrWhiteSpace(language))
        {
            var label = new TextBlock
            {
                Text = language,
                FontSize = 11,
                Foreground = Brush("V2MutedForegroundBrush"),
                Margin = new Thickness(0, 0, 0, 6),
            };
            grid.Children.Add(label);
        }

        var copy = CopyTextButton(code, T("chat.copy.code"), 24, 12);
        Grid.SetColumn(copy, 1);
        grid.Children.Add(copy);

        var text = new TextBlock
        {
            Text = code.TrimEnd(),
            FontFamily = new FontFamily("Consolas"),
            FontSize = 12,
            Foreground = Brush("V2ForegroundBrush"),
            TextWrapping = TextWrapping.NoWrap,
            IsTextSelectionEnabled = true,
        };
        var scroll = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = text,
        };
        Grid.SetRow(scroll, 1);
        Grid.SetColumnSpan(scroll, 2);
        grid.Children.Add(scroll);

        return new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = Brush("V2MutedBrush"),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(10, 8, 10, 8),
            Child = grid,
        };
    }

    private FrameworkElement MarkdownList(MarkdownBlockPresentation block)
    {
        var panel = new StackPanel { Spacing = 5 };
        var items = block.ListItems ?? [];
        for (var i = 0; i < items.Count; i++)
        {
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Children.Add(new TextBlock
            {
                Text = block.Ordered ? $"{i + 1}." : "\u2022",
                FontSize = 14,
                Foreground = Brush("V2MutedForegroundBrush"),
                HorizontalAlignment = HorizontalAlignment.Right,
            });
            var content = MarkdownTextBlock(items[i], 14, Microsoft.UI.Text.FontWeights.Normal);
            Grid.SetColumn(content, 1);
            row.Children.Add(content);
            panel.Children.Add(row);
        }

        return panel;
    }

    private FrameworkElement MarkdownQuote(MarkdownBlockPresentation block)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(3) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new Border
        {
            Background = Brush("V2BorderBrush"),
            CornerRadius = new CornerRadius(2),
        });
        var text = MarkdownTextBlock(block.Inlines, 13, Microsoft.UI.Text.FontWeights.Normal);
        text.Foreground = Brush("V2SecondaryForegroundBrush");
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        return grid;
    }

    private FrameworkElement MarkdownTable(MarkdownTablePresentation table)
    {
        var rows = table.Rows;
        var columnCount = rows.Count == 0 ? 0 : rows.Max(row => row.Count);
        if (columnCount == 0)
        {
            return new Border { Height = 0 };
        }

        var grid = new Grid();
        for (var c = 0; c < columnCount; c++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        }

        for (var r = 0; r < rows.Count; r++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            for (var c = 0; c < rows[r].Count; c++)
            {
                var cell = new Border
                {
                    BorderBrush = Brush("V2BorderBrush"),
                    BorderThickness = new Thickness(0, 0, 1, 1),
                    Padding = new Thickness(8, 6, 8, 6),
                    Background = table.HasHeader && r == 0 ? Brush("V2MutedBrush") : Transparent,
                    Child = MarkdownTextBlock([rows[r][c]], 12, table.HasHeader && r == 0
                        ? Microsoft.UI.Text.FontWeights.SemiBold
                        : Microsoft.UI.Text.FontWeights.Normal),
                };
                Grid.SetRow(cell, r);
                Grid.SetColumn(cell, c);
                grid.Children.Add(cell);
            }
        }

        return new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = new Border
            {
                BorderBrush = Brush("V2BorderBrush"),
                BorderThickness = new Thickness(1, 1, 0, 0),
                CornerRadius = new CornerRadius(8),
                Child = grid,
            },
        };
    }

    private FrameworkElement ProviderErrorCard(ProviderErrorInfo error)
    {
        var key = $"provider-error:{error.RequestId}";
        var expanded = IsToolRowExpanded(key);
        FrameworkElement? detailElement = null;
        if (expanded)
        {
            var detail = new StringBuilder()
                .AppendLine($"provider: {error.ProviderId}")
                .AppendLine($"model entry: {error.ModelEntryId}")
                .AppendLine($"model: {error.Model}")
                .AppendLine($"endpoint: {error.Endpoint}")
                .AppendLine($"request id: {error.RequestId}")
                .AppendLine($"route tier: {error.RouteTier}");
            if (!string.IsNullOrWhiteSpace(error.FallbackToModelEntry))
            {
                detail.AppendLine($"fallback from: {error.FallbackFromModelEntry}")
                    .AppendLine($"fallback to: {error.FallbackToModelEntry}")
                    .AppendLine($"fallback reason: {error.FallbackReason}");
            }

            detail.AppendLine()
                .AppendLine(error.Body);
            detailElement = ToolDetailBox(T("chat.providerError.details"), detail.ToString().TrimEnd());
        }

        var title = string.IsNullOrWhiteSpace(error.FallbackToModelEntry)
            ? T("chat.providerError.title")
            : T("chat.providerError.fallbackTitle");
        var presentation = new ToolInvocationPresentation(
            ToolInvocationPhase.Tool,
            ToolInvocationState.Failed,
            $"{title}: {error.Summary}",
            error.Body,
            error.Body,
            true);
        return ToolInlineRow(key, presentation, expanded, detailElement);
    }

    private Button CopyTextButton(string text, string tooltip, double size = 24, double iconSize = 13)
    {
        var button = new Button
        {
            Width = size,
            Height = size,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(7),
            Background = Brush("V2MutedBrush"),
            BorderBrush = Transparent,
            UseSystemFocusVisuals = false,
            Content = Icon("Copy", iconSize, Brush("V2MutedForegroundBrush")),
            VerticalAlignment = VerticalAlignment.Top,
            IsEnabled = !string.IsNullOrWhiteSpace(text),
        };
        ToolTipService.SetToolTip(button, tooltip);
        button.Click += (_, _) => CopyTextToClipboard(text, T("chat.copy.copied"));
        return button;
    }

    private void CopyTextToClipboard(string text, string status)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
        State.StatusLine = status;
    }

    private FrameworkElement ToolPairRow(AgentToolCall call, AgentToolResult? result)
    {
        var key = $"tool:{call.Id}";
        var expanded = IsToolRowExpanded(key);
        var presentation = ToolInvocationPresenter.Present(call, result, IsChineseUi());
        FrameworkElement? detail = null;
        if (expanded)
        {
            var detailPanel = new StackPanel { Spacing = 8 };
            if (TaskInvocationPresentation.Parse(call.InputJson) is { } taskPresentation &&
                string.Equals(AgentToolNameCanonicalizer.Canonical(call.Name), "Task", StringComparison.Ordinal))
            {
                detailPanel.Children.Add(ToolDetailBox(
                    taskPresentation.DetailTitle(IsChineseUi()),
                    taskPresentation.DetailText(IsChineseUi(), result?.Output)));
            }
            else if (TodoListPresentation.Parse(call.Name, call.InputJson, result?.Output) is { } todoPresentation)
            {
                detailPanel.Children.Add(ToolDetailBox(
                    todoPresentation.DetailTitle(IsChineseUi()),
                    todoPresentation.DetailText(IsChineseUi())));
            }
            else
            {
                var detailPresentation = ToolInvocationDetailPresentation.Parse(call.Name, call.InputJson);
                detailPanel.Children.Add(ToolDetailBox(
                    detailPresentation.Title,
                    detailPresentation.DetailText(IsChineseUi(), result?.Output, State.UiPreferences.ShowRawParameters)));
            }

            detail = detailPanel;
        }

        return ToolInlineRow(key, presentation, expanded, detail);
    }

    private FrameworkElement ToolGroupRow(IReadOnlyList<(AgentToolCall Call, AgentToolResult? Result)> items)
    {
        var key = $"tool-group:{string.Join(",", items.Select(item => item.Call.Id))}";
        var expanded = IsToolRowExpanded(key);
        var presentation = ToolInvocationPresenter.PresentGroup(items, IsChineseUi());
        FrameworkElement? detail = null;
        if (expanded)
        {
            var detailPanel = new StackPanel { Spacing = 8 };
            foreach (var item in items)
            {
                var itemPresentation = ToolInvocationPresenter.Present(item.Call, item.Result, IsChineseUi());
                var detailPresentation = ToolInvocationDetailPresentation.Parse(item.Call.Name, item.Call.InputJson);
                detailPanel.Children.Add(ToolDetailBox(
                    itemPresentation.Summary,
                    detailPresentation.DetailText(IsChineseUi(), item.Result?.Output, State.UiPreferences.ShowRawParameters)));
            }

            detail = detailPanel;
        }

        return ToolInlineRow(key, presentation, expanded, detail);
    }

    private FrameworkElement ToolResultRow(AgentToolResult result)
    {
        var call = new AgentToolCall(result.CallId, result.ToolName, result.ToolName);
        return ToolInlineRow(
            $"tool-result:{result.CallId}",
            ToolInvocationPresenter.Present(call, result, IsChineseUi()),
            false,
            null);
    }

    private FrameworkElement ToolInlineRow(
        string key,
        ToolInvocationPresentation presentation,
        bool expanded,
        FrameworkElement? detail)
    {
        var tone = presentation.State switch
        {
            ToolInvocationState.Failed => Brush("V2RedBrush"),
            ToolInvocationState.Running => Brush("V2MutedForegroundBrush"),
            _ => Brush("V2MutedForegroundBrush"),
        };
        var stack = new StackPanel { Spacing = 4, Margin = new Thickness(0, 1, 0, 1) };
        var button = new Button
        {
            MinWidth = 0,
            MinHeight = 0,
            Height = 30,
            Padding = new Thickness(0, 2, 0, 2),
            HorizontalAlignment = HorizontalAlignment.Left,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = Transparent,
            BorderBrush = Transparent,
            UseSystemFocusVisuals = false,
            Content = new Grid
            {
                ColumnSpacing = 8,
                ColumnDefinitions =
                {
                    new ColumnDefinition { Width = new GridLength(18) },
                    new ColumnDefinition { Width = GridLength.Auto },
                    new ColumnDefinition { Width = GridLength.Auto },
                },
                Children =
                {
                    ToolStateGlyph(presentation),
                    new TextBlock
                    {
                        Text = presentation.Summary,
                        FontSize = 13,
                        Foreground = tone,
                        VerticalAlignment = VerticalAlignment.Center,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                        MaxWidth = 560,
                    },
                    Icon(expanded ? "ChevronDown" : "ChevronRight", 12, Brush("V2MutedForegroundBrush")),
                },
            },
        };
        if (button.Content is Grid grid)
        {
            Grid.SetColumn((FrameworkElement)grid.Children[1], 1);
            Grid.SetColumn((FrameworkElement)grid.Children[2], 2);
        }

        button.Click += (_, _) =>
        {
            ToggleToolRow(key);
            RenderContent();
        };
        stack.Children.Add(button);
        if (expanded && detail is not null)
        {
            stack.Children.Add(new Border
            {
                Margin = new Thickness(22, 2, 0, 4),
                BorderBrush = Brush("V2BorderBrush"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Background = Brush("V2MutedBrush"),
                Padding = new Thickness(10, 8, 10, 8),
                Child = detail,
            });
        }

        return stack;
    }

    private FrameworkElement ToolStateGlyph(ToolInvocationPresentation presentation)
    {
        if (presentation.State == ToolInvocationState.Running)
        {
            return new ProgressRing
            {
                IsActive = true,
                Width = 12,
                Height = 12,
                VerticalAlignment = VerticalAlignment.Center,
            };
        }

        var icon = presentation.State == ToolInvocationState.Failed
            ? "XCircle"
            : presentation.Phase switch
            {
                ToolInvocationPhase.Command => "Terminal",
                ToolInvocationPhase.Read => "File",
                ToolInvocationPhase.Edit => "Edit",
                ToolInvocationPhase.Search => "Search",
                ToolInvocationPhase.Todo => "ListChecks",
                ToolInvocationPhase.Task => "Command",
                _ => "Hammer",
            };
        var foreground = presentation.State == ToolInvocationState.Failed
            ? Brush("V2RedBrush")
            : Brush("V2MutedForegroundBrush");
        return Icon(icon, 15, foreground);
    }

    private FrameworkElement ToolHeader(string key, string title, string status, Brush tone, bool expanded)
    {
        var button = new Button
        {
            MinWidth = 0,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = Transparent,
            BorderBrush = Transparent,
            Padding = new Thickness(0),
            Content = new Grid
            {
                ColumnSpacing = 8,
                ColumnDefinitions =
                {
                    new ColumnDefinition { Width = GridLength.Auto },
                    new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                    new ColumnDefinition { Width = GridLength.Auto },
                    new ColumnDefinition { Width = GridLength.Auto },
                },
                Children =
                {
                    Icon("Hammer", 14, tone),
                    new TextBlock
                    {
                        Text = title,
                        FontSize = 12,
                        FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                        Foreground = Brush("V2SecondaryForegroundBrush"),
                        TextTrimming = TextTrimming.CharacterEllipsis,
                    },
                    new TextBlock
                    {
                        Text = status,
                        FontSize = 11,
                        Foreground = tone,
                        VerticalAlignment = VerticalAlignment.Center,
                    },
                    Icon(expanded ? "ChevronUp" : "ChevronDown", 13, Brush("V2MutedForegroundBrush")),
                },
            },
        };
        if (button.Content is Grid grid)
        {
            Grid.SetColumn((FrameworkElement)grid.Children[1], 1);
            Grid.SetColumn((FrameworkElement)grid.Children[2], 2);
            Grid.SetColumn((FrameworkElement)grid.Children[3], 3);
        }

        button.Click += (_, _) =>
        {
            ToggleToolRow(key);
            RenderContent();
        };
        return button;
    }

    private FrameworkElement ToolShell(FrameworkElement child, Brush tone) => new Border
    {
        CornerRadius = new CornerRadius(8),
        BorderBrush = Brush("V2BorderBrush"),
        BorderThickness = new Thickness(1),
        Background = Brush("V2MutedBrush"),
        Padding = new Thickness(10, 8, 10, 8),
        Child = child,
    };

    private FrameworkElement ToolDetailBox(string title, string detail) => new StackPanel
    {
        Spacing = 4,
        Children =
        {
            new TextBlock
            {
                Text = title,
                FontSize = 11,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Foreground = Brush("V2MutedForegroundBrush"),
            },
            new TextBox
            {
                Text = detail,
                IsReadOnly = true,
                AcceptsReturn = true,
                TextWrapping = TextWrapping.Wrap,
                MaxHeight = 180,
                FontFamily = new FontFamily("Consolas"),
                FontSize = 11,
                Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
            },
        },
    };

    private static bool IsBoundaryTool(string toolName)
    {
        return ToolInvocationPresenter.IsBoundary(toolName);
    }

    private bool IsToolRowExpanded(string key) =>
        ToolRowExpansionPolicy.IsExpanded(
            key,
            State.ExpandedToolRowIds,
            State.CollapsedToolRowIds,
            State.UiPreferences.AutoExpandTools);

    private void ToggleToolRow(string key) =>
        ToolRowExpansionPolicy.Toggle(
            key,
            State.ExpandedToolRowIds,
            State.CollapsedToolRowIds,
            State.UiPreferences.AutoExpandTools);

    private FrameworkElement TurnTrace(AgentTurn turn)
    {
        var items = turn.Items
            .Where(item => item.Kind is
                AgentTurnItemKind.ContextCompaction or
                AgentTurnItemKind.Status or
                AgentTurnItemKind.Plan or
                AgentTurnItemKind.CommandExecution or
                AgentTurnItemKind.FileChange or
                AgentTurnItemKind.WebSearch or
                AgentTurnItemKind.ToolCall or
                AgentTurnItemKind.ToolResult)
            .TakeLast(10)
            .ToList();
        if (items.Count == 0)
        {
            return new Border { Height = 0 };
        }

        var panel = new StackPanel { Spacing = 6 };
        panel.Children.Add(new TextBlock
        {
            Text = turn.Status == AgentTurnStatus.InProgress
                ? T("chat.turn.working")
                : Tf("chat.turn.status", turn.Status.ToString().ToLowerInvariant()),
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2MutedForegroundBrush"),
        });

        foreach (var item in items)
        {
            panel.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(6),
                BorderBrush = Brush("V2BorderBrush"),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(10, 8, 10, 8),
                Child = new StackPanel
                {
                    Spacing = 3,
                    Children =
                    {
                        new TextBlock
                        {
                            Text = string.IsNullOrWhiteSpace(item.ToolName) ? item.Title : $"{item.ToolName} / {item.Status}",
                            FontSize = 12,
                            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                            Foreground = item.Status == AgentTurnItemStatus.Failed ? Brush("V2RedBrush") : Brush("V2SecondaryForegroundBrush"),
                        },
                        new TextBlock
                        {
                            Text = item.Text,
                            FontSize = 11,
                            TextWrapping = TextWrapping.Wrap,
                            TextTrimming = TextTrimming.CharacterEllipsis,
                            MaxHeight = 72,
                            Foreground = Brush("V2MutedForegroundBrush"),
                        },
                    },
                },
            });
        }

        return panel;
    }

    private FrameworkElement FilesPage()
    {
        if (State.SelectedProject is null)
        {
            return EmptyFullPage(T("files.title"), T("files.pickProject"), "Folder");
        }

        var root = new Grid { Background = Brush("V2BackgroundBrush") };
        var isFileEditorExpanded = _isFileEditorExpanded && !string.IsNullOrWhiteSpace(_selectedFilePath);
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = isFileEditorExpanded ? new GridLength(0) : new GridLength(0.46, GridUnitType.Star) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = isFileEditorExpanded ? new GridLength(0) : new GridLength(12) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0.54, GridUnitType.Star) });

        var left = new Grid { Background = Brush("V2BackgroundBrush") };
        left.Visibility = isFileEditorExpanded ? Visibility.Collapsed : Visibility.Visible;
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var list = new StackPanel { Padding = new Thickness(12, 0, 12, 10), Spacing = 2 };
        WorkspaceFileListing? listing = null;
        string? listingError = null;
        try
        {
            listing = _workspaceService.FileListing(State.SelectedProject.RootPath, _expandedFileDirectories);
            var files = listing.Files;
            if (!string.IsNullOrWhiteSpace(_fileSearchText))
            {
                files = files
                    .Where(file => file.RelativePath.Contains(_fileSearchText, StringComparison.OrdinalIgnoreCase) ||
                                   file.Name.Contains(_fileSearchText, StringComparison.OrdinalIgnoreCase))
                    .ToList();
            }

            if (files.Count == 0)
            {
                list.Children.Add(FilesTreeEmptyState(listing));
            }
            else
            {
                foreach (var file in files.Take(300))
                {
                    list.Children.Add(FileRow(file));
                }
            }
        }
        catch (Exception ex)
        {
            listingError = ex.Message;
            list.Children.Add(ErrorState(ex.Message));
        }

        left.Children.Add(FilesPaneHeader(listing, listingError));
        var scroller = new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroller, 1);
        left.Children.Add(scroller);
        root.Children.Add(left);

        var divider = SplitDivider();
        divider.Visibility = isFileEditorExpanded ? Visibility.Collapsed : Visibility.Visible;
        Grid.SetColumn(divider, 1);
        root.Children.Add(divider);

        var preview = FilePreviewPane();
        Grid.SetColumn(preview, 2);
        root.Children.Add(preview);
        return root;
    }

    private FrameworkElement FilesPaneHeader(WorkspaceFileListing? listing, string? listingError)
    {
        var header = new StackPanel
        {
            Spacing = 9,
            Padding = new Thickness(12, 10, 12, 10),
        };
        var top = new Grid { ColumnSpacing = 10 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.Children.Add(new StackPanel
        {
            Spacing = 2,
            Children =
            {
                new TextBlock
                {
                    Text = T("files.title"),
                    FontSize = 14,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Foreground = Brush("V2ForegroundBrush"),
                },
                new TextBlock
                {
                    Text = State.SelectedProject?.RootPath ?? T("chat.status.selectProject"),
                    FontSize = 10.5,
                    FontFamily = new FontFamily("Cascadia Mono, Consolas"),
                    Foreground = Brush("V2MutedForegroundBrush"),
                    TextTrimming = TextTrimming.CharacterEllipsis,
                },
            },
        });
        var toolbar = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Children =
            {
                FilesToolbarButton("Document", T("files.newFile"), async () => await CreateWorkspaceItemAsync(false)),
                FilesToolbarButton("FolderPlus", T("files.newFolder"), async () => await CreateWorkspaceItemAsync(true)),
                FilesToolbarButton("Upload", T("files.upload"), async () => await UploadWorkspaceFileAsync()),
                FilesToolbarButton("Refresh", T("common.refresh"), async () =>
                {
                    _previewDraftText = null;
                    await Task.CompletedTask;
                    RenderAll();
                }),
            },
        };
        Grid.SetColumn(toolbar, 1);
        top.Children.Add(toolbar);
        header.Children.Add(top);

        var search = new TextBox
        {
            Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
            PlaceholderText = T("files.search"),
            Text = _fileSearchText,
        };
        search.TextChanged += (_, _) =>
        {
            _fileSearchText = search.Text;
            RenderContent();
        };
        var tools = new Grid { ColumnSpacing = 8 };
        tools.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        tools.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        tools.Children.Add(SearchField(search));
        var more = FilesMoreButton();
        Grid.SetColumn(more, 1);
        tools.Children.Add(more);
        header.Children.Add(tools);

        if (FilePaneStatusLine(listing, listingError) is { } statusLine)
        {
            header.Children.Add(statusLine);
        }

        return new Border
        {
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Child = header,
        };
    }

    private FrameworkElement FilesTreeEmptyState(WorkspaceFileListing? listing)
    {
        if (!string.IsNullOrWhiteSpace(_fileSearchText))
        {
            return EmptyState(
                L("No matching files", "\u6ca1\u6709\u5339\u914d\u7684\u6587\u4ef6"),
                L("Try another filename or clear the search.", "\u6362\u4e2a\u6587\u4ef6\u540d\u641c\u7d22\uff0c\u6216\u6e05\u7a7a\u641c\u7d22\u6761\u4ef6\u3002"),
                "Search");
        }

        if (listing?.IsRootHiddenOnly == true)
        {
            var count = listing.SkippedRootItemCount;
            return EmptyState(
                L("Only hidden files here", "\u8fd9\u91cc\u6682\u65f6\u53ea\u6709\u9690\u85cf\u6587\u4ef6"),
                IsChineseUi()
                    ? $"\u5df2\u7701\u7565 {count} \u4e2a\u9690\u85cf\u6216\u751f\u6210\u9879\uff0c\u907f\u514d\u6587\u4ef6\u6811\u88ab\u5185\u90e8\u6570\u636e\u5360\u6ee1\u3002"
                    : $"{count} hidden or generated item{(count == 1 ? "" : "s")} are omitted from the project browser.",
                "Eye");
        }

        return EmptyState(
            L("No files found", "\u6ca1\u6709\u6587\u4ef6"),
            L("Create a file, upload project assets, or refresh after changing the workspace.", "\u4f60\u53ef\u4ee5\u65b0\u5efa\u6587\u4ef6\u3001\u4e0a\u4f20\u9879\u76ee\u8d44\u6e90\uff0c\u6216\u5728\u5916\u90e8\u4fee\u6539\u540e\u5237\u65b0\u3002"),
            "Document");
    }

    private FrameworkElement? FilePaneStatusLine(WorkspaceFileListing? listing, string? listingError)
    {
        if (!string.IsNullOrWhiteSpace(listingError))
        {
            return FilePaneStatusLine("AlertCircle", listingError, Brush("V2RedBrush"));
        }
        if (listing is { SkippedItemCount: > 0 })
        {
            var count = listing.SkippedItemCount;
            var text = IsChineseUi()
                ? $"\u5df2\u7701\u7565 {count} \u4e2a\u9690\u85cf\u6216\u751f\u6210\u9879"
                : $"{count} hidden or generated item{(count == 1 ? "" : "s")} omitted";
            return FilePaneStatusLine("Eye", text, Brush("V2MutedForegroundBrush"));
        }

        return null;
    }

    private FrameworkElement FilePaneStatusLine(string iconKey, string text, Brush foreground) => new StackPanel
    {
        Orientation = Orientation.Horizontal,
        Spacing = 5,
        Children =
        {
            Icon(iconKey, 10, foreground),
            new TextBlock
            {
                Text = text,
                FontSize = 10.5,
                Foreground = foreground,
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 1,
            },
        },
    };

    private Button FilesToolbarButton(string iconKey, string tooltip, Func<Task> action)
    {
        var button = PreviewHeaderButton(iconKey, tooltip);
        button.Click += async (_, _) => await action();
        return button;
    }

    private Button FilesMoreButton()
    {
        var button = PreviewHeaderButton("Ellipsis", L("More", "\u66f4\u591a"));
        var flyout = new MenuFlyout();
        var newFile = new MenuFlyoutItem { Text = T("files.newFile") };
        newFile.Click += async (_, _) => await CreateWorkspaceItemAsync(false);
        flyout.Items.Add(newFile);
        var newFolder = new MenuFlyoutItem { Text = T("files.newFolder") };
        newFolder.Click += async (_, _) => await CreateWorkspaceItemAsync(true);
        flyout.Items.Add(newFolder);
        flyout.Items.Add(new MenuFlyoutSeparator());
        var uploadFiles = new MenuFlyoutItem { Text = L("Upload Files", "\u4e0a\u4f20\u6587\u4ef6") };
        uploadFiles.Click += async (_, _) => await UploadWorkspaceFileAsync();
        flyout.Items.Add(uploadFiles);
        var uploadFolder = new MenuFlyoutItem { Text = L("Upload Folder", "\u4e0a\u4f20\u6587\u4ef6\u5939") };
        uploadFolder.Click += async (_, _) => await UploadWorkspaceFolderAsync();
        flyout.Items.Add(uploadFolder);
        var download = new MenuFlyoutItem { Text = L("Download", "\u4e0b\u8f7d") };
        download.Click += async (_, _) => await DownloadWorkspaceZipAsync();
        flyout.Items.Add(download);
        if (!string.IsNullOrWhiteSpace(_selectedFilePath))
        {
            flyout.Items.Add(new MenuFlyoutSeparator());
            var rename = new MenuFlyoutItem { Text = T("common.rename") };
            rename.Click += async (_, _) => await RenameWorkspaceItemAsync();
            flyout.Items.Add(rename);
            var delete = new MenuFlyoutItem { Text = T("common.delete") };
            delete.Click += async (_, _) => await DeleteWorkspaceItemAsync();
            flyout.Items.Add(delete);
        }
        flyout.Items.Add(new MenuFlyoutSeparator());
        var collapseAll = new MenuFlyoutItem { Text = L("Collapse all", "\u5168\u90e8\u6298\u53e0") };
        collapseAll.IsEnabled = _expandedFileDirectories.Count > 0;
        collapseAll.Click += (_, _) =>
        {
            _expandedFileDirectories.Clear();
            RenderAll();
        };
        flyout.Items.Add(collapseAll);
        var close = new MenuFlyoutItem { Text = L("Close", "\u5173\u95ed") };
        close.Click += (_, _) =>
        {
            State.ActiveTab = AppTab.Chat;
            RenderAll();
        };
        flyout.Items.Add(close);
        button.Flyout = flyout;
        return button;
    }

    private FrameworkElement SplitDivider() => new Grid
    {
        Width = 12,
        Background = Transparent,
        Children =
        {
            new Border
            {
                Width = 1,
                Background = Brush("V2BorderBrush"),
                HorizontalAlignment = HorizontalAlignment.Center,
            },
        },
    };

    private FrameworkElement FileRow(WorkspaceFile file)
    {
        var isSelected = _selectedFilePath is not null &&
                         string.Equals(_selectedFilePath, file.RelativePath, StringComparison.OrdinalIgnoreCase);
        var row = new Button
        {
            Height = 28,
            Background = isSelected ? Brush("V2SelectedBrush") : Transparent,
            BorderBrush = Transparent,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(6 + file.Depth * 18, 0, 6, 0),
            CornerRadius = new CornerRadius(6),
            Content = new Grid { ColumnSpacing = 8 },
        };
        row.Click += (_, _) =>
        {
            if (file.IsDirectory)
            {
                if (_expandedFileDirectories.Contains(file.Path))
                {
                    _expandedFileDirectories.Remove(file.Path);
                }
                else
                {
                    _expandedFileDirectories.Add(file.Path);
                }
            }
            else
            {
                _selectedFilePath = file.RelativePath;
                _previewDraftText = null;
                _isMarkdownPreviewing = false;
                _isCodePreviewing = false;
            }

            RenderContent();
        };
        var grid = (Grid)row.Content;
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(file.IsDirectory
            ? Icon(file.IsExpanded ? "ChevronDown" : "ChevronRight", 10, Brush("V2MutedForegroundBrush"))
            : new Border { Width = 12 });
        var fileIcon = Icon(FileTreeIcon(file), 14, FileTreeIconBrush(file));
        Grid.SetColumn(fileIcon, 1);
        grid.Children.Add(fileIcon);
        var name = new TextBlock
        {
            Text = file.Name,
            FontSize = 12.5,
            FontWeight = isSelected ? Microsoft.UI.Text.FontWeights.Medium : Microsoft.UI.Text.FontWeights.Normal,
            Foreground = isSelected ? Brush("V2ForegroundBrush") : Brush("V2SecondaryForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(name, 2);
        grid.Children.Add(name);
        if (FilePreviewActionPolicy.TreePreviewIcon(file) is { } previewIcon)
        {
            var preview = FileTreeInlineActionButton(previewIcon, L("Open HTML", "\u6253\u5f00 HTML"));
            preview.Click += async (_, _) => await OpenWorkspacePreviewAsync(file.Path);
            Grid.SetColumn(preview, 3);
            grid.Children.Add(preview);
        }
        return row;
    }

    private Button FileTreeInlineActionButton(string iconKey, string label)
    {
        var button = new Button
        {
            Width = 22,
            Height = 22,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(6),
            Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(20, 37, 99, 235)),
            BorderBrush = new SolidColorBrush(global::Windows.UI.Color.FromArgb(34, 37, 99, 235)),
            BorderThickness = new Thickness(1),
            Content = Icon(iconKey, 11, Brush("V2BlueBrush")),
        };
        ToolTipService.SetToolTip(button, label);
        return button;
    }

    private string FileTreeIcon(WorkspaceFile file)
    {
        if (file.IsDirectory) return "Folder";
        if (file.IsMarkdown || file.IsPdf) return "doc.richtext";
        if (file.IsHtml) return "Code";
        if (file.IsImage) return "Image";
        return "Document";
    }

    private Brush FileTreeIconBrush(WorkspaceFile file)
    {
        if (file.IsDirectory) return Brush("V2AmberBrush");
        if (file.IsMarkdown) return Brush("V2BlueBrush");
        if (file.IsPdf) return Brush("V2RedBrush");
        if (file.IsImage) return Brush("V2AmberBrush");
        return Brush("V2MutedForegroundBrush");
    }

    private FrameworkElement FilePreviewPane()
    {
        if (State.SelectedProject is null)
        {
            return EmptyState(T("files.noProject"), T("files.noProjectDetail"), "Folder");
        }

        if (string.IsNullOrWhiteSpace(_selectedFilePath))
        {
            return FileEmptyEditor();
        }

        try
        {
            var preview = _workspaceService.Preview(_selectedFilePath, State.SelectedProject.RootPath);
            var root = new Grid { Background = Brush("V2BackgroundBrush") };
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

            var header = new Grid
            {
                Padding = new Thickness(14, 10, 14, 10),
                ColumnSpacing = 8,
            };
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            header.Children.Add(Icon(FilePreviewHeaderIcon(preview), 14, FilePreviewHeaderIconBrush(preview)));
            var labels = new StackPanel { Spacing = 2 };
            labels.Children.Add(new TextBlock
            {
                Text = Path.GetFileName(preview.Path),
                FontSize = 13,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Foreground = Brush("V2ForegroundBrush"),
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            var languageAlias = CodeSyntaxHighlightingService.LanguageAliasForFileName(preview.RelativePath);
            labels.Children.Add(new TextBlock
            {
                Text = preview.RelativePath,
                FontSize = 10.5,
                FontFamily = new FontFamily("Cascadia Mono, Consolas"),
                Foreground = Brush("V2MutedForegroundBrush"),
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            Grid.SetColumn(labels, 1);
            header.Children.Add(labels);

            var actionPanel = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                VerticalAlignment = VerticalAlignment.Center,
                MaxWidth = 360,
            };
            if (FilePreviewActionPolicy.EditorPreviewToggleIcon(preview, _isMarkdownPreviewing) is { } toggleIcon)
            {
                var toggle = PreviewHeaderButton(toggleIcon, _isMarkdownPreviewing ? (IsChineseUi() ? "\u7f16\u8f91" : "Edit") : T("tabs.preview"));
                toggle.Click += (_, _) =>
                {
                    _isMarkdownPreviewing = !_isMarkdownPreviewing;
                    RenderContent();
                };
                actionPanel.Children.Add(toggle);
            }

            var canHighlight = CodeSyntaxHighlightingService.ShouldHighlight(
                _previewDraftText ?? preview.Text ?? "",
                languageAlias);
            if (canHighlight && preview.Kind is WorkspacePreviewKind.Text or WorkspacePreviewKind.Html)
            {
                var codeToggle = PreviewHeaderButton(
                    _isCodePreviewing ? "Edit" : "Code",
                    _isCodePreviewing ? (IsChineseUi() ? "\u7f16\u8f91" : "Edit") : T("tabs.preview"));
                codeToggle.Click += (_, _) =>
                {
                    _isCodePreviewing = !_isCodePreviewing;
                    RenderContent();
                };
                actionPanel.Children.Add(codeToggle);
            }

            if (preview.Kind == WorkspacePreviewKind.Html && !FilePreviewActionPolicy.EditorShowsHtmlPreview(preview))
            {
                var openHtml = PreviewHeaderButton("globe", IsChineseUi() ? "\u6253\u5f00" : "Open");
                openHtml.Click += async (_, _) => await OpenWorkspacePreviewAsync(preview.Path);
                actionPanel.Children.Add(openHtml);
            }

            if (FilePreviewActionPolicy.UsesNativePdfPreview(preview))
            {
                var openPdf = PreviewHeaderButton("doc.richtext", IsChineseUi() ? "\u6253\u5f00" : "Open");
                openPdf.Click += async (_, _) => await OpenWorkspacePreviewAsync(preview.Path);
                actionPanel.Children.Add(openPdf);
            }

            var download = PreviewHeaderButton("Download", L("Download", "\u4e0b\u8f7d"));
            download.Click += async (_, _) => await DownloadWorkspaceFileAsync(preview.Path);
            actionPanel.Children.Add(download);

            if (preview.Text is not null)
            {
                var revert = PreviewHeaderButton("Refresh", L("Revert", "\u8fd8\u539f"));
                revert.Click += (_, _) =>
                {
                    _previewDraftText = preview.Text;
                    RenderContent();
                };
                actionPanel.Children.Add(revert);

                var save = PreviewHeaderButton("Save", T("common.save"));
                save.Click += async (_, _) => await SavePreviewAsync();
                actionPanel.Children.Add(save);
            }

            var expand = PreviewHeaderButton(_isFileEditorExpanded ? "Shrink" : "Expand", _isFileEditorExpanded ? L("Restore", "\u8fd8\u539f") : L("Expand", "\u5c55\u5f00"));
            expand.Click += (_, _) =>
            {
                _isFileEditorExpanded = !_isFileEditorExpanded;
                RenderAll();
            };
            actionPanel.Children.Add(expand);

            var close = PreviewHeaderButton("X", L("Close", "\u5173\u95ed"));
            close.Click += async (_, _) => await ClosePreviewAsync(preview);
            actionPanel.Children.Add(close);

            Grid.SetColumn(actionPanel, 2);
            header.Children.Add(actionPanel);

            root.Children.Add(new Border
            {
                BorderBrush = Brush("V2BorderBrush"),
                BorderThickness = new Thickness(0, 0, 0, 1),
                Child = header,
            });

            FrameworkElement content = preview.Kind switch
            {
                WorkspacePreviewKind.Markdown when _isMarkdownPreviewing => MarkdownPreview(preview),
                WorkspacePreviewKind.Text or WorkspacePreviewKind.Html when _isCodePreviewing => CodeHighlightedPreview(preview, languageAlias),
                WorkspacePreviewKind.Text or WorkspacePreviewKind.Markdown or WorkspacePreviewKind.Html => TextPreview(preview),
                WorkspacePreviewKind.Image => new ScrollViewer
                {
                    Content = new Image
                    {
                        Source = new BitmapImage(new Uri(preview.Path)),
                        Stretch = Stretch.Uniform,
                        HorizontalAlignment = HorizontalAlignment.Center,
                        VerticalAlignment = VerticalAlignment.Center,
                    },
                },
                WorkspacePreviewKind.Pdf => EmptyState(T("files.pdfPreview"), T("files.pdfPreviewDetail"), "Document"),
                _ => EmptyState(T("files.binaryFile"), T("files.binaryFileDetail"), "Document"),
            };
            Grid.SetRow(content, 1);
            root.Children.Add(content);
            return root;
        }
        catch (Exception ex)
        {
            return new Grid
            {
                Padding = new Thickness(16),
                Children = { ErrorState(ex.Message) },
            };
        }
    }

    private bool PreviewHasUnsavedChanges(WorkspacePreview preview) =>
        preview.Text is not null
        && _previewDraftText is not null
        && !string.Equals(_previewDraftText, preview.Text, StringComparison.Ordinal);

    private async Task ClosePreviewAsync(WorkspacePreview preview)
    {
        if (PreviewHasUnsavedChanges(preview))
        {
            var dialog = Dialog(
                L($"Close without saving {Path.GetFileName(preview.Path)}?", $"\u4e0d\u4fdd\u5b58\u5e76\u5173\u95ed {Path.GetFileName(preview.Path)}\uff1f"),
                new TextBlock
                {
                    Text = L("Unsaved changes will be lost.", "\u672a\u4fdd\u5b58\u7684\u66f4\u6539\u4f1a\u4e22\u5931\u3002"),
                    TextWrapping = TextWrapping.Wrap,
                },
                L("Close", "\u5173\u95ed"));
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                return;
            }
        }

        _selectedFilePath = null;
        _previewDraftText = null;
        _isMarkdownPreviewing = false;
        _isCodePreviewing = false;
        _isFileEditorExpanded = false;
        RenderContent();
    }

    private FrameworkElement FileEmptyEditor() => new Grid
    {
        Background = Brush("V2CardSurfaceSubtleBrush"),
        Children =
        {
            new StackPanel
            {
                Spacing = 10,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                MaxWidth = 320,
                Children =
                {
                    Icon("SidebarLeft", 24, Brush("V2MutedForegroundBrush")),
                    new TextBlock
                    {
                        Text = L("Select a file to edit", "\u9009\u62e9\u6587\u4ef6\u5f00\u59cb\u7f16\u8f91"),
                        FontSize = 14,
                        FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                        Foreground = Brush("V2ForegroundBrush"),
                        TextAlignment = TextAlignment.Center,
                        HorizontalAlignment = HorizontalAlignment.Center,
                    },
                    new TextBlock
                    {
                        Text = L("Browse the project tree, then open a source file, image, or Markdown preview.", "\u5728\u5de6\u4fa7\u6d4f\u89c8\u9879\u76ee\u6587\u4ef6\uff0c\u6253\u5f00\u6e90\u7801\u3001\u56fe\u7247\u6216 Markdown \u9884\u89c8\u3002"),
                        FontSize = 12,
                        Foreground = Brush("V2SecondaryForegroundBrush"),
                        TextWrapping = TextWrapping.Wrap,
                        TextAlignment = TextAlignment.Center,
                        HorizontalAlignment = HorizontalAlignment.Center,
                    },
                },
            },
        },
    };

    private string FilePreviewHeaderIcon(WorkspacePreview preview) => preview.Kind switch
    {
        WorkspacePreviewKind.Image => "Image",
        WorkspacePreviewKind.Pdf or WorkspacePreviewKind.Markdown => "doc.richtext",
        WorkspacePreviewKind.Html => "Code",
        WorkspacePreviewKind.Binary => "Document",
        _ => "Document",
    };

    private Brush FilePreviewHeaderIconBrush(WorkspacePreview preview) => preview.Kind switch
    {
        WorkspacePreviewKind.Markdown or WorkspacePreviewKind.Html => Brush("V2BlueBrush"),
        WorkspacePreviewKind.Image => Brush("V2AmberBrush"),
        WorkspacePreviewKind.Pdf => Brush("V2RedBrush"),
        _ => Brush("V2MutedForegroundBrush"),
    };

    private FrameworkElement TextPreview(WorkspacePreview preview)
    {
        _previewDraftText ??= preview.Text ?? "";
        var editor = new TextBox
        {
            Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
            Text = _previewDraftText,
            AcceptsReturn = true,
            TextWrapping = State.Settings.EditorSettings.WordWrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = State.Settings.EditorSettings.FontSize,
            Padding = new Thickness(12),
            BorderThickness = new Thickness(0),
        };
        editor.TextChanged += (_, _) => _previewDraftText = editor.Text;
        return editor;
    }

    private FrameworkElement MarkdownPreview(WorkspacePreview preview)
    {
        _previewDraftText ??= preview.Text ?? "";
        return new ScrollViewer
        {
            Content = new Border
            {
                Padding = new Thickness(20),
                Child = MarkdownContent(_previewDraftText),
            },
        };
    }

    private FrameworkElement CodeHighlightedPreview(WorkspacePreview preview, string? languageAlias)
    {
        _previewDraftText ??= preview.Text ?? "";
        var lineCount = CodeLineNumberMetrics.LineCount(_previewDraftText);
        var rich = new RichTextBlock
        {
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = State.Settings.EditorSettings.FontSize,
            TextWrapping = State.Settings.EditorSettings.WordWrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            IsTextSelectionEnabled = true,
            Padding = new Thickness(
                State.Settings.EditorSettings.LineNumbers
                    ? CodeLineNumberMetrics.EditorTextInsetAfterLineNumberGutter
                    : CodeLineNumberMetrics.EditorTextInset.Width,
                CodeLineNumberMetrics.EditorTextInset.Height,
                CodeLineNumberMetrics.EditorTextInset.Width,
                CodeLineNumberMetrics.EditorTextInset.Height),
        };
        var paragraph = new Microsoft.UI.Xaml.Documents.Paragraph();
        foreach (var span in CodeSyntaxHighlightingService.HighlightedSpans(_previewDraftText, languageAlias))
        {
            paragraph.Inlines.Add(new Run
            {
                Text = span.Text,
                Foreground = SyntaxBrush(span.Kind),
            });
        }
        rich.Blocks.Add(paragraph);

        var codeContent = new Grid
        {
            ColumnSpacing = 0,
        };
        if (State.Settings.EditorSettings.LineNumbers)
        {
            codeContent.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(CodeLineNumberMetrics.RulerWidth(lineCount)) });
        }
        codeContent.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        if (State.Settings.EditorSettings.LineNumbers)
        {
            var lineNumbers = CodeLineNumberGutter(lineCount);
            Grid.SetColumn(lineNumbers, 0);
            codeContent.Children.Add(lineNumbers);
            Grid.SetColumn(rich, 1);
        }
        codeContent.Children.Add(rich);

        var scroll = new ScrollViewer
        {
            HorizontalScrollBarVisibility = State.Settings.EditorSettings.WordWrap ? ScrollBarVisibility.Disabled : ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = codeContent,
        };

        if (!State.Settings.EditorSettings.ShowMinimap)
        {
            return scroll;
        }

        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(CodeMinimapModel.Width) });
        root.Children.Add(scroll);
        var minimap = CodeMinimap(CodeMinimapModel.FromText(_previewDraftText));
        Grid.SetColumn(minimap, 1);
        root.Children.Add(minimap);
        return root;
    }

    private FrameworkElement CodeLineNumberGutter(int lineCount)
    {
        var panel = new StackPanel
        {
            Background = Brush("V2BackgroundBrush"),
            Padding = new Thickness(0, CodeLineNumberMetrics.EditorTextInset.Height + 2, 10, CodeLineNumberMetrics.EditorTextInset.Height),
        };
        for (var line = 1; line <= lineCount; line++)
        {
            panel.Children.Add(new TextBlock
            {
                Text = line.ToString(),
                FontFamily = new FontFamily("Cascadia Mono, Consolas"),
                FontSize = 11,
                Foreground = Brush("V2MutedForegroundBrush"),
                TextAlignment = TextAlignment.Right,
                LineHeight = State.Settings.EditorSettings.FontSize + 4,
            });
        }

        return new Border
        {
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(0, 0, 1, 0),
            Child = panel,
        };
    }

    private FrameworkElement CodeMinimap(CodeMinimapModel model)
    {
        var height = Math.Max(120, Math.Min(720, model.Lines.Count * 2.0));
        var canvas = new Canvas
        {
            Width = CodeMinimapModel.Width,
            Height = height,
            Background = Brush("V2BackgroundBrush"),
        };
        var count = Math.Max(1, model.Lines.Count);
        var rowHeight = Math.Max(1, height / count);
        for (var index = 0; index < model.Lines.Count; index++)
        {
            var line = model.Lines[index];
            var y = index * height / count;
            var x = Math.Min(CodeMinimapModel.Width - 12, 6 + line.IndentLevel * 0.65);
            var availableWidth = Math.Max(5, CodeMinimapModel.Width - x - 7);
            var width = Math.Max(4, availableWidth * line.WidthFraction);
            var rectangle = new Microsoft.UI.Xaml.Shapes.Rectangle
            {
                Width = width,
                Height = Math.Max(1, rowHeight * (line.IsBlank ? 0.20 : 0.42)),
                RadiusX = 0.8,
                RadiusY = 0.8,
                Fill = Brush("V2MutedForegroundBrush"),
                Opacity = line.Intensity,
            };
            Canvas.SetLeft(rectangle, x);
            Canvas.SetTop(rectangle, y + (rowHeight - rectangle.Height) / 2);
            canvas.Children.Add(rectangle);
        }

        var viewportHeight = Math.Max(
            CodeEditorScrollStabilityMetrics.MinimapViewportMinHeight,
            model.ViewportHeightFraction * height);
        var viewport = new Microsoft.UI.Xaml.Shapes.Rectangle
        {
            Width = Math.Max(0, CodeMinimapModel.Width - 8),
            Height = viewportHeight,
            RadiusX = 4,
            RadiusY = 4,
            Fill = Brush("V2MutedForegroundBrush"),
            Stroke = Brush("V2SecondaryForegroundBrush"),
            StrokeThickness = 1,
            Opacity = 0.22,
        };
        Canvas.SetLeft(viewport, 4);
        Canvas.SetTop(viewport, Math.Min(height - viewportHeight, model.ViewportStartFraction * height));
        canvas.Children.Add(viewport);

        return new Border
        {
            Width = CodeMinimapModel.Width,
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1, 0, 0, 0),
            Child = canvas,
        };
    }

    private Brush SyntaxBrush(CodeHighlightTokenKind kind)
    {
        var hex = CodeSyntaxHighlightingService.ColorHex(kind, RootGrid.ActualTheme == ElementTheme.Dark);
        return new SolidColorBrush(ColorFromHex(hex));
    }

    private static global::Windows.UI.Color ColorFromHex(string hex)
    {
        var value = hex.TrimStart('#');
        var offset = value.Length == 8 ? 2 : 0;
        var alpha = value.Length == 8 ? Convert.ToByte(value[..2], 16) : (byte)255;
        return global::Windows.UI.Color.FromArgb(
            alpha,
            Convert.ToByte(value.Substring(offset, 2), 16),
            Convert.ToByte(value.Substring(offset + 2, 2), 16),
            Convert.ToByte(value.Substring(offset + 4, 2), 16));
    }

    private Button PreviewHeaderButton(string iconKey, string label)
    {
        var button = new Button
        {
            Style = (Style)Application.Current.Resources["V2IconButtonStyle"],
            Width = EditorHeaderToolbarMetrics.IconButtonSize,
            Height = EditorHeaderToolbarMetrics.IconButtonSize,
            MinWidth = 0,
            CornerRadius = new CornerRadius(7),
            Background = Brush("V2CardBrush"),
            BorderBrush = Brush("V2BorderBrush"),
            Content = Icon(iconKey, EditorHeaderToolbarMetrics.IconFontSize, Brush("V2SecondaryForegroundBrush")),
        };
        ToolTipService.SetToolTip(button, label);
        return button;
    }

    private async Task CreateWorkspaceItemAsync(bool isDirectory)
    {
        if (State.SelectedProject is null) return;
        var nameBox = new TextBox { Style = (Style)Application.Current.Resources["V2TextBoxStyle"], Header = isDirectory ? T("files.folderName") : T("files.fileName") };
        var dialog = Dialog(isDirectory ? T("files.newFolder") : T("files.newFile"), nameBox, T("common.create"));
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        if (string.IsNullOrWhiteSpace(nameBox.Text)) return;
        var parent = SelectedDirectoryForFileOperation(State.SelectedProject.RootPath);
        try
        {
            var created = _workspaceService.CreateFile(parent, nameBox.Text, isDirectory, State.SelectedProject.RootPath);
            if (isDirectory)
            {
                _expandedFileDirectories.Add(created);
            }
            else
            {
                _selectedFilePath = Path.GetRelativePath(State.SelectedProject.RootPath, created);
                _previewDraftText = "";
                _isMarkdownPreviewing = false;
                _isCodePreviewing = false;
            }

            RenderAll();
        }
        catch (Exception ex)
        {
            await Dialog(T("files.createFailed"), new TextBlock { Text = ex.Message, TextWrapping = TextWrapping.Wrap }, T("common.ok")).ShowAsync();
        }
    }

    private async Task RenameWorkspaceItemAsync()
    {
        if (State.SelectedProject is null || string.IsNullOrWhiteSpace(_selectedFilePath)) return;
        var box = new TextBox
        {
            Text = Path.GetFileName(_selectedFilePath),
            Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
            Header = T("files.newName"),
        };
        if (await Dialog(T("common.rename"), box, T("common.rename")).ShowAsync() != ContentDialogResult.Primary) return;
        if (string.IsNullOrWhiteSpace(box.Text)) return;
        try
        {
            var renamed = _workspaceService.Rename(_selectedFilePath, box.Text, State.SelectedProject.RootPath);
            _selectedFilePath = Path.GetRelativePath(State.SelectedProject.RootPath, renamed);
            _previewDraftText = null;
            _isMarkdownPreviewing = false;
            _isCodePreviewing = false;
            RenderAll();
        }
        catch (Exception ex)
        {
            await Dialog(T("files.renameFailed"), new TextBlock { Text = ex.Message, TextWrapping = TextWrapping.Wrap }, T("common.ok")).ShowAsync();
        }
    }

    private async Task DeleteWorkspaceItemAsync()
    {
        if (State.SelectedProject is null || string.IsNullOrWhiteSpace(_selectedFilePath)) return;
        var dialog = Dialog(T("files.deleteTitle"), new TextBlock
        {
            Text = Tf("files.deleteConfirm", _selectedFilePath),
            TextWrapping = TextWrapping.Wrap,
        }, T("common.delete"));
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            _workspaceService.Delete(_selectedFilePath, State.SelectedProject.RootPath, recursive: true);
            _selectedFilePath = null;
            _previewDraftText = null;
            _isMarkdownPreviewing = false;
            _isCodePreviewing = false;
            RenderAll();
        }
        catch (Exception ex)
        {
            await Dialog(T("files.deleteFailed"), new TextBlock { Text = ex.Message, TextWrapping = TextWrapping.Wrap }, T("common.ok")).ShowAsync();
        }
    }

    private async Task UploadWorkspaceFileAsync()
    {
        if (State.SelectedProject is null) return;
        var picker = new FileOpenPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add("*");
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        try
        {
            var target = SelectedDirectoryForFileOperation(State.SelectedProject.RootPath);
            var uploaded = _workspaceService.UploadFile(file.Path, target, State.SelectedProject.RootPath, overwrite: true);
            _selectedFilePath = Path.GetRelativePath(State.SelectedProject.RootPath, uploaded);
            _previewDraftText = null;
            _isMarkdownPreviewing = false;
            _isCodePreviewing = false;
            RenderAll();
        }
        catch (Exception ex)
        {
            await Dialog(T("files.uploadFailed"), new TextBlock { Text = ex.Message, TextWrapping = TextWrapping.Wrap }, T("common.ok")).ShowAsync();
        }
    }

    private async Task UploadWorkspaceFolderAsync()
    {
        if (State.SelectedProject is null) return;
        var picker = new FolderPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add("*");
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;
        try
        {
            var targetDirectory = SelectedDirectoryForFileOperation(State.SelectedProject.RootPath);
            var uploaded = UploadFolderToWorkspace(folder.Path, targetDirectory, State.SelectedProject.RootPath);
            _selectedFilePath = Path.GetRelativePath(State.SelectedProject.RootPath, uploaded);
            _expandedFileDirectories.Add(uploaded);
            _previewDraftText = null;
            _isMarkdownPreviewing = false;
            _isCodePreviewing = false;
            RenderAll();
        }
        catch (Exception ex)
        {
            await Dialog(T("files.uploadFailed"), new TextBlock { Text = ex.Message, TextWrapping = TextWrapping.Wrap }, T("common.ok")).ShowAsync();
        }
    }

    private static string UploadFolderToWorkspace(string sourcePath, string targetDirectory, string workspaceRoot)
    {
        var source = Path.GetFullPath(sourcePath);
        var targetParent = WorkspaceService.ResolveWorkspacePath(targetDirectory, workspaceRoot);
        var target = Path.Combine(targetParent, PathHelpers.SafeFileToken(Path.GetFileName(source.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar))));
        if (Directory.Exists(target) || File.Exists(target))
        {
            throw new IOException($"Target folder already exists: {target}");
        }

        CopyDirectory(source, target);
        return target;
    }

    private async Task DownloadWorkspaceZipAsync()
    {
        if (State.SelectedProject is null) return;
        var picker = new FileSavePicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        picker.SuggestedFileName = $"{State.SelectedProject.DisplayName}.zip";
        picker.FileTypeChoices.Add("ZIP", [".zip"]);
        var file = await picker.PickSaveFileAsync();
        if (file is null || string.IsNullOrWhiteSpace(file.Path)) return;
        try
        {
            if (File.Exists(file.Path)) File.Delete(file.Path);
            ZipFile.CreateFromDirectory(State.SelectedProject.RootPath, file.Path, CompressionLevel.Fastest, includeBaseDirectory: false);
        }
        catch (Exception ex)
        {
            await Dialog(L("Download failed", "\u4e0b\u8f7d\u5931\u8d25"), new TextBlock { Text = ex.Message, TextWrapping = TextWrapping.Wrap }, T("common.ok")).ShowAsync();
        }
    }

    private async Task DownloadWorkspaceFileAsync(string sourcePath)
    {
        if (!File.Exists(sourcePath)) return;
        var picker = new FileSavePicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var extension = Path.GetExtension(sourcePath);
        var saveExtension = string.IsNullOrWhiteSpace(extension) ? ".bin" : extension;
        picker.SuggestedFileName = Path.GetFileName(sourcePath);
        picker.FileTypeChoices.Add(string.IsNullOrWhiteSpace(extension) ? "File" : extension.TrimStart('.').ToUpperInvariant(), [saveExtension]);
        var file = await picker.PickSaveFileAsync();
        if (file is null || string.IsNullOrWhiteSpace(file.Path)) return;
        try
        {
            File.Copy(sourcePath, file.Path, overwrite: true);
        }
        catch (Exception ex)
        {
            await Dialog(L("Download failed", "\u4e0b\u8f7d\u5931\u8d25"), new TextBlock { Text = ex.Message, TextWrapping = TextWrapping.Wrap }, T("common.ok")).ShowAsync();
        }
    }

    private static void CopyDirectory(string source, string target)
    {
        Directory.CreateDirectory(target);
        foreach (var directory in Directory.EnumerateDirectories(source, "*", SearchOption.AllDirectories))
        {
            Directory.CreateDirectory(Path.Combine(target, Path.GetRelativePath(source, directory)));
        }

        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            File.Copy(file, Path.Combine(target, Path.GetRelativePath(source, file)), overwrite: false);
        }
    }

    private async Task SavePreviewAsync()
    {
        if (State.SelectedProject is null || string.IsNullOrWhiteSpace(_selectedFilePath) || _previewDraftText is null) return;
        try
        {
            _workspaceService.WriteFile(_selectedFilePath, _previewDraftText, State.SelectedProject.RootPath);
            RenderAll();
        }
        catch (Exception ex)
        {
            await Dialog(T("files.saveFailed"), new TextBlock { Text = ex.Message, TextWrapping = TextWrapping.Wrap }, T("common.ok")).ShowAsync();
        }
    }

    private string SelectedDirectoryForFileOperation(string root)
    {
        if (string.IsNullOrWhiteSpace(_selectedFilePath)) return root;
        var resolved = WorkspaceService.ResolveWorkspacePath(_selectedFilePath, root);
        return Directory.Exists(resolved) ? resolved : Path.GetDirectoryName(resolved) ?? root;
    }

    private FrameworkElement ShellPage()
    {
        if (State.SelectedProject is null)
        {
            return EmptyFullPage(T("tabs.shell"), T("chat.status.selectProject"), "terminal");
        }

        var commandInput = ToolToolbarTextBox(_shellInputText, L("Command", "命令"), 360, isMonospaced: true);
        commandInput.TextChanged += (_, _) => _shellInputText = commandInput.Text;
        commandInput.KeyDown += async (_, args) =>
        {
            if (args.Key == global::Windows.System.VirtualKey.Enter)
            {
                args.Handled = true;
                await RunShellCommandAsync(commandInput.Text);
            }
        };

        var page = ToolPage(T("tabs.shell"), State.SelectedProject.RootPath, new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                commandInput,
                ToolbarTextButton(L("Run", "运行"), (Action)(async () => await RunShellCommandAsync(commandInput.Text)), isProminent: true),
            },
        });
        var body = (Grid)page.Tag!;
        var list = new StackPanel { Spacing = 2 };
        if (_runStore.Runs
            .Where(run => string.Equals(run.Kind, "shell", StringComparison.OrdinalIgnoreCase))
            .Take(24)
            .ToList() is { Count: > 0 } runs)
        {
            foreach (var run in runs)
            {
                list.Children.Add(TerminalRunRow(run));
            }
        }
        else
        {
            list.Children.Add(EmptyState(L("No shell output", "暂无 Shell 输出"), L("Run a command to create a terminal transcript.", "运行命令后这里会显示终端记录。"), "terminal"));
        }

        body.Children.Add(ToolList(list));
        return page;
    }

    private async Task RunShellCommandAsync(string command)
    {
        if (State.SelectedProject is null || string.IsNullOrWhiteSpace(command)) return;
        _shellInputText = command.Trim();
        _shellStatus = $"Running: {_shellInputText}";
        _runStore.StartShellTask(_shellInputText, State.SelectedProject.RootPath, _terminalService, 120_000, CancellationToken.None);
        await Task.CompletedTask;
        RenderAll();
    }

    private async Task StartShellSessionAsync()
    {
        if (State.SelectedProject is null) return;
        await DisposeShellSessionAsync();
        try
        {
            _shellSession = InteractiveTerminalSession.Start(State.SelectedProject.RootPath);
            _shellStatus = $"PowerShell session started in {State.SelectedProject.RootPath}";
        }
        catch (Exception ex)
        {
            _shellStatus = ex.Message;
        }

        RenderAll();
    }

    private async Task SendShellInputAsync(string input)
    {
        if (State.SelectedProject is null || string.IsNullOrWhiteSpace(input)) return;
        if (_shellSession is null || _shellSession.HasExited)
        {
            await StartShellSessionAsync();
        }

        try
        {
            if (_shellSession is not null)
            {
                await _shellSession.SendInputAsync(input);
                _shellStatus = $"Sent: {input}";
                await Task.Delay(150);
            }
        }
        catch (Exception ex)
        {
            _shellStatus = ex.Message;
        }

        _shellInputText = "";
        RenderAll();
    }

    private FrameworkElement GitPage()
    {
        if (State.SelectedProject is null)
        {
            return EmptyFullPage(T("git.title"), T("git.pickProject"), "GitBranch");
        }

        var page = ToolPage(T("git.title"), State.SelectedProject.RootPath, new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                ToolbarTextButton("Status", (Action)(() => { _gitDiffText = null; _toolStatus = null; RenderAll(); }), isProminent: true),
                ToolbarTextButton("Diff", (Action)(() =>
                {
                    try
                    {
                        _gitDiffText = _gitService.Diff(State.SelectedProject.RootPath);
                        _toolStatus = null;
                    }
                    catch (Exception ex)
                    {
                        _gitDiffText = ex.Message;
                    }

                    RenderAll();
                })),
                ToolbarTextButton("Fetch", (Action)(async () => await GitActionAsync(() => { _gitService.Fetch(State.SelectedProject.RootPath); return "Fetched origin."; }))),
                ToolbarTextButton("Pull", (Action)(async () => await GitActionAsync(() => { _gitService.Pull(State.SelectedProject.RootPath, "G9Claw", "g9claw@example.local"); return "Pulled current branch."; }))),
                ToolbarTextButton("Push", (Action)(async () => await GitActionAsync(() => { _gitService.PushCurrentBranch(State.SelectedProject.RootPath); return "Pushed current branch."; }))),
            },
        });
        var body = (Grid)page.Tag!;

        try
        {
            var status = _gitService.Status(State.SelectedProject.RootPath);
            var output = _gitDiffText ?? GitStatusOutput(status);
            if (!string.IsNullOrWhiteSpace(_toolStatus))
            {
                output = $"{_toolStatus}{Environment.NewLine}{Environment.NewLine}{output}";
            }

            body.Children.Add(MonospaceOutput(output));
        }
        catch (Exception ex)
        {
            body.Children.Add(MonospaceOutput($"Git is not initialized{Environment.NewLine}{Environment.NewLine}{ex.Message}"));
        }

        return page;
    }

    private string GitStatusOutput(GitStatusSnapshot status)
    {
        var lines = new List<string>
        {
            $"On branch {status.Branch}",
            "",
        };
        if (status.Entries.Count == 0)
        {
            lines.Add(T("git.clean"));
            lines.Add(T("git.cleanDetail"));
        }
        else
        {
            lines.Add("Changes:");
            foreach (var entry in status.Entries)
            {
                lines.Add($"  {entry.State,-24} {entry.Path}");
            }
        }

        return string.Join(Environment.NewLine, lines);
    }

    private async Task GitActionAsync(Func<string> action)
    {
        try
        {
            _toolStatus = action();
        }
        catch (Exception ex)
        {
            _toolStatus = ex.Message;
        }

        await Task.CompletedTask;
        RenderAll();
    }

    private async Task CommitGitAsync()
    {
        if (State.SelectedProject is null) return;
        var message = await PromptTextAsync("Commit message", "Describe the change");
        if (string.IsNullOrWhiteSpace(message)) return;
        await GitActionAsync(() =>
        {
            var status = _gitService.Status(State.SelectedProject.RootPath);
            var paths = status.Entries.Select(entry => entry.Path).ToList();
            if (paths.Count == 0) return "No changes to commit.";
            var commit = _gitService.Commit(State.SelectedProject.RootPath, message, paths, "G9Claw", "g9claw@example.local");
            return $"Committed {commit.Sha[..Math.Min(12, commit.Sha.Length)]}: {commit.Message}";
        });
    }

    private FrameworkElement RoutingPage()
    {
        var selectedProject = State.SelectedProject;
        var isProjectScoped = selectedProject is not null && !_routingShowsTotalDashboard;
        var routingRecords = isProjectScoped && selectedProject is not null
            ? State.RoutingUsage.Where(record =>
                string.Equals(record.ProjectName, selectedProject.DisplayName, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(record.ProjectName, selectedProject.Name, StringComparison.OrdinalIgnoreCase))
            : State.RoutingUsage;
        var snapshot = RoutingUsageAggregator.Snapshot(routingRecords);
        var baseline = Math.Max(snapshot.EstimatedCost + snapshot.SavedCost, snapshot.EstimatedCost);
        var savingsRate = baseline > 0 ? snapshot.SavedCost / baseline : 0;
        var isChinese = IsChineseUi();
        var recentSessions = snapshot.EffectiveRecentSessions;

        var root = new Grid { Background = Brush("V2BackgroundBrush") };
        var panel = new StackPanel
        {
            MaxWidth = 980,
            HorizontalAlignment = HorizontalAlignment.Left,
            Padding = new Thickness(32, 20, 32, 20),
            Spacing = 16,
        };
        var header = new Grid { ColumnSpacing = 12 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new StackPanel
        {
            Spacing = 6,
            Children =
            {
                new TextBlock
                {
                    Text = T("routing.title"),
                    FontSize = 19,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Foreground = Brush("V2ForegroundBrush"),
                },
                RoutingHeaderSubtitle(
                    isProjectScoped && selectedProject is not null
                        ? (IsChineseUi() ? $"{selectedProject.DisplayName} \u7684\u8def\u7531\u7edf\u8ba1" : $"{selectedProject.DisplayName} routing stats")
                        : L("Model routing, token saver, request log, and cost summary.", "\u6a21\u578b\u8def\u7531\u3001token saver\u3001\u8bf7\u6c42\u65e5\u5fd7\u548c\u6210\u672c\u6c47\u603b\u3002"),
                    selectedProject is not null && !isProjectScoped),
            },
        });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (selectedProject is not null)
        {
            actions.Children.Add(InlineSegmentedControl(new[]
            {
                (L("Project", "\u9879\u76ee"), !_routingShowsTotalDashboard, (Action)(() => { _routingShowsTotalDashboard = false; _expandedRoutingSessions.Clear(); RenderAll(); })),
                (L("Total", "\u603b\u8ba1"), _routingShowsTotalDashboard, (Action)(() => { _routingShowsTotalDashboard = true; _expandedRoutingSessions.Clear(); RenderAll(); })),
            }));
        }
        actions.Children.Add(ToolbarButton("Refresh", T("common.refresh"), RenderAll));
        Grid.SetColumn(actions, 1);
        header.Children.Add(actions);
        panel.Children.Add(header);

        panel.Children.Add(MetricGrid(
            MetricRow("CircleGauge", T("routing.metrics.requests"), snapshot.RequestCount.ToString(), isChinese ? $"{snapshot.RoutedSessions} \u4e2a\u5df2\u8def\u7531\u4f1a\u8bdd" : $"{snapshot.RoutedSessions} routed sessions"),
            MetricRow("Database", T("routing.metrics.tokens"), snapshot.TotalTokens.ToString("N0"), L("input/output recorded by native agent", "native agent \u8bb0\u5f55\u7684\u8f93\u5165/\u8f93\u51fa")),
            MetricRow("BarChart3", T("routing.metrics.actualCost"), Money(snapshot.EstimatedCost), baseline > 0 ? $"{L("No router", "\u4e0d\u8d70 Router")} {Money(baseline)}" : T("routing.metrics.costDetail"), snapshot.SavedCost > 0 ? $"{L("Saved", "\u8282\u7701")} {Money(snapshot.SavedCost)} ({(int)Math.Round(savingsRate * 100)}%)" : null)));

        if (!isProjectScoped && snapshot.EffectiveProjects.Count > 0)
        {
            var projects = new StackPanel { Spacing = 8 };
            foreach (var project in snapshot.EffectiveProjects)
            {
                projects.Children.Add(RoutingProjectSummaryRow(project));
            }

            panel.Children.Add(ToolSection(L("Projects", "\u9879\u76ee"), projects));
        }

        if (recentSessions.Count == 0)
        {
            panel.Children.Add(ToolSection(isChinese ? "\u4f1a\u8bdd" : T("routing.recentRoutes"),
                new TextBlock
                {
                    Text = L("No routing activity yet. Start a conversation to see stats here.", "\u6682\u65e0\u8def\u7531\u6d3b\u52a8\u3002\u5f00\u59cb\u5bf9\u8bdd\u540e\u8fd9\u91cc\u4f1a\u663e\u793a\u7edf\u8ba1\u3002"),
                    FontSize = 13,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    Padding = new Thickness(0, 18, 0, 18),
                }));
        }
        else
        {
            var recent = new StackPanel { Spacing = 0 };
            recent.Children.Add(RoutingTableHeader(isChinese));
            foreach (var session in recentSessions)
            {
                recent.Children.Add(RoutingSessionRow(session));
            }

            panel.Children.Add(ToolSection(isChinese ? "\u4f1a\u8bdd" : T("routing.recentRoutes"), recent));

            panel.Children.Add(RoutingCostSummaryCard(snapshot.EstimatedCost, baseline, snapshot.SavedCost, snapshot.RequestCount, snapshot.TotalTokens, savingsRate));
        }

        root.Children.Add(new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = panel,
        });
        return root;
    }

    private FrameworkElement RoutingHeaderSubtitle(string text, bool showTotalBadge)
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Children =
            {
                new TextBlock
                {
                    Text = text,
                    FontSize = 13,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    TextTrimming = TextTrimming.CharacterEllipsis,
                },
            },
        };
        if (showTotalBadge)
        {
            row.Children.Add(SkillBadge(L("Total", "\u5168\u90e8\u9879\u76ee"), Brush("V2MutedForegroundBrush")));
        }
        return row;
    }

    private FrameworkElement RoutingTableHeader(bool isChinese)
    {
        var header = new Grid
        {
            Padding = new Thickness(10, 0, 10, 6),
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = new GridLength(76) },
                new ColumnDefinition { Width = new GridLength(82) },
                new ColumnDefinition { Width = new GridLength(72) },
                new ColumnDefinition { Width = new GridLength(72) },
            },
        };
        header.Children.Add(RoutingHeaderText(L("Session", "\u4f1a\u8bdd"), 0, HorizontalAlignment.Left));
        header.Children.Add(RoutingHeaderText(isChinese ? "\u5206\u7c7b" : "Tier", 1, HorizontalAlignment.Right));
        header.Children.Add(RoutingHeaderText(T("routing.metrics.tokens"), 2, HorizontalAlignment.Right));
        header.Children.Add(RoutingHeaderText(T("routing.metrics.actualCost"), 3, HorizontalAlignment.Right));
        header.Children.Add(RoutingHeaderText(L("Saved", "\u8282\u7701"), 4, HorizontalAlignment.Right));
        return header;
    }

    private FrameworkElement RoutingHeaderText(string text, int column, HorizontalAlignment alignment)
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = 11,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2MutedForegroundBrush"),
            HorizontalAlignment = alignment,
        };
        Grid.SetColumn(block, column);
        return block;
    }

    private FrameworkElement RoutingProjectSummaryRow(RoutingDashboardProject project)
    {
        var row = new Grid
        {
            ColumnSpacing = 12,
            Padding = new Thickness(12, 10, 12, 10),
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = new GridLength(80) },
                new ColumnDefinition { Width = new GridLength(80) },
                new ColumnDefinition { Width = new GridLength(78) },
            },
        };
        row.Children.Add(new StackPanel
        {
            Spacing = 4,
            Children =
            {
                new TextBlock
                {
                    Text = project.DisplayName,
                    FontSize = 13,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Foreground = Brush("V2ForegroundBrush"),
                    TextTrimming = TextTrimming.CharacterEllipsis,
                },
                new TextBlock
                {
                    Text = IsChineseUi()
                        ? $"{project.Sessions} \u4e2a sessions \u00b7 {project.Total.RequestCount} \u6b21\u8bf7\u6c42"
                        : $"{project.Sessions} sessions \u00b7 {project.Total.RequestCount} requests",
                    FontSize = 11,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    TextTrimming = TextTrimming.CharacterEllipsis,
                },
            },
        });
        row.Children.Add(RoutingProjectMetric(RoutingFormatTokens(project.Total.TotalTokens), "tokens", 1));
        row.Children.Add(RoutingProjectMetric(Money(project.Total.EstimatedCost), "cost", 2));
        row.Children.Add(RoutingValueText(project.Total.SavedCost > 0 ? Money(project.Total.SavedCost) : "-", 3, project.Total.SavedCost > 0 ? Brush("V2GreenBrush") : Brush("V2MutedForegroundBrush")));

        return new Border
        {
            CornerRadius = new CornerRadius(6),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2ContentSurfaceBrush"),
            Child = row,
        };
    }

    private FrameworkElement RoutingProjectMetric(string value, string label, int column)
    {
        var metric = new StackPanel
        {
            Spacing = 2,
            HorizontalAlignment = HorizontalAlignment.Right,
            Children =
            {
                new TextBlock
                {
                    Text = value,
                    FontSize = 12,
                    FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                    FontFamily = new FontFamily("Consolas"),
                    Foreground = Brush("V2SecondaryForegroundBrush"),
                    HorizontalAlignment = HorizontalAlignment.Right,
                },
                new TextBlock
                {
                    Text = label,
                    FontSize = 10,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    HorizontalAlignment = HorizontalAlignment.Right,
                },
            },
        };
        Grid.SetColumn(metric, column);
        return metric;
    }

    private FrameworkElement RoutingSessionRow(RoutingDashboardSession session)
    {
        var expanded = _expandedRoutingSessions.Contains(session.Id);
        var row = new Grid
        {
            Padding = new Thickness(10, 8, 10, 8),
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = new GridLength(76) },
                new ColumnDefinition { Width = new GridLength(82) },
                new ColumnDefinition { Width = new GridLength(72) },
                new ColumnDefinition { Width = new GridLength(72) },
            },
        };
        row.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 10,
            Children =
            {
                Icon(expanded ? "ChevronDown" : "ChevronRight", 11, Brush("V2MutedForegroundBrush")),
                new StackPanel
                {
                    Spacing = 3,
                    Children =
                    {
                        new TextBlock
                        {
                            Text = session.Title,
                            FontSize = 13,
                            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                            Foreground = Brush("V2ForegroundBrush"),
                            TextTrimming = TextTrimming.CharacterEllipsis,
                        },
                        new TextBlock
                        {
                            Text = RoutingSessionSubtitle(session),
                            FontSize = 11,
                            Foreground = Brush("V2MutedForegroundBrush"),
                            TextTrimming = TextTrimming.CharacterEllipsis,
                        },
                    },
                },
            },
        });
        row.Children.Add(RoutingTierBadge(RoutingPrimaryTier(session), 1));
        row.Children.Add(RoutingValueText(RoutingFormatTokens(session.EffectiveTotal.TotalTokens), 2, Brush("V2MutedForegroundBrush")));
        row.Children.Add(RoutingValueText(Money(session.EffectiveTotal.EstimatedCost), 3, Brush("V2MutedForegroundBrush")));
        row.Children.Add(RoutingValueText(session.EffectiveTotal.SavedCost > 0 ? Money(session.EffectiveTotal.SavedCost) : "-", 4, session.EffectiveTotal.SavedCost > 0 ? Brush("V2GreenBrush") : Brush("V2MutedForegroundBrush")));

        var header = new Border
        {
            CornerRadius = new CornerRadius(6),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2ContentSurfaceBrush"),
            Child = row,
        };
        header.Tapped += (_, _) =>
        {
            if (!_expandedRoutingSessions.Add(session.Id))
            {
                _expandedRoutingSessions.Remove(session.Id);
            }

            RenderAll();
        };

        var stack = new StackPanel { Spacing = 0 };
        stack.Children.Add(header);
        if (expanded)
        {
            stack.Children.Add(RoutingSessionDetails(session));
        }

        return stack;
    }

    private FrameworkElement RoutingSessionDetails(RoutingDashboardSession session)
    {
        var content = new StackPanel { Spacing = 8 };
        var entries = session.EffectiveRequestEntries;
        if (entries.Count > 0)
        {
            foreach (var entry in entries)
            {
                content.Children.Add(RoutingRequestLogRow(entry));
            }
        }
        else
        {
            foreach (var line in session.RequestLog.TakeLast(8))
            {
                content.Children.Add(new TextBlock
                {
                    Text = line,
                    FontSize = 12,
                    FontFamily = new FontFamily("Consolas"),
                    Foreground = Brush("V2MutedForegroundBrush"),
                    TextWrapping = TextWrapping.Wrap,
                });
            }
        }

        return new Border
        {
            CornerRadius = new CornerRadius(6),
            Background = Brush("V2CardBrush"),
            Padding = new Thickness(38, 10, 10, 10),
            Child = content,
        };
    }

    private FrameworkElement RoutingRequestLogRow(RoutingRequestLogEntry entry)
    {
        var row = new Grid
        {
            ColumnSpacing = 10,
            Padding = new Thickness(10),
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(18) },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
            },
        };
        row.Children.Add(Icon(string.IsNullOrWhiteSpace(entry.Skill) ? "GitBranch" : "Sparkles", 12, string.IsNullOrWhiteSpace(entry.Skill) ? Brush("V2MutedForegroundBrush") : Brush("V2AmberBrush")));

        var body = new StackPanel { Spacing = 4 };
        var top = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        top.Children.Add(new TextBlock
        {
            Text = entry.Role == "sub" ? "Subagent" : "Main",
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
        });
        if (!string.IsNullOrWhiteSpace(entry.Tier))
        {
            top.Children.Add(RoutingTierBadge(entry.Tier, null));
        }
        top.Children.Add(new TextBlock
        {
            Text = entry.Model,
            FontSize = 12,
            FontFamily = new FontFamily("Consolas"),
            Foreground = Brush("V2MutedForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        top.Children.Add(new TextBlock
        {
            Text = RoutingFormatTokens(entry.Tokens),
            FontSize = 12,
            FontFamily = new FontFamily("Consolas"),
            Foreground = Brush("V2MutedForegroundBrush"),
        });
        top.Children.Add(new TextBlock
        {
            Text = Money(entry.Cost),
            FontSize = 12,
            FontFamily = new FontFamily("Consolas"),
            Foreground = Brush("V2SecondaryForegroundBrush"),
        });
        body.Children.Add(top);

        if (!string.IsNullOrWhiteSpace(entry.Skill))
        {
            body.Children.Add(new TextBlock
            {
                Text = $"Skill: {entry.Skill}",
                FontSize = 12,
                Foreground = Brush("V2SecondaryForegroundBrush"),
            });
        }
        if (!string.IsNullOrWhiteSpace(entry.Query))
        {
            body.Children.Add(new TextBlock
            {
                Text = entry.Query,
                FontSize = 12,
                Foreground = Brush("V2MutedForegroundBrush"),
                MaxLines = 2,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        if (entry.SavedCost is > 0)
        {
            body.Children.Add(new TextBlock
            {
                Text = $"Baseline {Money(entry.BaselineCost ?? 0)} \u00b7 Saved {Money(entry.SavedCost.Value)}",
                FontSize = 11,
                Foreground = Brush("V2GreenBrush"),
            });
        }

        Grid.SetColumn(body, 1);
        row.Children.Add(body);
        return new Border
        {
            CornerRadius = new CornerRadius(6),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2CardBrush"),
            Child = row,
        };
    }

    private FrameworkElement RoutingTierBadge(string tier, int? column)
    {
        var tint = RoutingTierBrush(tier);
        var badge = new Border
        {
            CornerRadius = new CornerRadius(999),
            Background = Brush("V2ControlSurfaceBrush"),
            Padding = new Thickness(7, 3, 7, 3),
            HorizontalAlignment = column is null ? HorizontalAlignment.Left : HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock
            {
                Text = tier,
                FontSize = 10,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Foreground = tint,
                TextTrimming = TextTrimming.CharacterEllipsis,
            },
        };
        if (column is int gridColumn)
        {
            badge.Width = 76;
            Grid.SetColumn(badge, gridColumn);
        }

        return badge;
    }

    private Brush RoutingTierBrush(string tier) => tier.ToUpperInvariant() switch
    {
        "SIMPLE" => Brush("V2BlueBrush"),
        "MEDIUM" => Brush("V2AmberBrush"),
        "REASONING" => new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 147, 51, 234)),
        _ => Brush("V2GreenBrush"),
    };

    private static string RoutingPrimaryTier(RoutingDashboardSession session)
    {
        var entryTier = session.EffectiveRequestEntries.LastOrDefault(entry => !string.IsNullOrWhiteSpace(entry.Tier))?.Tier;
        if (!string.IsNullOrWhiteSpace(entryTier))
        {
            return entryTier;
        }

        return session.ByTier.Keys.OrderBy(key => key, StringComparer.OrdinalIgnoreCase).FirstOrDefault() ?? "RECORDED";
    }

    private string RoutingSessionSubtitle(RoutingDashboardSession session)
    {
        var latest = session.EffectiveRequestEntries.LastOrDefault();
        if (!string.IsNullOrWhiteSpace(latest?.Skill))
        {
            return $"{session.ProjectName} \u00b7 skill {latest.Skill}";
        }

        if (!string.IsNullOrWhiteSpace(latest?.Query))
        {
            return $"{session.ProjectName} \u00b7 {latest.Query}";
        }

        return $"{session.ProjectName} \u00b7 {RelativeLabel(session.LastActiveAt)}";
    }

    private static string RoutingFormatTokens(int tokens)
    {
        if (tokens >= 1_000_000)
        {
            return $"{tokens / 1_000_000d:0.#}M";
        }

        if (tokens >= 10_000)
        {
            return $"{tokens / 1_000d:0.#}K";
        }

        return tokens.ToString("N0");
    }

    private FrameworkElement RoutingValueText(string text, int column, Brush foreground)
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = 12,
            FontFamily = new FontFamily("Consolas"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = foreground,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        Grid.SetColumn(block, column);
        return block;
    }

    private FrameworkElement RoutingCostSummaryCard(decimal actual, decimal baseline, decimal saved, int sessions, int tokens, decimal savingsRate)
    {
        var row = new Grid
        {
            MinHeight = 92,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
            },
        };
        row.Children.Add(RoutingCostMetric(L("Actual", "\u5b9e\u9645\u5f00\u9500"), Money(actual), $"{sessions} sessions / {tokens:N0} tokens", Brush("V2ForegroundBrush"), 0));
        row.Children.Add(RoutingCostDivider(1));
        row.Children.Add(RoutingCostMetric(L("No router", "\u4e0d\u8d70 Router"), Money(baseline), L("Estimated on main model", "\u6309\u4e3b\u6a21\u578b\u57fa\u51c6\u4f30\u7b97"), Brush("V2ForegroundBrush"), 2));
        row.Children.Add(RoutingCostDivider(3));
        row.Children.Add(RoutingCostMetric(L("Saved", "\u8282\u7701"), Money(saved), baseline > 0 ? $"{(int)Math.Round(savingsRate * 100)}% vs baseline" : L("No baseline", "\u6682\u65e0\u57fa\u51c6"), Brush("V2GreenBrush"), 4));

        return new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("V2GreenBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2ContentSurfaceBrush"),
            Child = row,
        };
    }

    private FrameworkElement RoutingCostMetric(string title, string value, string detail, Brush valueBrush, int column)
    {
        var stack = new StackPanel
        {
            Padding = new Thickness(16),
            Spacing = 7,
            Children =
            {
                new TextBlock { Text = title, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Medium, Foreground = Brush("V2MutedForegroundBrush") },
                new TextBlock { Text = value, FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, FontFamily = new FontFamily("Consolas"), Foreground = valueBrush },
                new TextBlock { Text = detail, FontSize = 11, Foreground = Brush("V2MutedForegroundBrush"), TextWrapping = TextWrapping.Wrap },
            },
        };
        Grid.SetColumn(stack, column);
        return stack;
    }

    private FrameworkElement RoutingCostDivider(int column)
    {
        var divider = new Border
        {
            Width = 1,
            Background = Brush("V2BorderBrush"),
            Opacity = 0.9,
            Margin = new Thickness(0, 14, 0, 14),
        };
        Grid.SetColumn(divider, column);
        return divider;
    }

    private FrameworkElement SkillsPage()
    {
        var page = ToolPage(T("skills.title"), T("skills.subtitle"), new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                ToolbarButton("Refresh", T("common.refresh"), (Action)(() => { RefreshNativeStores(); RenderAll(); })),
                ToolbarButton("FolderPlus", L("Import", "\u5bfc\u5165"), (Action)(async () => await ImportSkillFolderAsync())),
                ToolbarButton("Plus", T("skills.newSkill"), (Action)(async () => await CreateSkillAsync()), isProminent: true),
            },
        });

        var selected = SelectedSkill();
        var skillFilter = _skillFilterText.Trim();
        IEnumerable<SkillRecord> FilterSkills(IEnumerable<SkillRecord> skills) =>
            string.IsNullOrWhiteSpace(skillFilter)
                ? skills
                : skills.Where(skill =>
                    skill.Name.Contains(skillFilter, StringComparison.OrdinalIgnoreCase) ||
                    skill.Description.Contains(skillFilter, StringComparison.OrdinalIgnoreCase) ||
                    skill.Slug.Contains(skillFilter, StringComparison.OrdinalIgnoreCase) ||
                    skill.SkillFile.Contains(skillFilter, StringComparison.OrdinalIgnoreCase));
        var searchBox = Box(_skillFilterText, L("Search skills", "\u641c\u7d22\u6280\u80fd"));
        searchBox.Height = 32;
        searchBox.TextChanged += (_, _) =>
        {
            if (string.Equals(_skillFilterText, searchBox.Text, StringComparison.Ordinal)) return;
            _skillFilterText = searchBox.Text;
            RenderAll();
        };
        var shell = new Grid { Background = Brush("V2BackgroundBrush") };
        shell.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(304) });
        shell.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        shell.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var isGeneralContext = State.SelectedProject is null || IsGeneralProject(State.SelectedProject);

        var list = new StackPanel { Spacing = 0 };
        var listHeader = new StackPanel
        {
            Padding = new Thickness(12),
            Spacing = 10,
            Children =
            {
                SkillsScopeIntro(isGeneralContext),
                SearchField(searchBox),
            },
        };
        list.Children.Add(listHeader);
        list.Children.Add(new Border { Height = 1, Background = Brush("V2BorderBrush"), Opacity = 0.72 });

        var listContent = new StackPanel { Padding = new Thickness(12), Spacing = 12 };
        if (!string.IsNullOrWhiteSpace(_toolStatus)) listContent.Children.Add(StatusText(_toolStatus));
        var projectSkills = FilterSkills(State.Skills.Where(skill => skill.Scope == SkillScope.Project)).ToList();
        var userSkills = FilterSkills(State.Skills.Where(skill => skill.Scope == SkillScope.User)).ToList();
        if (!isGeneralContext)
        {
            listContent.Children.Add(SkillScopeSection(
                L("Project", "\u9879\u76ee"),
                L("Only active in this project. Project skills win on name conflicts.", "\u4ec5\u5f53\u524d\u9879\u76ee\u751f\u6548\u3002\u540c\u540d\u65f6\u9879\u76ee\u6280\u80fd\u4f18\u5148\u3002"),
                L("No project skills", "\u6682\u65e0\u9879\u76ee\u6280\u80fd"),
                projectSkills,
                selected));
        }
        listContent.Children.Add(SkillScopeSection(
            L("Global", "\u5168\u5c40"),
            isGeneralContext
                ? L("Available to General chat and every project.", "\u4f1a\u5728\u901a\u7528\u5bf9\u8bdd\u548c\u6240\u6709\u9879\u76ee\u91cc\u751f\u6548\u3002")
                : L("Shared across General chat and every project.", "\u901a\u7528\u5bf9\u8bdd\u548c\u6240\u6709\u9879\u76ee\u5171\u4eab\u3002"),
            L("No global skills", "\u6682\u65e0\u5168\u5c40\u6280\u80fd"),
            userSkills,
            selected));
        if (State.Skills.Count == 0 || ((!isGeneralContext && projectSkills.Count == 0) && userSkills.Count == 0))
        {
            listContent.Children.Add(SkillListEmptyCard(
                string.IsNullOrWhiteSpace(skillFilter) ? T("skills.emptyTitle") : L("No matching skills", "\u6ca1\u6709\u5339\u914d\u7684\u6280\u80fd"),
                string.IsNullOrWhiteSpace(skillFilter)
                    ? T("skills.emptyDetail")
                    : L("Try a different name, description, slug, or scope.", "\u6362\u4e2a\u540d\u79f0\u3001\u63cf\u8ff0\u3001slug \u6216\u4f5c\u7528\u57df\u518d\u8bd5\u3002")));
        }

        list.Children.Add(new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = listContent,
        });
        shell.Children.Add(list);

        var divider = new Border { Background = Brush("V2BorderBrush") };
        Grid.SetColumn(divider, 1);
        shell.Children.Add(divider);

        var detail = new Grid { Background = Brush("V2BackgroundBrush") };
        detail.Children.Add(selected is null ? EmptyState(T("skills.emptyTitle"), T("skills.emptyDetail"), "Sparkles") : SkillDetail(selected));
        Grid.SetColumn(detail, 2);
        shell.Children.Add(detail);

        ((Grid)page.Tag!).Children.Add(shell);
        return page;
    }

    private FrameworkElement MemoryPage()
    {
        var shell = new Grid { Background = Brush("V2BackgroundBrush") };
        shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        shell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var projectRecords = State.MemoryRecords.Count(record => record.Type == MemoryRecordType.Project);
        var feedbackRecords = State.MemoryRecords.Count(record => record.Type == MemoryRecordType.Feedback);
        var userRecords = State.MemoryRecords.Count(record => record.Type == MemoryRecordType.User);
        var latest = State.MemoryRecords
            .Select(record => record.UpdatedAt)
            .OrderByDescending(value => value)
            .FirstOrDefault();
        var memoryDashboard = State.MemoryDashboard;
        var latestIndexed = memoryDashboard.EffectiveOverview.LastIndexedAt ?? (latest == default ? null : latest);
        var memoryAuto = memoryDashboard.EffectiveScheduler.Enabled || State.Settings.MemorySettings?.Enabled == true;
        var isGeneralMemoryContext = State.SelectedProject is null || IsGeneralProject(State.SelectedProject);
        shell.Children.Add(ToolTabbedTopbar(
            new[]
            {
                (isGeneralMemoryContext ? L("General Memory", "\u901a\u7528\u8bb0\u5fc6") : L("Project Memory", "\u9879\u76ee\u8bb0\u5fc6"), _memoryToolTab == MemoryToolTab.ProjectMemory, (Action)(() => { _memoryToolTab = MemoryToolTab.ProjectMemory; _selectedMemoryRecordId = null; RenderAll(); })),
                (L("User Profile", "\u7528\u6237\u753b\u50cf"), _memoryToolTab == MemoryToolTab.Profile, (Action)(() => { _memoryToolTab = MemoryToolTab.Profile; _selectedMemoryRecordId = null; RenderAll(); })),
                (L("Memory Trace", "\u8bb0\u5fc6\u8ffd\u8e2a"), _memoryToolTab == MemoryToolTab.Trace, (Action)(() => { _memoryToolTab = MemoryToolTab.Trace; _selectedMemoryRecordId = null; RenderAll(); })),
            },
            false,
            StatusPill(L("Ready", "\u5c31\u7eea"), false),
            StatusPill(memoryAuto ? L("Auto", "\u81ea\u52a8") : L("Manual", "\u624b\u52a8"), memoryAuto),
            new TextBlock
            {
                Text = latestIndexed is null ? L("Not indexed", "\u672a\u7d22\u5f15") : $"{L("Indexed", "\u5df2\u7d22\u5f15")} {RelativeLabel(latestIndexed.Value)}",
                FontSize = 12,
                Foreground = Brush("V2MutedForegroundBrush"),
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            }));

        var selectedMemory = _selectedMemoryRecordId is { } selectedMemoryId
            ? State.MemoryRecords.FirstOrDefault(record => record.Id == selectedMemoryId)
            : null;
        if (selectedMemory is not null)
        {
            var detail = MemoryDetailPage(selectedMemory);
            Grid.SetRow(detail, 1);
            Grid.SetRowSpan(detail, 2);
            shell.Children.Add(detail);
            return shell;
        }
        _selectedMemoryRecordId = null;

        var memoryFilter = _memoryFilterText.Trim();
        IEnumerable<MemoryRecord> FilterMemory(IEnumerable<MemoryRecord> records) =>
            string.IsNullOrWhiteSpace(memoryFilter)
                ? records
                : records.Where(record =>
                    record.Name.Contains(memoryFilter, StringComparison.OrdinalIgnoreCase) ||
                    record.Summary.Contains(memoryFilter, StringComparison.OrdinalIgnoreCase) ||
                    record.Content.Contains(memoryFilter, StringComparison.OrdinalIgnoreCase));
        if (_memoryToolTab == MemoryToolTab.ProjectMemory)
        {
            var memorySearchBox = Box(_memoryFilterText, L("Search current view", "\u641c\u7d22\u5f53\u524d\u89c6\u56fe"));
            memorySearchBox.Height = 32;
            memorySearchBox.TextChanged += (_, _) =>
            {
                if (string.Equals(_memoryFilterText, memorySearchBox.Text, StringComparison.Ordinal)) return;
                _memoryFilterText = memorySearchBox.Text;
                RenderAll();
            };
            var memoryToolbar = new Border
            {
                Background = Brush("V2CardBrush"),
                BorderBrush = Brush("V2BorderBrush"),
                BorderThickness = new Thickness(0, 0, 0, 1),
                Padding = new Thickness(16, 0, 16, 10),
                Child = new Grid
                {
                    ColumnSpacing = 10,
                    ColumnDefinitions =
                    {
                        new ColumnDefinition { Width = new GridLength(360) },
                        new ColumnDefinition { Width = GridLength.Auto },
                        new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                        new ColumnDefinition { Width = GridLength.Auto },
                    },
                    Children =
                    {
                        SearchField(memorySearchBox),
                    },
                },
            };
            if (memoryToolbar.Child is Grid memoryToolbarGrid)
            {
                var searchAction = ToolbarButton("Search", L("Search", "\u641c\u7d22"), RenderAll);
                Grid.SetColumn(searchAction, 1);
                memoryToolbarGrid.Children.Add(searchAction);
                var memoryActions = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 8,
                    VerticalAlignment = VerticalAlignment.Center,
                    Children =
                    {
                        ToolbarButton("Refresh", T("common.refresh"), (Action)(() => { RefreshNativeStores(); RenderAll(); })),
                        ToolbarButton("Refresh", "Index", (Action)(() => ShowMemoryJobNotice("Index"))),
                        ToolbarButton("Sparkles", "Dream", (Action)(() => ShowMemoryJobNotice("Dream"))),
                        MemoryMoreButton(),
                    },
                };
                Grid.SetColumn(memoryActions, 3);
                memoryToolbarGrid.Children.Add(memoryActions);
            }
            Grid.SetRow(memoryToolbar, 1);
            shell.Children.Add(memoryToolbar);
        }

        var panel = new StackPanel
        {
            Padding = new Thickness(22, 18, 22, 18),
            Spacing = 18,
            MaxWidth = 1120,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        if (!string.IsNullOrWhiteSpace(_toolStatus)) panel.Children.Add(StatusText(_toolStatus));
        if (_memoryToolTab == MemoryToolTab.ProjectMemory)
        {
            if (isGeneralMemoryContext)
            {
                panel.Children.Add(MemoryRecordSection(
                    L("General Topics", "\u901a\u7528\u4e3b\u9898"),
                    L("Topic records formed from general conversations.", "\u4ece\u901a\u7528\u5bf9\u8bdd\u4e2d\u5f62\u6210\u7684\u4e3b\u9898\u8bb0\u5f55\u3002"),
                    FilterMemory(State.MemoryRecords.Where(record => record.Type == MemoryRecordType.GeneralProjectMeta && !record.Deprecated)),
                    SelectMemoryRecord));
            }
            else if (State.SelectedProject is { } selectedProject)
            {
                panel.Children.Add(MemoryProjectContextCard(selectedProject, projectRecords, feedbackRecords, latest));
            }
            panel.Children.Add(MemoryRecordSection(
                isGeneralMemoryContext ? L("General Memory", "\u901a\u7528\u8bb0\u5fc6") : L("Project Memory", "\u9879\u76ee\u8bb0\u5fc6"),
                isGeneralMemoryContext
                    ? L("Facts, preferences, and context from general conversations.", "\u901a\u7528\u5bf9\u8bdd\u4e2d\u7684\u4e8b\u5b9e\u3001\u504f\u597d\u548c\u4e0a\u4e0b\u6587\u8bb0\u5f55\u3002")
                    : L("Progress, facts, and state records for the current project.", "\u5f53\u524d\u9879\u76ee\u7684\u8fdb\u5c55\u3001\u4e8b\u5b9e\u548c\u72b6\u6001\u8bb0\u5f55\u3002"),
                FilterMemory(State.MemoryRecords.Where(record => record.Type == MemoryRecordType.Project && !record.Deprecated)),
                SelectMemoryRecord));
            panel.Children.Add(MemoryRecordSection(
                L("Collaboration Feedback", "\u534f\u4f5c\u53cd\u9988"),
                isGeneralMemoryContext
                    ? L("Preferences, constraints, and delivery rules from general conversations.", "\u901a\u7528\u5bf9\u8bdd\u4e2d\u7684\u504f\u597d\u3001\u7ea6\u675f\u548c\u4ea4\u4ed8\u89c4\u5219\u3002")
                    : L("User preferences, constraints, and delivery rules.", "\u7528\u6237\u504f\u597d\u3001\u7ea6\u675f\u548c\u4ea4\u4ed8\u89c4\u5219\u3002"),
                FilterMemory(State.MemoryRecords.Where(record => record.Type == MemoryRecordType.Feedback && !record.Deprecated)),
                SelectMemoryRecord));
            var deprecated = FilterMemory(State.MemoryRecords.Where(record => record.Deprecated)).ToList();
            if (deprecated.Count > 0)
            {
                panel.Children.Add(MemoryRecordSection(L("Deprecated", "\u5df2\u5f03\u7528"), L("Records marked as deprecated.", "\u6807\u8bb0\u4e3a\u5f03\u7528\u7684\u8bb0\u5f55\u3002"), deprecated, SelectMemoryRecord));
            }
        }
        else if (_memoryToolTab == MemoryToolTab.Profile)
        {
            panel.Children.Add(MemoryProfileSummary(userRecords, latest));
            panel.Children.Add(MemoryRecordSection(L("User Profile", "\u7528\u6237\u753b\u50cf"), L("Long-term identity background and preferences.", "\u957f\u671f\u8eab\u4efd\u80cc\u666f\u548c\u504f\u597d\u3002"), FilterMemory(State.MemoryRecords.Where(record => record.Type == MemoryRecordType.User && !record.Deprecated)), SelectMemoryRecord));
            panel.Children.Add(MemoryRecordSection(L("Feedback Profile", "\u53cd\u9988\u753b\u50cf"), L("Preferences extracted from collaboration feedback.", "\u4ece\u534f\u4f5c\u53cd\u9988\u4e2d\u63d0\u53d6\u7684\u504f\u597d\u3002"), FilterMemory(State.MemoryRecords.Where(record => record.Type == MemoryRecordType.Feedback && !record.Deprecated)), SelectMemoryRecord));
        }
        else
        {
            panel.Children.Add(MemoryTracePanel());
        }

        var scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = panel,
        };
        Grid.SetRow(scroll, 2);
        shell.Children.Add(scroll);
        return shell;
    }

    private FrameworkElement MemoryProjectContextCard(WorkspaceProject project, int projectRecords, int feedbackRecords, DateTimeOffset latest)
    {
        var rows = new StackPanel
        {
            Spacing = 8,
            Children =
            {
                ListCard("Folder", project.DisplayName, project.RootPath),
                ListCard("Database", L("Memory entries", "\u8bb0\u5fc6\u6761\u76ee"), IsChineseUi()
                    ? $"{projectRecords} \u4e2a\u9879\u76ee\u8bb0\u5fc6 / {feedbackRecords} \u4e2a\u53cd\u9988"
                    : $"{projectRecords} project memories / {feedbackRecords} feedback records"),
                ListCard("Clock", L("Last indexed", "\u6700\u8fd1\u7d22\u5f15"), latest == default ? L("Not indexed", "\u672a\u7d22\u5f15") : RelativeLabel(latest)),
            },
        };

        return ToolBoardGroup(
            L("Project Context", "\u9879\u76ee\u4e0a\u4e0b\u6587"),
            L("Current workspace scope for memory recall and editing.", "\u8bb0\u5fc6\u53ec\u56de\u548c\u7f16\u8f91\u4f7f\u7528\u7684\u5f53\u524d\u5de5\u4f5c\u533a\u8303\u56f4\u3002"),
            rows);
    }

    private FrameworkElement MemoryProfileSummary(int userRecords, DateTimeOffset latest)
    {
        var detail = userRecords == 0
            ? DashedEmptyState(
                L("No summarized user profile yet", "\u6682\u65e0\u6c47\u603b\u540e\u7684\u7528\u6237\u753b\u50cf"),
                L("User notes are merged here after Dream runs.", "User Notes \u4f1a\u5728 Dream \u540e\u5408\u5e76\u5230\u8fd9\u91cc\u3002"))
            : ListCard("Database", L("User Notes", "\u7528\u6237\u7b14\u8bb0"), IsChineseUi()
                ? $"{userRecords} \u6761\u8bb0\u5f55 / {(latest == default ? L("Not indexed", "\u672a\u7d22\u5f15") : RelativeLabel(latest))}"
                : $"{userRecords} records / {(latest == default ? L("Not indexed", "\u672a\u7d22\u5f15") : RelativeLabel(latest))}");

        return ToolBoardGroup(
            L("User Profile", "\u7528\u6237\u753b\u50cf"),
            L("Long-term identity background and preferences.", "\u957f\u671f\u8eab\u4efd\u80cc\u666f\u548c\u504f\u597d\u3002"),
            detail);
    }

    private FrameworkElement MemoryTracePanel()
    {
        var stack = new StackPanel { Spacing = 16 };
        stack.Children.Add(InlineSegmentedControl(new[]
        {
            ("Recall", _memoryTraceToolTab == MemoryTraceToolTab.Recall, (Action)(() => SelectMemoryTraceToolTab(MemoryTraceToolTab.Recall))),
            ("Index", _memoryTraceToolTab == MemoryTraceToolTab.Index, (Action)(() => SelectMemoryTraceToolTab(MemoryTraceToolTab.Index))),
            ("Dream", _memoryTraceToolTab == MemoryTraceToolTab.Dream, (Action)(() => SelectMemoryTraceToolTab(MemoryTraceToolTab.Dream))),
        }));

        var records = MemoryTraceRecordsForCurrentTab();
        if (records.Count == 0)
        {
            stack.Children.Add(ToolBoardGroup(
                MemoryTraceSelectTitle(),
                null,
                DashedEmptyState(L("No trace records", "\u6682\u65e0\u8ffd\u8e2a\u8bb0\u5f55"), MemoryTraceEmptyDetail())));
            return stack;
        }

        var selected = SelectedMemoryTrace(records);
        stack.Children.Add(ToolBoardGroup(MemoryTraceSelectTitle(), null, MemoryTraceSelectLabel(selected, records)));
        stack.Children.Add(MemoryTraceDetail(selected));

        return stack;
    }

    private void SelectMemoryTraceToolTab(MemoryTraceToolTab tab)
    {
        if (_memoryTraceToolTab == tab) return;
        _memoryTraceToolTab = tab;
        _selectedMemoryTraceId = null;
        RenderAll();
    }

    private string MemoryTraceSelectTitle() => _memoryTraceToolTab switch
    {
        MemoryTraceToolTab.Index => L("Select an Index trace", "\u9009\u62e9\u4e00\u6761 Index \u8ffd\u8e2a"),
        MemoryTraceToolTab.Dream => L("Select a Dream trace", "\u9009\u62e9\u4e00\u6761 Dream \u8ffd\u8e2a"),
        _ => L("Select a case", "\u9009\u62e9\u4e00\u4e2a\u4e8b\u4f8b"),
    };

    private string MemoryTraceEmptyDetail() => _memoryTraceToolTab switch
    {
        MemoryTraceToolTab.Index => L("Run Index Sync to show Index traces here.", "\u8fd0\u884c\u7d22\u5f15\u540c\u6b65\u540e\u8fd9\u91cc\u4f1a\u663e\u793a Index \u8ffd\u8e2a\u3002"),
        MemoryTraceToolTab.Dream => L("Run Memory Dream to show Dream traces here.", "\u8fd0\u884c Memory Dream \u540e\u8fd9\u91cc\u4f1a\u663e\u793a Dream \u8ffd\u8e2a\u3002"),
        _ => L("Select a case to inspect Recall details.", "\u9009\u62e9\u4e00\u4e2a\u4e8b\u4f8b\u67e5\u770b Recall \u8be6\u60c5\u3002"),
    };

    private IReadOnlyList<MemoryTraceRecord> MemoryTraceRecordsForCurrentTab()
    {
        var dashboard = State.MemoryDashboard;
        var records = _memoryTraceToolTab switch
        {
            MemoryTraceToolTab.Index => dashboard.IndexTraceRecords,
            MemoryTraceToolTab.Dream => dashboard.DreamTraceRecords,
            _ => dashboard.CaseTraceRecords,
        };
        if (records is { Count: > 0 }) return records;

        var legacy = _memoryTraceToolTab switch
        {
            MemoryTraceToolTab.Index => dashboard.IndexTraces,
            MemoryTraceToolTab.Dream => dashboard.DreamTraces,
            _ => dashboard.CaseTraces,
        };

        return legacy.Select((trace, index) => new MemoryTraceRecord(
            $"{_memoryTraceToolTab.ToString().ToLowerInvariant()}-{index}",
            MemoryTraceFallbackTitle(index),
            "completed",
            "legacy",
            DateTimeOffset.Now,
            [],
            "",
            "",
            trace,
            [])).ToList();
    }

    private string MemoryTraceFallbackTitle(int index) => _memoryTraceToolTab switch
    {
        MemoryTraceToolTab.Index => $"Index trace #{index + 1}",
        MemoryTraceToolTab.Dream => $"Dream trace #{index + 1}",
        _ => $"Recall trace #{index + 1}",
    };

    private MemoryTraceRecord? SelectedMemoryTrace(IReadOnlyList<MemoryTraceRecord> records)
    {
        if (!string.IsNullOrWhiteSpace(_selectedMemoryTraceId))
        {
            var selected = records.FirstOrDefault(trace => string.Equals(trace.Id, _selectedMemoryTraceId, StringComparison.Ordinal));
            if (selected is not null) return selected;
        }

        return records.FirstOrDefault();
    }

    private Button MemoryTraceSelectLabel(MemoryTraceRecord? selected, IReadOnlyList<MemoryTraceRecord> records)
    {
        var label = new TextBlock
        {
            Text = selected is null ? L("Select a trace...", "\u9009\u62e9\u8ffd\u8e2a...") : MemoryTraceOptionLabel(selected),
            FontSize = 13,
            Foreground = selected is null ? Brush("V2MutedForegroundBrush") : Brush("V2ForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var chevron = Icon("ChevronDown", 10, Brush("V2MutedForegroundBrush"));
        Grid.SetColumn(chevron, 1);
        var content = new Grid
        {
            ColumnSpacing = 10,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
            Children =
            {
                label,
                chevron,
            },
        };
        var button = new Button
        {
            Height = 34,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(10, 0, 10, 0),
            CornerRadius = new CornerRadius(8),
            Background = Brush("V2CardBrush"),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Content = content,
        };

        var flyout = new MenuFlyout();
        foreach (var trace in records)
        {
            var item = new MenuFlyoutItem { Text = MemoryTraceOptionLabel(trace) };
            item.Click += (_, _) =>
            {
                _selectedMemoryTraceId = trace.Id;
                RenderAll();
            };
            flyout.Items.Add(item);
        }
        button.Flyout = flyout;
        return button;
    }

    private string MemoryTraceOptionLabel(MemoryTraceRecord trace) =>
        $"{trace.Title} \u00b7 {trace.Trigger} \u00b7 {RelativeLabel(trace.CreatedAt)}";

    private FrameworkElement MemoryTraceDetail(MemoryTraceRecord? trace)
    {
        if (trace is null)
        {
            return ToolBoardGroup(
                L("No trace records", "\u6682\u65e0\u8ffd\u8e2a\u8bb0\u5f55"),
                null,
                DashedEmptyState(L("Select a trace", "\u9009\u62e9\u8ffd\u8e2a"), L("Select a trace to inspect details.", "\u9009\u62e9\u4e00\u6761\u8ffd\u8e2a\u67e5\u770b\u8be6\u60c5\u3002")));
        }

        var stack = new StackPanel { Spacing = 14 };
        stack.Children.Add(ToolBoardGroup(trace.Title, $"{trace.Trigger} \u00b7 {RelativeLabel(trace.CreatedAt)}", MemoryTraceReply(trace)));
        stack.Children.Add(MemoryTraceBlock("Meta", MemoryTraceMetaText(trace)));
        stack.Children.Add(MemoryTraceBlock(L("Injected Context", "\u6ce8\u5165\u4e0a\u4e0b\u6587"), trace.Context));
        stack.Children.Add(MemoryTraceBlock(L("Tool Events", "\u5de5\u5177\u4e8b\u4ef6"), trace.ToolEvents));
        stack.Children.Add(ToolBoardGroup(L("Reasoning Timeline", "\u63a8\u7406\u8fc7\u7a0b"), null, MemoryTraceTimeline(trace)));
        return stack;
    }

    private FrameworkElement MemoryTraceReply(MemoryTraceRecord trace) => new TextBlock
    {
        Text = string.IsNullOrWhiteSpace(trace.Reply) ? L("No output yet.", "\u6682\u65e0\u8f93\u51fa\u3002") : trace.Reply,
        FontSize = 13,
        Foreground = Brush("V2SecondaryForegroundBrush"),
        TextWrapping = TextWrapping.Wrap,
    };

    private string MemoryTraceMetaText(MemoryTraceRecord trace) =>
        trace.Meta.Count == 0
            ? ""
            : string.Join(Environment.NewLine, trace.Meta.OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase).Select(pair => $"{pair.Key}: {pair.Value}"));

    private FrameworkElement MemoryTraceBlock(string title, string text) => ToolBoardGroup(title, null, new TextBox
    {
        Text = string.IsNullOrWhiteSpace(text) ? L("No records.", "\u6682\u65e0\u8bb0\u5f55\u3002") : text,
        IsReadOnly = true,
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        FontFamily = new FontFamily("Consolas"),
        FontSize = 12,
        MinHeight = 42,
        MaxHeight = 220,
        Padding = new Thickness(10),
        Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
    });

    private FrameworkElement MemoryTraceTimeline(MemoryTraceRecord trace)
    {
        if (trace.Steps.Count == 0)
        {
            return DashedEmptyState(L("No steps yet.", "\u6682\u65e0\u6b65\u9aa4\u3002"), L("Timeline events will appear here as the trace records reasoning steps.", "\u8ffd\u8e2a\u8bb0\u5f55\u63a8\u7406\u6b65\u9aa4\u540e\u4f1a\u663e\u793a\u5728\u8fd9\u91cc\u3002"));
        }

        var stack = new StackPanel { Spacing = 0 };
        for (var index = 0; index < trace.Steps.Count; index++)
        {
            stack.Children.Add(MemoryTraceTimelineStep(index + 1, trace.Steps[index]));
        }
        return stack;
    }

    private FrameworkElement MemoryTraceTimelineStep(int index, MemoryTraceStep step)
    {
        var tint = MemoryTraceStatusBrush(step.Status);
        var grid = new Grid
        {
            Padding = new Thickness(0, 8, 0, 8),
            ColumnSpacing = 12,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
            },
        };
        grid.Children.Add(new Border
        {
            Width = 20,
            Height = 20,
            CornerRadius = new CornerRadius(999),
            Background = tint,
            Margin = new Thickness(0, 2, 0, 0),
            Child = new TextBlock
            {
                Text = index.ToString(),
                FontSize = 10,
                FontWeight = Microsoft.UI.Text.FontWeights.Bold,
                Foreground = Brush("V2BackgroundBrush"),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        });

        var body = new StackPanel { Spacing = 4 };
        body.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children =
            {
                new TextBlock
                {
                    Text = step.Title,
                    FontSize = 13,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Foreground = Brush("V2ForegroundBrush"),
                    VerticalAlignment = VerticalAlignment.Center,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                },
                SkillBadge(string.IsNullOrWhiteSpace(step.Status) ? L("Unknown", "\u672a\u77e5") : step.Status, tint),
            },
        });
        body.Children.Add(new TextBlock
        {
            Text = step.Detail,
            FontSize = 12,
            Foreground = Brush("V2SecondaryForegroundBrush"),
            TextWrapping = TextWrapping.Wrap,
        });
        Grid.SetColumn(body, 1);
        grid.Children.Add(body);
        return grid;
    }

    private Brush MemoryTraceStatusBrush(string status) => status.Trim().ToLowerInvariant() switch
    {
        "success" or "completed" => Brush("V2GreenBrush"),
        "warning" or "skipped" => Brush("V2AmberBrush"),
        "error" or "failed" => Brush("V2RedBrush"),
        _ => Brush("V2ForegroundBrush"),
    };

    private void ShowMemoryJobNotice(string job)
    {
        _toolStatus = L(
            $"{job} is not wired to the Windows native runtime yet.",
            $"{job} \u5c1a\u672a\u63a5\u5165 Windows \u539f\u751f\u8fd0\u884c\u65f6\u3002");
        RenderAll();
    }

    private Button MemoryMoreButton()
    {
        var button = ToolbarButton("Ellipsis", L("More", "\u66f4\u591a"), () => { });
        var flyout = new MenuFlyout();
        var create = new MenuFlyoutItem { Text = L("New", "\u65b0\u5efa") };
        create.Click += async (_, _) => await CreateMemoryAsync();
        flyout.Items.Add(create);
        var export = new MenuFlyoutItem { Text = T("common.export") };
        export.Click += async (_, _) => await ExportMemoryAsync();
        flyout.Items.Add(export);
        flyout.Items.Add(new MenuFlyoutSeparator());
        var rollback = new MenuFlyoutItem { Text = L("Rollback Last Dream", "\u56de\u6eda\u4e0a\u4e00\u6b21 Dream") };
        rollback.Click += (_, _) => ShowMemoryJobNotice("Rollback");
        flyout.Items.Add(rollback);
        button.Flyout = flyout;
        return button;
    }

    private FrameworkElement AlwaysOnPage()
    {
        var shell = new Grid { Background = Brush("V2BackgroundBrush") };
        shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        shell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var projectContext = State.SelectedProject is { } selectedAlwaysOnProject && !V2SidebarProjection.IsGeneralProject(selectedAlwaysOnProject)
            ? selectedAlwaysOnProject
            : null;
        var isProjectContext = projectContext is not null;
        var scopedPlans = isProjectContext
            ? State.AlwaysOnPlans.Where(plan => AlwaysOnPlanMatchesProject(plan, projectContext!)).ToList()
            : State.AlwaysOnPlans.ToList();
        var scopedCronJobs = isProjectContext
            ? State.AlwaysOnCronJobs.Where(job => AlwaysOnCronMatchesProject(job, projectContext!)).ToList()
            : State.AlwaysOnCronJobs.ToList();
        var scopedRunHistory = isProjectContext
            ? State.AlwaysOnRunHistory.Where(run => AlwaysOnRunMatchesProject(run, projectContext!)).ToList()
            : State.AlwaysOnRunHistory.ToList();
        var enabledProjects = isProjectContext
            ? (IsAlwaysOnProjectEnabled(projectContext!) ? 1 : 0)
            : State.Settings.AlwaysOnSettings?.ProjectEnabled.Count(pair => pair.Value) ?? 0;
        var totalProjects = isProjectContext
            ? 1
            : Math.Max(enabledProjects, State.Projects.Count(project => !V2SidebarProjection.IsGeneralProject(project)));
        var readyPlans = scopedPlans.Count(plan => plan.Status == AlwaysOnStatus.Ready || plan.Status == AlwaysOnStatus.Scheduled);
        var runningPlans = scopedPlans.Count(plan => plan.Status == AlwaysOnStatus.Running || plan.ExecutionStatus == AlwaysOnStatus.Running);
        var todayEvents = scopedPlans.Count(plan => plan.UpdatedAt.LocalDateTime.Date == DateTime.Today)
            + scopedCronJobs.Count(job => (job.LastFiredAt ?? job.CreatedAt)?.LocalDateTime.Date == DateTime.Today)
            + scopedRunHistory.Count(run => run.StartedAt.LocalDateTime.Date == DateTime.Today);
        if (!isProjectContext && _alwaysOnToolTab == AlwaysOnToolTab.History)
        {
            _alwaysOnToolTab = AlwaysOnToolTab.Dashboard;
        }

        var tabs = new List<(string Label, bool IsActive, Action Action)>
        {
            (L("Dashboard", "\u770b\u677f"), _alwaysOnToolTab == AlwaysOnToolTab.Dashboard, (Action)(() => { _alwaysOnToolTab = AlwaysOnToolTab.Dashboard; ClearAlwaysOnSelection(); RenderAll(); })),
            (L("Plans & Cron Jobs", "\u8ba1\u5212\u4e0e\u5468\u671f\u4efb\u52a1"), _alwaysOnToolTab == AlwaysOnToolTab.Items, (Action)(() => { _alwaysOnToolTab = AlwaysOnToolTab.Items; ClearAlwaysOnSelection(); RenderAll(); })),
        };
        if (isProjectContext)
        {
            tabs.Add((L("Run History", "\u8fd0\u884c\u5386\u53f2"), _alwaysOnToolTab == AlwaysOnToolTab.History, (Action)(() => { _alwaysOnToolTab = AlwaysOnToolTab.History; ClearAlwaysOnSelection(); RenderAll(); })));
        }
        shell.Children.Add(ToolTabbedTopbar(tabs));

        var selectedPlan = !string.IsNullOrWhiteSpace(_selectedAlwaysOnPlanId)
            ? scopedPlans.FirstOrDefault(plan => string.Equals(plan.Id, _selectedAlwaysOnPlanId, StringComparison.Ordinal))
            : null;
        if (selectedPlan is not null)
        {
            var detail = AlwaysOnPlanDetailPage(selectedPlan);
            Grid.SetRow(detail, 1);
            shell.Children.Add(detail);
            return shell;
        }
        var selectedCronJob = !string.IsNullOrWhiteSpace(_selectedAlwaysOnCronJobId)
            ? scopedCronJobs.FirstOrDefault(job => string.Equals(job.Id, _selectedAlwaysOnCronJobId, StringComparison.Ordinal))
            : null;
        if (selectedCronJob is not null)
        {
            var detail = AlwaysOnCronDetailPage(selectedCronJob);
            Grid.SetRow(detail, 1);
            shell.Children.Add(detail);
            return shell;
        }
        var selectedRun = !string.IsNullOrWhiteSpace(_selectedAlwaysOnRunId)
            ? scopedRunHistory.FirstOrDefault(run => string.Equals(run.Id, _selectedAlwaysOnRunId, StringComparison.Ordinal))
            : null;
        if (selectedRun is not null)
        {
            var detail = AlwaysOnRunDetailPage(selectedRun);
            Grid.SetRow(detail, 1);
            shell.Children.Add(detail);
            return shell;
        }
        _selectedAlwaysOnPlanId = null;
        _selectedAlwaysOnCronJobId = null;
        _selectedAlwaysOnRunId = null;

        var panel = new StackPanel
        {
            Padding = new Thickness(24, 18, 24, 18),
            Spacing = 18,
            MaxWidth = 1120,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        if (!string.IsNullOrWhiteSpace(_toolStatus)) panel.Children.Add(StatusText(_toolStatus));
        panel.Children.Add(AlwaysOnContentHeader());
        if (_alwaysOnToolTab == AlwaysOnToolTab.Dashboard)
        {
            panel.Children.Add(AlwaysOnDashboardContent(enabledProjects, totalProjects, readyPlans, runningPlans, todayEvents, isProjectContext, scopedPlans, scopedCronJobs, scopedRunHistory));
        }
        else if (_alwaysOnToolTab == AlwaysOnToolTab.Items)
        {
            panel.Children.Add(AlwaysOnItemsSection(scopedPlans, scopedCronJobs));
        }
        else
        {
            panel.Children.Add(AlwaysOnRunHistorySection(scopedRunHistory));
        }

        var scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = panel,
        };
        Grid.SetRow(scroll, 1);
        shell.Children.Add(scroll);
        return shell;
    }

    private void ClearAlwaysOnSelection()
    {
        _selectedAlwaysOnPlanId = null;
        _selectedAlwaysOnCronJobId = null;
        _selectedAlwaysOnRunId = null;
    }

    private FrameworkElement AlwaysOnContentHeader()
    {
        var header = new Grid
        {
            ColumnSpacing = 12,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
        };
        header.Children.Add(new StackPanel
        {
            Spacing = 4,
            Children =
            {
                new TextBlock
                {
                    Text = T("tabs.alwaysOn"),
                    FontSize = 20,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Foreground = Brush("V2ForegroundBrush"),
                },
                new TextBlock
                {
                    Text = AlwaysOnHeaderSubtitle(),
                    FontSize = 13,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    TextTrimming = TextTrimming.CharacterEllipsis,
                },
            },
        });
        var isProjectContext = State.SelectedProject is { } selected && !V2SidebarProjection.IsGeneralProject(selected);
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                ToolbarButton("Refresh", T("common.refresh"), (Action)(() => { RefreshNativeStores(); RenderAll(); })),
            },
        };
        if (isProjectContext)
        {
            actions.Children.Add(ToolbarButton("Search", L("Discover", "\u53d1\u73b0"), (Action)(async () => await StartAlwaysOnDiscoveryAsync()), isProminent: true));
        }
        Grid.SetColumn(actions, 1);
        header.Children.Add(actions);
        return header;
    }

    private string AlwaysOnHeaderSubtitle()
    {
        if (State.SelectedProject is { } selected && !V2SidebarProjection.IsGeneralProject(selected))
        {
            return L("Background discovery agent for this project.", "\u4e3a\u8be5\u9879\u76ee\u6301\u7eed\u8fd0\u884c\u7684\u540e\u53f0\u53d1\u73b0\u4ee3\u7406\u3002");
        }

        return L("Global background automation across enabled projects.", "\u6240\u6709\u5df2\u542f\u7528\u9879\u76ee\u7684\u540e\u53f0\u81ea\u52a8\u5316\u3002");
    }

    private FrameworkElement TasksPage()
    {
        var subtitle = L("Task plans and execution queue", "任务计划和执行队列");
        var titleInput = ToolToolbarTextBox(_taskTitleText, "Task title", 180);
        titleInput.TextChanged += (_, _) => _taskTitleText = titleInput.Text;
        var promptInput = ToolToolbarTextBox(_taskPromptText, "Prompt", 280);
        promptInput.TextChanged += (_, _) => _taskPromptText = promptInput.Text;
        promptInput.KeyDown += async (_, args) =>
        {
            if (args.Key == global::Windows.System.VirtualKey.Enter)
            {
                args.Handled = true;
                await QueueTaskAsync();
            }
        };

        var page = ToolPage(T("tabs.tasks"), subtitle, new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                titleInput,
                promptInput,
                ToolbarTextButton(L("Queue", "入队"), (Action)(async () => await QueueTaskAsync()), isProminent: true),
            },
        });
        var panel = new StackPanel { Spacing = 2 };

        if (State.TaskPlans.Count == 0)
        {
            panel.Children.Add(EmptyState(L("No tasks queued", "暂无任务"), L("Create a task plan from the toolbar.", "从顶部工具栏创建任务计划。"), "checklist"));
        }
        else
        {
            foreach (var plan in State.TaskPlans)
            {
                panel.Children.Add(ToolListRow("checklist", plan.Title, plan.Prompt, plan.Status.ToString()));
            }
        }

        ((Grid)page.Tag!).Children.Add(ToolList(panel));
        return page;
    }

    private async Task QueueTaskAsync()
    {
        if (State.SelectedProject is null)
        {
            _toolStatus = T("chat.status.selectProject");
            RenderAll();
            return;
        }

        var title = string.IsNullOrWhiteSpace(_taskTitleText) ? "Untitled task" : _taskTitleText.Trim();
        var prompt = _taskPromptText.Trim();
        var task = _taskMasterService.AddTask(State.SelectedProject.RootPath, title, prompt);
        _taskPlanStore.Save(task);
        _taskTitleText = "";
        _taskPromptText = "";
        _toolStatus = $"Queued: {task.Title}";
        RefreshNativeStores();
        await Task.CompletedTask;
        RenderAll();
    }

    private FrameworkElement InlineSegmentedControl(IReadOnlyList<(string Label, bool IsActive, Action Action)> tabs)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        foreach (var tab in tabs)
        {
            panel.Children.Add(ToolTabButton(tab.Label, tab.IsActive, tab.Action));
        }

        return new Border
        {
            Padding = new Thickness(3),
            CornerRadius = new CornerRadius(16),
            Background = Brush("V2ControlSurfaceBrush"),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            VerticalAlignment = VerticalAlignment.Center,
            Child = panel,
        };
    }

    private FrameworkElement ToolTabbedTopbar(IReadOnlyList<(string Label, bool IsActive, Action Action)> tabs, params FrameworkElement[] statusItems)
    {
        return ToolTabbedTopbar(tabs, useSegmentChrome: true, statusItems);
    }

    private FrameworkElement ToolTabbedTopbar(IReadOnlyList<(string Label, bool IsActive, Action Action)> tabs, bool useSegmentChrome, params FrameworkElement[] statusItems)
    {
        var root = new Grid
        {
            Height = 44,
            Padding = new Thickness(16, 0, 16, 0),
            Background = Brush("V2CardBrush"),
            ColumnSpacing = 12,
        };
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        root.Children.Add(useSegmentChrome
            ? InlineSegmentedControl(tabs)
            : ToolTabPanel(tabs, activeBorder: false));

        var statusPanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
        };
        foreach (var item in statusItems)
        {
            statusPanel.Children.Add(item);
        }
        Grid.SetColumn(statusPanel, 2);
        root.Children.Add(statusPanel);

        return new Border
        {
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Child = root,
        };
    }

    private FrameworkElement ToolTabPanel(IReadOnlyList<(string Label, bool IsActive, Action Action)> tabs, bool activeBorder)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        foreach (var tab in tabs)
        {
            panel.Children.Add(ToolTabButton(tab.Label, tab.IsActive, tab.Action, activeBorder));
        }

        return panel;
    }

    private Button ToolTabButton(string label, bool isActive, Action action, bool activeBorder = true)
    {
        var button = new Button
        {
            Height = 30,
            MinWidth = 0,
            Padding = new Thickness(12, 0, 12, 0),
            CornerRadius = new CornerRadius(8),
            Background = isActive ? Brush("V2ControlActiveBrush") : Transparent,
            BorderBrush = isActive && activeBorder ? Brush("V2BorderBrush") : Transparent,
            BorderThickness = new Thickness(isActive && activeBorder ? 1 : 0),
            Content = new TextBlock
            {
                Text = label,
                FontSize = 13,
                FontWeight = isActive ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Medium,
                Foreground = isActive ? Brush("V2ForegroundBrush") : Brush("V2SecondaryForegroundBrush"),
                TextTrimming = TextTrimming.CharacterEllipsis,
            },
        };
        button.Click += (_, _) => action();
        return button;
    }

    private FrameworkElement StatusPill(string text, bool active) => new Border
    {
        CornerRadius = new CornerRadius(999),
        Background = active ? new SolidColorBrush(global::Windows.UI.Color.FromArgb(22, 34, 197, 94)) : Brush("V2ControlSurfaceBrush"),
        BorderBrush = active ? Brush("V2GreenBrush") : Brush("V2BorderBrush"),
        BorderThickness = new Thickness(1),
        Padding = new Thickness(8, 3, 8, 3),
        Child = new TextBlock
        {
            Text = text,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            Foreground = active ? Brush("V2GreenBrush") : Brush("V2MutedForegroundBrush"),
        },
    };

    private FrameworkElement SkillsScopeIntro(bool isGeneralContext)
    {
        var iconKey = isGeneralContext ? "globe" : "Folder";
        var title = isGeneralContext ? SkillScopeLabel(SkillScope.User) : L("Project + Global", "\u9879\u76ee + \u5168\u5c40");
        var detail = isGeneralContext
            ? L("Skills added from General are global by design.", "\u4ece\u901a\u7528\u5bf9\u8bdd\u6dfb\u52a0\u7684\u6280\u80fd\u9ed8\u8ba4\u5c31\u662f\u5168\u5c40\u6280\u80fd\u3002")
            : L("Current project skills override global skills with the same name.", "\u5f53\u524d\u9879\u76ee\u6280\u80fd\u4f1a\u8986\u76d6\u540c\u540d\u5168\u5c40\u6280\u80fd\u3002");
        var stack = new StackPanel
        {
            Spacing = 4,
            Children =
            {
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 6,
                    Children =
                    {
                        Icon(iconKey, 12.5, Brush("V2ForegroundBrush")),
                        new TextBlock
                        {
                            Text = title,
                            FontSize = 12.5,
                            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                            Foreground = Brush("V2ForegroundBrush"),
                            VerticalAlignment = VerticalAlignment.Center,
                        },
                    },
                },
                new TextBlock
                {
                    Text = detail,
                    FontSize = 11.5,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    TextWrapping = TextWrapping.Wrap,
                    MaxLines = 3,
                },
            },
        };

        return new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = Brush("V2CardSurfaceSubtleBrush"),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(10),
            Child = stack,
        };
    }

    private FrameworkElement SearchField(TextBox textBox)
    {
        textBox.BorderThickness = new Thickness(0);
        textBox.Background = Transparent;
        textBox.Padding = new Thickness(0);

        var grid = new Grid
        {
            Height = 32,
            Padding = new Thickness(10, 0, 10, 0),
            ColumnSpacing = 8,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
            },
            Children =
            {
                Icon("Search", 13, Brush("V2MutedForegroundBrush")),
                textBox,
            },
        };
        Grid.SetColumn(textBox, 1);

        return new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = Brush("V2ControlSurfaceBrush"),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Child = grid,
        };
    }

    private SkillRecord? SelectedSkill()
    {
        if (_selectedSkillKey is not null &&
            State.Skills.FirstOrDefault(skill => string.Equals(SkillKey(skill), _selectedSkillKey, StringComparison.Ordinal)) is { } selected)
        {
            return selected;
        }

        var first = State.Skills.FirstOrDefault();
        _selectedSkillKey = first is null ? null : SkillKey(first);
        return first;
    }

    private static string SkillKey(SkillRecord skill) => $"{skill.Scope}:{skill.Slug}:{skill.SkillFile}";

    private FrameworkElement SkillScopeSection(string title, string detail, string emptyTitle, IReadOnlyList<SkillRecord> skills, SkillRecord? selected)
    {
        var rows = skills.OrderBy(skill => skill.Name, StringComparer.OrdinalIgnoreCase).ToList();
        var stack = new StackPanel { Spacing = 6, Padding = new Thickness(8, 0, 8, 0) };
        stack.Children.Add(new StackPanel
        {
            Spacing = 2,
            Padding = new Thickness(6, 0, 6, 0),
            Children =
            {
                new TextBlock
                {
                    Text = $"{title.ToUpperInvariant()} \u00b7 {rows.Count}",
                    FontSize = 10.5,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    CharacterSpacing = 36,
                },
                new TextBlock
                {
                    Text = detail,
                    FontSize = 10.5,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    TextWrapping = TextWrapping.Wrap,
                    MaxLines = 2,
                },
            },
        });

        if (rows.Count == 0)
        {
            stack.Children.Add(new TextBlock
            {
                Text = emptyTitle,
                FontSize = 12,
                Foreground = Brush("V2MutedForegroundBrush"),
                Padding = new Thickness(6, 8, 6, 8),
            });
            return stack;
        }

        foreach (var skill in rows)
        {
            stack.Children.Add(SkillListRow(skill, selected is not null && SkillKey(skill) == SkillKey(selected)));
        }

        return stack;
    }

    private FrameworkElement SkillListRow(SkillRecord skill, bool isSelected)
    {
        var content = new StackPanel { Spacing = 4 };
        var titleRow = new Grid { ColumnSpacing = 6 };
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        titleRow.Children.Add(new TextBlock
        {
            Text = skill.Name,
            FontSize = 13,
            FontWeight = isSelected ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Medium,
            Foreground = Brush("V2ForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        if (!string.IsNullOrWhiteSpace(skill.Version))
        {
            var version = new Border
            {
                CornerRadius = new CornerRadius(999),
                Background = Brush("V2CardSurfaceSubtleBrush"),
                Padding = new Thickness(5, 2, 5, 2),
                Child = new TextBlock
                {
                    Text = $"v{skill.Version}",
                    FontSize = 10,
                    FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                    Foreground = Brush("V2MutedForegroundBrush"),
                },
            };
            Grid.SetColumn(version, 1);
            titleRow.Children.Add(version);
        }
        content.Children.Add(titleRow);
        if (!string.IsNullOrWhiteSpace(skill.Description))
        {
            content.Children.Add(new TextBlock
            {
                Text = skill.Description,
                FontSize = 11,
                Foreground = Brush("V2MutedForegroundBrush"),
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 1,
            });
        }
        content.Children.Add(new TextBlock
        {
            Text = skill.Slug,
            FontSize = 10.5,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            Foreground = Brush("V2MutedForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });

        var button = new Button
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = isSelected ? Brush("V2SelectedBrush") : Transparent,
            BorderBrush = Transparent,
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 8, 10, 8),
            Content = content,
        };
        button.Click += (_, _) =>
        {
            _selectedSkillKey = SkillKey(skill);
            RenderAll();
        };
        return button;
    }

    private FrameworkElement SkillListEmptyCard(string title, string detail) => new Border
    {
        CornerRadius = new CornerRadius(8),
        Background = Brush("V2CardSurfaceSubtleBrush"),
        BorderBrush = Brush("V2BorderBrush"),
        BorderThickness = new Thickness(1),
        Margin = new Thickness(10, 0, 10, 0),
        Padding = new Thickness(14),
        Child = new StackPanel
        {
            Spacing = 8,
            Children =
            {
                IconText("Sparkles", title, 13, Brush("V2ForegroundBrush")),
                new TextBlock
                {
                    Text = detail,
                    FontSize = 12,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    TextWrapping = TextWrapping.Wrap,
                    MaxLines = 3,
                },
            },
        },
    };

    private FrameworkElement SkillDetail(SkillRecord skill)
    {
        EnsureSkillEditorState(skill);
        var editorChanged = !string.Equals(_skillEditorContent, _skillEditorOriginalContent, StringComparison.Ordinal);
        var scopeBrush = SkillScopeBrush(skill.Scope);
        var root = new Grid
        {
            RowSpacing = 0,
            Background = Brush("V2BackgroundBrush"),
            RowDefinitions =
            {
                new RowDefinition { Height = GridLength.Auto },
                new RowDefinition { Height = new GridLength(1, GridUnitType.Star) },
                new RowDefinition { Height = GridLength.Auto },
            },
        };

        var header = new StackPanel
        {
            Spacing = 12,
            Padding = new Thickness(18, 14, 18, 14),
        };
        var headerGrid = new Grid
        {
            ColumnSpacing = 12,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
        };
        headerGrid.Children.Add(new Border
        {
            Width = 42,
            Height = 42,
            CornerRadius = new CornerRadius(10),
            Background = Brush("V2CardSurfaceSubtleBrush"),
            BorderBrush = Transparent,
            BorderThickness = new Thickness(0),
            Child = Icon("Sparkles", 17, scopeBrush),
        });
        var titleBlock = new StackPanel { Spacing = 5, MinWidth = 0 };
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        titleRow.Children.Add(new TextBlock
        {
            Text = skill.Name,
            FontSize = 16,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        });
        titleRow.Children.Add(SkillBadge(SkillScopeLabel(skill.Scope), scopeBrush));
        if (!string.IsNullOrWhiteSpace(skill.Version))
        {
            titleRow.Children.Add(SkillBadge($"v{skill.Version}", Brush("V2MutedForegroundBrush")));
        }
        if (editorChanged)
        {
            titleRow.Children.Add(SkillBadge(L("Unsaved", "\u672a\u4fdd\u5b58"), Brush("V2AmberBrush")));
        }

        titleBlock.Children.Add(titleRow);
        titleBlock.Children.Add(new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(skill.Description) ? skill.Slug : skill.Description,
            FontSize = 12,
            Foreground = Brush("V2SecondaryForegroundBrush"),
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
        });
        var metaRow = new StackPanel { Spacing = 4 };
        metaRow.Children.Add(SkillMetaLabel(L("Saved at", "\u4fdd\u5b58\u4f4d\u7f6e"), skill.SkillDir));
        metaRow.Children.Add(SkillMetaLabel(L("Effective in", "\u751f\u6548\u8303\u56f4"), SkillEffectiveRange(skill)));
        titleBlock.Children.Add(metaRow);
        Grid.SetColumn(titleBlock, 1);
        headerGrid.Children.Add(titleBlock);

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Top,
            Children =
            {
                SkillHeaderButton("Folder", L("Reveal", "\u663e\u793a"), async () => await RevealSkillAsync(skill)),
                SkillHeaderButton("Copy", L("Open", "\u6253\u5f00"), async () => await ShowTextDialogAsync(skill.Name, _skillEditorContent)),
                SkillHeaderButton("Trash", T("common.delete"), async () => await DeleteSkillAsync(skill)),
            },
        };
        Grid.SetColumn(actions, 2);
        headerGrid.Children.Add(actions);
        header.Children.Add(headerGrid);

        if (skill.Scope == SkillScope.User && State.SelectedProject is not null)
        {
            header.Children.Add(SkillInlineNotice("globe", L("This is a global skill. It remains available when you switch to other projects.", "\u8fd9\u662f\u5168\u5c40\u6280\u80fd\uff0c\u5207\u6362\u5230\u5176\u4ed6\u9879\u76ee\u540e\u4ecd\u7136\u53ef\u7528\u3002")));
        }
        else if (skill.Scope == SkillScope.Project)
        {
            header.Children.Add(SkillInlineNotice("Folder", L("If a global skill has the same name, this project skill is the one the agent will load here.", "\u5982\u679c\u5b58\u5728\u540c\u540d\u5168\u5c40\u6280\u80fd\uff0c\u5f53\u524d\u9879\u76ee\u4f1a\u4f18\u5148\u52a0\u8f7d\u8fd9\u4e2a\u9879\u76ee\u6280\u80fd\u3002")));
        }

        root.Children.Add(new Border
        {
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Child = header,
        });

        var editor = new TextBox
        {
            AcceptsReturn = true,
            Text = _skillEditorContent,
            TextWrapping = TextWrapping.NoWrap,
            FontFamily = new FontFamily("Consolas"),
            FontSize = 13,
            Padding = new Thickness(12),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
        };
        editor.TextChanged += (_, _) => _skillEditorContent = editor.Text;
        Grid.SetRow(editor, 1);
        root.Children.Add(editor);

        var footer = new Grid
        {
            Height = 44,
            Padding = new Thickness(18, 0, 18, 0),
            ColumnSpacing = 8,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = GridLength.Auto },
            },
        };
        footer.Children.Add(new TextBlock
        {
            Text = editorChanged ? L("Edited SKILL.md", "SKILL.md \u5df2\u7f16\u8f91") : L("No unsaved changes", "\u6ca1\u6709\u672a\u4fdd\u5b58\u66f4\u6539"),
            FontSize = 11,
            Foreground = editorChanged ? Brush("V2AmberBrush") : Brush("V2MutedForegroundBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        });
        var revert = SkillFooterButton(L("Revert", "\u8fd8\u539f"), async () =>
        {
            _skillEditorContent = _skillEditorOriginalContent;
            await Task.CompletedTask;
            RenderAll();
        });
        revert.IsEnabled = editorChanged;
        Grid.SetColumn(revert, 1);
        footer.Children.Add(revert);
        var save = SkillFooterButton(T("common.save"), async () => await SaveSkillAsync(skill));
        save.Content = IconText("Save", T("common.save"), 14, editorChanged ? null : Brush("V2MutedForegroundBrush"));
        save.IsEnabled = editorChanged;
        Grid.SetColumn(save, 2);
        footer.Children.Add(save);
        var footerHost = new Border
        {
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(0, 1, 0, 0),
            Child = footer,
        };
        Grid.SetRow(footerHost, 2);
        root.Children.Add(footerHost);
        return root;
    }

    private void EnsureSkillEditorState(SkillRecord skill)
    {
        var key = SkillKey(skill);
        if (string.Equals(_skillEditorKey, key, StringComparison.Ordinal)) return;
        _skillEditorKey = key;
        try
        {
            _skillEditorContent = _skillService.Read(skill);
            _skillEditorOriginalContent = _skillEditorContent;
        }
        catch (Exception ex)
        {
            _skillEditorContent = ex.Message;
            _skillEditorOriginalContent = _skillEditorContent;
        }
    }

    private async Task SaveSkillAsync(SkillRecord skill)
    {
        try
        {
            var updated = _skillService.Write(skill, _skillEditorContent);
            _skillEditorOriginalContent = _skillEditorContent;
            _skillEditorKey = SkillKey(updated);
            _selectedSkillKey = SkillKey(updated);
            _toolStatus = L("Skill saved.", "\u6280\u80fd\u5df2\u4fdd\u5b58\u3002");
            RefreshNativeStores();
        }
        catch (Exception ex)
        {
            _toolStatus = ex.Message;
        }

        await Task.CompletedTask;
        RenderAll();
    }

    private async Task RevealSkillAsync(SkillRecord skill)
    {
        try
        {
            var explorerArg = File.Exists(skill.SkillFile) ? $"/select,\"{skill.SkillFile}\"" : $"\"{skill.SkillDir}\"";
            Process.Start(new ProcessStartInfo("explorer.exe", explorerArg) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            _toolStatus = ex.Message;
            RenderAll();
        }

        await Task.CompletedTask;
    }

    private Button SkillHeaderButton(string iconKey, string label, Func<Task> action)
    {
        var button = new Button
        {
            Content = IconText(iconKey, label, 14),
            Height = 32,
            MinWidth = 0,
            Padding = new Thickness(10, 0, 10, 0),
            Style = (Style)Application.Current.Resources["V2ToolbarButtonStyle"],
        };
        button.Click += async (_, _) => await action();
        return button;
    }

    private Button SkillFooterButton(string label, Func<Task> action)
    {
        var button = new Button
        {
            Content = label,
            Height = 30,
            MinWidth = 0,
            Padding = new Thickness(10, 0, 10, 0),
            Style = (Style)Application.Current.Resources["V2ToolbarButtonStyle"],
        };
        button.Click += async (_, _) => await action();
        return button;
    }

    private FrameworkElement SkillBadge(string title, Brush tint) => new Border
    {
        CornerRadius = new CornerRadius(999),
        Background = Brush("V2ControlSurfaceBrush"),
        BorderBrush = tint,
        BorderThickness = new Thickness(1),
        Padding = new Thickness(7, 3, 7, 3),
        Child = new TextBlock
        {
            Text = title,
            FontSize = 10,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = tint,
        },
    };

    private FrameworkElement SkillMetaLabel(string title, string value)
    {
        var grid = new Grid
        {
            ColumnSpacing = 5,
            MaxWidth = 360,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
            },
        };
        grid.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 11,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            Foreground = Brush("V2MutedForegroundBrush"),
        });
        var valueBlock = new TextBlock
        {
            Text = value,
            FontSize = 11,
            Foreground = Brush("V2SecondaryForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MinWidth = 0,
        };
        Grid.SetColumn(valueBlock, 1);
        grid.Children.Add(valueBlock);
        return grid;
    }

    private FrameworkElement SkillInlineNotice(string iconKey, string text)
    {
        var body = new Grid
        {
            ColumnSpacing = 8,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
            },
        };
        body.Children.Add(Icon(iconKey, 13, Brush("V2MutedForegroundBrush")));
        var copy = new TextBlock
        {
            Text = text,
            FontSize = 12,
            Foreground = Brush("V2SecondaryForegroundBrush"),
            TextWrapping = TextWrapping.Wrap,
        };
        Grid.SetColumn(copy, 1);
        body.Children.Add(copy);
        return new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = Brush("V2CardSurfaceSubtleBrush"),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(10, 8, 10, 8),
            Child = body,
        };
    }

    private string SkillScopeLabel(SkillScope scope) => scope switch
    {
        SkillScope.Project => L("Project", "\u9879\u76ee"),
        SkillScope.Plugin => "Plugin",
        _ => L("Global", "\u5168\u5c40"),
    };

    private Brush SkillScopeBrush(SkillScope scope) => scope switch
    {
        SkillScope.Project => Brush("V2BlueBrush"),
        SkillScope.Plugin => Brush("V2AmberBrush"),
        _ => Brush("V2MutedForegroundBrush"),
    };

    private string SkillEffectiveRange(SkillRecord skill) => skill.Scope switch
    {
        SkillScope.Project => State.SelectedProject?.DisplayName ?? L("Current project", "\u5f53\u524d\u9879\u76ee"),
        SkillScope.Plugin => L("Bundled plugin", "\u5185\u7f6e\u63d2\u4ef6"),
        _ => L("General chat and every project", "\u901a\u7528\u5bf9\u8bdd\u548c\u6240\u6709\u9879\u76ee"),
    };

    private void SelectMemoryRecord(MemoryRecord record)
    {
        _selectedMemoryRecordId = record.Id;
        RenderAll();
    }

    private FrameworkElement MemoryRecordSection(string title, string subtitle, IEnumerable<MemoryRecord> records, Action<MemoryRecord> onSelect)
    {
        var rows = records.OrderByDescending(record => record.UpdatedAt).ToList();
        if (rows.Count == 0)
        {
            return ToolBoardGroup(title, subtitle, DashedEmptyState(L("No records yet", "\u6682\u65e0\u8bb0\u5f55"), L("Records will appear here after they are created or imported.", "\u521b\u5efa\u6216\u5bfc\u5165\u540e\u8bb0\u5f55\u4f1a\u663e\u793a\u5728\u8fd9\u91cc\u3002")));
        }

        var cardStack = new StackPanel { Spacing = 10 };
        foreach (var record in rows)
        {
            cardStack.Children.Add(MemoryRecordRow(record, onSelect));
        }

        return ToolBoardGroup(title, subtitle, cardStack);
    }

    private FrameworkElement MemoryRecordRow(MemoryRecord record, Action<MemoryRecord> onSelect)
    {
        var grid = new Grid
        {
            MinHeight = 96,
            Padding = new Thickness(14, 12, 12, 12),
            RowSpacing = 6,
        };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var header = new Grid
        {
            ColumnSpacing = 8,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
        };
        header.Children.Add(new TextBlock
        {
            Text = record.Name,
            FontSize = 14,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 2,
        });
        var badge = SkillBadge(record.Deprecated ? L("Deprecated", "\u5df2\u5f03\u7528") : MemoryRecordTypeLabel(record.Type), MemoryRecordBrush(record));
        Grid.SetColumn(badge, 1);
        header.Children.Add(badge);
        grid.Children.Add(header);

        var meta = new TextBlock
        {
            Text = MemoryRecordMetaLine(record),
            FontSize = 11,
            Foreground = Brush("V2MutedForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        Grid.SetRow(meta, 1);
        grid.Children.Add(meta);

        var summary = new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(record.Summary) ? record.Content : record.Summary,
            FontSize = 12,
            Foreground = Brush("V2SecondaryForegroundBrush"),
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 3,
        };
        Grid.SetRow(summary, 2);
        grid.Children.Add(summary);

        var button = new Button
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(0),
            Background = Brush("V2ContentSurfaceBrush"),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Content = grid,
        };
        button.Click += (_, _) => onSelect(record);
        return new Grid
        {
            Children =
            {
                button,
                new Border
                {
                    Width = 3,
                    Margin = new Thickness(1, 10, 0, 10),
                    HorizontalAlignment = HorizontalAlignment.Left,
                    CornerRadius = new CornerRadius(999),
                    Background = MemoryRecordBrush(record),
                },
            },
        };
    }

    private FrameworkElement MemoryDetailPage(MemoryRecord record)
    {
        var body = new StackPanel
        {
            Spacing = 18,
            Padding = new Thickness(28),
            MaxWidth = 1120,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        body.Children.Add(SkillHeaderButton("ChevronLeft", L("Back", "\u8fd4\u56de"), async () =>
        {
            _selectedMemoryRecordId = null;
            await Task.CompletedTask;
            RenderAll();
        }));

        var header = new Grid
        {
            ColumnSpacing = 16,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
        };
        var title = new StackPanel { Spacing = 7 };
        title.Children.Add(new TextBlock
        {
            Text = MemoryRecordTypeLabel(record.Type),
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            Foreground = Brush("V2MutedForegroundBrush"),
        });
        title.Children.Add(new TextBlock
        {
            Text = record.Name,
            FontSize = 24,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
            TextWrapping = TextWrapping.Wrap,
        });
        title.Children.Add(new TextBlock
        {
            Text = record.Summary,
            FontSize = 14,
            Foreground = Brush("V2SecondaryForegroundBrush"),
            TextWrapping = TextWrapping.Wrap,
        });
        title.Children.Add(new TextBlock
        {
            Text = MemoryRecordMetaLine(record),
            FontSize = 11,
            Foreground = Brush("V2MutedForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        header.Children.Add(title);
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Top,
            Children =
            {
                SkillHeaderButton("Edit", L("Edit", "\u7f16\u8f91"), async () => await EditMemoryAsync(record)),
                SkillHeaderButton(record.Deprecated ? "Refresh" : "Stop", record.Deprecated ? L("Restore", "\u6062\u590d") : L("Deprecate", "\u5f03\u7528"), async () => await ToggleMemoryDeprecatedAsync(record)),
                SkillHeaderButton("Trash", T("common.delete"), async () => await DeleteMemoryAsync(record)),
            },
        };
        Grid.SetColumn(actions, 1);
        header.Children.Add(actions);
        body.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2ContentSurfaceBrush"),
            Padding = new Thickness(18),
            Child = header,
        });

        body.Children.Add(new Border
        {
            MinHeight = 360,
            CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2CardSurfaceSubtleBrush"),
            Padding = new Thickness(16),
            Child = new TextBlock
            {
                Text = string.IsNullOrWhiteSpace(record.Content) ? record.Summary : record.Content,
                TextWrapping = TextWrapping.Wrap,
                FontFamily = new FontFamily("Consolas"),
                FontSize = 12,
                Foreground = Brush("V2SecondaryForegroundBrush"),
                IsTextSelectionEnabled = true,
            },
        });
        return new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = body,
        };
    }

    private string MemoryRecordTypeLabel(MemoryRecordType type) => type switch
    {
        MemoryRecordType.Project => L("Project", "\u9879\u76ee"),
        MemoryRecordType.Feedback => L("Feedback", "\u53cd\u9988"),
        MemoryRecordType.User => L("User", "\u7528\u6237"),
        MemoryRecordType.GeneralProjectMeta => L("Chat Project", "\u901a\u7528\u4e3b\u9898"),
        _ => type.ToString(),
    };

    private string MemoryRecordMetaLine(MemoryRecord record) =>
        string.Join(" / ", new[]
        {
            RelativeLabel(record.UpdatedAt),
            MemoryRecordTypeLabel(record.Type),
            record.RelativePath,
        }.Where(part => !string.IsNullOrWhiteSpace(part)));

    private Brush MemoryRecordBrush(MemoryRecord record)
    {
        if (record.Deprecated) return Brush("V2MutedForegroundBrush");
        return record.Type switch
        {
            MemoryRecordType.Project => Brush("V2BlueBrush"),
            MemoryRecordType.Feedback => Brush("V2GreenBrush"),
            MemoryRecordType.User => Brush("V2AmberBrush"),
            _ => Brush("V2MutedForegroundBrush"),
        };
    }

    private readonly record struct AlwaysOnTimelineItem(
        string Title,
        string Kind,
        AlwaysOnStatus Status,
        DateTimeOffset CreatedAt,
        string Detail);

    private FrameworkElement AlwaysOnDashboardContent(
        int enabledProjects,
        int totalProjects,
        int readyPlans,
        int runningPlans,
        int todayEvents,
        bool isProjectContext,
        IReadOnlyList<AlwaysOnPlan> plans,
        IReadOnlyList<AlwaysOnCronJob> cronJobs,
        IReadOnlyList<AlwaysOnRunHistory> runs)
    {
        var stack = new StackPanel { Spacing = 18 };
        stack.Children.Add(MetricGrid(
            MetricRow("Folder", L("Enabled Projects", "\u542f\u7528\u9879\u76ee"), $"{enabledProjects}/{totalProjects}", L("participating", "\u5df2\u53c2\u4e0e")),
            MetricRow("ListChecks", L("Ready Plans", "\u5c31\u7eea\u8ba1\u5212"), readyPlans.ToString(), L("manual runnable", "\u53ef\u624b\u52a8\u8fd0\u884c")),
            MetricRow("Radio", L("Running", "\u8fd0\u884c\u4e2d"), runningPlans.ToString(), L("background sessions", "\u540e\u53f0\u4f1a\u8bdd")),
            MetricRow("Calendar", L("Today", "\u4eca\u5929"), todayEvents.ToString(), L("activity events", "\u6d3b\u52a8\u4e8b\u4ef6"))));

        if (!isProjectContext && AlwaysOnProjectRows().Count > 1)
        {
            stack.Children.Add(AlwaysOnProjectsSection());
        }

        var split = new Grid
        {
            ColumnSpacing = 14,
        };
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(340) });
        var timeline = ToolBoardGroup(L("Timeline", "\u65f6\u95f4\u7ebf"), null, AlwaysOnTimelineRows(plans, cronJobs, runs));
        split.Children.Add(timeline);
        var runRows = ToolBoardGroup(L("Runs", "\u8fd0\u884c"), null, AlwaysOnRecentRunRows(runs));
        Grid.SetColumn(runRows, 1);
        split.Children.Add(runRows);
        stack.Children.Add(split);

        return stack;
    }

    private List<WorkspaceProject> AlwaysOnProjectRows() =>
        State.Projects
            .Where(project => !V2SidebarProjection.IsGeneralProject(project))
            .OrderByDescending(project => project.LatestActivity)
            .ThenBy(project => project.DisplayName, StringComparer.OrdinalIgnoreCase)
            .ToList();

    private FrameworkElement AlwaysOnProjectsSection()
    {
        var rows = new StackPanel { Spacing = 8 };
        foreach (var project in AlwaysOnProjectRows())
        {
            rows.Children.Add(AlwaysOnProjectDashboardRow(project));
        }

        return ToolBoardGroup(L("Projects", "\u9879\u76ee"), null, rows);
    }

    private FrameworkElement AlwaysOnProjectDashboardRow(WorkspaceProject project)
    {
        var enabled = IsAlwaysOnProjectEnabled(project);
        var readyPlans = State.AlwaysOnPlans.Count(plan => AlwaysOnPlanMatchesProject(plan, project)
            && plan.Status is AlwaysOnStatus.Ready or AlwaysOnStatus.Scheduled);
        var cronCount = State.AlwaysOnCronJobs.Count(job => AlwaysOnCronMatchesProject(job, project));
        var lastGate = enabled ? L("enabled", "\u5df2\u542f\u7528") : L("off", "\u5173\u95ed");
        var grid = new Grid
        {
            MinHeight = 58,
            Padding = new Thickness(12, 10, 12, 10),
            ColumnSpacing = 12,
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new Border
        {
            Width = 7,
            Height = 7,
            CornerRadius = new CornerRadius(999),
            Background = enabled ? Brush("V2GreenBrush") : Brush("V2MutedForegroundBrush"),
            Opacity = enabled ? 1 : 0.45,
            VerticalAlignment = VerticalAlignment.Center,
        });

        var text = new StackPanel { Spacing = 3 };
        text.Children.Add(new TextBlock
        {
            Text = project.DisplayName,
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });
        text.Children.Add(new TextBlock
        {
            Text = project.RootPath,
            FontSize = 11,
            FontFamily = new FontFamily("Consolas"),
            Foreground = Brush("V2MutedForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        var metrics = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 12,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                AlwaysOnCompactMetric(readyPlans.ToString(), L("plans", "\u8ba1\u5212")),
                AlwaysOnCompactMetric(cronCount.ToString(), "cron"),
                AlwaysOnCompactMetric(lastGate, L("gate", "\u95e8\u63a7")),
                SmallIconActionButton("Sparkles", L("Discover", "\u53d1\u73b0"), async () => await StartAlwaysOnDiscoveryAsync(project), isEnabled: enabled),
            },
        };
        Grid.SetColumn(metrics, 2);
        grid.Children.Add(metrics);

        return new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2CardSurfaceSubtleBrush"),
            Child = grid,
        };
    }

    private FrameworkElement AlwaysOnCompactMetric(string value, string label) => new StackPanel
    {
        MinWidth = 42,
        Spacing = 1,
        Children =
        {
            new TextBlock
            {
                Text = value,
                FontSize = 12,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Foreground = Brush("V2ForegroundBrush"),
                TextAlignment = TextAlignment.Right,
            },
            new TextBlock
            {
                Text = label,
                FontSize = 10,
                Foreground = Brush("V2MutedForegroundBrush"),
                TextAlignment = TextAlignment.Right,
            },
        },
    };

    private FrameworkElement AlwaysOnTimelineRows(
        IReadOnlyList<AlwaysOnPlan> plans,
        IReadOnlyList<AlwaysOnCronJob> cronJobs,
        IReadOnlyList<AlwaysOnRunHistory> runs)
    {
        var rows = AlwaysOnTimelineItems(plans, cronJobs, runs).Take(18).ToList();
        var stack = new StackPanel { Spacing = 0 };
        if (rows.Count == 0)
        {
            stack.Children.Add(new TextBlock
            {
                Text = L("No Always-On activity yet.", "\u6682\u65e0 Always-On \u6d3b\u52a8\u3002"),
                FontSize = 13,
                Foreground = Brush("V2MutedForegroundBrush"),
                Padding = new Thickness(0, 8, 0, 8),
            });
            return stack;
        }

        foreach (var item in rows)
        {
            stack.Children.Add(AlwaysOnTimelineRow(item));
        }

        return stack;
    }

    private FrameworkElement AlwaysOnTimelineRow(AlwaysOnTimelineItem item)
    {
        var grid = new Grid
        {
            Padding = new Thickness(0, 9, 0, 9),
            ColumnSpacing = 10,
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new Border
        {
            Width = 7,
            Height = 7,
            CornerRadius = new CornerRadius(999),
            Background = AlwaysOnStatusBrush(item.Status),
            Margin = new Thickness(0, 6, 0, 0),
            VerticalAlignment = VerticalAlignment.Top,
        });

        var body = new StackPanel { Spacing = 4 };
        var title = new Grid { ColumnSpacing = 8 };
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        title.Children.Add(new TextBlock
        {
            Text = item.Title,
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            Foreground = Brush("V2ForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });
        var kind = new TextBlock
        {
            Text = item.Kind,
            FontSize = 10,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = AlwaysOnStatusBrush(item.Status),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(kind, 1);
        title.Children.Add(kind);
        var time = new TextBlock
        {
            Text = RelativeLabel(item.CreatedAt),
            FontSize = 11,
            Foreground = Brush("V2MutedForegroundBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(time, 2);
        title.Children.Add(time);
        body.Children.Add(title);
        body.Children.Add(new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(item.Detail) ? item.Kind : item.Detail,
            FontSize = 12,
            Foreground = Brush("V2MutedForegroundBrush"),
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
        });
        Grid.SetColumn(body, 1);
        grid.Children.Add(body);

        return new Border
        {
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Child = grid,
        };
    }

    private List<AlwaysOnTimelineItem> AlwaysOnTimelineItems(
        IReadOnlyList<AlwaysOnPlan> plans,
        IReadOnlyList<AlwaysOnCronJob> cronJobs,
        IReadOnlyList<AlwaysOnRunHistory> runs)
    {
        var items = new List<AlwaysOnTimelineItem>();
        foreach (var plan in plans)
        {
            items.Add(new AlwaysOnTimelineItem(
                plan.Title,
                L("plan", "\u8ba1\u5212"),
                plan.ExecutionStatus ?? plan.Status,
                plan.UpdatedAt,
                string.IsNullOrWhiteSpace(plan.Summary) ? plan.Content : plan.Summary));
        }

        foreach (var job in cronJobs)
        {
            items.Add(new AlwaysOnTimelineItem(
                AlwaysOnCronTitle(job),
                "cron",
                job.Status,
                job.LastFiredAt ?? job.CreatedAt ?? DateTimeOffset.MinValue,
                string.IsNullOrWhiteSpace(job.Prompt) ? job.Cron : job.Prompt));
        }

        foreach (var run in runs)
        {
            items.Add(new AlwaysOnTimelineItem(
                run.Title,
                run.Kind,
                run.Status,
                run.StartedAt,
                AlwaysOnRunMetaLine(run)));
        }

        return items.OrderByDescending(item => item.CreatedAt).ToList();
    }

    private FrameworkElement AlwaysOnRecentRunRows(IReadOnlyList<AlwaysOnRunHistory> runHistory)
    {
        var rows = runHistory.OrderByDescending(run => run.StartedAt).Take(8).ToList();
        var stack = new StackPanel { Spacing = 8 };
        if (rows.Count == 0)
        {
            stack.Children.Add(new TextBlock
            {
                Text = L("No Always-On runs yet.", "\u6682\u65e0 Always-On \u8fd0\u884c\u8bb0\u5f55\u3002"),
                FontSize = 13,
                Foreground = Brush("V2MutedForegroundBrush"),
                Padding = new Thickness(0, 8, 0, 8),
            });
            return stack;
        }

        foreach (var run in rows)
        {
            stack.Children.Add(AlwaysOnRecentRunRow(run));
        }

        return stack;
    }

    private FrameworkElement AlwaysOnRecentRunRow(AlwaysOnRunHistory run)
    {
        var grid = new Grid
        {
            Padding = new Thickness(9),
            ColumnSpacing = 10,
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(Icon(string.Equals(run.Kind, "cron", StringComparison.OrdinalIgnoreCase) ? "Calendar" : "ListChecks", 13, AlwaysOnStatusBrush(run.Status)));
        var text = new StackPanel { Spacing = 3 };
        text.Children.Add(new TextBlock
        {
            Text = run.Title,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            Foreground = Brush("V2ForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });
        text.Children.Add(new TextBlock
        {
            Text = $"{AlwaysOnStatusLabel(run.Status)} / {RelativeLabel(run.StartedAt)}",
            FontSize = 11,
            Foreground = Brush("V2MutedForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        var button = new Button
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(0),
            Background = Transparent,
            BorderBrush = Transparent,
            Content = new Border
            {
                CornerRadius = new CornerRadius(8),
                Background = Brush("V2CardSurfaceSubtleBrush"),
                Child = grid,
            },
        };
        button.Click += (_, _) =>
        {
            _selectedAlwaysOnRunId = run.Id;
            RenderAll();
        };
        return button;
    }

    private bool IsAlwaysOnProjectEnabled(WorkspaceProject project) =>
        State.Settings.AlwaysOnSettings?.ProjectEnabled.TryGetValue(project.RootPath, out var enabled) == true && enabled;

    private bool AlwaysOnPlanMatchesProject(AlwaysOnPlan plan, WorkspaceProject project) =>
        PathLooksUnderRoot(plan.PlanFilePath, project.RootPath)
        || TextMentionsProject(plan.Content, project)
        || TextMentionsProject(plan.Summary, project);

    private bool AlwaysOnCronMatchesProject(AlwaysOnCronJob job, WorkspaceProject project) =>
        TextMentionsProject(job.Prompt, project)
        || TextMentionsProject(job.TranscriptKey, project)
        || TextMentionsProject(job.LatestSessionId, project);

    private bool AlwaysOnRunMatchesProject(AlwaysOnRunHistory run, WorkspaceProject project) =>
        TextMentionsProject(run.SourceId, project)
        || TextMentionsProject(run.RelativeTranscriptPath, project)
        || TextMentionsProject(run.TranscriptKey, project)
        || (run.Metadata?.Values.Any(value => TextMentionsProject(value, project)) ?? false);

    private static bool TextMentionsProject(string? text, WorkspaceProject project) =>
        !string.IsNullOrWhiteSpace(text)
        && (!string.IsNullOrWhiteSpace(project.RootPath) && text.Contains(project.RootPath, StringComparison.OrdinalIgnoreCase)
            || !string.IsNullOrWhiteSpace(project.DisplayName) && text.Contains(project.DisplayName, StringComparison.OrdinalIgnoreCase));

    private static bool PathLooksUnderRoot(string? path, string root)
    {
        if (string.IsNullOrWhiteSpace(path) || string.IsNullOrWhiteSpace(root)) return false;
        try
        {
            var normalizedPath = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var normalizedRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            return normalizedPath.Equals(normalizedRoot, StringComparison.OrdinalIgnoreCase)
                || normalizedPath.StartsWith(normalizedRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                || normalizedPath.StartsWith(normalizedRoot + Path.AltDirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return path.Contains(root, StringComparison.OrdinalIgnoreCase);
        }
    }

    private FrameworkElement AlwaysOnItemsSection(IEnumerable<AlwaysOnPlan> plans, IEnumerable<AlwaysOnCronJob> cronJobs)
    {
        var planRows = plans.OrderByDescending(plan => plan.UpdatedAt).ToList();
        var cronRows = cronJobs
            .OrderByDescending(job => job.LastFiredAt ?? job.CreatedAt ?? DateTimeOffset.MinValue)
            .ToList();
        if (planRows.Count == 0 && cronRows.Count == 0)
        {
            return ToolBoardGroup(L("Plans / Cron Jobs", "\u8ba1\u5212\u4e0e\u5468\u671f\u4efb\u52a1"), L("Manual and scheduled background work.", "\u624b\u52a8\u548c\u5b9a\u65f6\u7684\u540e\u53f0\u4efb\u52a1\u3002"),
                DashedEmptyState(T("alwaysOn.empty.title"), T("alwaysOn.emptyDetail")));
        }

        var cardStack = new StackPanel { Spacing = 10 };
        foreach (var plan in planRows)
        {
            cardStack.Children.Add(AlwaysOnPlanRow(plan));
        }
        foreach (var job in cronRows)
        {
            cardStack.Children.Add(AlwaysOnCronRow(job));
        }

        return ToolBoardGroup(L("Plans / Cron Jobs", "\u8ba1\u5212\u4e0e\u5468\u671f\u4efb\u52a1"), L("Manual and scheduled background work.", "\u624b\u52a8\u548c\u5b9a\u65f6\u7684\u540e\u53f0\u4efb\u52a1\u3002"), cardStack);
    }

    private FrameworkElement AlwaysOnPlanRow(AlwaysOnPlan plan)
    {
        var grid = new Grid
        {
            MinHeight = 82,
            Padding = new Thickness(12),
            ColumnSpacing = 12,
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new Border
        {
            Width = 34,
            Height = 34,
            CornerRadius = new CornerRadius(8),
            Background = Brush("V2CardSurfaceSubtleBrush"),
            BorderBrush = AlwaysOnStatusBrush(plan.ExecutionStatus ?? plan.Status),
            BorderThickness = new Thickness(1),
            Child = Icon("Radio", 15, AlwaysOnStatusBrush(plan.ExecutionStatus ?? plan.Status)),
        });
        var text = new StackPanel { Spacing = 5 };
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        titleRow.Children.Add(new TextBlock
        {
            Text = plan.Title,
            FontSize = 14,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });
        titleRow.Children.Add(SkillBadge(AlwaysOnStatusLabel(plan.ExecutionStatus ?? plan.Status), AlwaysOnStatusBrush(plan.ExecutionStatus ?? plan.Status)));
        text.Children.Add(titleRow);
        text.Children.Add(new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(plan.Summary) ? plan.Content : plan.Summary,
            FontSize = 12,
            Foreground = Brush("V2SecondaryForegroundBrush"),
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
        });
        text.Children.Add(new TextBlock
        {
            Text = AlwaysOnPlanMetaLine(plan),
            FontSize = 11,
            Foreground = Brush("V2MutedForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        Grid.SetColumn(text, 1);
        var open = new Button
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(0),
            Background = Transparent,
            BorderBrush = Transparent,
            Content = text,
        };
        open.Click += (_, _) =>
        {
            _selectedAlwaysOnPlanId = plan.Id;
            RenderAll();
        };
        grid.Children.Add(open);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        actions.Children.Add(SmallIconActionButton("Play", L("Run", "\u8fd0\u884c"), async () => await RunAlwaysOnPlanAsync(plan), isProminent: true));
        actions.Children.Add(SmallIconActionButton("Trash", L("Delete", "\u5220\u9664"), async () => await DeleteAlwaysOnPlanAsync(plan)));
        Grid.SetColumn(actions, 2);
        grid.Children.Add(actions);
        return new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2ContentSurfaceBrush"),
            Child = grid,
        };
    }

    private FrameworkElement AlwaysOnCronRow(AlwaysOnCronJob job)
    {
        var grid = new Grid
        {
            MinHeight = 82,
            Padding = new Thickness(12),
            ColumnSpacing = 12,
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new Border
        {
            Width = 34,
            Height = 34,
            CornerRadius = new CornerRadius(8),
            Background = Brush("V2CardSurfaceSubtleBrush"),
            BorderBrush = AlwaysOnStatusBrush(job.Status),
            BorderThickness = new Thickness(1),
            Child = Icon("Calendar", 15, AlwaysOnStatusBrush(job.Status)),
        });

        var text = new StackPanel { Spacing = 5 };
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        titleRow.Children.Add(new TextBlock
        {
            Text = AlwaysOnCronTitle(job),
            FontSize = 14,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });
        titleRow.Children.Add(SkillBadge(AlwaysOnStatusLabel(job.Status), AlwaysOnStatusBrush(job.Status)));
        titleRow.Children.Add(SkillBadge(L("Cron", "\u5468\u671f"), Brush("V2MutedForegroundBrush")));
        text.Children.Add(titleRow);
        text.Children.Add(new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(job.Prompt) ? job.Cron : job.Prompt,
            FontSize = 12,
            Foreground = Brush("V2SecondaryForegroundBrush"),
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
        });
        text.Children.Add(new TextBlock
        {
            Text = AlwaysOnCronMetaLine(job),
            FontSize = 11,
            Foreground = Brush("V2MutedForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        Grid.SetColumn(text, 1);
        var open = new Button
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(0),
            Background = Transparent,
            BorderBrush = Transparent,
            Content = text,
        };
        open.Click += (_, _) =>
        {
            _selectedAlwaysOnCronJobId = job.Id;
            RenderAll();
        };
        grid.Children.Add(open);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        actions.Children.Add(SmallIconActionButton("Eye", L("View", "\u67e5\u770b"), async () =>
        {
            _selectedAlwaysOnCronJobId = job.Id;
            await Task.CompletedTask;
            RenderAll();
        }));
        actions.Children.Add(SmallIconActionButton("Play", L("Run", "\u8fd0\u884c"), async () =>
        {
            _toolStatus = L("Cron job execution is not wired to the Windows native runtime yet.", "Cron \u4efb\u52a1\u5c1a\u672a\u63a5\u5165 Windows \u539f\u751f\u8fd0\u884c\u65f6\u3002");
            await Task.CompletedTask;
            RenderAll();
        }, isProminent: true));
        Grid.SetColumn(actions, 2);
        grid.Children.Add(actions);

        return new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2ContentSurfaceBrush"),
            Child = grid,
        };
    }

    private FrameworkElement AlwaysOnPlanDetailPage(AlwaysOnPlan plan)
    {
        var body = new StackPanel
        {
            Spacing = 16,
            Padding = new Thickness(24, 18, 24, 18),
            MaxWidth = 1120,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        var header = new Grid
        {
            ColumnSpacing = 16,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
        };
        var title = new StackPanel { Spacing = 9 };
        title.Children.Add(SkillHeaderButton("ChevronLeft", L("Back", "\u8fd4\u56de"), async () =>
        {
            _selectedAlwaysOnPlanId = null;
            await Task.CompletedTask;
            RenderAll();
        }));
        title.Children.Add(new TextBlock
        {
            Text = plan.Title,
            FontSize = 22,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
            TextWrapping = TextWrapping.Wrap,
        });
        title.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children =
            {
                SkillBadge(AlwaysOnStatusLabel(plan.ExecutionStatus ?? plan.Status), AlwaysOnStatusBrush(plan.ExecutionStatus ?? plan.Status)),
                SkillBadge(RelativeLabel(plan.UpdatedAt), Brush("V2MutedForegroundBrush")),
            },
        });
        header.Children.Add(title);
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Top,
            Children =
            {
                SkillHeaderButton("Play", L("Run", "\u8fd0\u884c"), async () => await RunAlwaysOnPlanAsync(plan)),
                SkillHeaderButton("Trash", T("common.delete"), async () => await DeleteAlwaysOnPlanAsync(plan)),
            },
        };
        Grid.SetColumn(actions, 1);
        header.Children.Add(actions);
        body.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2ContentSurfaceBrush"),
            Padding = new Thickness(18),
            Child = header,
        });

        if (!string.IsNullOrWhiteSpace(plan.Summary) || !string.IsNullOrWhiteSpace(plan.Rationale))
        {
            var summary = new StackPanel { Spacing = 8 };
            if (!string.IsNullOrWhiteSpace(plan.Summary))
            {
                summary.Children.Add(new TextBlock
                {
                    Text = plan.Summary,
                    FontSize = 13,
                    Foreground = Brush("V2SecondaryForegroundBrush"),
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            if (!string.IsNullOrWhiteSpace(plan.Rationale))
            {
                summary.Children.Add(new TextBlock
                {
                    Text = plan.Rationale,
                    FontSize = 12,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            body.Children.Add(ToolBoardGroup(L("Summary", "\u6458\u8981"), null, summary));
        }

        body.Children.Add(ToolBoardGroup(L("Plan Markdown", "\u8ba1\u5212 Markdown"), null, new TextBox
        {
            AcceptsReturn = true,
            Text = string.IsNullOrWhiteSpace(plan.Content) ? T("alwaysOn.emptyDetail") : plan.Content,
            IsReadOnly = true,
            TextWrapping = TextWrapping.Wrap,
            FontFamily = new FontFamily("Consolas"),
            FontSize = 12,
            MinHeight = 240,
            Padding = new Thickness(12),
            Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
        }));

        body.Children.Add(ToolBoardGroup(L("Metadata", "\u5143\u6570\u636e"), null, AlwaysOnMetaGrid(plan)));
        return new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = body,
        };
    }

    private FrameworkElement AlwaysOnCronDetailPage(AlwaysOnCronJob job)
    {
        var body = new StackPanel
        {
            Spacing = 16,
            Padding = new Thickness(24, 18, 24, 18),
            MaxWidth = 1120,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        var header = new Grid
        {
            ColumnSpacing = 16,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
        };
        var title = new StackPanel { Spacing = 9 };
        title.Children.Add(SkillHeaderButton("ChevronLeft", L("Back", "\u8fd4\u56de"), async () =>
        {
            _selectedAlwaysOnCronJobId = null;
            await Task.CompletedTask;
            RenderAll();
        }));
        title.Children.Add(new TextBlock
        {
            Text = AlwaysOnCronTitle(job),
            FontSize = 22,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
            TextWrapping = TextWrapping.Wrap,
        });
        title.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children =
            {
                SkillBadge(AlwaysOnStatusLabel(job.Status), AlwaysOnStatusBrush(job.Status)),
                SkillBadge(L("Cron", "\u5468\u671f"), Brush("V2MutedForegroundBrush")),
                SkillBadge(job.LastFiredAt is null ? L("Not triggered", "\u672a\u89e6\u53d1") : RelativeLabel(job.LastFiredAt.Value), Brush("V2MutedForegroundBrush")),
            },
        });
        header.Children.Add(title);
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Top,
            Children =
            {
                SkillHeaderButton("Play", L("Run", "\u8fd0\u884c"), async () =>
                {
                    _toolStatus = L("Cron job execution is not wired to the Windows native runtime yet.", "Cron \u4efb\u52a1\u5c1a\u672a\u63a5\u5165 Windows \u539f\u751f\u8fd0\u884c\u65f6\u3002");
                    await Task.CompletedTask;
                    RenderAll();
                }),
            },
        };
        Grid.SetColumn(actions, 1);
        header.Children.Add(actions);
        body.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2ContentSurfaceBrush"),
            Padding = new Thickness(18),
            Child = header,
        });

        body.Children.Add(ToolBoardGroup(L("Prompt", "\u63d0\u793a\u8bcd"), null, ReadOnlyMonospaceBox(string.IsNullOrWhiteSpace(job.Prompt) ? "-" : job.Prompt, 160)));
        body.Children.Add(ToolBoardGroup(L("Schedule", "\u65e5\u7a0b"), null, AlwaysOnMetaGrid(new[]
        {
            (L("Cron", "\u5468\u671f"), job.Cron),
            (L("Recurring", "\u5faa\u73af"), job.Recurring ? L("Yes", "\u662f") : L("No", "\u5426")),
            (L("Durable", "\u6301\u4e45"), job.Durable ? L("Yes", "\u662f") : L("No", "\u5426")),
            (L("Manual only", "\u4ec5\u624b\u52a8"), job.ManualOnly ? L("Yes", "\u662f") : L("No", "\u5426")),
        })));
        body.Children.Add(ToolBoardGroup(L("Created From", "\u6765\u6e90"), null, AlwaysOnMetaGrid(new[]
        {
            (L("Created", "\u521b\u5efa"), job.CreatedAt?.LocalDateTime.ToString("g") ?? "-"),
            (L("Last triggered", "\u6700\u8fd1\u89e6\u53d1"), job.LastFiredAt?.LocalDateTime.ToString("g") ?? "-"),
            (L("Origin session", "\u6765\u6e90\u4f1a\u8bdd"), string.IsNullOrWhiteSpace(job.OriginSessionId) ? "-" : job.OriginSessionId),
            (L("Session", "\u4f1a\u8bdd"), string.IsNullOrWhiteSpace(job.LatestSessionId) ? "-" : job.LatestSessionId),
            (L("Transcript", "Transcript"), string.IsNullOrWhiteSpace(job.TranscriptKey) ? "-" : job.TranscriptKey),
            (L("Latest run", "\u6700\u8fd1\u8fd0\u884c"), job.LatestRun?.Id ?? "-"),
        })));

        if (job.LatestRun is { } latest)
        {
            body.Children.Add(ToolBoardGroup(L("Latest Run", "\u6700\u8fd1\u8fd0\u884c"), null, AlwaysOnMetaGrid(new[]
            {
                (L("Status", "\u72b6\u6001"), latest.Status is null ? "-" : AlwaysOnStatusLabel(latest.Status.Value)),
                (L("Started", "\u5f00\u59cb"), latest.StartedAt?.LocalDateTime.ToString("g") ?? "-"),
                (L("Session", "\u4f1a\u8bdd"), latest.SessionId ?? "-"),
                (L("Task", "\u4efb\u52a1"), latest.TaskId ?? "-"),
                (L("Output", "\u8f93\u51fa"), latest.OutputFile ?? "-"),
                (L("Transcript", "Transcript"), latest.TranscriptKey ?? "-"),
            })));
        }

        return new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = body,
        };
    }

    private FrameworkElement AlwaysOnRunHistorySection(IEnumerable<AlwaysOnRunHistory> runs)
    {
        var rows = runs.OrderByDescending(run => run.StartedAt).ToList();
        if (rows.Count == 0)
        {
            return ToolBoardGroup(L("Run History", "\u8fd0\u884c\u5386\u53f2"), L("Background run output, sessions, and transcript references.", "\u540e\u53f0\u8fd0\u884c\u8f93\u51fa\u3001\u4f1a\u8bdd\u548c transcript \u5f15\u7528\u3002"),
                DashedEmptyState(L("No run history", "\u6682\u65e0\u8fd0\u884c\u5386\u53f2"), L("Run a plan to show background execution history here.", "\u8fd0\u884c\u8ba1\u5212\u540e\u8fd9\u91cc\u4f1a\u663e\u793a\u540e\u53f0\u6267\u884c\u5386\u53f2\u3002")));
        }

        var cardStack = new StackPanel { Spacing = 10 };
        foreach (var run in rows)
        {
            cardStack.Children.Add(AlwaysOnRunRow(run));
        }
        return ToolBoardGroup(L("Run History", "\u8fd0\u884c\u5386\u53f2"), L("Background run output, sessions, and transcript references.", "\u540e\u53f0\u8fd0\u884c\u8f93\u51fa\u3001\u4f1a\u8bdd\u548c transcript \u5f15\u7528\u3002"), cardStack);
    }

    private FrameworkElement AlwaysOnRunRow(AlwaysOnRunHistory run)
    {
        var grid = new Grid
        {
            MinHeight = 72,
            Padding = new Thickness(12),
            ColumnSpacing = 12,
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new Border
        {
            Width = 34,
            Height = 34,
            CornerRadius = new CornerRadius(8),
            Background = Brush("V2CardSurfaceSubtleBrush"),
            BorderBrush = AlwaysOnStatusBrush(run.Status),
            BorderThickness = new Thickness(1),
            Child = Icon("Radio", 15, AlwaysOnStatusBrush(run.Status)),
        });

        var text = new StackPanel { Spacing = 5 };
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        titleRow.Children.Add(new TextBlock
        {
            Text = run.Title,
            FontSize = 14,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });
        titleRow.Children.Add(SkillBadge(AlwaysOnStatusLabel(run.Status), AlwaysOnStatusBrush(run.Status)));
        titleRow.Children.Add(SkillBadge(run.Kind, Brush("V2MutedForegroundBrush")));
        text.Children.Add(titleRow);
        text.Children.Add(new TextBlock
        {
            Text = AlwaysOnRunMetaLine(run),
            FontSize = 11,
            Foreground = Brush("V2MutedForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        Grid.SetColumn(text, 1);
        var open = new Button
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(0),
            Background = Transparent,
            BorderBrush = Transparent,
            Content = text,
        };
        open.Click += (_, _) =>
        {
            _selectedAlwaysOnRunId = run.Id;
            RenderAll();
        };
        grid.Children.Add(open);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        actions.Children.Add(SmallIconActionButton("Eye", L("View", "\u67e5\u770b"), async () =>
        {
            _selectedAlwaysOnRunId = run.Id;
            await Task.CompletedTask;
            RenderAll();
        }));
        Grid.SetColumn(actions, 2);
        grid.Children.Add(actions);

        return new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2ContentSurfaceBrush"),
            Child = grid,
        };
    }

    private FrameworkElement AlwaysOnRunDetailPage(AlwaysOnRunHistory run)
    {
        var body = new StackPanel
        {
            Spacing = 16,
            Padding = new Thickness(24, 18, 24, 18),
            MaxWidth = 1120,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        var title = new StackPanel { Spacing = 9 };
        title.Children.Add(SkillHeaderButton("ChevronLeft", L("Back", "\u8fd4\u56de"), async () =>
        {
            _selectedAlwaysOnRunId = null;
            await Task.CompletedTask;
            RenderAll();
        }));
        title.Children.Add(new TextBlock
        {
            Text = run.Title,
            FontSize = 22,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
            TextWrapping = TextWrapping.Wrap,
        });
        title.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children =
            {
                SkillBadge(AlwaysOnStatusLabel(run.Status), AlwaysOnStatusBrush(run.Status)),
                SkillBadge(run.Kind, Brush("V2MutedForegroundBrush")),
                SkillBadge(RelativeLabel(run.StartedAt), Brush("V2MutedForegroundBrush")),
            },
        });
        body.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2ContentSurfaceBrush"),
            Padding = new Thickness(18),
            Child = title,
        });
        body.Children.Add(ToolBoardGroup(L("Output", "\u8f93\u51fa"), null, ReadOnlyMonospaceBox(string.IsNullOrWhiteSpace(run.OutputLog) ? L("No output yet.", "\u6682\u65e0\u8f93\u51fa\u3002") : run.OutputLog, 240)));
        if (!string.IsNullOrWhiteSpace(run.Error))
        {
            body.Children.Add(ToolBoardGroup(L("Error", "\u9519\u8bef"), null, ReadOnlyMonospaceBox(run.Error, 100)));
        }
        body.Children.Add(ToolBoardGroup(L("Metadata", "\u5143\u6570\u636e"), null, AlwaysOnMetaGrid(new[]
        {
            (L("Started", "\u5f00\u59cb"), run.StartedAt.LocalDateTime.ToString("g")),
            (L("Finished", "\u5b8c\u6210"), run.FinishedAt?.LocalDateTime.ToString("g") ?? "-"),
            (L("Source", "\u6765\u6e90"), run.SourceId),
            (L("Session", "\u4f1a\u8bdd"), run.SessionId ?? "-"),
            (L("Parent session", "\u7236\u4f1a\u8bdd"), run.ParentSessionId ?? "-"),
            (L("Transcript", "Transcript"), run.TranscriptKey ?? run.RelativeTranscriptPath ?? "-"),
        })));
        return new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = body,
        };
    }

    private FrameworkElement AlwaysOnMetaGrid(AlwaysOnPlan plan)
    {
        var items = new (string Label, string Value)[]
        {
            (L("Created", "\u521b\u5efa"), plan.CreatedAt.LocalDateTime.ToString("g")),
            (L("Updated", "\u66f4\u65b0"), plan.UpdatedAt.LocalDateTime.ToString("g")),
            (L("Approval", "\u5ba1\u6279"), string.IsNullOrWhiteSpace(plan.ApprovalMode) ? "-" : plan.ApprovalMode),
            (L("Session", "\u4f1a\u8bdd"), string.IsNullOrWhiteSpace(plan.ExecutionSessionId) ? "-" : plan.ExecutionSessionId),
            (L("Plan file", "\u8ba1\u5212\u6587\u4ef6"), string.IsNullOrWhiteSpace(plan.PlanFilePath) ? "-" : plan.PlanFilePath),
        };
        return AlwaysOnMetaGrid(items);
    }

    private FrameworkElement AlwaysOnMetaGrid(IReadOnlyList<(string Label, string Value)> items)
    {
        var grid = new Grid { ColumnSpacing = 12, RowSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var i = 0; i < items.Count; i++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var item = SkillMetaLabel(items[i].Label, items[i].Value);
            Grid.SetColumn(item, i % 2);
            Grid.SetRow(item, i / 2);
            grid.Children.Add(item);
        }

        return grid;
    }

    private FrameworkElement ReadOnlyMonospaceBox(string text, double minHeight) => new TextBox
    {
        AcceptsReturn = true,
        Text = text,
        IsReadOnly = true,
        TextWrapping = TextWrapping.Wrap,
        FontFamily = new FontFamily("Consolas"),
        FontSize = 12,
        MinHeight = minHeight,
        Padding = new Thickness(12),
        Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
    };

    private string AlwaysOnPlanMetaLine(AlwaysOnPlan plan) =>
        $"{L("Created", "\u521b\u5efa")} {RelativeLabel(plan.CreatedAt)} / {L("Updated", "\u66f4\u65b0")} {RelativeLabel(plan.UpdatedAt)}";

    private string AlwaysOnCronTitle(AlwaysOnCronJob job)
    {
        var firstLine = job.Prompt.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        return string.IsNullOrWhiteSpace(firstLine) ? job.Id : firstLine.Trim();
    }

    private string AlwaysOnCronMetaLine(AlwaysOnCronJob job)
    {
        var created = job.CreatedAt is null ? "-" : RelativeLabel(job.CreatedAt.Value);
        var triggered = job.LastFiredAt is null ? "-" : RelativeLabel(job.LastFiredAt.Value);
        return $"{L("Created", "\u521b\u5efa")} {created} / {L("Triggered", "\u89e6\u53d1")} {triggered} / {job.Cron}";
    }

    private string AlwaysOnRunMetaLine(AlwaysOnRunHistory run)
    {
        var finished = run.FinishedAt is null ? "-" : RelativeLabel(run.FinishedAt.Value);
        return $"{L("Started", "\u5f00\u59cb")} {RelativeLabel(run.StartedAt)} / {L("Finished", "\u5b8c\u6210")} {finished} / {run.SourceId}";
    }

    private string AlwaysOnStatusLabel(AlwaysOnStatus status) => status switch
    {
        AlwaysOnStatus.Scheduled => L("Scheduled", "\u5df2\u6392\u671f"),
        AlwaysOnStatus.Ready => L("Ready", "\u5c31\u7eea"),
        AlwaysOnStatus.Queued => L("Queued", "\u6392\u961f\u4e2d"),
        AlwaysOnStatus.Running => L("Running", "\u8fd0\u884c\u4e2d"),
        AlwaysOnStatus.Completed => L("Completed", "\u5df2\u5b8c\u6210"),
        AlwaysOnStatus.Failed => L("Failed", "\u5931\u8d25"),
        AlwaysOnStatus.Draft => L("Draft", "\u8349\u7a3f"),
        AlwaysOnStatus.Superseded => L("Superseded", "\u5df2\u66ff\u6362"),
        _ => L("Unknown", "\u672a\u77e5"),
    };

    private Brush AlwaysOnStatusBrush(AlwaysOnStatus status) => status switch
    {
        AlwaysOnStatus.Running => Brush("V2BlueBrush"),
        AlwaysOnStatus.Completed => Brush("V2GreenBrush"),
        AlwaysOnStatus.Failed => Brush("V2RedBrush"),
        AlwaysOnStatus.Scheduled or AlwaysOnStatus.Queued => Brush("V2AmberBrush"),
        _ => Brush("V2MutedForegroundBrush"),
    };

    private FrameworkElement ToolBoardGroup(string title, string? subtitle, params FrameworkElement[] children)
    {
        var content = new StackPanel { Spacing = 0 };
        for (var index = 0; index < children.Length; index++)
        {
            content.Children.Add(children[index]);
            if (index < children.Length - 1)
            {
                content.Children.Add(new Border
                {
                    Height = 1,
                    Background = Brush("V2BorderBrush"),
                    Opacity = 0.72,
                    Margin = new Thickness(34, 0, 0, 0),
                });
            }
        }

        var stack = new StackPanel { Spacing = 12 };
        var header = new StackPanel { Spacing = 2 };
        header.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 14,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
        });
        if (!string.IsNullOrWhiteSpace(subtitle))
        {
            header.Children.Add(new TextBlock
            {
                Text = subtitle,
                FontSize = 12,
                Foreground = Brush("V2MutedForegroundBrush"),
                TextWrapping = TextWrapping.Wrap,
                MaxLines = 2,
            });
        }
        stack.Children.Add(header);
        stack.Children.Add(content);

        return new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2ContentSurfaceBrush"),
            Padding = new Thickness(16, 14, 16, 14),
            Child = stack,
        };
    }

    private FrameworkElement DashedEmptyState(string title, string detail) => new Border
    {
        MinHeight = 78,
        CornerRadius = new CornerRadius(8),
        BorderBrush = Brush("V2BorderBrush"),
        BorderThickness = new Thickness(1),
        Background = Brush("V2CardSurfaceSubtleBrush"),
        Padding = new Thickness(16),
        Child = new StackPanel
        {
            VerticalAlignment = VerticalAlignment.Center,
            Spacing = 4,
            Children =
            {
                new TextBlock
                {
                    Text = title,
                    FontSize = 13,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Foreground = Brush("V2ForegroundBrush"),
                    TextAlignment = TextAlignment.Center,
                    HorizontalAlignment = HorizontalAlignment.Center,
                },
                new TextBlock
                {
                    Text = detail,
                    FontSize = 12,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    TextWrapping = TextWrapping.Wrap,
                    TextAlignment = TextAlignment.Center,
                    HorizontalAlignment = HorizontalAlignment.Center,
                },
            },
        },
    };

    private Button SmallIconActionButton(string iconKey, string label, Func<Task> action, bool isProminent = false, bool isEnabled = true)
    {
        var button = new Button
        {
            Content = Icon(iconKey, 14, Brush(isProminent ? "V2InverseForegroundBrush" : "V2SecondaryForegroundBrush")),
            Height = 28,
            Width = 32,
            MinWidth = 0,
            Padding = new Thickness(0),
            Style = (Style)Application.Current.Resources[isProminent ? "V2PrimaryButtonStyle" : "V2ToolbarButtonStyle"],
            IsEnabled = isEnabled,
        };
        ToolTipService.SetToolTip(button, label);
        button.Click += async (_, _) => await action();
        return button;
    }

    private string RelativeLabel(DateTimeOffset value)
    {
        var span = DateTimeOffset.Now - value.ToLocalTime();
        if (span.TotalSeconds < 60) return L("just now", "\u521a\u521a");
        if (span.TotalMinutes < 60) return IsChineseUi() ? $"{Math.Floor(span.TotalMinutes)} \u5206\u949f\u524d" : $"{Math.Floor(span.TotalMinutes)}m ago";
        if (span.TotalHours < 24) return IsChineseUi() ? $"{Math.Floor(span.TotalHours)} \u5c0f\u65f6\u524d" : $"{Math.Floor(span.TotalHours)}h ago";
        if (span.TotalDays < 7) return IsChineseUi() ? $"{Math.Floor(span.TotalDays)} \u5929\u524d" : $"{Math.Floor(span.TotalDays)}d ago";
        return value.LocalDateTime.ToString("g");
    }

    private TextBlock StatusText(string text) => new()
    {
        Text = text,
        FontSize = 12,
        Foreground = Brush("V2MutedForegroundBrush"),
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 0, 0, 4),
    };

    private FrameworkElement ActionCard(string iconKey, string title, string detail, params (string Label, Func<Task> Action)[] actions)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Icon(iconKey, 16, Brush("V2MutedForegroundBrush")));
        var text = new StackPanel
        {
            Spacing = 2,
            Children =
            {
                new TextBlock { Text = title, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = Brush("V2ForegroundBrush"), TextTrimming = TextTrimming.CharacterEllipsis },
                new TextBlock { Text = detail, FontSize = 12, Foreground = Brush("V2MutedForegroundBrush"), TextWrapping = TextWrapping.Wrap },
            },
        };
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        var actionPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        foreach (var action in actions)
        {
            var button = new Button
            {
                Content = action.Label,
                Height = 28,
                Style = (Style)Application.Current.Resources["V2ToolbarButtonStyle"],
            };
            button.Click += async (_, _) => await action.Action();
            actionPanel.Children.Add(button);
        }

        Grid.SetColumn(actionPanel, 2);
        grid.Children.Add(actionPanel);
        return new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2CardBrush"),
            Padding = new Thickness(12),
            Child = grid,
        };
    }

    private async Task<string?> PromptTextAsync(string title, string placeholder, string initial = "")
    {
        var box = new TextBox
        {
            Text = initial,
            PlaceholderText = placeholder,
            Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
        };
        var result = await Dialog(title, box, T("common.ok")).ShowAsync();
        return result == ContentDialogResult.Primary ? box.Text.Trim() : null;
    }

    private async Task<string?> PromptMultilineAsync(string title, string placeholder, string initial = "")
    {
        var box = new TextBox
        {
            Text = initial,
            PlaceholderText = placeholder,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 160,
            Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
        };
        var result = await Dialog(title, box, T("common.ok")).ShowAsync();
        return result == ContentDialogResult.Primary ? box.Text.Trim() : null;
    }

    private async Task ShowTextDialogAsync(string title, string text)
    {
        await Dialog(title, new TextBox
        {
            Text = text,
            IsReadOnly = true,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 320,
            FontFamily = new FontFamily("Consolas"),
            FontSize = 12,
            Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
        }, T("common.ok")).ShowAsync();
    }

    private async Task CreateSkillAsync()
    {
        var slug = await PromptTextAsync(T("skills.newSkill"), "skill-slug");
        if (string.IsNullOrWhiteSpace(slug)) return;
        var description = await PromptMultilineAsync(T("skills.newSkill"), "Description");
        try
        {
            var (scope, projectRoot) = SkillDestination();
            _skillService.Create(scope, projectRoot, slug, slug, description ?? "");
            _toolStatus = $"Created skill {slug}.";
            RefreshNativeStores();
        }
        catch (Exception ex)
        {
            _toolStatus = ex.Message;
        }

        RenderAll();
    }

    private async Task ImportSkillFolderAsync()
    {
        try
        {
            var picker = new FolderPicker();
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
            picker.FileTypeFilter.Add("*");
            var folder = await picker.PickSingleFolderAsync();
            if (folder is null) return;

            var (scope, projectRoot) = SkillDestination();
            var skill = _skillService.ImportFolder(scope, projectRoot, folder.Path);
            _selectedSkillKey = SkillKey(skill);
            _skillEditorKey = null;
            _toolStatus = $"Imported skill {skill.Name}.";
            RefreshNativeStores();
        }
        catch (Exception ex)
        {
            _toolStatus = ex.Message;
        }

        RenderAll();
    }

    private (SkillScope Scope, string? ProjectRoot) SkillDestination()
    {
        if (State.SelectedProject is { } project && !IsGeneralProject(project))
        {
            return (SkillScope.Project, project.RootPath);
        }

        return (SkillScope.User, null);
    }

    private async Task DeleteSkillAsync(SkillRecord skill)
    {
        try
        {
            _skillService.Delete(skill);
            _toolStatus = $"Deleted skill {skill.Name}.";
            _selectedSkillKey = null;
            _skillEditorKey = null;
            _skillEditorContent = "";
            _skillEditorOriginalContent = "";
            RefreshNativeStores();
        }
        catch (Exception ex)
        {
            _toolStatus = ex.Message;
        }

        await Task.CompletedTask;
        RenderAll();
    }

    private async Task CreateMemoryAsync()
    {
        var name = await PromptTextAsync("New memory", "Name");
        if (string.IsNullOrWhiteSpace(name)) return;
        var summary = await PromptMultilineAsync("New memory", "Summary");
        _memoryService.Create(name, summary ?? "", State.SelectedProject?.DisplayName);
        _toolStatus = $"Created memory {name}.";
        RefreshNativeStores();
        RenderAll();
    }

    private async Task EditMemoryAsync(MemoryRecord memory)
    {
        var name = await PromptTextAsync(L("Edit Memory", "\u7f16\u8f91\u8bb0\u5fc6"), L("Name", "\u540d\u79f0"), memory.Name);
        if (string.IsNullOrWhiteSpace(name)) return;
        var summary = await PromptMultilineAsync(L("Edit Memory", "\u7f16\u8f91\u8bb0\u5fc6"), L("Summary", "\u6458\u8981"), memory.Summary);
        try
        {
            var updated = _memoryService.Edit(memory, name, summary ?? "");
            _selectedMemoryRecordId = updated.Id;
            _toolStatus = $"Updated memory {updated.Name}.";
            RefreshNativeStores();
        }
        catch (Exception ex)
        {
            _toolStatus = ex.Message;
        }

        RenderAll();
    }

    private async Task ToggleMemoryDeprecatedAsync(MemoryRecord memory)
    {
        try
        {
            var updated = _memoryService.SetDeprecated(memory, !memory.Deprecated);
            _selectedMemoryRecordId = null;
            _toolStatus = updated.Deprecated ? $"Deprecated memory {updated.Name}." : $"Restored memory {updated.Name}.";
            RefreshNativeStores();
        }
        catch (Exception ex)
        {
            _toolStatus = ex.Message;
        }

        await Task.CompletedTask;
        RenderAll();
    }

    private async Task DeleteMemoryAsync(MemoryRecord memory)
    {
        _memoryService.Delete(memory);
        _toolStatus = $"Deleted memory {memory.Name}.";
        if (_selectedMemoryRecordId == memory.Id) _selectedMemoryRecordId = null;
        RefreshNativeStores();
        await Task.CompletedTask;
        RenderAll();
    }

    private async Task ExportMemoryAsync()
    {
        var target = Path.Combine(AppPaths.EnsureCreated().Root, $"memory-export-{DateTimeOffset.Now:yyyyMMdd-HHmmss}.json");
        _memoryService.ExportJson(target);
        _toolStatus = $"Exported memory to {target}.";
        await Task.CompletedTask;
        RenderAll();
    }

    private async Task CreateAlwaysOnPlanAsync()
    {
        var title = await PromptTextAsync("New always-on plan", "Plan title");
        if (string.IsNullOrWhiteSpace(title)) return;
        var prompt = await PromptMultilineAsync("New always-on plan", "Prompt");
        _alwaysOnStore.Create(title, prompt ?? "");
        _toolStatus = $"Created always-on plan {title}.";
        RefreshNativeStores();
        RenderAll();
    }

    private async Task StartAlwaysOnDiscoveryAsync(WorkspaceProject? targetProject = null)
    {
        var project = targetProject ?? State.SelectedProject;
        if (project is null || V2SidebarProjection.IsGeneralProject(project))
        {
            await CreateAlwaysOnPlanAsync();
            return;
        }

        var title = L("Discovery plan", "\u53d1\u73b0\u8ba1\u5212");
        var prompt = IsChineseUi()
            ? $"\u68c0\u67e5\u9879\u76ee {project.DisplayName}\uff08{project.RootPath}\uff09\u7684\u5f53\u524d\u72b6\u6001\u3001\u6700\u8fd1\u5bf9\u8bdd\u3001\u8bb0\u5fc6\u548c\u8ba1\u5212\uff0c\u63d0\u51fa\u4e00\u4e2a\u53ef\u624b\u52a8\u8fd0\u884c\u7684 Always-on \u540e\u53f0\u8ba1\u5212\u3002"
            : $"Review project {project.DisplayName} ({project.RootPath}), including recent chats, memories, and existing plans, then propose one manually runnable Always-on background plan.";
        var plan = _alwaysOnStore.Create(title, prompt);
        _alwaysOnToolTab = AlwaysOnToolTab.Items;
        _selectedAlwaysOnPlanId = plan.Id;
        _toolStatus = L(
            $"Discovery plan created for {project.DisplayName}.",
            $"\u5df2\u4e3a {project.DisplayName} \u521b\u5efa\u53d1\u73b0\u8ba1\u5212\u3002");
        RefreshNativeStores();
        await Task.CompletedTask;
        RenderAll();
    }

    private async Task RunFirstAlwaysOnPlanAsync()
    {
        if (State.AlwaysOnPlans.FirstOrDefault() is { } plan)
        {
            await RunAlwaysOnPlanAsync(plan);
        }
    }

    private async Task RunAlwaysOnPlanAsync(AlwaysOnPlan plan)
    {
        _alwaysOnStore.MarkRunNow(plan);
        _toolStatus = $"Ran always-on plan {plan.Title}.";
        RefreshNativeStores();
        await Task.CompletedTask;
        RenderAll();
    }

    private async Task DeleteAlwaysOnPlanAsync(AlwaysOnPlan plan)
    {
        _alwaysOnStore.Delete(plan);
        _toolStatus = $"Deleted always-on plan {plan.Title}.";
        if (string.Equals(_selectedAlwaysOnPlanId, plan.Id, StringComparison.Ordinal)) _selectedAlwaysOnPlanId = null;
        RefreshNativeStores();
        await Task.CompletedTask;
        RenderAll();
    }

    private async Task CreateTaskAsync()
    {
        if (State.SelectedProject is null) return;
        var title = await PromptTextAsync("New task", "Task title");
        if (string.IsNullOrWhiteSpace(title)) return;
        var prompt = await PromptMultilineAsync("New task", "Prompt");
        var task = _taskMasterService.AddTask(State.SelectedProject.RootPath, title, prompt ?? "");
        _taskPlanStore.Save(task);
        _toolStatus = $"Created task {task.Title}.";
        RefreshNativeStores();
        RenderAll();
    }

    private async Task InitTaskMasterAsync()
    {
        if (State.SelectedProject is null) return;
        var snapshot = _taskMasterService.Init(State.SelectedProject.RootPath);
        _toolStatus = $"TaskMaster initialized at {snapshot.Root}.";
        RefreshNativeStores();
        await Task.CompletedTask;
        RenderAll();
    }

    private FrameworkElement ToolPlaceholder(string title, string subtitle, string iconKey)
    {
        var page = ToolPage(title, subtitle, Array.Empty<(string, string, Action)>());
        ((Grid)page.Tag!).Children.Add(EmptyState(title, subtitle, iconKey));
        return page;
    }

    private FrameworkElement PluginPlaceholder(PluginManifest plugin)
    {
        var subtitle = $"{plugin.Version} - {plugin.Id}";
        var page = ToolPage(plugin.Name, subtitle, Array.Empty<(string, string, Action)>());
        ((Grid)page.Tag!).Children.Add(EmptyState(plugin.Name, T("preview.detail"), "Sparkles"));
        return page;
    }

    private Grid ToolPage(string title, string subtitle, IReadOnlyList<(string Icon, string Label, Action Action)> actions)
    {
        return ToolPage(title, subtitle, ToolActionPanel(actions));
    }

    private Grid ToolPage(string title, string subtitle, FrameworkElement actions)
    {
        var root = new Grid { Background = Brush("V2BackgroundBrush") };
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(V2LayoutMetrics.ToolbarHeight) });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var toolbarHost = new Border
        {
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(0, 0, 0, 1),
        };
        var toolbar = new Grid
        {
            Padding = new Thickness(16, 0, 16, 0),
        };
        toolbarHost.Child = toolbar;
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 2 };
        label.Children.Add(new TextBlock { Text = title, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = Brush("V2ForegroundBrush") });
        label.Children.Add(new TextBlock { Text = subtitle, FontSize = 11, Foreground = Brush("V2MutedForegroundBrush"), TextTrimming = TextTrimming.CharacterEllipsis, Visibility = string.IsNullOrWhiteSpace(subtitle) ? Visibility.Collapsed : Visibility.Visible });
        toolbar.Children.Add(label);
        actions.VerticalAlignment = VerticalAlignment.Center;
        actions.HorizontalAlignment = HorizontalAlignment.Right;
        Grid.SetColumn(actions, 1);
        toolbar.Children.Add(actions);
        root.Children.Add(toolbarHost);

        var body = new Grid();
        Grid.SetRow(body, 1);
        root.Children.Add(body);
        root.Tag = body;
        return root;
    }

    private StackPanel ToolActionPanel(IReadOnlyList<(string Icon, string Label, Action Action)> actions)
    {
        var actionPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        foreach (var action in actions)
        {
            actionPanel.Children.Add(ToolbarButton(action.Icon, action.Label, action.Action));
        }

        return actionPanel;
    }

    private Button ToolbarButton(string iconKey, string label, Action action, bool isProminent = false)
    {
        var button = new Button
        {
            Style = (Style)Application.Current.Resources[isProminent ? "V2PrimaryButtonStyle" : "V2ToolbarButtonStyle"],
            Height = 32,
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                Children =
                {
                    Icon(iconKey, 14, Brush(isProminent ? "V2InverseForegroundBrush" : "V2SecondaryForegroundBrush")),
                    new TextBlock { Text = label, FontSize = 12, Foreground = Brush(isProminent ? "V2InverseForegroundBrush" : "V2SecondaryForegroundBrush"), VerticalAlignment = VerticalAlignment.Center },
                },
            },
        };
        button.Click += (_, _) => action();
        return button;
    }

    private Button ToolbarTextButton(string label, Action action, bool isProminent = false)
    {
        var button = new Button
        {
            Style = (Style)Application.Current.Resources[isProminent ? "V2PrimaryButtonStyle" : "V2ToolbarButtonStyle"],
            Height = 32,
            MinWidth = isProminent ? 56 : 0,
            Content = new TextBlock
            {
                Text = label,
                FontSize = 12,
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                Foreground = Brush(isProminent ? "V2InverseForegroundBrush" : "V2SecondaryForegroundBrush"),
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            },
        };
        button.Click += (_, _) => action();
        return button;
    }

    private TextBox ToolToolbarTextBox(string text, string placeholder, double width, bool isMonospaced = false)
    {
        return new TextBox
        {
            Text = text,
            PlaceholderText = placeholder,
            Width = width,
            Height = 32,
            MinWidth = 0,
            FontSize = 13,
            FontFamily = isMonospaced ? new FontFamily("Consolas") : null,
            Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
        };
    }

    private FrameworkElement MetricRow(string iconKey, string label, string value, string detail, string? hint = null) => new Border
    {
        CornerRadius = new CornerRadius(8),
        BorderBrush = Brush("V2BorderBrush"),
        BorderThickness = new Thickness(1),
        Background = Brush("V2ContentSurfaceBrush"),
        Padding = new Thickness(14),
        MinHeight = 104,
        Child = new StackPanel
        {
            Spacing = 7,
            Children =
            {
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 8,
                    Children =
                    {
                        Icon(iconKey, 13, Brush("V2MutedForegroundBrush")),
                        new TextBlock
                        {
                            Text = label,
                            FontSize = 12,
                            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                            Foreground = Brush("V2MutedForegroundBrush"),
                            VerticalAlignment = VerticalAlignment.Center,
                        },
                    },
                },
                new TextBlock
                {
                    Text = value,
                    FontSize = 22,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Foreground = Brush("V2ForegroundBrush"),
                },
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 8,
                    Children =
                    {
                        new TextBlock
                        {
                            Text = detail,
                            FontSize = 11,
                            Foreground = Brush("V2MutedForegroundBrush"),
                            TextTrimming = TextTrimming.CharacterEllipsis,
                        },
                        new TextBlock
                        {
                            Text = hint ?? "",
                            FontSize = 11,
                            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                            Foreground = Brush("V2GreenBrush"),
                            Visibility = string.IsNullOrWhiteSpace(hint) ? Visibility.Collapsed : Visibility.Visible,
                        },
                    },
                },
            },
        },
    };

    private Grid MetricGrid(params FrameworkElement[] cards)
    {
        var grid = new Grid { ColumnSpacing = 12, RowSpacing = 12 };
        for (var index = 0; index < cards.Length; index++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetColumn(cards[index], index);
            grid.Children.Add(cards[index]);
        }

        return grid;
    }

    private FrameworkElement ToolSection(string title, params FrameworkElement[] children)
    {
        var content = new StackPanel { Spacing = 2 };
        foreach (var child in children)
        {
            content.Children.Add(child);
        }

        return new StackPanel
        {
            Spacing = 8,
            Children =
            {
                new TextBlock
                {
                    Text = title.ToUpperInvariant(),
                    FontSize = 11,
                    FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    CharacterSpacing = 44,
                },
                new Border
                {
                    CornerRadius = new CornerRadius(8),
                    BorderBrush = Brush("V2BorderBrush"),
                    BorderThickness = new Thickness(1),
                    Background = Brush("V2CardBrush"),
                    Padding = new Thickness(16),
                    Child = content,
                },
            },
        };
    }

    private FrameworkElement ToolList(StackPanel content) => new ScrollViewer
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Content = new Border
        {
            Padding = new Thickness(16),
            Child = content,
        },
    };

    private static T Column<T>(int column, T element) where T : FrameworkElement
    {
        Grid.SetColumn(element, column);
        return element;
    }

    private FrameworkElement ToolListRow(string iconKey, string title, string detail, string trailing) => new Grid
    {
        Padding = new Thickness(10, 9, 10, 9),
        ColumnSpacing = 10,
        ColumnDefinitions =
        {
            new ColumnDefinition { Width = new GridLength(20) },
            new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
            new ColumnDefinition { Width = GridLength.Auto },
        },
        Children =
        {
            Icon(iconKey, 14, Brush("V2MutedForegroundBrush")),
            Column(1, new StackPanel
            {
                Spacing = 2,
                Children =
                {
                    new TextBlock { Text = title, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = Brush("V2ForegroundBrush"), TextTrimming = TextTrimming.CharacterEllipsis },
                    new TextBlock { Text = string.IsNullOrWhiteSpace(detail) ? " " : detail, FontSize = 12, Foreground = Brush("V2MutedForegroundBrush"), TextWrapping = TextWrapping.Wrap, MaxLines = 2 },
                },
            }),
            Column(2, new TextBlock
            {
                Text = trailing,
                FontSize = 11,
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                Foreground = Brush("V2MutedForegroundBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            }),
        },
    };

    private FrameworkElement MonospaceOutput(string text) => new ScrollViewer
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        Content = new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(text) ? " " : text,
            FontFamily = new FontFamily("Consolas"),
            FontSize = 12,
            Foreground = Brush("V2ForegroundBrush"),
            TextWrapping = TextWrapping.NoWrap,
            Padding = new Thickness(16),
        },
    };

    private FrameworkElement TerminalRunRow(NativeBackgroundRun run)
    {
        var header = new Grid { ColumnSpacing = 12 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock
        {
            Text = $"$ {run.Description}",
            FontFamily = new FontFamily("Consolas"),
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        var statusBrush = run.ExitCode is 0 ? Brush("V2GreenBrush") : Brush("V2RedBrush");
        var exitText = run.Status == G9Claw.Windows.Core.TaskStatus.Running ? "running" : $"exit {run.ExitCode ?? -1}";
        var exit = new TextBlock
        {
            Text = exitText,
            FontFamily = new FontFamily("Consolas"),
            FontSize = 11,
            Foreground = statusBrush,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(exit, 1);
        header.Children.Add(exit);

        return new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2ControlSurfaceBrush"),
            Padding = new Thickness(12),
            Margin = new Thickness(0, 0, 0, 2),
            Child = new StackPanel
            {
                Spacing = 8,
                Children =
                {
                    header,
                    new TextBlock
                    {
                        Text = string.IsNullOrWhiteSpace(run.Output) ? " " : run.Output,
                        FontFamily = new FontFamily("Consolas"),
                        FontSize = 11,
                        Foreground = Brush("V2SecondaryForegroundBrush"),
                        TextWrapping = TextWrapping.Wrap,
                    },
                },
            },
        };
    }

    private FrameworkElement ListCard(string iconKey, string title, string detail) => new Border
    {
        CornerRadius = new CornerRadius(8),
        BorderBrush = Brush("V2BorderBrush"),
        BorderThickness = new Thickness(1),
        Background = Brush("V2ContentSurfaceBrush"),
        Padding = new Thickness(12),
        Child = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 10,
            Children =
            {
                Icon(iconKey, 16, Brush("V2MutedForegroundBrush")),
                new StackPanel
                {
                    Spacing = 2,
                    Children =
                    {
                        new TextBlock { Text = title, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = Brush("V2ForegroundBrush") },
                        new TextBlock { Text = detail, FontSize = 12, Foreground = Brush("V2MutedForegroundBrush"), TextWrapping = TextWrapping.Wrap },
                    },
                },
            },
        },
    };

    private FrameworkElement EmptyFullPage(string title, string detail, string iconKey) => new Grid
    {
        Background = Brush("V2BackgroundBrush"),
        Children =
        {
            EmptyState(title, detail, iconKey),
        },
    };

    private FrameworkElement EmptyState(string title, string detail, string iconKey) => new StackPanel
    {
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        Spacing = 8,
        Width = 420,
        MaxWidth = 420,
        Children =
        {
            Icon(iconKey, 28, Brush("V2MutedForegroundBrush")),
            new TextBlock { Text = title, FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = Brush("V2ForegroundBrush"), HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 420, TextTrimming = TextTrimming.CharacterEllipsis },
            new TextBlock { Text = detail, FontSize = 12, Foreground = Brush("V2MutedForegroundBrush"), TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, MaxWidth = 420 },
        },
    };

    private FrameworkElement ChatEmptyPrompt(string title, string detail) => new StackPanel
    {
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Top,
        Margin = new Thickness(0, 0, 0, 34),
        Spacing = 10,
        MaxWidth = V2LayoutMetrics.ComposerMaxWidth,
        Children =
        {
            new TextBlock
            {
                Text = title,
                FontSize = 24,
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                Foreground = Brush("V2ForegroundBrush"),
                TextAlignment = TextAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
                MaxWidth = V2LayoutMetrics.ComposerMaxWidth,
            },
            new TextBlock
            {
                Text = detail,
                FontSize = 13,
                Foreground = Brush("V2MutedForegroundBrush"),
                TextAlignment = TextAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
                MaxWidth = 520,
                Visibility = string.IsNullOrWhiteSpace(detail) ? Visibility.Collapsed : Visibility.Visible,
            },
        },
    };

    private FrameworkElement GeneralProjectEntryButton()
    {
        var button = new Button
        {
            Height = 30,
            MinWidth = 0,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 8, 0, 0),
            Padding = new Thickness(10, 0, 10, 0),
            CornerRadius = new CornerRadius(999),
            Background = Brush("V2CardBrush"),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Foreground = Brush("V2SecondaryForegroundBrush"),
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 7,
                Children =
                {
                    Icon("FolderPlus", 13, Brush("V2MutedForegroundBrush")),
                    new TextBlock
                    {
                        Text = T("chat.empty.enterProjectWork"),
                        FontSize = 12.5,
                        FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                        VerticalAlignment = VerticalAlignment.Center,
                    },
                    Icon("ChevronDown", 11, Brush("V2MutedForegroundBrush")),
                },
            },
        };
        button.Flyout = GeneralProjectEntryFlyout();
        return button;
    }

    private Flyout GeneralProjectEntryFlyout()
    {
        var flyout = new Flyout
        {
            Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.Top,
        };
        var queryBox = new TextBox
        {
            PlaceholderText = T("chat.empty.searchProjects"),
            Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
        };
        var projectList = new StackPanel { Spacing = 2 };

        void RenderProjects()
        {
            projectList.Children.Clear();
            var projects = GeneralProjectEntryPresentation.Projects(State.Projects, State.Settings.ProjectSortOrder);
            var filtered = GeneralProjectEntryPresentation.FilteredProjects(projects, queryBox.Text);
            if (filtered.Count == 0)
            {
                projectList.Children.Add(new TextBlock
                {
                    Text = T("chat.empty.noProjectsFound"),
                    FontSize = 12,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    Padding = new Thickness(10, 8, 10, 8),
                });
                return;
            }

            foreach (var project in filtered)
            {
                var item = new Button
                {
                    Background = Transparent,
                    BorderBrush = Transparent,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Stretch,
                    Padding = new Thickness(10, 0, 10, 0),
                    Height = 32,
                    CornerRadius = new CornerRadius(6),
                    Content = new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        Spacing = 9,
                        Children =
                        {
                            Icon("Folder", 13, Brush("V2MutedForegroundBrush")),
                            new TextBlock
                            {
                                Text = project.DisplayName,
                                FontSize = 13,
                                Foreground = Brush("V2ForegroundBrush"),
                                TextTrimming = TextTrimming.CharacterEllipsis,
                                VerticalAlignment = VerticalAlignment.Center,
                            },
                        },
                    },
                };
                item.Click += (_, _) =>
                {
                    flyout.Hide();
                    StartSession(project);
                };
                projectList.Children.Add(item);
            }
        }

        queryBox.TextChanged += (_, _) => RenderProjects();
        RenderProjects();

        var addProject = new Button
        {
            Background = Transparent,
            BorderBrush = Transparent,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(10, 0, 10, 0),
            Height = 32,
            CornerRadius = new CornerRadius(6),
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 9,
                Children =
                {
                    Icon("FolderPlus", 13, Brush("V2MutedForegroundBrush")),
                    new TextBlock
                    {
                        Text = T("chat.empty.addNewProject"),
                        FontSize = 13,
                        FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                        Foreground = Brush("V2ForegroundBrush"),
                        VerticalAlignment = VerticalAlignment.Center,
                    },
                    Icon("ChevronRight", 11, Brush("V2MutedForegroundBrush")),
                },
            },
        };
        addProject.Click += async (_, _) =>
        {
            flyout.Hide();
            await CreateProjectAsync();
        };

        flyout.Content = new StackPanel
        {
            Width = 300,
            Padding = new Thickness(10),
            Spacing = 8,
            Children =
            {
                queryBox,
                new ScrollViewer
                {
                    MaxHeight = 230,
                    VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                    Content = projectList,
                },
                new Border
                {
                    Height = 1,
                    Background = Brush("V2BorderBrush"),
                },
                addProject,
            },
        };
        return flyout;
    }

    private FrameworkElement ReadOnlyBackgroundFooter() => new Border
    {
        HorizontalAlignment = HorizontalAlignment.Center,
        BorderBrush = Brush("V2BorderBrush"),
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(999),
        Background = Brush("V2CardBrush"),
        Padding = new Thickness(12, 7, 12, 7),
        Child = new TextBlock
        {
            Text = T("chat.readOnlyBackground.footer"),
            FontSize = 12,
            Foreground = Brush("V2SecondaryForegroundBrush"),
        },
    };

    private FrameworkElement ErrorState(string message) => new Border
    {
        CornerRadius = new CornerRadius(8),
        BorderBrush = Brush("V2RedBrush"),
        BorderThickness = new Thickness(1),
            Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(28, 239, 68, 68)),
        Padding = new Thickness(12),
        Child = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, FontSize = 13, Foreground = Brush("V2RedBrush") },
    };

    private TextBlock MutedText(string text, double size, Thickness margin) => new()
    {
        Text = text,
        FontSize = size,
        Foreground = Brush("V2MutedForegroundBrush"),
        Margin = margin,
    };

    private Button TinyIconButton(string iconKey, RoutedEventHandler handler)
    {
        var button = new Button
        {
            Style = (Style)Application.Current.Resources["V2IconButtonStyle"],
            Width = 24,
            Height = 24,
            Content = Icon(iconKey, 14, Brush("V2MutedForegroundBrush")),
        };
        button.Click += handler;
        return button;
    }

    private Button ComposerIconButton(string iconKey, string tooltip)
    {
        var button = new Button
        {
            Width = 28,
            Height = 28,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(6),
            Background = Transparent,
            BorderBrush = Transparent,
            Foreground = Brush("V2MutedForegroundBrush"),
            Content = Icon(iconKey, 16, Brush("V2MutedForegroundBrush")),
        };
        ToolTipService.SetToolTip(button, tooltip);
        return button;
    }

    private Button ComposerPillButton(string iconKey, string label) => new()
    {
        Height = 28,
        MinWidth = 0,
        MaxWidth = 190,
        Padding = new Thickness(8, 0, 8, 0),
        CornerRadius = new CornerRadius(6),
        Background = Transparent,
        BorderBrush = Transparent,
        Foreground = Brush("V2SecondaryForegroundBrush"),
        Content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Children =
            {
                Icon(iconKey, 16, Brush("V2MutedForegroundBrush")),
                new TextBlock
                {
                    Text = label,
                    FontSize = 12,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    VerticalAlignment = VerticalAlignment.Center,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                },
                Icon("ChevronDown", 14, Brush("V2MutedForegroundBrush")),
            },
        },
    };

    private FrameworkElement Icon(string key, double size, Brush? foreground = null) =>
        V2IconCatalog.Icon(key, size, foreground ?? Brush("V2MutedForegroundBrush"));

    private FrameworkElement IconText(string iconKey, string text, double iconSize, Brush? iconBrush = null) => new StackPanel
    {
        Orientation = Orientation.Horizontal,
        Spacing = 6,
        VerticalAlignment = VerticalAlignment.Center,
        Children =
        {
            Icon(iconKey, iconSize, iconBrush ?? Brush("V2MutedForegroundBrush")),
            new TextBlock { Text = text, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Foreground = iconBrush ?? Brush("V2SecondaryForegroundBrush") },
        },
    };

    private void InitializeStaticIcons()
    {
        CollapseSidebarButton.Content = Icon("PanelLeftClose", 16, Brush("V2MutedForegroundBrush"));
        OpenSidebarButton.Content = Icon("PanelLeftOpen", 16, Brush("V2MutedForegroundBrush"));
        SettingsButton.Content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children =
            {
                Icon("Settings", 16, Brush("V2MutedForegroundBrush")),
                new TextBlock { Text = T("sidebar.settings"), FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold },
            },
        };
    }

    private async void UpdateLogo()
    {
        var logo = RootGrid.ActualTheme == ElementTheme.Dark ? "9gclaw-logo-white.png" : "9gclaw-logo.png";
        var logoPath = Path.Combine(AppContext.BaseDirectory, "Assets", logo);
        if (!File.Exists(logoPath))
        {
            LogoImage.Source = new BitmapImage(new Uri($"ms-appx:///Assets/{logo}"));
            return;
        }

        try
        {
            var file = await StorageFile.GetFileFromPathAsync(logoPath);
            using var stream = await file.OpenAsync(FileAccessMode.Read);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
            var source = new SoftwareBitmapSource();
            await source.SetBitmapAsync(bitmap);
            LogoImage.Source = source;
        }
        catch
        {
            LogoImage.Source = new BitmapImage(new Uri($"ms-appx:///Assets/{logo}"));
        }
    }

    private void SyncSidebarSectionWithProject(WorkspaceProject? project)
    {
        if (project is null) return;
        var nextSection = IsGeneralProject(project) ? SidebarSection.General : SidebarSection.Projects;
        var lastProjectId = IsGeneralProject(project) ? _uiSettings.LastProjectId : project.Id.ToString();
        if (_uiSettings.SidebarSection != nextSection || _uiSettings.LastProjectId != lastProjectId)
        {
            _uiSettings = _uiSettings with
            {
                SidebarSection = nextSection,
                LastProjectId = lastProjectId,
            };
        }
    }

    private async Task OpenWorkspacePreviewAsync(string path)
    {
        try
        {
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            await Dialog(T("common.failed"), new TextBlock { Text = ex.Message, TextWrapping = TextWrapping.Wrap }, T("common.ok")).ShowAsync();
        }
    }

    private void ApplyStartupSidebarSelection()
    {
        if (_uiSettings.SidebarSection == SidebarSection.General)
        {
            if (V2SidebarProjection.GeneralProject(State.Projects) is { } general)
            {
                State.SelectProject(general);
            }
            return;
        }

        if (!RestoreLastProjectSelection())
        {
            SyncSidebarSectionWithProject(State.SelectedProject);
        }
    }

    private bool RestoreLastProjectSelection()
    {
        if (State.SelectedProject is { } selected && !IsGeneralProject(selected)) return false;
        var projects = V2SidebarProjection.ProjectSection(State.Projects, State.Settings.ProjectSortOrder);
        var project = SidebarProjectRestorationPolicy.PreferredProject(projects, _uiSettings.LastProjectId);
        if (project is null) return false;

        State.SelectProject(project);
        RestoreComposerPermissionMode(null);
        _expandedProjectNames.Add(project.Name);
        SyncSidebarSectionWithProject(project);
        return true;
    }

    private string ChatEmptyStateTitle()
    {
        var titleKey = ChatEmptyStatePresentation.TitleKey(State.SelectedProject);
        return titleKey == ChatEmptyStatePresentation.ProjectTitleKey && State.SelectedProject is { } project
            ? Tf(titleKey, project.DisplayName)
            : T(titleKey);
    }

    private static bool IsGeneralProject(WorkspaceProject project) =>
        V2SidebarProjection.IsGeneralProject(project);

    private void ToggleOrSelectProject(WorkspaceProject project, bool flatSessions)
    {
        if (State.SelectedProjectId != project.Id)
        {
            State.SelectProject(project);
            RestoreComposerPermissionMode(null);
            SyncSidebarSectionWithProject(project);
            RefreshNativeStores();
        }

        if (!flatSessions)
        {
            if (_expandedProjectNames.Contains(project.Name))
            {
                _expandedProjectNames.Remove(project.Name);
            }
            else
            {
                _expandedProjectNames.Add(project.Name);
            }
        }

        PersistUiSettings();
        RenderAll();
    }

    private void ToggleAllProjects()
    {
        var projects = V2SidebarProjection.ProjectSection(State.Projects, State.Settings.ProjectSortOrder);
        var allExpanded = projects.Count > 0 && projects.All(project => _expandedProjectNames.Contains(project.Name));
        foreach (var project in projects)
        {
            if (allExpanded)
            {
                _expandedProjectNames.Remove(project.Name);
            }
            else
            {
                _expandedProjectNames.Add(project.Name);
            }
        }

        PersistUiSettings();
        RenderSidebar();
    }

    private void StartSession(WorkspaceProject project)
    {
        State.SelectProject(project);
        SyncSidebarSectionWithProject(project);
        RefreshNativeStores();
        State.StartDraftSession(project);
        RestoreComposerPermissionMode(null);
        _expandedProjectNames.Add(project.Name);
        ChatLines.Clear();

        PersistUiSettings();
        RenderAll();
    }

    private void OnTabClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: V2TabDescriptor tab })
        {
            if (tab.Tab == AppTab.Preview)
            {
                State.ActiveTab = AppTab.Preview;
                State.ActivePluginTabId = tab.Id;
            }
            else
            {
                State.ActiveTab = tab.Tab;
                State.ActivePluginTabId = null;
            }

            RenderAll();
            return;
        }

        if (sender is Button { Tag: AppTab appTab })
        {
            State.ActiveTab = appTab;
            State.ActivePluginTabId = null;
            RenderAll();
        }
    }

    private async void OnSendClick(object sender, RoutedEventArgs e)
    {
        await SendComposerAsync();
    }

    private async Task SendComposerAsync()
    {
        var prompt = State.ComposerText.Trim();
        var attachments = State.PendingAttachments.ToList();
        if (string.IsNullOrWhiteSpace(prompt) && attachments.Count == 0) return;
        if (State.IsSelectedSessionReadOnlyBackground) return;

        var session = State.SelectedSession ?? State.CreateSessionForSelectedProject(
            AppState.PromptTitleFromComposerPrompt(prompt, T("sidebar.newSession")));
        if (session is null)
        {
            AppendAssistantMessage(T("chat.status.selectProjectBeforeSend"));
            RenderContent();
            return;
        }

        var priorMessages = State.CurrentMessages.ToList();
        ResolvedAgentModel resolvedModel;
        Dictionary<string, string> routeValues;
        try
        {
            var routeTier = NativeRoutingClassifier.ClassifyTier(prompt, State.ComposerRunMode);
            routeValues = CurrentNativeConfigValues();
            var routeSignals = NativeRouterRuntime.SignalsForRequest(prompt, priorMessages, attachments);
            var routeDecision = NativeRouterRuntime.DecisionForTier(routeTier, routeValues, routeSignals);
            resolvedModel = AgentModelResolver.Resolve(State.Settings, routeDecision.EntryId, routeTier, "router");
        }
        catch (Exception ex)
        {
            AppendAssistantMessage($"Provider configuration is invalid.\n\n{ex.Message}");
            RenderAll();
            return;
        }

        var apiKey = await ReadProviderSecretAsync(resolvedModel);
        var preflight = AgentModelResolver.Preflight(resolvedModel, apiKey);
        _lastProviderPreflight = preflight;
        if (!preflight.Ok)
        {
            AppendAssistantMessage(ProviderPreflightText(preflight));
            RenderAll();
            return;
        }

        var userBlocks = new List<ChatBlock>();
        if (!string.IsNullOrWhiteSpace(prompt))
        {
            userBlocks.Add(ChatBlock.FromText(prompt));
        }
        userBlocks.AddRange(attachments.Select(attachment => new ChatBlock(ChatBlockKind.Attachment, Attachment: attachment)));
        State.AppendMessage(new ChatMessage(
            Guid.NewGuid(),
            session.Id,
            SessionProvider.G9Claw,
            ChatRole.User,
            userBlocks,
            DateTimeOffset.UtcNow,
            false,
            null));
        State.ComposerText = "";
        State.PendingAttachments.Clear();
        ClearVisibleComposerText();
        _agentRunCts?.Cancel();
        var runCts = new CancellationTokenSource();
        _agentRunCts = runCts;
        _isAgentSubmitting = true;
        _isAgentRunning = false;
        _processingSessionIds.Add(session.Id);
        State.MarkSessionState(session.Id, SessionState.Processing);
        var assistantMessageId = State.BeginStreamingAssistantMessage(session.Id, forceNew: true);
        RenderAll();

        var request = CreateAgentRequest(session, prompt, attachments, resolvedModel, apiKey!, priorMessages, routeValues);
        _ = RunNativeAgentAsync(request, assistantMessageId, runCts, runCts.Token);
    }

    private void OnStopAgentClick(object sender, RoutedEventArgs e)
    {
        _agentRunCts?.Cancel();
        if (State.SelectedSessionId is { } sessionId)
        {
            _agentRunner.Interrupt(sessionId);
        }
    }

    private AgentRequest CreateAgentRequest(
        ProjectSession session,
        string prompt,
        List<FileAttachment> attachments,
        ResolvedAgentModel model,
        string apiKey,
        List<ChatMessage> priorMessages,
        IReadOnlyDictionary<string, string>? nativeConfigValues = null)
    {
        var configValues = AgentConfigValuesForModel(model, nativeConfigValues);

        return new AgentRequest(
            session.Id,
            State.SelectedProject?.RootPath ?? State.Settings.GeneralWorkspacePath,
            prompt,
            attachments,
            model.ToProviderConfig(),
            apiKey,
            priorMessages,
            State.Settings.ApiTimeoutMs,
            model.ContextWindow,
            State.ComposerPermissionMode,
            State.ComposerRunMode,
            State.Settings.Permissions,
            string.IsNullOrWhiteSpace(model.RouteEntryId) ? model.ModelEntryId : model.RouteEntryId,
            configValues);
    }

    private Dictionary<string, string> AgentConfigValuesForModel(
        ResolvedAgentModel model,
        IReadOnlyDictionary<string, string>? baseValues = null,
        RouterFallbackCandidate? fallback = null)
    {
        var router = State.Settings.RouterSettings.Normalize();
        var configValues = baseValues is null
            ? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            : new Dictionary<string, string>(baseValues, StringComparer.OrdinalIgnoreCase);
        configValues["router.inputPricePerMillion"] = router.InputPricePerMillion.ToString();
        configValues["router.outputPricePerMillion"] = router.OutputPricePerMillion.ToString();
        configValues["router.baselineInputPricePerMillion"] = router.BaselineInputPricePerMillion.ToString();
        configValues["router.baselineOutputPricePerMillion"] = router.BaselineOutputPricePerMillion.ToString();
        configValues["router.tier"] = model.RouteTier;
        configValues["router.routeEntryId"] = string.IsNullOrWhiteSpace(model.RouteEntryId) ? model.ModelEntryId : model.RouteEntryId;
        configValues["router.routeSource"] = model.RouteSource;
        configValues["provider.providerId"] = model.ProviderId;
        configValues["provider.modelEntryId"] = model.ModelEntryId;
        configValues["provider.modelName"] = model.ModelName;
        configValues["provider.endpointUrl"] = model.EndpointUrl.ToString();
        configValues["provider.requestId"] = Guid.NewGuid().ToString("N");
        if (fallback is not null)
        {
            configValues["router.fallbackFromModelEntry"] = fallback.FromModelEntryId;
            configValues["router.fallbackReason"] = fallback.Reason;
            configValues["router.finalModelEntry"] = model.ModelEntryId;
        }

        return configValues;
    }

    private Dictionary<string, string> CurrentNativeConfigValues()
    {
        var yaml = State.Settings.RawConfigDocument?.LastYaml;
        if (string.IsNullOrWhiteSpace(yaml))
        {
            yaml = NativeConfigYamlCodec.ToYaml(State.Settings);
        }

        return NativeConfigService.ScalarMap(yaml);
    }

    private async Task RunNativeAgentAsync(
        AgentRequest request,
        Guid assistantMessageId,
        CancellationTokenSource runCts,
        CancellationToken cancellationToken)
    {
        TokenBudget? lastBudget = null;
        var currentRequest = request;
        var fallbackAttempted = false;
        try
        {
            while (true)
            {
                AgentRequest? fallbackRequest = null;
                await foreach (var agentEvent in _agentRunner.RunAsync(
                    currentRequest,
                    new NativeAgentRunOptions(ShowPermissionRequestAsync),
                    cancellationToken))
                {
                    if (_isAgentSubmitting)
                    {
                        _isAgentSubmitting = false;
                        _isAgentRunning = true;
                        RenderAll();
                    }

                    switch (agentEvent.Kind)
                    {
                        case AgentEventKind.ContentDelta when agentEvent.Text is { } text:
                            State.AppendStreamingAssistantText(currentRequest.SessionId, assistantMessageId, text, lastBudget);
                            ScheduleChatRender();
                            break;
                        case AgentEventKind.ReasoningDelta when agentEvent.Text is { } reasoning:
                            State.AppendStreamingAssistantReasoning(currentRequest.SessionId, assistantMessageId, reasoning);
                            ScheduleChatRender();
                            break;
                        case AgentEventKind.ContextBudget when agentEvent.ContextBudget is { } contextBudget:
                            lastBudget = new TokenBudget(contextBudget.Used, contextBudget.Total);
                            State.UpsertContextBudget(currentRequest.SessionId, assistantMessageId, contextBudget);
                            State.AppendStreamingAssistantText(currentRequest.SessionId, assistantMessageId, "", lastBudget);
                            ScheduleChatRender();
                            break;
                        case AgentEventKind.CompactStarted when agentEvent.CompactStarted is { } compactStarted:
                            State.UpsertContextCompactionStarted(currentRequest.SessionId, assistantMessageId, compactStarted);
                            ScheduleChatRender();
                            break;
                        case AgentEventKind.CompactCompleted when agentEvent.CompactCompleted is { } compactCompleted:
                            State.CompleteContextCompaction(currentRequest.SessionId, assistantMessageId, compactCompleted);
                            ScheduleChatRender();
                            break;
                        case AgentEventKind.TokenBudget when agentEvent.TokenBudget is { } budget:
                            lastBudget = budget;
                            State.TokenBudgetBySession[currentRequest.SessionId] = budget;
                            State.AppendStreamingAssistantText(currentRequest.SessionId, assistantMessageId, "", budget);
                            ScheduleChatRender();
                            break;
                        case AgentEventKind.Status when agentEvent.Text is { } status:
                            if (status.Contains("compact", StringComparison.OrdinalIgnoreCase) ||
                                status.Contains("recover", StringComparison.OrdinalIgnoreCase))
                            {
                                _lastContextStage = status;
                                if (status.Contains("compact", StringComparison.OrdinalIgnoreCase))
                                {
                                    _contextCompactCount++;
                                }
                            }
                            break;
                        case AgentEventKind.ToolUse when agentEvent.ToolCall is { } toolCall:
                            State.AppendStreamingAssistantToolCall(currentRequest.SessionId, assistantMessageId, toolCall);
                            ScheduleChatRender();
                            break;
                        case AgentEventKind.ToolResult when agentEvent.ToolResult is { } result:
                            State.AppendStreamingAssistantToolResult(currentRequest.SessionId, assistantMessageId, result);
                            ScheduleChatRender();
                            break;
                        case AgentEventKind.SubagentStatus when agentEvent.SubagentStatus is { } subagentStatus:
                            State.UpsertSubagentStatus(currentRequest.SessionId, assistantMessageId, subagentStatus);
                            ScheduleChatRender();
                            break;
                        case AgentEventKind.TurnItemStarted or AgentEventKind.TurnItemUpdated or AgentEventKind.TurnItemCompleted
                            when agentEvent.TurnItem is { } turnItem:
                            State.UpsertTurnItem(turnItem);
                            ScheduleChatRender();
                            break;
                        case AgentEventKind.TurnStarted or AgentEventKind.TurnCompleted when agentEvent.Turn is { } turn:
                            State.UpsertTurn(turn);
                            if (agentEvent.Kind == AgentEventKind.TurnStarted)
                            {
                                State.AppendStreamingAssistantText(currentRequest.SessionId, assistantMessageId, "", lastBudget);
                            }
                            break;
                        case AgentEventKind.Error when agentEvent.Text is { } error:
                            if (!fallbackAttempted &&
                                await TryCreateRouterFallbackRequestAsync(currentRequest, error) is { } fallbackResult)
                            {
                                fallbackAttempted = true;
                                fallbackRequest = fallbackResult.Request;
                                State.AppendStreamingAssistantProviderError(
                                    currentRequest.SessionId,
                                    assistantMessageId,
                                    BuildProviderErrorInfo(currentRequest, error, fallbackResult.Candidate));
                            }
                            else
                            {
                                State.AppendStreamingAssistantProviderError(
                                    currentRequest.SessionId,
                                    assistantMessageId,
                                    BuildProviderErrorInfo(currentRequest, error, null));
                            }
                            ScheduleChatRender();
                            break;
                        case AgentEventKind.Abort when agentEvent.Text is { } reason:
                            State.AppendStreamingAssistantText(currentRequest.SessionId, assistantMessageId, reason, lastBudget);
                            ScheduleChatRender();
                            break;
                    }
                }

                if (fallbackRequest is null)
                {
                    break;
                }

                currentRequest = fallbackRequest;
                State.AppendStreamingAssistantText(currentRequest.SessionId, assistantMessageId, "", lastBudget);
                ScheduleChatRender();
            }

            State.FinishStreamingAssistantMessage(currentRequest.SessionId, assistantMessageId);
            if (lastBudget is not null)
            {
                State.RoutingUsage.Add(RoutingUsageEstimator.FromBudget(currentRequest, State.SelectedProject, lastBudget));
            }
        }
        finally
        {
            State.FinishStreamingAssistantMessage(request.SessionId, assistantMessageId);
            var isCurrentRun = ReferenceEquals(_agentRunCts, runCts);
            if (isCurrentRun)
            {
                _isAgentSubmitting = false;
                _isAgentRunning = false;
                _processingSessionIds.Remove(request.SessionId);
                State.MarkSessionState(request.SessionId, SessionState.Idle);
            }

            runCts.Dispose();
            if (isCurrentRun)
            {
                _agentRunCts = null;
                RenderAll();
            }
        }
    }

    private async Task<(AgentRequest Request, RouterFallbackCandidate Candidate)?> TryCreateRouterFallbackRequestAsync(
        AgentRequest failedRequest,
        string error)
    {
        var failedModel = ModelFromRequest(failedRequest);
        var candidate = RouterFallbackPolicy.TryResolve(State.Settings, failedRequest.NativeConfigValues, failedModel, error);
        if (candidate is null) return null;

        var apiKey = await ReadProviderSecretAsync(candidate.Model);
        var preflight = AgentModelResolver.Preflight(candidate.Model, apiKey);
        if (!preflight.Ok) return null;

        var configValues = AgentConfigValuesForModel(candidate.Model, failedRequest.NativeConfigValues, candidate);
        var fallbackRequest = failedRequest with
        {
            ProviderConfig = candidate.Model.ToProviderConfig(),
            ApiKey = apiKey!,
            ContextWindow = candidate.Model.ContextWindow,
            RouterRoute = string.IsNullOrWhiteSpace(candidate.Model.RouteEntryId) ? candidate.Model.ModelEntryId : candidate.Model.RouteEntryId,
            NativeConfigValues = configValues,
        };

        return (fallbackRequest, candidate);
    }

    private static ResolvedAgentModel ModelFromRequest(AgentRequest request)
    {
        var values = request.NativeConfigValues;
        return new ResolvedAgentModel(
            values.GetValueOrDefault("provider.providerId", "g9claw"),
            values.GetValueOrDefault("provider.modelEntryId", "default"),
            request.ProviderConfig.ApiType,
            request.ProviderConfig.BaseUrl,
            NativeAgentRuntime.EndpointUrl(request.ProviderConfig.BaseUrl, AgentModelResolver.SuffixFor(request.ProviderConfig.ApiType)),
            request.ProviderConfig.Model,
            request.ProviderConfig.SecretAccount,
            new Dictionary<string, string>(request.ProviderConfig.Headers, StringComparer.OrdinalIgnoreCase),
            request.ContextWindow,
            values.GetValueOrDefault("router.tier", "direct"),
            values.GetValueOrDefault("router.routeEntryId", values.GetValueOrDefault("provider.modelEntryId", "default")),
            values.GetValueOrDefault("router.routeSource", "agent"));
    }

    private static ProviderErrorInfo BuildProviderErrorInfo(
        AgentRequest request,
        string error,
        RouterFallbackCandidate? fallback)
    {
        var values = request.NativeConfigValues;
        var provider = values.GetValueOrDefault("provider.providerId", request.ProviderConfig.Provider.DisplayName());
        var modelEntry = values.GetValueOrDefault("provider.modelEntryId", "default");
        var model = request.ProviderConfig.Model;
        var endpoint = values.GetValueOrDefault("provider.endpointUrl", request.ProviderConfig.BaseUrl);
        var requestId = values.GetValueOrDefault("provider.requestId", "");
        var tier = values.GetValueOrDefault("router.tier", "direct");
        var summary = fallback is null
            ? $"Provider request failed: {ShortProviderError(error)}"
            : $"Router fallback: {tier} -> {modelEntry}:{model} failed; retrying {fallback.Model.ModelEntryId}:{fallback.Model.ModelName}.";
        return new ProviderErrorInfo(
            summary,
            error,
            provider,
            modelEntry,
            model,
            endpoint,
            requestId,
            tier,
            fallback?.FromModelEntryId,
            fallback?.Model.ModelEntryId,
            fallback?.Reason);
    }

    private static string ShortProviderError(string error)
    {
        var compact = (error ?? "").Replace("\r", " ").Replace("\n", " ").Trim();
        return compact.Length <= 220 ? compact : $"{compact[..220]}...";
    }

    private Task<PermissionRecord> ShowPermissionRequestAsync(PermissionRequest request, CancellationToken cancellationToken)
    {
        var completion = new TaskCompletionSource<PermissionRecord>(TaskCreationOptions.RunContinuationsAsynchronously);
        var registration = cancellationToken.Register(() => completion.TrySetCanceled(cancellationToken));
        completion.Task.ContinueWith(_ => registration.Dispose(), TaskScheduler.Default);
        if (!DispatcherQueue.TryEnqueue(async () =>
            {
                try
                {
                    completion.TrySetResult(await ShowPermissionRequestOnUiAsync(request, cancellationToken));
                }
                catch (Exception ex)
                {
                    completion.TrySetException(ex);
                }
            }))
        {
            completion.TrySetResult(new PermissionRecord(request, PermissionDecision.Denied, null, DateTimeOffset.UtcNow, null));
        }

        return completion.Task;
    }

    private async Task<PermissionRecord> ShowPermissionRequestOnUiAsync(PermissionRequest request, CancellationToken cancellationToken)
    {
        if (!State.PendingPermissions.Any(item => item.Id == request.Id))
        {
            State.PendingPermissions.Add(request);
        }
        RenderAll();
        if (request.Kind is PermissionRequestKind.Tool or PermissionRequestKind.AskUserQuestion or PermissionRequestKind.ExitPlanMode or PermissionRequestKind.DestructivePlanApproval)
        {
            return await AwaitInlinePermissionRequestAsync(request, cancellationToken);
        }

        var details = new StackPanel
        {
            Spacing = 8,
            Children =
            {
                new TextBlock { Text = request.Reason, TextWrapping = TextWrapping.Wrap, Foreground = Brush("V2ForegroundBrush") },
                new TextBlock { Text = request.ToolName, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = Brush("V2MutedForegroundBrush") },
                new TextBox
                {
                    Text = request.InputJson,
                    AcceptsReturn = true,
                    IsReadOnly = true,
                    MaxHeight = 180,
                    TextWrapping = TextWrapping.Wrap,
                    Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
                },
            },
        };
        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = T("chat.permission.title"),
            Content = details,
            PrimaryButtonText = T("chat.permission.allowOnce"),
            SecondaryButtonText = T("chat.permission.allowProject"),
            CloseButtonText = T("chat.permission.deny"),
            DefaultButton = ContentDialogButton.Primary,
        };
        var result = await dialog.ShowAsync();
        State.PendingPermissions.Remove(request);
        return result switch
        {
            ContentDialogResult.Primary => new PermissionRecord(request, PermissionDecision.Allowed, PermissionScope.Session, DateTimeOffset.UtcNow, null),
            ContentDialogResult.Secondary => new PermissionRecord(request, PermissionDecision.Allowed, PermissionScope.Project, DateTimeOffset.UtcNow, null),
            _ => new PermissionRecord(request, PermissionDecision.Denied, null, DateTimeOffset.UtcNow, null),
        };
    }

    private async Task<PermissionRecord> AwaitInlinePermissionRequestAsync(PermissionRequest request, CancellationToken cancellationToken)
    {
        var completion = new TaskCompletionSource<PermissionRecord>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pendingPermissionCompletions[request.Id] = completion;
        using var registration = cancellationToken.Register(() =>
        {
            if (!DispatcherQueue.TryEnqueue(async () =>
                {
                    await ResolveInlinePermissionRequestAsync(request, PermissionDecision.Denied, null, null);
                }))
            {
                completion.TrySetCanceled(cancellationToken);
            }
        });
        RenderContent();
        return await completion.Task;
    }

    private async Task ResolveInlinePermissionRequestAsync(
        PermissionRequest request,
        PermissionDecision decision,
        PermissionScope? grantedScope,
        string? response,
        bool remember = false)
    {
        if (!_pendingPermissionCompletions.Remove(request.Id, out var completion)) return;
        State.PendingPermissions.RemoveAll(item => item.Id == request.Id);
        ClearInlinePermissionState(request.Id);

        if (decision == PermissionDecision.Allowed && remember)
        {
            State.Settings = State.Settings with
            {
                Permissions = PermissionSettingsMutation.GrantAllowedToolFromChat(State.Settings.Permissions, request.ToolName),
            };
            await _settingsStore.SaveAsync(State.Settings);
        }

        State.StatusLine = decision == PermissionDecision.Allowed
            ? $"Permission allowed: {request.ToolName}"
            : $"Permission denied: {request.ToolName}";
        completion.TrySetResult(new PermissionRecord(request, decision, grantedScope, DateTimeOffset.UtcNow, response));
        RenderAll();
    }

    private async Task<string?> ReadProviderSecretAsync(ResolvedAgentModel model)
    {
        try
        {
            var secret = await _credentialStore.ReadSecretAsync(model.SecretAccount);
            return string.Equals(secret?.Trim(), "********", StringComparison.Ordinal) ? null : secret;
        }
        catch
        {
            return null;
        }
    }

    private async Task<string?> ReadProviderSecretAsync()
    {
        try
        {
            return await ReadProviderSecretAsync(AgentModelResolver.Resolve(State.Settings));
        }
        catch
        {
            var secret = await _credentialStore.ReadSecretAsync(State.Settings.ProviderConfig.SecretAccount);
            return string.Equals(secret?.Trim(), "********", StringComparison.Ordinal) ? null : secret;
        }
    }

    private void AppendAssistantMessage(string text, string? sessionId = null)
    {
        var targetSessionId = sessionId ?? State.SelectedSessionId;
        if (targetSessionId is null) return;
        State.AppendMessage(new ChatMessage(
            Guid.NewGuid(),
            targetSessionId,
            SessionProvider.G9Claw,
            ChatRole.Assistant,
            [ChatBlock.FromText(text)],
            DateTimeOffset.UtcNow,
            false,
            null));
    }

    private void AppendToolMessage(string sessionId, AgentToolCall call)
    {
        State.AppendMessage(new ChatMessage(
            Guid.NewGuid(),
            sessionId,
            SessionProvider.G9Claw,
            ChatRole.Tool,
            [new ChatBlock(ChatBlockKind.ToolCall, ToolCall: call)],
            DateTimeOffset.UtcNow,
            false,
            null));
    }

    private void AppendToolResultMessage(string sessionId, AgentToolResult result)
    {
        State.AppendMessage(new ChatMessage(
            Guid.NewGuid(),
            sessionId,
            SessionProvider.G9Claw,
            ChatRole.Tool,
            [new ChatBlock(ChatBlockKind.ToolResult, ToolResult: result)],
            DateTimeOffset.UtcNow,
            false,
            null));
    }

    private string AgentComposerStatus()
    {
        if (_isAgentRunning) return T("chat.status.streaming");
        if (State.SelectedProject is null) return T("chat.status.selectProject");
        ResolvedAgentModel model;
        try
        {
            model = AgentModelResolver.Resolve(State.Settings);
        }
        catch
        {
            return _lastProviderPreflight is { Ok: false } failed
                ? failed.Diagnostic
                : T("chat.status.providerMissing");
        }

        if (string.IsNullOrWhiteSpace(model.BaseUrl)) return T("chat.status.providerMissing");
        if (string.IsNullOrWhiteSpace(model.ModelName)) return T("chat.status.modelMissing");
        var mode = State.ComposerRunMode == ChatRunMode.Plan ? "Plan" : "Agent";
        if (_lastProviderPreflight is { Ok: false } preflight &&
            string.Equals(preflight.ModelEntryId, model.ModelEntryId, StringComparison.OrdinalIgnoreCase))
        {
            return $"{mode} / {model.DisplayLabel} - {preflight.Diagnostic}";
        }

        return $"{mode} / {model.DisplayLabel} - ~/.g9claw/config.yaml";
    }

    private bool IsAgentModelConfigured()
    {
        if (_lastProviderPreflight is { } preflight)
        {
            return preflight.Ok;
        }

        try
        {
            var model = AgentModelResolver.Resolve(State.Settings);
            return !string.IsNullOrWhiteSpace(model.BaseUrl) && !string.IsNullOrWhiteSpace(model.ModelName);
        }
        catch
        {
            return false;
        }
    }

    private static string ProviderPreflightText(ProviderPreflightResult preflight)
    {
        var builder = new StringBuilder()
            .AppendLine("Provider configuration is not ready.")
            .AppendLine()
            .AppendLine(preflight.Diagnostic);
        if (!string.IsNullOrWhiteSpace(preflight.ProviderId)) builder.AppendLine($"provider: {preflight.ProviderId}");
        if (!string.IsNullOrWhiteSpace(preflight.ModelEntryId)) builder.AppendLine($"model entry: {preflight.ModelEntryId}");
        if (!string.IsNullOrWhiteSpace(preflight.EndpointUrl)) builder.AppendLine($"endpoint: {preflight.EndpointUrl}");
        if (!string.IsNullOrWhiteSpace(preflight.SuggestedFix))
        {
            builder.AppendLine($"fix: {preflight.SuggestedFix}");
        }

        return builder.ToString().TrimEnd();
    }

    private async Task RefreshProviderPreflightAsync()
    {
        try
        {
            var model = AgentModelResolver.Resolve(State.Settings);
            var apiKey = await ReadProviderSecretAsync(model);
            _lastProviderPreflight = AgentModelResolver.Preflight(State.Settings, apiKey);
        }
        catch (Exception ex)
        {
            _lastProviderPreflight = ProviderPreflightResult.Failure(null, ex.Message, "Fix ~/.g9claw/config.yaml or Settings.");
        }
    }

    private static string ProviderErrorText(AgentRequest request, string error)
    {
        var values = request.NativeConfigValues;
        var builder = new StringBuilder()
            .AppendLine(error)
            .AppendLine()
            .AppendLine("Provider diagnostics:")
            .AppendLine($"provider: {values.GetValueOrDefault("provider.providerId", request.ProviderConfig.Provider.DisplayName())}")
            .AppendLine($"model entry: {values.GetValueOrDefault("provider.modelEntryId", "default")}")
            .AppendLine($"model: {request.ProviderConfig.Model}")
            .AppendLine($"endpoint: {values.GetValueOrDefault("provider.endpointUrl", request.ProviderConfig.BaseUrl)}")
            .AppendLine($"request id: {values.GetValueOrDefault("provider.requestId", "")}");
        return builder.ToString().TrimEnd();
    }

    private void OnLogoClick(object sender, RoutedEventArgs e)
    {
        if (V2SidebarProjection.GeneralProject(State.Projects) is { } general)
        {
            State.SelectProject(general);
            RestoreComposerPermissionMode(null);
            _uiSettings = _uiSettings with { SidebarSection = SidebarSection.General };
        }
        else
        {
            State.ActiveTab = AppTab.Chat;
        }

        PersistUiSettings();
        RenderAll();
    }

    private void OnCollapseSidebarClick(object sender, RoutedEventArgs e)
    {
        _isSidebarVisible = false;
        PersistUiPreferences();
        RenderAll();
    }

    private void OnOpenSidebarClick(object sender, RoutedEventArgs e)
    {
        _isSidebarVisible = true;
        PersistUiPreferences();
        RenderAll();
    }

    private void OnProjectsSectionClick(object sender, RoutedEventArgs e)
    {
        _uiSettings = _uiSettings with { SidebarSection = SidebarSection.Projects };
        if (RestoreLastProjectSelection())
        {
            RefreshNativeStores();
        }
        PersistUiSettings();
        RenderAll();
    }

    private void OnGeneralSectionClick(object sender, RoutedEventArgs e)
    {
        _uiSettings = _uiSettings with { SidebarSection = SidebarSection.General };
        if (V2SidebarProjection.GeneralProject(State.Projects) is { } general)
        {
            State.SelectProject(general);
            RestoreComposerPermissionMode(null);
        }

        PersistUiSettings();
        RenderAll();
    }

    private async void OnSettingsClick(object sender, RoutedEventArgs e) => await ShowSettingsAsync(SettingsMainTab.Appearance);

    private async void OnCreateProjectRequested() => await CreateProjectAsync();

    private async Task CreateProjectAsync()
    {
        var nameBox = new TextBox
        {
            Header = T("project.displayName"),
            Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
            MinHeight = ProjectCreationWizardMetrics.FieldHeight,
        };
        var pathBox = new TextBox
        {
            Header = T("project.workspacePath"),
            Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
            Text = State.Settings.WorkspacesRoot,
            MinHeight = ProjectCreationWizardMetrics.FieldHeight,
        };
        var browse = new Button
        {
            Style = (Style)Application.Current.Resources["V2IconButtonStyle"],
            Width = ProjectCreationWizardMetrics.BrowseButtonWidth,
            Height = ProjectCreationWizardMetrics.FieldHeight,
            CornerRadius = new CornerRadius(6),
            BorderBrush = Brush("V2BorderBrush"),
            Background = Brush("V2CardBrush"),
            Content = Icon("Folder", 13, Brush("V2SecondaryForegroundBrush")),
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        ToolTipService.SetToolTip(browse, T("common.browse"));
        browse.Click += async (_, _) =>
        {
            var picker = new FolderPicker();
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
            picker.FileTypeFilter.Add("*");
            var folder = await picker.PickSingleFolderAsync();
            if (folder is not null)
            {
                pathBox.Text = folder.Path;
                if (string.IsNullOrWhiteSpace(nameBox.Text))
                {
                    nameBox.Text = Path.GetFileName(folder.Path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
                }
            }
        };
        var pathRow = new Grid
        {
            ColumnSpacing = 8,
        };
        pathRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        pathRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        pathRow.Children.Add(pathBox);
        Grid.SetColumn(browse, 1);
        pathRow.Children.Add(browse);

        var stack = new StackPanel
        {
            Spacing = 12,
            MinHeight = ProjectCreationWizardMetrics.ContentMinHeight,
            MaxWidth = ProjectCreationWizardMetrics.FormMaxWidth,
            Padding = new Thickness(ProjectCreationWizardMetrics.ContentPadding),
        };
        stack.Children.Add(nameBox);
        stack.Children.Add(pathRow);

        var dialog = Dialog(T("project.createTitle"), stack, T("common.create"));
        dialog.MaxWidth = ProjectCreationWizardMetrics.MaxWidth;
        var result = await dialog.ShowAsync();
        if (result != ContentDialogResult.Primary) return;

        var validation = _workspaceService.ValidateWorkspacePath(pathBox.Text);
        if (!validation.Valid || validation.ResolvedPath is null)
        {
            await Dialog(T("project.invalidTitle"), new TextBlock { Text = validation.Error ?? T("project.invalidPath"), TextWrapping = TextWrapping.Wrap }, T("common.ok")).ShowAsync();
            return;
        }

        Directory.CreateDirectory(validation.ResolvedPath);
        var displayName = string.IsNullOrWhiteSpace(nameBox.Text)
            ? Path.GetFileName(validation.ResolvedPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar))
            : nameBox.Text.Trim();
        var project = new WorkspaceProject(
            Guid.NewGuid(),
            WorkspaceService.ProjectNameFor(validation.ResolvedPath),
            displayName,
            validation.ResolvedPath,
            [],
            [],
            [],
            [],
            DateTimeOffset.UtcNow,
            DateTimeOffset.UtcNow);
        State.Projects.Add(project);
        State.SelectProject(project);
        RestoreComposerPermissionMode(null);
        SyncSidebarSectionWithProject(project);
        _expandedProjectNames.Add(project.Name);
        _uiSettings = _uiSettings with { SidebarSection = SidebarSection.Projects };
        PersistUiSettings();
        RenderAll();
    }

    private async Task RenameProjectAsync(WorkspaceProject project)
    {
        var box = new TextBox { Text = project.DisplayName, Style = (Style)Application.Current.Resources["V2TextBoxStyle"] };
        var dialog = Dialog(T("project.renameTitle"), box, T("common.rename"));
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var next = box.Text.Trim();
        if (string.IsNullOrWhiteSpace(next)) return;
        var index = State.Projects.IndexOf(project);
        if (index < 0) return;
        State.Projects[index] = project with { DisplayName = next };
        RenderAll();
    }

    private async Task DeleteProjectAsync(WorkspaceProject project)
    {
        var dialog = Dialog(T("project.deleteTitle"), new TextBlock
        {
            Text = Tf("project.deleteConfirm", project.DisplayName),
            TextWrapping = TextWrapping.Wrap,
        }, T("common.delete"));
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        State.Projects.Remove(project);
        _expandedProjectNames.Remove(project.Name);
        if (State.SelectedProjectId == project.Id)
        {
            State.SelectedProjectId = State.Projects.FirstOrDefault()?.Id;
            State.SelectedSessionId = null;
            RestoreComposerPermissionMode(null);
            SyncSidebarSectionWithProject(State.SelectedProject);
        }

        PersistUiSettings();
        RenderAll();
    }

    private async Task RenameSessionAsync(WorkspaceProject project, ProjectSession session)
    {
        var box = new TextBox { Text = session.DisplayTitle, Style = (Style)Application.Current.Resources["V2TextBoxStyle"] };
        var dialog = Dialog(T("session.renameTitle"), box, T("common.rename"));
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var next = box.Text.Trim();
        if (string.IsNullOrWhiteSpace(next)) return;
        ReplaceSession(project, session, session with { Title = next });
        RenderAll();
    }

    private async Task DeleteSessionAsync(WorkspaceProject project, ProjectSession session)
    {
        var dialog = Dialog(T("session.deleteTitle"), new TextBlock
        {
            Text = Tf("session.deleteConfirm", session.DisplayTitle, project.DisplayName),
            TextWrapping = TextWrapping.Wrap,
        }, T("common.delete"));
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        project.Sessions.Remove(session);
        project.CodexSessions.Remove(session);
        project.CursorSessions.Remove(session);
        project.GeminiSessions.Remove(session);
        if (State.SelectedSessionId == session.Id)
        {
            State.SelectedSessionId = null;
            RestoreComposerPermissionMode(null);
        }

        ChatLines.Clear();
        RenderAll();
    }

    private void ReplaceSession(WorkspaceProject project, ProjectSession oldSession, ProjectSession newSession)
    {
        static bool Replace(List<ProjectSession> list, ProjectSession oldSession, ProjectSession newSession)
        {
            var index = list.IndexOf(oldSession);
            if (index < 0) return false;
            list[index] = newSession;
            return true;
        }

        _ = Replace(project.Sessions, oldSession, newSession)
        || Replace(project.CodexSessions, oldSession, newSession)
        || Replace(project.CursorSessions, oldSession, newSession)
        || Replace(project.GeminiSessions, oldSession, newSession);
    }

    private async Task ShowSettingsAsync(SettingsMainTab? initialTab = null)
    {
        if (initialTab is { } tab)
        {
            State.OpenSettings(tab);
        }

        var existingSecret = await ReadProviderSecretAsync() ?? "";
        var draft = NativeSettingsDraft.From(State.Settings, existingSecret);

        var colorScheme = EnumCombo(draft.ColorScheme);
        var language = EnumCombo(draft.Language);
        var sortOrder = EnumCombo(draft.ProjectSortOrder);
        var wordWrap = Check(T("settings.appearance.wordWrap"), draft.EditorWordWrap);
        var minimap = Check(T("settings.appearance.showMinimap"), draft.EditorShowMinimap);
        var lineNumbers = Check(T("settings.appearance.lineNumbers"), draft.EditorLineNumbers);
        var editorFont = IntCombo(NativeAppearanceSettingsLayout.FontSizeOptions, draft.EditorFontSize, "px", 96);
        var autoExpandTools = Check(T("settings.preferences.autoExpandTools"), State.UiPreferences.AutoExpandTools);
        var showRawParameters = Check(T("settings.preferences.showRawParameters"), State.UiPreferences.ShowRawParameters);
        var showThinking = Check(T("settings.preferences.showThinking"), State.UiPreferences.ShowThinking);
        var autoScrollToBottom = Check(T("settings.preferences.autoScrollToBottom"), State.UiPreferences.AutoScrollToBottom);
        var sendByCtrlEnter = Check(T("settings.preferences.sendByCtrlEnter"), State.UiPreferences.SendByCtrlEnter);

        var allowedTools = Area(string.Join(Environment.NewLine, draft.AllowedTools));
        var disallowedTools = Area(string.Join(Environment.NewLine, draft.DisallowedTools));
        var permissionsJson = Area("");
        permissionsJson.MinHeight = 86;
        permissionsJson.PlaceholderText = T("settings.permissions.jsonPlaceholder");

        var apiType = EnumCombo(draft.ApiType);
        var baseUrl = Box(draft.BaseUrl, "https://api.openai.com/v1");
        var model = Box(draft.Model, "gpt-5.2");
        var apiKey = new PasswordBox
        {
            PlaceholderText = string.IsNullOrWhiteSpace(existingSecret) ? T("settings.config.apiKey") : $"Stored: {SettingsSecurity.MaskSecret(existingSecret)}",
            FontSize = 13,
            Height = 34,
            MinWidth = 0,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            CornerRadius = new CornerRadius(8),
        };
        var workspaceRoot = Box(draft.WorkspacesRoot, @"C:\Users\you\Workspace");
        var generalWorkspace = Box(draft.GeneralWorkspacePath, @"C:\Users\you\G9Claw\general");
        var databasePath = Box(draft.RuntimeSettings?.DatabasePath ?? State.Settings.RuntimeSettings?.DatabasePath ?? "", @"%LOCALAPPDATA%\G9Claw\g9claw.db");
        var httpsProxy = Box(draft.RuntimeSettings?.HttpsProxy ?? State.Settings.RuntimeSettings?.HttpsProxy ?? "", "http://127.0.0.1:7890");
        var timeout = Box(draft.ApiTimeoutMs.ToString(), "90000");
        var contextWindow = Box(draft.ContextWindow.ToString(), "160000");
        var routerEnabled = Check(T("settings.config.enableRouter"), draft.RouterEnabled);
        var routerLog = Check(T("settings.config.routerLog"), State.Settings.RouterSettings.Log);
        var routerHost = Box(State.Settings.RouterSettings.Host, "127.0.0.1");
        var routerPort = Box(State.Settings.RouterSettings.Port.ToString(), "19080");
        var routerRoute = Box(draft.RouterDefaultRoute, "default");
        var inputPrice = Box(draft.RouterInputPricePerMillion.ToString(), "0");
        var outputPrice = Box(draft.RouterOutputPricePerMillion.ToString(), "0");
        var baselineInput = Box(draft.RouterBaselineInputPricePerMillion.ToString(), "0");
        var baselineOutput = Box(draft.RouterBaselineOutputPricePerMillion.ToString(), "0");
        var memoryEnabled = Check(T("settings.config.memoryEnabled"), draft.MemoryEnabled);
        var memory = draft.MemorySettings ?? NativeMemorySettings.Defaults;
        var memoryModel = Box(memory.ModelEntryId, "memory");
        var memoryReasoningMode = Box(memory.ReasoningMode, "answer_first");
        var memoryAutoIndex = Box(memory.AutoIndexIntervalMinutes.ToString(), "1");
        var memoryAutoDream = Box(memory.AutoDreamIntervalMinutes.ToString(), "2");
        var memoryCapture = Box(memory.CaptureStrategy, "last_turn");
        var memoryIncludeAssistant = Check(T("settings.config.memoryIncludeAssistant"), memory.IncludeAssistant);
        var memoryMaxChars = Box(memory.MaxMessageChars.ToString(), "6000");
        var memoryHeartbeatBatch = Box(memory.HeartbeatBatchSize.ToString(), "30");
        var ragEnabled = Check(T("settings.config.ragEnabled"), draft.RagEnabled);
        var gatewayEnabled = Check(T("settings.config.gatewayEnabled"), draft.GatewayEnabled);
        var alwaysOn = draft.AlwaysOnSettings ?? NativeAlwaysOnSettings.Defaults;
        var alwaysOnEnabled = Check(T("settings.config.alwaysOnEnabled"), alwaysOn.Enabled);
        var alwaysOnTick = Box(alwaysOn.TickIntervalMinutes.ToString(), "15");
        var alwaysOnCooldown = Box(alwaysOn.CooldownMinutes.ToString(), "60");
        var alwaysOnDailyBudget = Box(alwaysOn.DailyBudget.ToString(), "12");
        var alwaysOnHeartbeat = Box(alwaysOn.HeartbeatStaleSeconds.ToString(), "300");
        var alwaysOnRecent = Box(alwaysOn.RecentUserMessageMinutes.ToString(), "30");
        var alwaysOnClient = Box(alwaysOn.PreferClient, "webui");
        var rag = draft.RagSettings ?? NativeRagSettings.Defaults;
        var ragDisableBuiltIn = Check(T("settings.config.ragDisableBuiltIn"), rag.DisableBuiltInWebTools);
        var ragLocalUrl = Box(rag.LocalKnowledgeBaseUrl, "http://127.0.0.1:8000");
        var ragLocalModel = Box(rag.LocalKnowledgeModelName, "glm-4");
        var ragLocalDatabase = Box(rag.LocalKnowledgeDatabaseUrl, "postgres://...");
        var ragLocalTopK = Box(rag.LocalKnowledgeDefaultTopK.ToString(), "5");
        var ragGlmUrl = Box(rag.GlmWebSearchBaseUrl, "https://open.bigmodel.cn/api/paas/v4");
        var ragGlmTopK = Box(rag.GlmWebSearchDefaultTopK.ToString(), "5");
        var gateway = draft.GatewaySettings ?? NativeGatewaySettings.Defaults;
        var gatewayHome = Box(gateway.Home, @"%USERPROFILE%\.g9claw");
        var gatewayHost = Box(gateway.Host, "0.0.0.0");
        var gatewayServerPort = Box(gateway.ServerPort.ToString(), "3001");
        var gatewayVitePort = Box(gateway.VitePort.ToString(), "5173");
        var gatewayProxyPort = Box(gateway.ProxyPort.ToString(), "18080");
        var providerId = Box(draft.Providers?.FirstOrDefault()?.Id ?? "g9claw", "g9claw");
        var modelEntryId = Box(draft.ModelEntries?.FirstOrDefault()?.Id ?? "default", "default");
        var agentMain = Box(draft.AgentSettings?.MainModelEntryId ?? "default", "default");
        var agentSubagent = Box(draft.AgentSettings?.SubagentDefaultModelEntryId ?? "default", "default");
        var agentParams = Area(draft.AgentSettings?.ParamsJson ?? "{}");
        var providerSecrets = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var provider in draft.Providers ?? [])
        {
            var secret = await _credentialStore.ReadSecretAsync(provider.SecretAccount);
            if (!string.IsNullOrWhiteSpace(secret))
            {
                providerSecrets[provider.SecretAccount] = secret;
            }
        }
        var modelsEditor = BuildModelsEditor(
            draft.Providers ?? [NativeProviderEntry.FromProviderConfig(State.Settings.ProviderConfig)],
            draft.ModelEntries ?? [NativeModelEntry.FromProviderConfig(State.Settings.ProviderConfig)],
            providerSecrets);
        var errorText = new TextBlock
        {
            FontSize = 12,
            Foreground = Brush("V2RedBrush"),
            TextWrapping = TextWrapping.Wrap,
        };

        var behaviorPanel = SettingsPanel(
            SettingsSection(T("settings.preferences.toolDisplay"), "",
                autoExpandTools,
                showRawParameters,
                showThinking),
            SettingsSection(T("settings.preferences.viewOptions"), "",
                autoScrollToBottom),
            SettingsSection(T("settings.preferences.inputSettings"), T("settings.preferences.sendByCtrlEnterDetail"),
                sendByCtrlEnter));

        var codeEditorPanel = SettingsPanel(
            SettingsSection(T("settings.appearance.codeEditor"), "",
                wordWrap,
                lineNumbers,
                minimap,
                Field(T("settings.appearance.editorFontSize"), editorFont)));

        var presetRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var allowPreset = new Button { Content = T("settings.permissions.safeDefaults"), Style = (Style)Application.Current.Resources["V2ToolbarButtonStyle"] };
        allowPreset.Click += (_, _) => allowedTools.Text = MergeLines(allowedTools.Text, ToolPermissionSettings.QuickAllowedTools);
        var blockPreset = new Button { Content = T("settings.permissions.blockRisky"), Style = (Style)Application.Current.Resources["V2ToolbarButtonStyle"] };
        blockPreset.Click += (_, _) => disallowedTools.Text = MergeLines(disallowedTools.Text, ToolPermissionSettings.QuickBlockedTools);
        var import = new Button { Content = $"{T("common.import")} JSON", Style = (Style)Application.Current.Resources["V2ToolbarButtonStyle"] };
        import.Click += (_, _) =>
        {
            try
            {
                errorText.Text = "";
                var imported = PermissionsExportCodec.Import(permissionsJson.Text);
                allowedTools.Text = string.Join(Environment.NewLine, imported.AllowedTools);
                disallowedTools.Text = string.Join(Environment.NewLine, imported.DisallowedTools);
            }
            catch (Exception ex)
            {
                errorText.Text = $"{T("settings.permissions.importFailed")}: {ex.Message}";
            }
        };
        var export = new Button { Content = $"{T("common.export")} JSON", Style = (Style)Application.Current.Resources["V2ToolbarButtonStyle"] };
        export.Click += (_, _) =>
        {
            permissionsJson.Text = PermissionsExportCodec.Export(new ToolPermissionSettings(
                Lines(allowedTools.Text),
                Lines(disallowedTools.Text),
                DateTimeOffset.UtcNow));
        };
        presetRow.Children.Add(allowPreset);
        presetRow.Children.Add(blockPreset);
        presetRow.Children.Add(import);
        presetRow.Children.Add(export);
        var permissionsPanel = SettingsPanel(
            SettingsSection(T("settings.permissions.title"), T("settings.permissions.detail"),
                presetRow,
                Field(T("settings.permissions.allowedTools"), allowedTools),
                Field(T("settings.permissions.disallowedTools"), disallowedTools),
                Field(T("settings.permissions.jsonTransfer"), permissionsJson)));

        var configPanel = ConfigSettingsPanel(
            apiType,
            baseUrl,
            model,
            apiKey,
            providerId,
            modelEntryId,
            workspaceRoot,
            generalWorkspace,
            databasePath,
            httpsProxy,
            timeout,
            contextWindow,
            agentMain,
            agentSubagent,
            agentParams,
            alwaysOnEnabled,
            alwaysOnTick,
            alwaysOnCooldown,
            alwaysOnDailyBudget,
            alwaysOnHeartbeat,
            alwaysOnRecent,
            alwaysOnClient,
            memoryEnabled,
            memoryModel,
            memoryReasoningMode,
            memoryAutoIndex,
            memoryAutoDream,
            memoryCapture,
            memoryIncludeAssistant,
            memoryMaxChars,
            memoryHeartbeatBatch,
            ragEnabled,
            ragDisableBuiltIn,
            ragLocalUrl,
            ragLocalModel,
            ragLocalDatabase,
            ragLocalTopK,
            ragGlmUrl,
            ragGlmTopK,
            gatewayEnabled,
            gatewayHome,
            gatewayHost,
            gatewayServerPort,
            gatewayVitePort,
            gatewayProxyPort,
            routerEnabled,
            routerLog,
            routerHost,
            routerPort,
            routerRoute,
            inputPrice,
            outputPrice,
            baselineInput,
            baselineOutput,
            modelsEditor.Root);

        var viewModel = new SettingsOverlayViewModel(State.Settings, existingSecret);
        var rawYaml = Area(viewModel.RawConfigText);
        rawYaml.TextWrapping = TextWrapping.NoWrap;
        rawYaml.MinHeight = 420;
        rawYaml.MaxHeight = double.PositiveInfinity;
        var rawPanel = SettingsPanel(
            SettingsSection(T("settings.config.rawYaml"), T("settings.config.rawYamlDetail"), rawYaml));
        var mcpProjectOptions = State.Projects
            .Where(project => !IsGeneralProject(project) && !string.IsNullOrWhiteSpace(project.RootPath))
            .Select(project => (Name: project.DisplayName, Root: project.RootPath))
            .ToList();
        var mcpScope = "global";
        var mcpProjectRoot = State.SelectedProject is { } selectedProject && !IsGeneralProject(selectedProject)
            ? selectedProject.RootPath
            : mcpProjectOptions.Count > 0 ? mcpProjectOptions[0].Root : "";
        string CurrentMcpPath() =>
            string.Equals(mcpScope, "project", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(mcpProjectRoot)
                ? Path.Combine(mcpProjectRoot, ".g9claw", "mcp.json")
                : Path.Combine(AppPaths.Current().Root, "mcp.json");
        static string ReadMcpRaw(string path) =>
            File.Exists(path)
                ? File.ReadAllText(path)
                : """
                {
                  "mcpServers": {}
                }
                """;
        var mcpPath = CurrentMcpPath();
        var initialMcpRaw = ReadMcpRaw(mcpPath);
        var mcpRaw = Area(initialMcpRaw);
        mcpRaw.TextWrapping = TextWrapping.NoWrap;
        mcpRaw.MinHeight = 260;
        var mcpStatusText = new TextBlock
        {
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
        };
        var mcpPathText = new TextBlock
        {
            FontSize = 11,
            FontFamily = new FontFamily("Consolas"),
            Foreground = Brush("V2MutedForegroundBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var mcpServerCountText = new TextBlock
        {
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var mcpEmptyState = DashedEmptyState(L("No MCP servers configured.", "\u6682\u65e0 MCP \u670d\u52a1\u5668\u3002"), L("Add a STDIO or HTTP server, or edit Advanced JSON directly.", "\u6dfb\u52a0 STDIO \u6216 HTTP \u670d\u52a1\u5668\uff0c\u6216\u76f4\u63a5\u7f16\u8f91\u9ad8\u7ea7 JSON\u3002"));
        var mcpServerCards = new StackPanel { Spacing = 12 };
        var mcpServerDrafts = ParseMcpServers(initialMcpRaw);
        var suppressMcpRawRefresh = false;
        var mcpMessageText = new TextBlock
        {
            FontSize = 12,
            Foreground = Brush("V2GreenBrush"),
            TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed,
        };
        var mcpProjectPicker = new ComboBox
        {
            Height = 34,
            MinWidth = 0,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            IsEnabled = mcpProjectOptions.Count > 0,
        };
        foreach (var option in mcpProjectOptions)
        {
            mcpProjectPicker.Items.Add(new ComboBoxItem { Content = option.Name, Tag = option.Root });
        }
        var selectedMcpProjectIndex = mcpProjectOptions.FindIndex(option => string.Equals(option.Root, mcpProjectRoot, StringComparison.OrdinalIgnoreCase));
        mcpProjectPicker.SelectedIndex = selectedMcpProjectIndex >= 0 ? selectedMcpProjectIndex : (mcpProjectOptions.Count > 0 ? 0 : -1);

        FrameworkElement? mcpProjectRow = null;
        Button McpToolbarButton(string icon, string label, bool primary = false)
        {
            return new Button
            {
                Content = IconText(icon, label, 14, primary ? Brush("V2InverseForegroundBrush") : null),
                Height = 32,
                Style = (Style)Application.Current.Resources[primary ? "V2PrimaryButtonStyle" : "V2ToolbarButtonStyle"],
            };
        }

        var scopeGlobalButton = McpToolbarButton("Database", L("Global", "\u5168\u5c40"));
        var scopeProjectButton = McpToolbarButton("Folder", L("Project", "\u9879\u76ee"));
        scopeProjectButton.IsEnabled = mcpProjectOptions.Count > 0;
        var scopeSelector = new Border
        {
            Padding = new Thickness(3),
            CornerRadius = new CornerRadius(16),
            Background = Brush("V2ControlSurfaceBrush"),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 2,
                Children = { scopeGlobalButton, scopeProjectButton },
            },
        };

        void RefreshMcpView(bool rebuildCards = true)
        {
            mcpPath = CurrentMcpPath();
            mcpStatusText.Text = File.Exists(mcpPath) ? L("Existing config", "\u5df2\u5b58\u5728") : L("Not created yet", "\u5c1a\u672a\u521b\u5efa");
            mcpPathText.Text = mcpPath;
            if (rebuildCards)
            {
                mcpServerDrafts = ParseMcpServers(mcpRaw.Text);
                RebuildMcpServerCards();
            }

            var serverCount = mcpServerDrafts.Count;
            mcpServerCountText.Text = IsChineseUi() ? $"{serverCount} \u4e2a\u670d\u52a1\u5668" : $"{serverCount} servers";
            mcpEmptyState.Visibility = serverCount == 0 ? Visibility.Visible : Visibility.Collapsed;
            mcpServerCards.Visibility = serverCount == 0 ? Visibility.Collapsed : Visibility.Visible;
            mcpProjectRow!.Visibility = string.Equals(mcpScope, "project", StringComparison.OrdinalIgnoreCase) ? Visibility.Visible : Visibility.Collapsed;
            scopeGlobalButton.Background = string.Equals(mcpScope, "global", StringComparison.OrdinalIgnoreCase) ? Brush("V2ControlActiveBrush") : Transparent;
            scopeProjectButton.Background = string.Equals(mcpScope, "project", StringComparison.OrdinalIgnoreCase) ? Brush("V2ControlActiveBrush") : Transparent;
        }

        void RebuildMcpServerCards()
        {
            mcpServerCards.Children.Clear();
            foreach (var server in mcpServerDrafts)
            {
                mcpServerCards.Children.Add(McpServerCard(server));
            }
        }

        void SyncMcpRawFromServerCards()
        {
            try
            {
                suppressMcpRawRefresh = true;
                mcpRaw.Text = McpRawFromServers(mcpRaw.Text, mcpServerDrafts);
                RefreshMcpView(rebuildCards: false);
                mcpMessageText.Visibility = Visibility.Collapsed;
            }
            catch (Exception ex)
            {
                errorText.Text = ex.Message;
            }
            finally
            {
                suppressMcpRawRefresh = false;
            }
        }

        FrameworkElement McpServerCard(McpServerDraft server)
        {
            var nameBox = Box(server.Name, L("Server name", "\u670d\u52a1\u5668\u540d\u79f0"));
            nameBox.TextChanged += (_, _) =>
            {
                server.Name = nameBox.Text;
                SyncMcpRawFromServerCards();
            };

            var transportBox = new ComboBox
            {
                Height = 34,
                MinWidth = 0,
                Width = 150,
                HorizontalAlignment = HorizontalAlignment.Right,
            };
            transportBox.Items.Add(new ComboBoxItem { Content = "STDIO", Tag = "stdio" });
            transportBox.Items.Add(new ComboBoxItem { Content = "HTTP", Tag = "http" });
            transportBox.SelectedIndex = string.Equals(server.Transport, "http", StringComparison.OrdinalIgnoreCase) ? 1 : 0;
            transportBox.SelectionChanged += (_, _) =>
            {
                if (transportBox.SelectedItem is ComboBoxItem { Tag: string tag })
                {
                    server.Transport = tag;
                    SyncMcpRawFromServerCards();
                    RebuildMcpServerCards();
                }
            };

            var remove = new Button
            {
                Width = 30,
                Height = 30,
                Padding = new Thickness(0),
                Style = (Style)Application.Current.Resources["V2IconButtonStyle"],
                Content = Icon("Trash", 14, Brush("V2RedBrush")),
            };
            remove.Click += (_, _) =>
            {
                mcpServerDrafts.Remove(server);
                SyncMcpRawFromServerCards();
                RebuildMcpServerCards();
            };

            var summary = new TextBlock
            {
                Text = McpServerSummary(server),
                FontSize = 11,
                Foreground = Brush("V2MutedForegroundBrush"),
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            var header = new Grid
            {
                ColumnSpacing = 10,
                ColumnDefinitions =
                {
                    new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                    new ColumnDefinition { Width = GridLength.Auto },
                    new ColumnDefinition { Width = GridLength.Auto },
                },
                Children =
                {
                    new StackPanel
                    {
                        Spacing = 4,
                        Children = { nameBox, summary },
                    },
                    transportBox,
                    remove,
                },
            };
            Grid.SetColumn(transportBox, 1);
            Grid.SetColumn(remove, 2);

            var fields = new StackPanel { Spacing = 10 };
            if (string.Equals(server.Transport, "http", StringComparison.OrdinalIgnoreCase))
            {
                var urlBox = Box(server.Url, "http://127.0.0.1:3000/mcp");
                urlBox.TextChanged += (_, _) =>
                {
                    server.Url = urlBox.Text;
                    summary.Text = McpServerSummary(server);
                    SyncMcpRawFromServerCards();
                };
                var headersBox = Area(server.HeadersText);
                headersBox.MinHeight = 84;
                headersBox.TextChanged += (_, _) =>
                {
                    server.HeadersText = headersBox.Text;
                    SyncMcpRawFromServerCards();
                };
                fields.Children.Add(Field("URL", urlBox));
                fields.Children.Add(Field(L("Headers KEY=VALUE", "Headers KEY=VALUE"), headersBox));
            }
            else
            {
                var commandBox = Box(server.Command, "npx");
                commandBox.TextChanged += (_, _) =>
                {
                    server.Command = commandBox.Text;
                    summary.Text = McpServerSummary(server);
                    SyncMcpRawFromServerCards();
                };
                var argsBox = Area(server.ArgsText);
                argsBox.MinHeight = 84;
                argsBox.TextChanged += (_, _) =>
                {
                    server.ArgsText = argsBox.Text;
                    SyncMcpRawFromServerCards();
                };
                var envBox = Area(server.EnvText);
                envBox.MinHeight = 84;
                envBox.TextChanged += (_, _) =>
                {
                    server.EnvText = envBox.Text;
                    SyncMcpRawFromServerCards();
                };
                var perSession = new CheckBox
                {
                    Content = "Per-session",
                    IsChecked = server.PerSession,
                    FontSize = 13,
                    Foreground = Brush("V2ForegroundBrush"),
                    Margin = new Thickness(14, 8, 14, 8),
                };
                perSession.Checked += (_, _) =>
                {
                    server.PerSession = true;
                    SyncMcpRawFromServerCards();
                };
                perSession.Unchecked += (_, _) =>
                {
                    server.PerSession = false;
                    SyncMcpRawFromServerCards();
                };
                fields.Children.Add(Field(L("Command", "\u547d\u4ee4"), commandBox));
                fields.Children.Add(Field(L("Args (one per line)", "\u53c2\u6570\uff08\u6bcf\u884c\u4e00\u4e2a\uff09"), argsBox));
                fields.Children.Add(Field(L("Env KEY=VALUE", "\u73af\u5883\u53d8\u91cf KEY=VALUE"), envBox));
                fields.Children.Add(SettingsMenuRow("Terminal", "Per-session", L("Start a separate MCP process for each session.", "\u4e3a\u6bcf\u4e2a\u4f1a\u8bdd\u72ec\u7acb\u542f\u52a8 MCP \u8fdb\u7a0b\u3002"), perSession));
            }

            return new Border
            {
                CornerRadius = new CornerRadius(8),
                BorderBrush = Brush("V2BorderBrush"),
                BorderThickness = new Thickness(1),
                Background = Brush("V2CardSurfaceSubtleBrush"),
                Padding = new Thickness(12),
                Child = new StackPanel
                {
                    Spacing = 12,
                    Children = { header, fields },
                },
            };
        }

        void LoadMcpIntoEditor()
        {
            mcpPath = CurrentMcpPath();
            initialMcpRaw = ReadMcpRaw(mcpPath);
            mcpRaw.Text = initialMcpRaw;
            mcpMessageText.Visibility = Visibility.Collapsed;
            RefreshMcpView();
        }

        scopeGlobalButton.Click += (_, _) =>
        {
            mcpScope = "global";
            LoadMcpIntoEditor();
        };
        scopeProjectButton.Click += (_, _) =>
        {
            if (mcpProjectOptions.Count == 0) return;
            mcpScope = "project";
            if (string.IsNullOrWhiteSpace(mcpProjectRoot)) mcpProjectRoot = mcpProjectOptions[0].Root;
            LoadMcpIntoEditor();
        };
        mcpProjectPicker.SelectionChanged += (_, _) =>
        {
            if (mcpProjectPicker.SelectedItem is ComboBoxItem { Tag: string root })
            {
                mcpProjectRoot = root;
                if (string.Equals(mcpScope, "project", StringComparison.OrdinalIgnoreCase)) LoadMcpIntoEditor();
            }
        };
        mcpRaw.TextChanged += (_, _) =>
        {
            if (suppressMcpRawRefresh) return;
            RefreshMcpView();
        };

        var revealMcp = McpToolbarButton("Folder", T("settings.config.revealFile"));
        revealMcp.Click += (_, _) =>
        {
            try
            {
                var directory = Path.GetDirectoryName(mcpPath);
                if (!string.IsNullOrWhiteSpace(directory)) Directory.CreateDirectory(directory);
                var explorerArg = File.Exists(mcpPath) ? $"/select,\"{mcpPath}\"" : $"\"{directory}\"";
                Process.Start(new ProcessStartInfo("explorer.exe", explorerArg) { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                errorText.Text = ex.Message;
            }
        };
        var refreshMcp = McpToolbarButton("Refresh", T("common.refresh"));
        refreshMcp.Click += (_, _) => LoadMcpIntoEditor();
        var saveMcp = McpToolbarButton("Save", L("Save MCP", "\u4fdd\u5b58 MCP"), primary: true);
        saveMcp.Click += (_, _) =>
        {
            try
            {
                using var _ = JsonDocument.Parse(mcpRaw.Text);
                Directory.CreateDirectory(Path.GetDirectoryName(mcpPath)!);
                File.WriteAllText(mcpPath, mcpRaw.Text);
                initialMcpRaw = mcpRaw.Text;
                mcpMessageText.Text = L("MCP config saved.", "MCP \u914d\u7f6e\u5df2\u4fdd\u5b58\u3002");
                mcpMessageText.Visibility = Visibility.Visible;
                errorText.Text = "";
                RefreshMcpView();
            }
            catch (Exception ex)
            {
                errorText.Text = ex.Message;
            }
        };
        var addStdio = McpToolbarButton("Plus", "STDIO");
        addStdio.Click += (_, _) =>
        {
            try
            {
                mcpRaw.Text = AddMcpServerTemplate(mcpRaw.Text, "stdio");
                mcpMessageText.Visibility = Visibility.Collapsed;
            }
            catch (Exception ex)
            {
                errorText.Text = ex.Message;
            }
        };
        var addHttp = McpToolbarButton("Plus", "HTTP");
        addHttp.Click += (_, _) =>
        {
            try
            {
                mcpRaw.Text = AddMcpServerTemplate(mcpRaw.Text, "http");
                mcpMessageText.Visibility = Visibility.Collapsed;
            }
            catch (Exception ex)
            {
                errorText.Text = ex.Message;
            }
        };

        var mcpConfigActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        mcpConfigActions.Children.Add(revealMcp);
        mcpConfigActions.Children.Add(refreshMcp);
        mcpConfigActions.Children.Add(saveMcp);
        var mcpConfigCard = new StackPanel
        {
            Padding = new Thickness(14),
            Spacing = 12,
            Children =
            {
                new Grid
                {
                    ColumnSpacing = 10,
                    ColumnDefinitions =
                    {
                        new ColumnDefinition { Width = new GridLength(24) },
                        new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                    },
                    Children =
                    {
                        Icon("Database", 16, Brush("V2MutedForegroundBrush")),
                        new StackPanel
                        {
                            Spacing = 6,
                            Children =
                            {
                                mcpStatusText,
                                new Border
                                {
                                    CornerRadius = new CornerRadius(5),
                                    Background = Brush("V2ControlSurfaceBrush"),
                                    Padding = new Thickness(8, 4, 8, 4),
                                    Child = mcpPathText,
                                },
                            },
                        },
                    },
                },
                mcpConfigActions,
                mcpMessageText,
            },
        };
        if (mcpConfigCard.Children[0] is Grid mcpConfigGrid)
        {
            Grid.SetColumn((FrameworkElement)mcpConfigGrid.Children[1], 1);
        }

        var mcpServersActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        mcpServersActions.Children.Add(addStdio);
        mcpServersActions.Children.Add(addHttp);
        var mcpServersSummary = new StackPanel
        {
            Padding = new Thickness(14),
            Spacing = 12,
            Children =
            {
                new Grid
                {
                    ColumnDefinitions =
                    {
                        new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                        new ColumnDefinition { Width = GridLength.Auto },
                    },
                    Children =
                    {
                        mcpServerCountText,
                        mcpServersActions,
                    },
                },
                mcpEmptyState,
                mcpServerCards,
            },
        };
        if (mcpServersSummary.Children[0] is Grid mcpServersGrid)
        {
            Grid.SetColumn((FrameworkElement)mcpServersGrid.Children[1], 1);
        }

        mcpProjectRow = SettingsMenuRow("Folder", T("sidebar.projects"), L("Choose the project whose `.g9claw/mcp.json` should be edited.", "\u9009\u62e9\u8981\u7f16\u8f91 `.g9claw/mcp.json` \u7684\u9879\u76ee\u3002"), mcpProjectPicker);
        var mcpPanel = SettingsPanel(
            SettingsSection(L("MCP Servers", "MCP \u670d\u52a1\u5668"), L("Configure MCP tools with global or project JSON. Project servers override global servers with the same name.", "\u901a\u8fc7\u5168\u5c40\u6216\u9879\u76ee JSON \u914d\u7f6e MCP \u5de5\u5177\u3002\u540c\u540d\u9879\u76ee\u670d\u52a1\u5668\u4f1a\u8986\u76d6\u5168\u5c40\u670d\u52a1\u5668\u3002"),
                SettingsMenuRow("Database", L("Scope", "\u4f5c\u7528\u57df"), L("Global MCP servers are available to every project.", "\u5168\u5c40 MCP \u4f1a\u5728\u6240\u6709\u9879\u76ee\u4e2d\u53ef\u7528\u3002"), scopeSelector),
                mcpProjectRow),
            SettingsSection(L("Config File", "\u914d\u7f6e\u6587\u4ef6"), "", mcpConfigCard),
            SettingsSection(L("Servers", "\u670d\u52a1\u5668"), L("Supports STDIO and HTTP MCP servers.", "\u652f\u6301 STDIO \u548c HTTP MCP \u670d\u52a1\u5668\u3002"),
                mcpServersSummary,
                Field(L("Advanced JSON", "\u9ad8\u7ea7 JSON"), mcpRaw)));
        RefreshMcpView();
        var configContent = new ContentControl { Content = configPanel };
        var formMode = new Button { Content = IconText("LayoutList", T("settings.config.form"), 14), Height = 32, Style = (Style)Application.Current.Resources["V2ToolbarButtonStyle"] };
        var rawMode = new Button { Content = IconText("Code", T("settings.config.rawYaml"), 14), Height = 32, Style = (Style)Application.Current.Resources["V2ToolbarButtonStyle"] };
        void SetConfigMode(SettingsConfigViewMode mode)
        {
            viewModel.ConfigViewMode = mode;
            configContent.Content = mode == SettingsConfigViewMode.RawYaml ? rawPanel : configPanel;
            formMode.Background = mode == SettingsConfigViewMode.Form ? Brush("V2HoverBrush") : Transparent;
            rawMode.Background = mode == SettingsConfigViewMode.RawYaml ? Brush("V2HoverBrush") : Transparent;
        }
        formMode.Click += (_, _) => SetConfigMode(SettingsConfigViewMode.Form);
        rawMode.Click += (_, _) => SetConfigMode(SettingsConfigViewMode.RawYaml);
        var modeRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        modeRow.Children.Add(formMode);
        modeRow.Children.Add(rawMode);
        var configPath = NativeConfigService.DefaultConfigPath();
        var revealConfig = new Button { Content = IconText("Folder", T("settings.config.revealFile"), 14), Height = 32, Style = (Style)Application.Current.Resources["V2ToolbarButtonStyle"] };
        revealConfig.Click += (_, _) =>
        {
            try
            {
                System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(configPath)!);
                Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{configPath}\"") { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                errorText.Text = ex.Message;
            }
        };
        var refreshConfig = new Button { Content = IconText("Refresh", T("common.refresh"), 14), Height = 32, Style = (Style)Application.Current.Resources["V2ToolbarButtonStyle"] };
        refreshConfig.Click += (_, _) =>
        {
            rawYaml.Text = NativeConfigYamlCodec.MaskSecretsInYaml(NativeConfigService.ReadDefaultConfigText());
            viewModel.RawConfigText = rawYaml.Text;
            SetConfigMode(SettingsConfigViewMode.RawYaml);
        };
        var configHeaderActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        configHeaderActions.Children.Add(modeRow);
        configHeaderActions.Children.Add(revealConfig);
        configHeaderActions.Children.Add(refreshConfig);
        var configHeader = new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(14),
            Margin = new Thickness(0, 0, 0, 14),
            Child = new StackPanel
            {
                Spacing = 10,
                Children =
                {
                    new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        Spacing = 10,
                        Children =
                        {
                            Icon("FileCog", 16, Brush("V2MutedForegroundBrush")),
                            new TextBlock { Text = T("settings.config.configFile"), FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = Brush("V2ForegroundBrush") },
                            new TextBlock { Text = configPath, FontSize = 11, FontFamily = new FontFamily("Consolas"), Foreground = Brush("V2MutedForegroundBrush"), TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 460 },
                        },
                    },
                    configHeaderActions,
                },
            },
        };
        var configShell = new Grid();
        configShell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        configShell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        configShell.Children.Add(configHeader);
        Grid.SetRow(configContent, 1);
        configShell.Children.Add(configContent);
        SetConfigMode(SettingsConfigViewMode.Form);

        var content = new ContentControl();
        var pageTitle = new TextBlock
        {
            Text = T("settings.title"),
            FontSize = 22,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
        };
        var backButton = new Button
        {
            Height = 28,
            MinWidth = 0,
            Padding = new Thickness(8, 0, 10, 0),
            Background = Transparent,
            BorderBrush = Transparent,
            CornerRadius = new CornerRadius(8),
            Content = IconText("ChevronLeft", L("Back", "\u8fd4\u56de"), 14),
        };

        void ShowSettingsPage(SettingsOverlayPage page)
        {
            viewModel.ActiveTab = page switch
            {
                SettingsOverlayPage.Permissions => SettingsMainTab.Permissions,
                SettingsOverlayPage.Config => SettingsMainTab.Config,
                SettingsOverlayPage.Mcp => SettingsMainTab.Mcp,
                _ => SettingsMainTab.Appearance,
            };
            State.OpenSettings(viewModel.ActiveTab);
            pageTitle.Text = page switch
            {
                SettingsOverlayPage.Behavior => L("Chat & Input", "\u804a\u5929\u4e0e\u8f93\u5165"),
                SettingsOverlayPage.CodeEditor => T("settings.appearance.codeEditor"),
                SettingsOverlayPage.Permissions => T("settings.tabs.permissions"),
                SettingsOverlayPage.Config => T("settings.tabs.config"),
                SettingsOverlayPage.Mcp => L("MCP Servers", "MCP \u670d\u52a1\u5668"),
                _ => T("settings.title"),
            };
            backButton.Visibility = page == SettingsOverlayPage.Main ? Visibility.Collapsed : Visibility.Visible;
            content.Content = page switch
            {
                SettingsOverlayPage.Behavior => behaviorPanel,
                SettingsOverlayPage.CodeEditor => codeEditorPanel,
                SettingsOverlayPage.Permissions => permissionsPanel,
                SettingsOverlayPage.Config => configShell,
                SettingsOverlayPage.Mcp => mcpPanel,
                _ => SettingsPanel(
                    SettingsSection(L("Basics", "\u57fa\u7840"), "",
                        SettingsNavigationRow("FileCog", T("settings.tabs.config"), L("Models, runtime, Search, Always-on, and essential config", "\u6a21\u578b\u3001\u8fd0\u884c\u65f6\u3001\u641c\u7d22\u3001\u5e38\u9a7b\u7b49\u57fa\u7840\u914d\u7f6e"), () => ShowSettingsPage(SettingsOverlayPage.Config))),
                    SettingsSection(L("Application", "\u5e94\u7528"), "",
                        SettingsMenuRow("Palette", T("settings.appearance.theme"), T("settings.appearance.detail"), colorScheme),
                        SettingsMenuRow("globe", T("settings.appearance.language"), "", language),
                        SettingsMenuRow("Chevrons", T("settings.appearance.projectSorting"), "", sortOrder)),
                    SettingsSection(L("Workflow", "\u5de5\u4f5c\u6d41"), "",
                        SettingsNavigationRow("MessageSquarePlus", L("Chat & Input", "\u804a\u5929\u4e0e\u8f93\u5165"), L("Tool display, scrolling, and send shortcut", "\u5de5\u5177\u663e\u793a\u3001\u6eda\u52a8\u884c\u4e3a\u548c\u53d1\u9001\u5feb\u6377\u952e"), () => ShowSettingsPage(SettingsOverlayPage.Behavior)),
                        SettingsNavigationRow("Code", T("settings.appearance.codeEditor"), L("Word wrap, line numbers, minimap, and font size", "\u81ea\u52a8\u6362\u884c\u3001\u884c\u53f7\u3001\u7f29\u7565\u56fe\u548c\u5b57\u53f7"), () => ShowSettingsPage(SettingsOverlayPage.CodeEditor))),
                    SettingsSection(L("Advanced", "\u9ad8\u7ea7"), "",
                        SettingsNavigationRow("Database", L("MCP Servers", "MCP \u670d\u52a1\u5668"), L("Configure global and project MCP tools", "\u914d\u7f6e\u5168\u5c40\u548c\u9879\u76ee MCP \u5de5\u5177"), () => ShowSettingsPage(SettingsOverlayPage.Mcp)),
                        SettingsNavigationRow("Shield", T("settings.tabs.permissions"), L("Manage allowed and blocked tool rules", "\u7ba1\u7406\u5141\u8bb8\u548c\u7981\u7528\u7684\u5de5\u5177\u89c4\u5219"), () => ShowSettingsPage(SettingsOverlayPage.Permissions)))),
            };
        }

        backButton.Click += (_, _) => ShowSettingsPage(SettingsOverlayPage.Main);

        var completion = new TaskCompletionSource<bool>();
        var saveStatus = new TextBlock
        {
            Text = "",
            FontSize = 12,
            Foreground = Brush("V2MutedForegroundBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };

        async Task<bool> SaveAsync()
        {
            try
            {
                errorText.Text = "";
                var nextUiPreferences = new NativeUIPreferences(
                    AutoExpandTools: autoExpandTools.IsChecked == true,
                    ShowRawParameters: showRawParameters.IsChecked == true,
                    ShowThinking: showThinking.IsChecked == true,
                    AutoScrollToBottom: autoScrollToBottom.IsChecked == true,
                    SendByCtrlEnter: sendByCtrlEnter.IsChecked == true,
                    SidebarVisible: _isSidebarVisible);
                AppSettings nextSettings;
                if (viewModel.ConfigViewMode == SettingsConfigViewMode.RawYaml)
                {
                    var parsed = NativeConfigYamlCodec.ApplyYaml(State.Settings, rawYaml.Text);
                    foreach (var secret in parsed.Secrets)
                    {
                        await _credentialStore.WriteSecretAsync(secret.Key, secret.Value);
                    }

                    nextSettings = parsed.Settings with
                    {
                        ColorScheme = SelectedEnum<AppColorScheme>(colorScheme),
                        Language = SelectedEnum<AppLanguage>(language),
                        ProjectSortOrder = SelectedEnum<ProjectSortOrder>(sortOrder),
                        EditorSettings = new NativeEditorSettings(
                            wordWrap.IsChecked == true,
                            minimap.IsChecked == true,
                            lineNumbers.IsChecked == true,
                            IntComboValue(editorFont, State.Settings.EditorSettings.FontSize)).Normalize(),
                        Permissions = new ToolPermissionSettings(Lines(allowedTools.Text), Lines(disallowedTools.Text), DateTimeOffset.UtcNow),
                    };
                }
                else
                {
                    var next = new NativeSettingsDraft(
                        SelectedEnum<ProviderApiType>(apiType),
                        baseUrl.Text,
                        model.Text,
                        apiKey.Password,
                        workspaceRoot.Text,
                        generalWorkspace.Text,
                        IntValue(timeout.Text, State.Settings.ApiTimeoutMs),
                        IntValue(contextWindow.Text, State.Settings.ContextWindow),
                        SelectedEnum<ProjectSortOrder>(sortOrder),
                        SelectedEnum<AppColorScheme>(colorScheme),
                        SelectedEnum<AppLanguage>(language),
                        wordWrap.IsChecked == true,
                        minimap.IsChecked == true,
                        lineNumbers.IsChecked == true,
                        IntComboValue(editorFont, State.Settings.EditorSettings.FontSize),
                        Lines(allowedTools.Text),
                        Lines(disallowedTools.Text),
                        routerEnabled.IsChecked == true,
                        routerRoute.Text,
                        DecimalValue(inputPrice.Text),
                        DecimalValue(outputPrice.Text),
                        DecimalValue(baselineInput.Text),
                        DecimalValue(baselineOutput.Text),
                        memoryEnabled.IsChecked == true,
                        ragEnabled.IsChecked == true,
                        gatewayEnabled.IsChecked == true,
                        modelsEditor.ReadProviders(),
                        modelsEditor.ReadModelEntries(),
                        new NativeAgentSettings(agentMain.Text, agentSubagent.Text, agentParams.Text),
                        new NativeRuntimeSettings(
                            workspaceRoot.Text,
                            generalWorkspace.Text,
                            IntValue(timeout.Text, State.Settings.ApiTimeoutMs),
                            IntValue(contextWindow.Text, State.Settings.ContextWindow),
                            databasePath.Text,
                            httpsProxy.Text),
                        new NativeAlwaysOnSettings(
                            alwaysOnEnabled.IsChecked == true,
                            IntValue(alwaysOnTick.Text, NativeAlwaysOnSettings.Defaults.TickIntervalMinutes),
                            IntValue(alwaysOnCooldown.Text, NativeAlwaysOnSettings.Defaults.CooldownMinutes),
                            IntValue(alwaysOnDailyBudget.Text, NativeAlwaysOnSettings.Defaults.DailyBudget),
                            IntValue(alwaysOnHeartbeat.Text, NativeAlwaysOnSettings.Defaults.HeartbeatStaleSeconds),
                            IntValue(alwaysOnRecent.Text, NativeAlwaysOnSettings.Defaults.RecentUserMessageMinutes),
                            alwaysOnClient.Text,
                            State.Settings.AlwaysOnSettings?.ProjectEnabled ?? new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase)),
                        new NativeMemorySettings(
                            memoryEnabled.IsChecked == true,
                            memoryModel.Text,
                            (State.Settings.MemorySettings ?? NativeMemorySettings.Defaults).ParamsJson,
                            memoryReasoningMode.Text,
                            IntValue(memoryAutoIndex.Text, NativeMemorySettings.Defaults.AutoIndexIntervalMinutes),
                            IntValue(memoryAutoDream.Text, NativeMemorySettings.Defaults.AutoDreamIntervalMinutes),
                            memoryCapture.Text,
                            memoryIncludeAssistant.IsChecked == true,
                            IntValue(memoryMaxChars.Text, NativeMemorySettings.Defaults.MaxMessageChars),
                            IntValue(memoryHeartbeatBatch.Text, NativeMemorySettings.Defaults.HeartbeatBatchSize)),
                        new NativeRagSettings(
                            ragEnabled.IsChecked == true,
                            ragDisableBuiltIn.IsChecked == true,
                            ragLocalUrl.Text,
                            (State.Settings.RagSettings ?? NativeRagSettings.Defaults).LocalKnowledgeSecretAccount,
                            ragLocalModel.Text,
                            ragLocalDatabase.Text,
                            IntValue(ragLocalTopK.Text, NativeRagSettings.Defaults.LocalKnowledgeDefaultTopK),
                            ragGlmUrl.Text,
                            (State.Settings.RagSettings ?? NativeRagSettings.Defaults).GlmWebSearchSecretAccount,
                            IntValue(ragGlmTopK.Text, NativeRagSettings.Defaults.GlmWebSearchDefaultTopK)),
                        new NativeGatewaySettings(
                            gatewayEnabled.IsChecked == true,
                            gatewayHome.Text,
                            gatewayHost.Text,
                            IntValue(gatewayServerPort.Text, NativeGatewaySettings.Defaults.ServerPort),
                            IntValue(gatewayVitePort.Text, NativeGatewaySettings.Defaults.VitePort),
                            IntValue(gatewayProxyPort.Text, NativeGatewaySettings.Defaults.ProxyPort)),
                        new NativeConfigRawDocument(rawYaml.Text, DateTimeOffset.UtcNow));

                    var validation = next.Validate();
                    if (!validation.Valid)
                    {
                        errorText.Text = string.Join(Environment.NewLine, validation.Errors);
                        return false;
                    }

                    await modelsEditor.WriteSecretsAsync(_credentialStore);

                    var applied = next.ApplyTo(State.Settings);
                    nextSettings = applied with
                    {
                        RouterSettings = applied.RouterSettings with
                        {
                            Log = routerLog.IsChecked == true,
                            Host = routerHost.Text,
                            Port = IntValue(routerPort.Text, NativeRouterSettings.Defaults.Port),
                        },
                    };
                    nextSettings = nextSettings with
                    {
                        RawConfigDocument = new NativeConfigRawDocument(
                            NativeConfigYamlCodec.ToYaml(nextSettings, State.Settings.RawConfigDocument?.LastYaml ?? rawYaml.Text),
                            DateTimeOffset.UtcNow),
                    };
                }

                State.Settings = AppState.NormalizeSettings(nextSettings);
                State.UiPreferences = nextUiPreferences;
                State.IsSidebarVisible = _isSidebarVisible;
                _uiSettings = State.Settings.UiSettings.Normalize();
                _strings = new StringCatalog(State.Settings.Language);
                _workspaceService = new WorkspaceService(State.Settings.WorkspacesRoot);
                ApplyUiSettings();
                await _settingsStore.SaveAsync(State.Settings);
                await _uiPreferencesStore.SaveAsync(State.UiPreferences);
                NativeConfigService.WriteDefaultConfigText(State.Settings.RawConfigDocument?.LastYaml ?? NativeConfigYamlCodec.ToYaml(State.Settings));
                if (!string.Equals(mcpRaw.Text, initialMcpRaw, StringComparison.Ordinal))
                {
                    using var mcpDocument = JsonDocument.Parse(mcpRaw.Text);
                    Directory.CreateDirectory(Path.GetDirectoryName(mcpPath)!);
                    File.WriteAllText(mcpPath, mcpRaw.Text);
                    initialMcpRaw = mcpRaw.Text;
                }
                await RefreshProviderPreflightAsync();
                saveStatus.Text = T("common.saved");
                return true;
            }
            catch (Exception ex)
            {
                errorText.Text = ex.Message;
                return false;
            }
        }

        var modal = BuildSettingsOverlay(content, pageTitle, backButton, errorText, saveStatus, completion, SaveAsync);
        ShowSettingsPage(State.SettingsInitialTab switch
        {
            SettingsMainTab.Permissions => SettingsOverlayPage.Permissions,
            SettingsMainTab.Config => SettingsOverlayPage.Config,
            SettingsMainTab.Mcp => SettingsOverlayPage.Mcp,
            _ => SettingsOverlayPage.Main,
        });
        SettingsOverlayHost.Content = modal;
        SettingsOverlayRoot.Visibility = Visibility.Visible;
        await completion.Task;
        SettingsOverlayRoot.Visibility = Visibility.Collapsed;
        SettingsOverlayHost.Content = null;
        RenderAll();
    }

    private FrameworkElement BuildSettingsOverlay(
        ContentControl content,
        TextBlock pageTitle,
        Button backButton,
        TextBlock errorText,
        TextBlock saveStatus,
        TaskCompletionSource<bool> completion,
        Func<Task<bool>> saveAsync)
    {
        var modal = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Stretch,
            Background = Brush("V2BackgroundBrush"),
            BorderThickness = new Thickness(0),
        };

        void UpdateBounds()
        {
            var metrics = new SettingsOverlayMetrics(RootGrid.ActualWidth, RootGrid.ActualHeight);
            modal.Width = metrics.Width;
            modal.Height = RootGrid.ActualHeight > 0 ? RootGrid.ActualHeight : metrics.Height;
            var contentWidth = Math.Max(0, metrics.Width - 80);
            content.Width = contentWidth;
            content.MaxWidth = contentWidth;
        }

        UpdateBounds();
        SizeChangedEventHandler? sizeHandler = null;
        sizeHandler = (_, _) => UpdateBounds();
        RootGrid.SizeChanged += sizeHandler;

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var header = new Grid
        {
            Padding = new Thickness(40, 48, 40, 18),
        };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        backButton.HorizontalAlignment = HorizontalAlignment.Left;
        backButton.Margin = new Thickness(0, 0, 0, 8);
        var titleStack = new StackPanel
        {
            Spacing = 0,
            Children =
            {
                backButton,
                pageTitle,
            },
        };
        header.Children.Add(titleStack);
        var closeButton = new Button
        {
            Width = 32,
            Height = 32,
            Padding = new Thickness(0),
            Background = Transparent,
            BorderBrush = Transparent,
            CornerRadius = new CornerRadius(8),
            Content = Icon("X", 16, Brush("V2MutedForegroundBrush")),
        };
        closeButton.VerticalAlignment = VerticalAlignment.Top;
        closeButton.Click += (_, _) =>
        {
            if (sizeHandler is not null) RootGrid.SizeChanged -= sizeHandler;
            completion.TrySetResult(false);
        };
        Grid.SetColumn(closeButton, 1);
        header.Children.Add(closeButton);
        root.Children.Add(header);

        var body = new Grid
        {
            MinHeight = 0,
        };
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var contentHost = new Grid
        {
            Padding = new Thickness(40, 0, 40, 18),
            MinWidth = 0,
        };
        content.HorizontalAlignment = HorizontalAlignment.Stretch;
        content.VerticalAlignment = VerticalAlignment.Stretch;
        contentHost.Children.Add(content);
        body.Children.Add(contentHost);
        Grid.SetRow(body, 1);
        root.Children.Add(body);

        var footer = new Grid
        {
            Padding = new Thickness(40, 10, 40, 20),
        };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        errorText.VerticalAlignment = VerticalAlignment.Center;
        errorText.MaxHeight = 36;
        footer.Children.Add(errorText);
        Grid.SetColumn(saveStatus, 1);
        saveStatus.Margin = new Thickness(0, 0, 10, 0);
        footer.Children.Add(saveStatus);
        var footerButtons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Spacing = 8,
        };
        var reloadButton = new Button
        {
            Content = IconText("Refresh", T("settings.config.reloadCurrent"), 14),
            Height = 32,
            MinWidth = 132,
            Style = (Style)Application.Current.Resources["V2ToolbarButtonStyle"],
        };
        reloadButton.Click += (_, _) =>
        {
            saveStatus.Text = T("settings.config.reloadSummary");
        };
        var saveButton = new Button
        {
            Content = IconText("Save", T("settings.config.saveReload"), 14, Brush("V2InverseForegroundBrush")),
            Height = 32,
            MinWidth = 132,
            Background = Brush("V2InverseBrush"),
            Foreground = Brush("V2InverseForegroundBrush"),
            BorderBrush = Transparent,
            CornerRadius = new CornerRadius(8),
        };
        saveButton.Click += async (_, _) =>
        {
            saveButton.IsEnabled = false;
            reloadButton.IsEnabled = false;
            saveStatus.Text = T("settings.config.saving");
            var saved = await saveAsync();
            saveButton.IsEnabled = true;
            reloadButton.IsEnabled = true;
            if (!saved)
            {
                saveStatus.Text = "";
                return;
            }

            if (sizeHandler is not null) RootGrid.SizeChanged -= sizeHandler;
            completion.TrySetResult(true);
        };
        footerButtons.Children.Add(reloadButton);
        footerButtons.Children.Add(saveButton);
        Grid.SetColumn(footerButtons, 2);
        footer.Children.Add(footerButtons);
        Grid.SetRow(footer, 2);
        root.Children.Add(footer);

        modal.Child = root;
        return modal;
    }

    private TextBox Box(string text, string placeholder = "") => new()
    {
        Text = text,
        PlaceholderText = placeholder,
        Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
        Height = 34,
        MinWidth = 0,
        HorizontalAlignment = HorizontalAlignment.Stretch,
    };

    private sealed class SettingsModelsEditorState
    {
        public required FrameworkElement Root { get; init; }
        public required Func<List<NativeProviderEntry>> ReadProviders { get; init; }
        public required Func<List<NativeModelEntry>> ReadModelEntries { get; init; }
        public required Func<ICredentialStore, Task> WriteSecretsAsync { get; init; }
    }

    private sealed class McpServerDraft
    {
        public string Name { get; set; } = "";
        public string Transport { get; set; } = "stdio";
        public string Command { get; set; } = "";
        public string ArgsText { get; set; } = "";
        public string EnvText { get; set; } = "";
        public bool PerSession { get; set; }
        public string Url { get; set; } = "";
        public string HeadersText { get; set; } = "";
    }

    private sealed class ProviderEditorRow
    {
        public required Border Container { get; init; }
        public required TextBox IdBox { get; init; }
        public required ComboBox ApiTypeBox { get; init; }
        public required TextBox BaseUrlBox { get; init; }
        public required PasswordBox ApiKeyBox { get; init; }
        public required TextBox HeadersBox { get; init; }
        public required string InitialSecretAccount { get; init; }
    }

    private sealed class ModelEntryEditorRow
    {
        public required Border Container { get; init; }
        public required TextBox IdBox { get; init; }
        public required ComboBox ProviderBox { get; init; }
        public required TextBox NameBox { get; init; }
        public required TextBox ContextWindowBox { get; init; }
    }

    private SettingsModelsEditorState BuildModelsEditor(
        IEnumerable<NativeProviderEntry> providers,
        IEnumerable<NativeModelEntry> entries,
        IReadOnlyDictionary<string, string> providerSecrets)
    {
        var providerRows = new List<ProviderEditorRow>();
        var modelRows = new List<ModelEntryEditorRow>();
        var providerList = new StackPanel { Spacing = 10 };
        var entryList = new StackPanel { Spacing = 10 };

        Button SmallButton(string text) => new()
        {
            Content = text,
            Height = 32,
            Style = (Style)Application.Current.Resources["V2ToolbarButtonStyle"],
        };

        Border SubCard(string title, string detail, Button action, StackPanel list)
        {
            var header = new Grid { ColumnSpacing = 12 };
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            header.Children.Add(new StackPanel
            {
                Spacing = 2,
                Children =
                {
                    new TextBlock { Text = title, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = Brush("V2ForegroundBrush") },
                    new TextBlock { Text = detail, FontSize = 12, Foreground = Brush("V2MutedForegroundBrush"), TextWrapping = TextWrapping.Wrap },
                },
            });
            Grid.SetColumn(action, 1);
            header.Children.Add(action);

            return new Border
            {
                CornerRadius = new CornerRadius(8),
                BorderBrush = Brush("V2BorderBrush"),
                BorderThickness = new Thickness(1),
                Background = Brush("V2CardBrush"),
                Padding = new Thickness(14),
                Child = new StackPanel
                {
                    Spacing = 12,
                    Children = { header, list },
                },
            };
        }

        void RefreshProviderChoices()
        {
            var ids = providerRows
                .Select(row => row.IdBox.Text.Trim())
                .Where(id => !string.IsNullOrWhiteSpace(id))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
            if (ids.Count == 0) ids.Add("g9claw");

            foreach (var row in modelRows)
            {
                var previous = row.ProviderBox.SelectedItem is ComboBoxItem { Tag: string tag } ? tag : "";
                row.ProviderBox.Items.Clear();
                foreach (var id in ids)
                {
                    row.ProviderBox.Items.Add(new ComboBoxItem { Content = id, Tag = id });
                }

                var selectedIndex = Math.Max(0, ids.FindIndex(id => string.Equals(id, previous, StringComparison.OrdinalIgnoreCase)));
                row.ProviderBox.SelectedIndex = selectedIndex;
            }
        }

        ProviderEditorRow AddProviderRow(NativeProviderEntry provider)
        {
            var id = Box(provider.Id, "g9claw");
            id.FontFamily = new FontFamily("Consolas");
            var type = EnumCombo(provider.ApiType);
            var baseUrl = Box(provider.BaseUrl, "https://api.example.com/v1");
            baseUrl.FontFamily = new FontFamily("Consolas");
            var apiKey = new PasswordBox
            {
                PlaceholderText = providerSecrets.TryGetValue(provider.SecretAccount, out var secret)
                    ? $"Stored: {SettingsSecurity.MaskSecret(secret)}"
                    : "sk-...",
                FontSize = 13,
                Height = 34,
                MinWidth = 0,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                CornerRadius = new CornerRadius(8),
            };
            var headers = Area(JsonSerializer.Serialize(provider.Headers ?? [], new JsonSerializerOptions { WriteIndented = true }));
            headers.MinHeight = 74;
            headers.MaxHeight = 120;
            headers.FontFamily = new FontFamily("Consolas");
            var remove = SmallButton(T("common.delete"));
            remove.Foreground = Brush("V2RedBrush");

            var content = new StackPanel
            {
                Spacing = 8,
                Children =
                {
                    new Grid
                    {
                        ColumnSpacing = 8,
                        ColumnDefinitions =
                        {
                            new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                            new ColumnDefinition { Width = GridLength.Auto },
                        },
                        Children =
                        {
                            Field("id", id),
                            remove,
                        },
                    },
                    TwoColumn(Field(T("settings.config.apiType"), type), Field(T("settings.config.baseUrl"), baseUrl)),
                    Field(T("settings.config.apiKey"), apiKey),
                    Field(T("settings.config.headers"), headers),
                },
            };
            Grid.SetColumn(remove, 1);

            var row = new ProviderEditorRow
            {
                Container = new Border
                {
                    CornerRadius = new CornerRadius(8),
                    BorderBrush = Brush("V2BorderBrush"),
                    BorderThickness = new Thickness(1),
                    Background = Brush("V2BackgroundBrush"),
                    Padding = new Thickness(10),
                    Child = content,
                },
                IdBox = id,
                ApiTypeBox = type,
                BaseUrlBox = baseUrl,
                ApiKeyBox = apiKey,
                HeadersBox = headers,
                InitialSecretAccount = provider.SecretAccount,
            };

            remove.Click += (_, _) =>
            {
                providerRows.Remove(row);
                providerList.Children.Remove(row.Container);
                RefreshProviderChoices();
            };
            id.TextChanged += (_, _) => RefreshProviderChoices();
            providerRows.Add(row);
            providerList.Children.Add(row.Container);
            return row;
        }

        ModelEntryEditorRow AddModelRow(NativeModelEntry entry)
        {
            var id = Box(entry.Id, "default");
            id.FontFamily = new FontFamily("Consolas");
            var providerBox = new ComboBox { Height = 34, MinWidth = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
            var name = Box(entry.Name, "qwen3.6-27b");
            name.FontFamily = new FontFamily("Consolas");
            var context = Box(entry.ContextWindow.ToString(), "160000");
            var remove = SmallButton(T("common.delete"));
            remove.Foreground = Brush("V2RedBrush");

            var content = new StackPanel
            {
                Spacing = 8,
                Children =
                {
                    new Grid
                    {
                        ColumnSpacing = 8,
                        ColumnDefinitions =
                        {
                            new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                            new ColumnDefinition { Width = GridLength.Auto },
                        },
                        Children =
                        {
                            Field("id", id),
                            remove,
                        },
                    },
                    TwoColumn(Field(T("settings.config.providerId"), providerBox), Field(T("settings.config.model"), name)),
                    Field(T("settings.config.contextWindow"), context),
                },
            };
            Grid.SetColumn(remove, 1);

            var row = new ModelEntryEditorRow
            {
                Container = new Border
                {
                    CornerRadius = new CornerRadius(8),
                    BorderBrush = Brush("V2BorderBrush"),
                    BorderThickness = new Thickness(1),
                    Background = Brush("V2BackgroundBrush"),
                    Padding = new Thickness(10),
                    Child = content,
                },
                IdBox = id,
                ProviderBox = providerBox,
                NameBox = name,
                ContextWindowBox = context,
            };

            remove.Click += (_, _) =>
            {
                modelRows.Remove(row);
                entryList.Children.Remove(row.Container);
            };
            modelRows.Add(row);
            entryList.Children.Add(row.Container);
            RefreshProviderChoices();
            for (var index = 0; index < providerBox.Items.Count; index++)
            {
                if (providerBox.Items[index] is ComboBoxItem { Tag: string tag } &&
                    string.Equals(tag, entry.ProviderId, StringComparison.OrdinalIgnoreCase))
                {
                    providerBox.SelectedIndex = index;
                    break;
                }
            }

            return row;
        }

        foreach (var provider in providers)
        {
            AddProviderRow(provider);
        }

        if (providerRows.Count == 0)
        {
            AddProviderRow(NativeProviderEntry.FromProviderConfig(State.Settings.ProviderConfig));
        }

        foreach (var entry in entries)
        {
            AddModelRow(entry);
        }

        if (modelRows.Count == 0)
        {
            AddModelRow(NativeModelEntry.FromProviderConfig(State.Settings.ProviderConfig));
        }

        var addProvider = SmallButton(T("settings.config.addProvider"));
        addProvider.Click += (_, _) =>
        {
            var index = providerRows.Count + 1;
            AddProviderRow(new NativeProviderEntry($"provider{index}", ProviderApiType.OpenAIChat, "", $"g9claw-provider-provider{index}", []));
            RefreshProviderChoices();
        };
        var addEntry = SmallButton(T("settings.config.addModelEntry"));
        addEntry.Click += (_, _) =>
        {
            var providerId = providerRows.FirstOrDefault()?.IdBox.Text.Trim() ?? "g9claw";
            AddModelRow(new NativeModelEntry(modelRows.Count == 0 ? "default" : $"entry{modelRows.Count + 1}", providerId, "", State.Settings.ContextWindow));
        };

        var root = new StackPanel
        {
            Spacing = 10,
            Children =
            {
                new TextBlock
                {
                    Text = T("settings.config.models").ToUpperInvariant(),
                    FontSize = 13,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    CharacterSpacing = 50,
                },
                new TextBlock
                {
                    Text = T("settings.config.modelsDetail"),
                    FontSize = 12,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    TextWrapping = TextWrapping.Wrap,
                },
                SubCard(T("settings.config.providers"), T("settings.config.providersDetail"), addProvider, providerList),
                SubCard(T("settings.config.modelEntries"), T("settings.config.modelEntriesDetail"), addEntry, entryList),
            },
        };

        return new SettingsModelsEditorState
        {
            Root = root,
            ReadProviders = () => providerRows.Select((row, index) =>
            {
                var id = NativeSettingsIds.Normalize(row.IdBox.Text, index == 0 ? "g9claw" : $"provider{index + 1}");
                var account = string.IsNullOrWhiteSpace(row.InitialSecretAccount)
                    ? $"g9claw-provider-{id}"
                    : row.InitialSecretAccount;
                return new NativeProviderEntry(
                    id,
                    SelectedEnum<ProviderApiType>(row.ApiTypeBox),
                    row.BaseUrlBox.Text,
                    account,
                    HeadersFromText(row.HeadersBox.Text));
            }).ToList(),
            ReadModelEntries = () => modelRows.Select((row, index) =>
            {
                var provider = row.ProviderBox.SelectedItem is ComboBoxItem { Tag: string tag }
                    ? tag
                    : providerRows.FirstOrDefault()?.IdBox.Text.Trim() ?? "g9claw";
                return new NativeModelEntry(
                    NativeSettingsIds.Normalize(row.IdBox.Text, index == 0 ? "default" : $"model{index + 1}"),
                    provider,
                    row.NameBox.Text,
                    IntValue(row.ContextWindowBox.Text, State.Settings.ContextWindow));
            }).ToList(),
            WriteSecretsAsync = async store =>
            {
                foreach (var row in providerRows)
                {
                    if (string.IsNullOrWhiteSpace(row.ApiKeyBox.Password)) continue;
                    var id = NativeSettingsIds.Normalize(row.IdBox.Text, "g9claw");
                    var account = string.IsNullOrWhiteSpace(row.InitialSecretAccount)
                        ? $"g9claw-provider-{id}"
                        : row.InitialSecretAccount;
                    await store.WriteSecretAsync(account, row.ApiKeyBox.Password);
                }
            },
        };
    }

    private Grid TwoColumn(FrameworkElement left, FrameworkElement right)
    {
        var grid = new Grid { ColumnSpacing = 10, MinWidth = 0 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(left);
        Grid.SetColumn(right, 1);
        grid.Children.Add(right);
        return grid;
    }

    private static Dictionary<string, string> HeadersFromText(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        using var doc = JsonDocument.Parse(text);
        if (doc.RootElement.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidOperationException("Provider headers must be a JSON object.");
        }

        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var property in doc.RootElement.EnumerateObject())
        {
            result[property.Name] = property.Value.ValueKind == JsonValueKind.String
                ? property.Value.GetString() ?? ""
                : property.Value.ToString();
        }

        return result;
    }

    private FrameworkElement ConfigSettingsPanel(
        ComboBox apiType,
        TextBox baseUrl,
        TextBox model,
        PasswordBox apiKey,
        TextBox providerId,
        TextBox modelEntryId,
        TextBox workspaceRoot,
        TextBox generalWorkspace,
        TextBox databasePath,
        TextBox httpsProxy,
        TextBox timeout,
        TextBox contextWindow,
        TextBox agentMain,
        TextBox agentSubagent,
        TextBox agentParams,
        CheckBox alwaysOnEnabled,
        TextBox alwaysOnTick,
        TextBox alwaysOnCooldown,
        TextBox alwaysOnDailyBudget,
        TextBox alwaysOnHeartbeat,
        TextBox alwaysOnRecent,
        TextBox alwaysOnClient,
        CheckBox memoryEnabled,
        TextBox memoryModel,
        TextBox memoryReasoningMode,
        TextBox memoryAutoIndex,
        TextBox memoryAutoDream,
        TextBox memoryCapture,
        CheckBox memoryIncludeAssistant,
        TextBox memoryMaxChars,
        TextBox memoryHeartbeatBatch,
        CheckBox ragEnabled,
        CheckBox ragDisableBuiltIn,
        TextBox ragLocalUrl,
        TextBox ragLocalModel,
        TextBox ragLocalDatabase,
        TextBox ragLocalTopK,
        TextBox ragGlmUrl,
        TextBox ragGlmTopK,
        CheckBox gatewayEnabled,
        TextBox gatewayHome,
        TextBox gatewayHost,
        TextBox gatewayServerPort,
        TextBox gatewayVitePort,
        TextBox gatewayProxyPort,
        CheckBox routerEnabled,
        CheckBox routerLog,
        TextBox routerHost,
        TextBox routerPort,
        TextBox routerRoute,
        TextBox inputPrice,
        TextBox outputPrice,
        TextBox baselineInput,
        TextBox baselineOutput,
        FrameworkElement modelsEditorRoot)
    {
        var sections = new List<(string Label, FrameworkElement Content)>
        {
            (T("settings.config.runtime"), SettingsPanel(
                SettingsSection(T("settings.config.runtime"), T("settings.config.runtimeDetail"),
                    Field(T("settings.config.gatewayHost"), gatewayHost),
                    Field(T("settings.config.gatewayServerPort"), gatewayServerPort),
                    Field(T("settings.config.gatewayVitePort"), gatewayVitePort),
                    Field(T("settings.config.gatewayProxyPort"), gatewayProxyPort),
                    Field(T("settings.config.contextWindow"), contextWindow),
                    Field(T("settings.config.apiTimeoutMs"), timeout),
                    Field(T("settings.config.httpsProxy"), httpsProxy),
                    Field(T("settings.config.databasePath"), databasePath),
                    Field(T("settings.config.workspacesRoot"), workspaceRoot),
                    Field(T("settings.config.generalWorkspace"), generalWorkspace)))),
            (T("settings.config.models"), SettingsPanel(
                modelsEditorRoot)),
            (T("settings.config.agents"), SettingsPanel(
                SettingsSection(T("settings.config.agents"), T("settings.config.agentsDetail"),
                    Field(T("settings.config.mainModelEntry"), agentMain),
                    Field(T("settings.config.subagentModelEntry"), agentSubagent),
                    Field(T("settings.config.paramsJson"), agentParams)))),
            (T("settings.config.alwaysOn"), SettingsPanel(
                SettingsSection(T("settings.config.alwaysOn"), T("settings.config.alwaysOnDetail"),
                    alwaysOnEnabled,
                    Field(T("settings.config.alwaysOnTick"), alwaysOnTick),
                    Field(T("settings.config.alwaysOnCooldown"), alwaysOnCooldown),
                    Field(T("settings.config.alwaysOnDailyBudget"), alwaysOnDailyBudget),
                    Field(T("settings.config.alwaysOnHeartbeat"), alwaysOnHeartbeat),
                    Field(T("settings.config.alwaysOnRecent"), alwaysOnRecent),
                    Field(T("settings.config.alwaysOnClient"), alwaysOnClient)))),
            (T("settings.config.memory"), SettingsPanel(
                SettingsSection(T("settings.config.memory"), T("settings.config.memoryDetail"),
                    memoryEnabled,
                    memoryIncludeAssistant,
                    Field(T("settings.config.memoryModel"), memoryModel),
                    Field(T("settings.config.memoryReasoningMode"), memoryReasoningMode),
                    Field(T("settings.config.memoryAutoIndex"), memoryAutoIndex),
                    Field(T("settings.config.memoryAutoDream"), memoryAutoDream),
                    Field(T("settings.config.memoryCapture"), memoryCapture),
                    Field(T("settings.config.memoryMaxChars"), memoryMaxChars),
                    Field(T("settings.config.memoryHeartbeatBatch"), memoryHeartbeatBatch)))),
            (T("settings.config.rag"), SettingsPanel(
                SettingsSection(T("settings.config.rag"), T("settings.config.ragDetail"),
                    ragEnabled,
                    ragDisableBuiltIn,
                    Field(T("settings.config.ragLocalUrl"), ragLocalUrl),
                    Field(T("settings.config.ragLocalModel"), ragLocalModel),
                    Field(T("settings.config.ragLocalDatabase"), ragLocalDatabase),
                    Field(T("settings.config.ragLocalTopK"), ragLocalTopK),
                    Field(T("settings.config.ragGlmUrl"), ragGlmUrl),
                    Field(T("settings.config.ragGlmTopK"), ragGlmTopK)))),
            (T("settings.config.router"), SettingsPanel(
                SettingsSection(T("settings.config.router"), T("settings.config.routerDetail"),
                    routerEnabled,
                    routerLog,
                    Field(T("settings.config.routerHost"), routerHost),
                    Field(T("settings.config.routerPort"), routerPort),
                    Field(T("settings.config.defaultRoute"), routerRoute),
                    Field(T("settings.config.inputPrice"), inputPrice),
                    Field(T("settings.config.outputPrice"), outputPrice),
                    Field(T("settings.config.baselineInputPrice"), baselineInput),
                    Field(T("settings.config.baselineOutputPrice"), baselineOutput)))),
            (T("settings.config.gateway"), SettingsPanel(
                SettingsSection(T("settings.config.gateway"), T("settings.config.gatewayDetail"),
                    gatewayEnabled,
                    Field(T("settings.config.gatewayHome"), gatewayHome),
                    DisabledLegacyField(T("settings.config.serverPort"), T("settings.config.serverPortDisabled")),
                    DisabledLegacyField(T("settings.config.vitePort"), T("settings.config.vitePortDisabled"))))),
        };

        var nav = new StackPanel { Spacing = 4, Width = 180, MinWidth = 180 };
        var content = new ContentControl { Content = sections[0].Content };
        var navButtons = new List<Button>();
        void SelectConfigSection(Button activeButton, FrameworkElement sectionContent)
        {
            content.Content = sectionContent;
            foreach (var button in navButtons)
            {
                var active = ReferenceEquals(button, activeButton);
                button.Background = active ? Brush("V2HoverBrush") : Transparent;
                button.Foreground = active ? Brush("V2ForegroundBrush") : Brush("V2MutedForegroundBrush");
            }
        }

        foreach (var section in sections)
        {
            var button = new Button
            {
                Content = section.Label,
                Height = 32,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Style = (Style)Application.Current.Resources["V2ToolbarButtonStyle"],
            };
            button.Click += (_, _) => SelectConfigSection(button, section.Content);
            navButtons.Add(button);
            nav.Children.Add(button);
        }

        if (navButtons.Count > 0)
        {
            SelectConfigSection(navButtons[0], sections[0].Content);
        }

        var root = new Grid { ColumnSpacing = 12 };
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(nav);
        Grid.SetColumn(content, 1);
        root.Children.Add(content);
        return root;
    }

    private FrameworkElement DisabledLegacyField(string label, string detail)
    {
        var box = Box("", "");
        box.IsEnabled = false;
        box.PlaceholderText = detail;
        return Field(label, box);
    }

    private TextBox Area(string text) => new()
    {
        AcceptsReturn = true,
        Text = text,
        TextWrapping = TextWrapping.NoWrap,
        MinHeight = 126,
        MaxHeight = 220,
        Style = (Style)Application.Current.Resources["V2TextBoxStyle"],
        MinWidth = 0,
        HorizontalAlignment = HorizontalAlignment.Stretch,
    };

    private CheckBox Check(string label, bool isChecked) => new()
    {
        Content = label,
        IsChecked = isChecked,
        FontSize = 13,
        Margin = new Thickness(14, 8, 14, 8),
        Foreground = Brush("V2ForegroundBrush"),
    };

    private ComboBox EnumCombo<TEnum>(TEnum value) where TEnum : struct, Enum
    {
        var combo = new ComboBox { Height = 34, MinWidth = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var item in Enum.GetValues<TEnum>())
        {
            combo.Items.Add(new ComboBoxItem
            {
                Content = EnumLabel(item),
                Tag = item,
            });
        }

        combo.SelectedIndex = Math.Max(0, Enum.GetValues<TEnum>().ToList().IndexOf(value));
        return combo;
    }

    private ComboBox IntCombo(IEnumerable<int> values, int selectedValue, string suffix, double width)
    {
        var options = values.ToList();
        var combo = new ComboBox
        {
            Height = 34,
            Width = width,
            MinWidth = 0,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        foreach (var value in options)
        {
            combo.Items.Add(new ComboBoxItem
            {
                Content = string.IsNullOrWhiteSpace(suffix) ? value.ToString() : $"{value}{suffix}",
                Tag = value,
            });
        }

        var selectedIndex = options.IndexOf(selectedValue);
        combo.SelectedIndex = selectedIndex >= 0 ? selectedIndex : Math.Max(0, options.IndexOf(NativeEditorSettings.Defaults.FontSize));
        return combo;
    }

    private string EnumLabel<TEnum>(TEnum value) where TEnum : struct, Enum
    {
        var name = value.ToString();
        var key = typeof(TEnum) == typeof(AppColorScheme)
            ? $"settings.enum.theme.{name}"
            : typeof(TEnum) == typeof(AppLanguage)
                ? $"settings.enum.language.{name}"
                : typeof(TEnum) == typeof(ProjectSortOrder)
                    ? $"settings.enum.projectSort.{name}"
                    : "";
        var localized = string.IsNullOrEmpty(key) ? name : T(key);
        return localized == key ? name : localized;
    }

    private FrameworkElement SettingsPanel(params FrameworkElement[] sections)
    {
        var panel = new Grid
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            RowSpacing = 18,
        };
        for (var index = 0; index < sections.Length; index++)
        {
            var section = sections[index];
            section.HorizontalAlignment = HorizontalAlignment.Stretch;
            panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(section, index);
            panel.Children.Add(section);
        }

        var scroll = new ScrollViewer
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = panel,
        };
        scroll.SizeChanged += (_, args) =>
        {
            if (args.NewSize.Width > 0)
            {
                panel.Width = args.NewSize.Width;
            }
        };
        return scroll;
    }

    private FrameworkElement SettingsSection(string title, string detail, params FrameworkElement[] children)
    {
        var section = new StackPanel
        {
            Spacing = 8,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        section.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 15,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush("V2ForegroundBrush"),
        });
        if (!string.IsNullOrWhiteSpace(detail))
        {
            section.Children.Add(new TextBlock
            {
                Text = detail,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                Foreground = Brush("V2MutedForegroundBrush"),
            });
        }

        var panel = new StackPanel { Spacing = 0 };
        for (var index = 0; index < children.Length; index++)
        {
            var child = children[index];
            if (child is CheckBox checkBox)
            {
                child = SettingsToggleRow(checkBox.Content?.ToString() ?? "", "", checkBox);
            }

            panel.Children.Add(child);
            if (index < children.Length - 1)
            {
                panel.Children.Add(new Border
                {
                    Height = 1,
                    Background = Brush("V2BorderBrush"),
                    Opacity = 0.8,
                    Margin = new Thickness(54, 0, 0, 0),
                });
            }
        }

        section.Children.Add(new Border
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("V2BorderBrush"),
            BorderThickness = new Thickness(1),
            Background = Brush("V2CardBrush"),
            Child = panel,
        });

        return section;
    }

    private FrameworkElement SettingsToggleRow(string title, string detail, CheckBox checkBox)
    {
        checkBox.Content = null;
        checkBox.Margin = new Thickness(0);
        checkBox.VerticalAlignment = VerticalAlignment.Center;
        checkBox.HorizontalAlignment = HorizontalAlignment.Right;
        checkBox.MinWidth = 0;

        var grid = new Grid
        {
            MinHeight = 48,
            Padding = new Thickness(16, 7, 16, 7),
            ColumnSpacing = 16,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
            Children =
            {
                SettingsFieldLabel(title, detail),
                checkBox,
            },
        };
        Grid.SetColumn(checkBox, 1);
        return grid;
    }

    private FrameworkElement SettingsNavigationRow(string iconKey, string title, string detail, Action action)
    {
        var button = new Button
        {
            MinHeight = 58,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = Transparent,
            BorderBrush = Transparent,
            Padding = new Thickness(16, 9, 16, 9),
            Content = new Grid
            {
                ColumnSpacing = 14,
                ColumnDefinitions =
                {
                    new ColumnDefinition { Width = new GridLength(28) },
                    new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                    new ColumnDefinition { Width = GridLength.Auto },
                },
                Children =
                {
                    Icon(iconKey, 16, Brush("V2SecondaryForegroundBrush")),
                    SettingsFieldLabel(title, detail),
                    Icon("ChevronRight", 13, Brush("V2MutedForegroundBrush")),
                },
            },
        };
        if (button.Content is Grid grid)
        {
            Grid.SetColumn((FrameworkElement)grid.Children[1], 1);
            Grid.SetColumn((FrameworkElement)grid.Children[2], 2);
        }

        button.Click += (_, _) => action();
        return button;
    }

    private FrameworkElement SettingsMenuRow(string iconKey, string title, string detail, FrameworkElement trailing)
    {
        trailing.VerticalAlignment = VerticalAlignment.Center;
        trailing.HorizontalAlignment = HorizontalAlignment.Right;
        trailing.MinWidth = 0;
        trailing.MaxWidth = 220;

        var grid = new Grid
        {
            MinHeight = 58,
            Padding = new Thickness(16, 9, 16, 9),
            ColumnSpacing = 14,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(28) },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
            Children =
            {
                Icon(iconKey, 16, Brush("V2SecondaryForegroundBrush")),
                SettingsFieldLabel(title, detail),
                trailing,
            },
        };
        Grid.SetColumn((FrameworkElement)grid.Children[1], 1);
        Grid.SetColumn((FrameworkElement)grid.Children[2], 2);
        return grid;
    }

    private StackPanel SettingsFieldLabel(string title, string detail) => new()
    {
        Spacing = 2,
        VerticalAlignment = VerticalAlignment.Center,
        Children =
        {
            new TextBlock
            {
                Text = title,
                FontSize = 13,
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                Foreground = Brush("V2ForegroundBrush"),
                TextWrapping = TextWrapping.Wrap,
            },
            new TextBlock
            {
                Text = detail,
                FontSize = 12,
                Foreground = Brush("V2MutedForegroundBrush"),
                TextWrapping = TextWrapping.Wrap,
                Visibility = string.IsNullOrWhiteSpace(detail) ? Visibility.Collapsed : Visibility.Visible,
            },
        },
    };

    private FrameworkElement Field(string label, Control control)
    {
        control.HorizontalAlignment = HorizontalAlignment.Stretch;
        control.MinWidth = 0;
        control.MaxWidth = double.PositiveInfinity;
        control.Width = double.NaN;

        return new StackPanel
        {
            Padding = new Thickness(14, 11, 14, 11),
            Spacing = 5,
            MinWidth = 0,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Children =
            {
                new TextBlock
                {
                    Text = label,
                    FontSize = 12,
                    FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                    Foreground = Brush("V2MutedForegroundBrush"),
                    TextWrapping = TextWrapping.Wrap,
                },
                control,
            },
        };
    }

    private static string MergeLines(string existing, IEnumerable<string> additions) =>
        string.Join(Environment.NewLine, Lines(existing).Concat(additions).Distinct(StringComparer.OrdinalIgnoreCase));

    private static int McpServerCount(string raw)
    {
        try
        {
            using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(raw) ? "{}" : raw);
            return document.RootElement.TryGetProperty("mcpServers", out var servers) && servers.ValueKind == JsonValueKind.Object
                ? servers.EnumerateObject().Count()
                : 0;
        }
        catch
        {
            return 0;
        }
    }

    private static List<McpServerDraft> ParseMcpServers(string raw)
    {
        var result = new List<McpServerDraft>();
        try
        {
            using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(raw) ? "{}" : raw);
            if (!document.RootElement.TryGetProperty("mcpServers", out var servers) ||
                servers.ValueKind != JsonValueKind.Object)
            {
                return result;
            }

            foreach (var pair in servers.EnumerateObject())
            {
                if (pair.Value.ValueKind != JsonValueKind.Object) continue;
                var server = pair.Value;
                var command = JsonElementString(server, "command");
                var url = JsonElementString(server, "url");
                if (string.IsNullOrWhiteSpace(url)) url = JsonElementString(server, "httpUrl");
                var transport = !string.IsNullOrWhiteSpace(command) || string.IsNullOrWhiteSpace(url)
                    ? "stdio"
                    : "http";
                result.Add(new McpServerDraft
                {
                    Name = pair.Name,
                    Transport = transport,
                    Command = command,
                    ArgsText = JsonElementArrayToLines(server, "args"),
                    EnvText = JsonElementObjectToKeyValueLines(server, "env"),
                    PerSession = JsonElementBool(server, "perSession"),
                    Url = url,
                    HeadersText = JsonElementObjectToKeyValueLines(server, "headers"),
                });
            }
        }
        catch
        {
            return [];
        }

        return result;
    }

    private static string JsonElementString(JsonElement obj, string property)
    {
        if (!obj.TryGetProperty(property, out var value)) return "";
        return value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? ""
            : value.GetRawText();
    }

    private static bool JsonElementBool(JsonElement obj, string property) =>
        obj.TryGetProperty(property, out var value) &&
        value.ValueKind == JsonValueKind.True;

    private static string JsonElementArrayToLines(JsonElement obj, string property)
    {
        if (!obj.TryGetProperty(property, out var value) || value.ValueKind != JsonValueKind.Array) return "";
        return string.Join(Environment.NewLine, value.EnumerateArray().Select(item =>
            item.ValueKind == JsonValueKind.String ? item.GetString() ?? "" : item.GetRawText()));
    }

    private static string JsonElementObjectToKeyValueLines(JsonElement obj, string property)
    {
        if (!obj.TryGetProperty(property, out var value) || value.ValueKind != JsonValueKind.Object) return "";
        return string.Join(Environment.NewLine, value.EnumerateObject().Select(item =>
            $"{item.Name}={(item.Value.ValueKind == JsonValueKind.String ? item.Value.GetString() ?? "" : item.Value.GetRawText())}"));
    }

    private static string McpRawFromServers(string existingRaw, IEnumerable<McpServerDraft> drafts)
    {
        var root = JsonNode.Parse(string.IsNullOrWhiteSpace(existingRaw) ? "{}" : existingRaw) as JsonObject ?? [];
        var servers = new JsonObject();
        var usedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var draft in drafts)
        {
            var name = string.IsNullOrWhiteSpace(draft.Name) ? "new-mcp-server" : draft.Name.Trim();
            var baseName = name;
            var index = 2;
            while (!usedNames.Add(name))
            {
                name = $"{baseName}-{index}";
                index++;
            }

            if (string.Equals(draft.Transport, "http", StringComparison.OrdinalIgnoreCase))
            {
                var server = new JsonObject
                {
                    ["url"] = draft.Url,
                };
                var headers = JsonObjectFromKeyValueLines(draft.HeadersText);
                if (headers.Count > 0) server["headers"] = headers;
                servers[name] = server;
            }
            else
            {
                var server = new JsonObject
                {
                    ["command"] = draft.Command,
                    ["args"] = JsonArrayFromLines(draft.ArgsText),
                };
                var env = JsonObjectFromKeyValueLines(draft.EnvText);
                if (env.Count > 0) server["env"] = env;
                if (draft.PerSession) server["perSession"] = true;
                servers[name] = server;
            }
        }

        root["mcpServers"] = servers;
        return root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    private static string McpServerSummary(McpServerDraft server)
    {
        if (string.Equals(server.Transport, "http", StringComparison.OrdinalIgnoreCase))
        {
            return string.IsNullOrWhiteSpace(server.Url) ? "HTTP" : $"HTTP / {server.Url}";
        }

        var args = RawLines(server.ArgsText).ToList();
        var command = string.IsNullOrWhiteSpace(server.Command) ? "command" : server.Command;
        return args.Count == 0 ? $"STDIO / {command}" : $"STDIO / {command} {string.Join(" ", args)}";
    }

    private static string JsonString(JsonNode? node)
    {
        if (node is null) return "";
        try
        {
            return node.GetValue<string>() ?? "";
        }
        catch
        {
            return node.ToJsonString();
        }
    }

    private static bool JsonBool(JsonNode? node)
    {
        if (node is null) return false;
        try
        {
            return node.GetValue<bool>();
        }
        catch
        {
            return false;
        }
    }

    private static string JsonArrayToLines(JsonNode? node)
    {
        if (node is not JsonArray array) return "";
        return string.Join(Environment.NewLine, array.Select(JsonString).Where(value => !string.IsNullOrWhiteSpace(value)));
    }

    private static JsonArray JsonArrayFromLines(string text)
    {
        var array = new JsonArray();
        foreach (var line in RawLines(text))
        {
            array.Add(line);
        }
        return array;
    }

    private static string JsonObjectToKeyValueLines(JsonNode? node)
    {
        if (node is not JsonObject obj) return "";
        return string.Join(Environment.NewLine, obj.Select(pair => $"{pair.Key}={JsonString(pair.Value)}"));
    }

    private static JsonObject JsonObjectFromKeyValueLines(string text)
    {
        var obj = new JsonObject();
        foreach (var line in RawLines(text))
        {
            var split = line.IndexOf('=');
            if (split <= 0) continue;
            obj[line[..split].Trim()] = line[(split + 1)..].Trim();
        }

        return obj;
    }

    private static string AddMcpServerTemplate(string raw, string transport)
    {
        var root = JsonNode.Parse(string.IsNullOrWhiteSpace(raw) ? "{}" : raw) as JsonObject ?? [];
        if (root["mcpServers"] is not JsonObject servers)
        {
            servers = [];
            root["mcpServers"] = servers;
        }

        var normalizedTransport = string.Equals(transport, "http", StringComparison.OrdinalIgnoreCase) ? "http" : "stdio";
        var baseName = normalizedTransport == "http" ? "new-http-server" : "new-stdio-server";
        var name = baseName;
        var index = 2;
        while (servers.ContainsKey(name))
        {
            name = $"{baseName}-{index}";
            index++;
        }

        if (normalizedTransport == "http")
        {
            var headers = new JsonObject
            {
                ["Authorization"] = "Bearer ${env:MCP_TOKEN}",
            };
            servers[name] = new JsonObject
            {
                ["url"] = "http://127.0.0.1:3000/mcp",
                ["headers"] = headers,
            };
        }
        else
        {
            var args = new JsonArray();
            args.Add("-y");
            args.Add("@modelcontextprotocol/server-filesystem");
            args.Add(".");
            servers[name] = new JsonObject
            {
                ["command"] = "npx",
                ["args"] = args,
                ["env"] = new JsonObject(),
                ["perSession"] = true,
            };
        }

        return root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    private static List<string> Lines(string value) =>
        value.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(line => !string.IsNullOrWhiteSpace(line))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

    private static IEnumerable<string> RawLines(string value) =>
        value.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(line => !string.IsNullOrWhiteSpace(line));

    private static T SelectedEnum<T>(ComboBox combo) where T : struct, Enum
    {
        if (combo.SelectedItem is ComboBoxItem { Tag: T value }) return value;
        return Enum.TryParse<T>(combo.SelectedItem?.ToString(), out var parsed) ? parsed : default;
    }

    private static int IntValue(string value, int fallback) =>
        int.TryParse(value, out var parsed) ? parsed : fallback;

    private static int IntComboValue(ComboBox combo, int fallback)
    {
        if (combo.SelectedItem is ComboBoxItem { Tag: int value }) return value;
        return fallback;
    }

    private static decimal DecimalValue(string value) =>
        decimal.TryParse(value, out var parsed) ? parsed : 0;

    private ContentDialog Dialog(string title, object content, string primaryButtonText) => new()
    {
        XamlRoot = RootGrid.XamlRoot,
        Title = title,
        Content = content,
        PrimaryButtonText = primaryButtonText,
        CloseButtonText = T("common.cancel"),
        DefaultButton = ContentDialogButton.Primary,
    };

    private void PersistUiSettings()
    {
        _uiSettings = _uiSettings with
        {
            SidebarWidth = Math.Clamp(_uiSettings.SidebarWidth, V2UiSettings.SidebarMinWidth, V2UiSettings.SidebarMaxWidth),
            ExpandedProjectNames = _expandedProjectNames.ToList(),
            CollapsedSessionProjectNames = _collapsedSessionProjectNames.ToList(),
        };
        State.Settings = State.Settings with { UiSettings = _uiSettings.Normalize() };
        _ = _settingsStore.SaveAsync(State.Settings);
    }

    private void PersistUiPreferences()
    {
        State.UiPreferences = State.UiPreferences with { SidebarVisible = _isSidebarVisible };
        State.IsSidebarVisible = _isSidebarVisible;
        _ = _uiPreferencesStore.SaveAsync(State.UiPreferences);
    }

    private void RestoreComposerPermissionMode(string? sessionId)
    {
        State.ComposerPermissionMode = ComposerPermissionModeStorage.StoredMode(sessionId, _permissionModeValues);
    }

    private void SetComposerPermissionMode(ComposerPermissionMode mode)
    {
        State.ComposerPermissionMode = mode;
        _permissionModeValues = ComposerPermissionModeStorage.Save(mode, State.SelectedSessionId, _permissionModeValues);
        _ = _permissionModeStore.SaveAsync(_permissionModeValues);
    }

    private void OnSidebarDividerPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        _isDraggingSidebar = true;
        _dragStartX = e.GetCurrentPoint(RootGrid).Position.X;
        _dragStartWidth = _uiSettings.SidebarWidth;
        SidebarDivider.CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnSidebarDividerPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_isDraggingSidebar) return;
        var x = e.GetCurrentPoint(RootGrid).Position.X;
        _uiSettings = _uiSettings with
        {
            SidebarWidth = Math.Clamp(_dragStartWidth + (x - _dragStartX), V2UiSettings.SidebarMinWidth, V2UiSettings.SidebarMaxWidth),
        };
        SidebarColumn.Width = new GridLength(_uiSettings.SidebarWidth);
    }

    private void OnSidebarDividerPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_isDraggingSidebar) return;
        _isDraggingSidebar = false;
        SidebarDivider.ReleasePointerCapture(e.Pointer);
        PersistUiSettings();
    }

    private void OnSidebarDividerPointerEntered(object sender, PointerRoutedEventArgs e)
    {
        SidebarDivider.Background = Brush("V2BlueBrush");
    }

    private void OnSidebarDividerPointerExited(object sender, PointerRoutedEventArgs e)
    {
        if (!_isDraggingSidebar)
        {
            SidebarDivider.Background = Brush("V2BorderBrush");
        }
    }

    private Brush Brush(string key) => Application.Current.Resources.TryGetValue(key, out var value) && value is Brush brush
        ? brush
        : new SolidColorBrush(Colors.Transparent);

    private string T(string key) => _strings.T(key);

    private string Tf(string key, params object[] values) => string.Format(T(key), values);

    private string L(string english, string chinese) => IsChineseUi() ? chinese : english;

    private bool IsChineseUi() =>
        string.Equals(NativeI18nLanguageResolver.Resolve(State.Settings.Language), "zh-CN", StringComparison.OrdinalIgnoreCase);

    private static SolidColorBrush Transparent => new(Colors.Transparent);

    private static string FormatRelative(DateTimeOffset date)
    {
        var delta = DateTimeOffset.UtcNow - date.ToUniversalTime();
        if (delta.TotalMinutes < 1) return "just now";
        if (delta.TotalHours < 1) return $"{Math.Max(1, (int)delta.TotalMinutes)} mins ago";
        if (delta.TotalDays < 1) return $"{Math.Max(1, (int)delta.TotalHours)} hours ago";
        return $"{Math.Max(1, (int)delta.TotalDays)} days ago";
    }

    private static string FormatBytes(long bytes)
    {
        if (bytes < 1024) return $"{bytes} B";
        if (bytes < 1024 * 1024) return $"{bytes / 1024.0:0.#} KB";
        return $"{bytes / 1024.0 / 1024.0:0.#} MB";
    }

    private static string Money(decimal value) => value <= 0 ? "$0.00" : $"${value:0.######}";
}

public sealed class ChatLine
{
    public ChatLine(string role, string text)
    {
        Role = role;
        Text = text;
    }

    public string Role { get; set; }
    public string Text { get; set; }
}
