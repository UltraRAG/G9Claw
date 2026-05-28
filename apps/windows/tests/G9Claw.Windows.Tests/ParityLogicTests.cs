using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Runtime.CompilerServices;
using G9Claw.Windows.Core;
using Xunit;

namespace G9Claw.Windows.Tests;

public sealed class ParityLogicTests
{
    [Fact]
    public void WorkspacePathValidationCoversOutsideAndSystemPaths()
    {
        var root = @"C:\Users\tester\Workspace";
        var service = new WorkspaceService(root);

        Assert.False(service.ValidateWorkspacePath(@"C:\Windows").Valid);
        Assert.False(service.ValidateWorkspacePath(@"C:\Program Files").Valid);
        Assert.False(service.ValidateWorkspacePath(@"C:\ProgramData").Valid);
        Assert.False(service.ValidateWorkspacePath(@"C:\$Recycle.Bin").Valid);

        var outside = service.ValidateWorkspacePath(@"C:\Users\tester\Downloads\project");
        Assert.False(outside.Valid);
        Assert.Equal($"Workspace path must be within the allowed workspace root: {PathHelpers.NormalizeFullPath(root)}", outside.Error);

        var inside = service.ValidateWorkspacePath(@"C:\Users\tester\Workspace\project");
        Assert.True(inside.Valid);
        Assert.Equal(PathHelpers.NormalizeFullPath(@"C:\Users\tester\Workspace\project"), inside.ResolvedPath);
    }

    [Fact]
    public void WorkspacePathValidationHandlesChineseAndCaseInsensitivePaths()
    {
        var service = new WorkspaceService(@"C:\Users\tester\Workspace");

        Assert.True(service.ValidateWorkspacePath(@"C:\Users\tester\Workspace\中文项目").Valid);
        Assert.True(service.ValidateWorkspacePath(@"c:\users\tester\workspace\MixedCase").Valid);
        Assert.False(service.ValidateWorkspacePath(@"C:\Users\tester\workspace-other").Valid);
    }

    [Fact]
    public void ProjectSortingByNameMatchesSidebarPolicy()
    {
        var now = DateTimeOffset.UtcNow;
        var projects = new[]
        {
            Project("zeta", "Zeta", now),
            Project("alpha", "Alpha", now),
        };

        Assert.Equal(["Alpha", "Zeta"], WorkspaceService.SortedProjects(projects, ProjectSortOrder.Name).Select(project => project.DisplayName));
    }

    [Fact]
    public void ProjectSortingByDateUsesMostRecentSessionActivity()
    {
        var now = DateTimeOffset.UtcNow;
        var old = Project("old", "Old", now.AddMinutes(-50));
        var recent = Project("recent", "Recent", now.AddMinutes(-90));
        recent.Sessions.Add(new ProjectSession(
            "recent-session",
            SessionProvider.G9Claw,
            "Recent",
            "",
            now.AddMinutes(-90),
            null,
            now,
            null,
            SessionState.Idle));

        Assert.Equal("recent", WorkspaceService.SortedProjects([old, recent], ProjectSortOrder.Date).First().Name);
    }

    [Fact]
    public void WebV2PrimaryTabsMatchDesktopOrder()
    {
        Assert.Equal(
            [AppTab.Chat, AppTab.Files, AppTab.Skills, AppTab.Dashboard, AppTab.Memory, AppTab.AlwaysOn],
            AppTabCatalog.PrimaryTabs);
        Assert.Equal(["Agent", "Files", "Skills", "Routing", "Memory", "Always-on"], AppTabCatalog.PrimaryTabDescriptors.Select(tab => tab.Label));
        Assert.DoesNotContain(AppTab.Shell, AppTabCatalog.PrimaryTabs);
        Assert.DoesNotContain(AppTab.Git, AppTabCatalog.PrimaryTabs);
        Assert.DoesNotContain(AppTab.Tasks, AppTabCatalog.PrimaryTabs);
    }

    [Fact]
    public void CoreDescriptorsMatchNativeMacAppModels()
    {
        Assert.Equal("g9claw", SessionProvider.G9Claw.Id());
        Assert.Equal("PilotDeck", SessionProvider.G9Claw.DisplayName());
        Assert.Equal("Cursor", SessionProvider.Cursor.DisplayName());
        Assert.True(SessionProvider.G9Claw.IsNativeAvailable());
        Assert.False(SessionProvider.Codex.IsNativeAvailable());

        Assert.Equal("agent", ChatRunMode.Agent.Id());
        Assert.Equal("\u667a\u80fd\u4f53", ChatRunMode.Agent.Label());
        Assert.Equal("sparkles", ChatRunMode.Agent.SystemImage());
        Assert.Equal("Run the agent with tools and streaming output.", ChatRunMode.Agent.Detail());
        Assert.Equal("plan", ChatRunMode.Plan.Id());
        Assert.Equal("\u8ba1\u5212", ChatRunMode.Plan.Label());
        Assert.Equal("checklist", ChatRunMode.Plan.SystemImage());

        Assert.Equal("permissionMode-default", ComposerPermissionModeCatalog.DefaultStorageKey);
        Assert.Equal("permissionMode-", ComposerPermissionModeCatalog.SessionStorageKeyPrefix);
        Assert.Equal("default", ComposerPermissionMode.Default.Id());
        Assert.Equal("Default permissions", ComposerPermissionMode.Default.Label());
        Assert.Equal("hand.raised", ComposerPermissionMode.Default.SystemImage());
        Assert.Equal("bypassPermissions", ComposerPermissionMode.BypassPermissions.Id());
        Assert.Equal("\u5b8c\u5168\u8bbf\u95ee\u6743\u9650", ComposerPermissionMode.BypassPermissions.Label());
        Assert.Equal("shield.lefthalf.filled", ComposerPermissionMode.BypassPermissions.SystemImage());
    }

    [Fact]
    public void NativeUIPreferencesAndToolExpansionMatchMacDefaults()
    {
        var preferences = new NativeUIPreferences();

        Assert.False(preferences.AutoExpandTools);
        Assert.False(preferences.ShowRawParameters);
        Assert.True(preferences.ShowThinking);
        Assert.True(preferences.AutoScrollToBottom);
        Assert.False(preferences.SendByCtrlEnter);
        Assert.True(preferences.SidebarVisible);

        var expanded = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var collapsed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        Assert.False(ToolRowExpansionPolicy.IsExpanded("tool-1", expanded, collapsed, autoExpandTools: false));
        Assert.True(ToolRowExpansionPolicy.IsExpanded("tool-1", expanded, collapsed, autoExpandTools: true));

        ToolRowExpansionPolicy.Toggle("tool-1", expanded, collapsed, autoExpandTools: true);
        Assert.False(ToolRowExpansionPolicy.IsExpanded("tool-1", expanded, collapsed, autoExpandTools: true));
        Assert.Contains("tool-1", collapsed);

        ToolRowExpansionPolicy.Toggle("tool-1", expanded, collapsed, autoExpandTools: true);
        Assert.True(ToolRowExpansionPolicy.IsExpanded("tool-1", expanded, collapsed, autoExpandTools: true));
        Assert.Contains("tool-1", expanded);
    }

    [Fact]
    public void ProjectSessionAndChatBlocksExposeMacParityMetadata()
    {
        var session = new ProjectSession(
            "task-session",
            SessionProvider.G9Claw,
            "",
            "background task",
            DateTimeOffset.UtcNow,
            null,
            null,
            null,
            SessionState.Idle,
            MessageCount: 3,
            SessionKind: ProjectSessionKind.BackgroundTask,
            ParentSessionId: "parent-session",
            RelativeTranscriptPath: "tasks/task-session.jsonl",
            TranscriptKey: "transcript-key",
            TaskId: "task-1",
            TaskStatus: "running",
            OutputFile: "output.log",
            IsReadOnly: true);

        Assert.Equal("task-session", session.DisplayTitle);
        Assert.True(session.IsBackgroundTaskSession);
        Assert.Equal(3, session.MessageCount);
        Assert.Equal("task-1", session.TaskId);
        Assert.True(session.IsReadOnly);

        var reasoning = ChatBlock.FromReasoning("thinking");
        var text = ChatBlock.FromText("answer");

        Assert.False(ChatBlockVisibilityPolicy.IsVisible(reasoning, showThinking: false));
        Assert.True(ChatBlockVisibilityPolicy.IsVisible(reasoning, showThinking: true));
        Assert.True(ChatBlockVisibilityPolicy.IsVisible(text, showThinking: false));
    }

    [Fact]
    public void AgentTurnModelsExposeMacLifecycleAndPayloadShape()
    {
        Assert.Contains(TurnLifecycle.WaitingApproval, Enum.GetValues<TurnLifecycle>());
        Assert.Contains(AgentTurnItemKind.Reasoning, Enum.GetValues<AgentTurnItemKind>());
        Assert.Contains(AgentTurnItemKind.CommandExecution, Enum.GetValues<AgentTurnItemKind>());
        Assert.Contains(AgentTurnItemKind.ContextCompaction, Enum.GetValues<AgentTurnItemKind>());
        Assert.Contains(AgentTurnItemStatus.Pending, Enum.GetValues<AgentTurnItemStatus>());
        Assert.Contains(AgentTurnItemStatus.Declined, Enum.GetValues<AgentTurnItemStatus>());

        var command = new CommandExecutionPayload("git status", @"C:\repo", "clean", "", 0, 12);
        var fileChange = new FileChangePayload("README.md", "modify", Additions: 2, Deletions: 1);
        var webSearch = new WebSearchPayload("WinUI 3", 5);
        var item = new AgentTurnItem(
            "item-1",
            1,
            AgentTurnItemKind.WebSearch,
            AgentTurnItemStatus.Pending,
            "",
            "",
            null,
            DateTimeOffset.UtcNow,
            DateTimeOffset.UtcNow,
            null,
            command,
            fileChange,
            null,
            "session-1",
            "turn-1",
            webSearch);
        var turn = new AgentTurn(
            "turn-1",
            "session-1",
            Guid.NewGuid(),
            @"C:\repo",
            AgentTurnStatus.InProgress,
            ChatRunMode.Agent,
            DateTimeOffset.UtcNow,
            DateTimeOffset.UtcNow,
            null,
            [item]);

        Assert.True(item.IsRenderable);
        Assert.Equal("session-1", item.SessionId);
        Assert.Equal("turn-1", item.TurnId);
        Assert.Equal(12, command.DurationMs);
        Assert.Equal(2, fileChange.Additions);
        Assert.Equal(5, webSearch.ResultCount);
        Assert.True(turn.HasPendingWork);
    }

    [Fact]
    public void AgentActivityModelsMatchMacProcessTracePolicies()
    {
        var now = DateTimeOffset.UtcNow;
        var status = new AgentActivity(
            "status",
            "session-1",
            "run-1",
            "Working",
            "",
            AgentActivityPhase.Status,
            AgentActivityState.Running,
            now,
            now);
        var quiet = status with
        {
            Id = "quiet",
            State = AgentActivityState.Completed,
            Title = "Done",
        };
        var tool = status with
        {
            Id = "tool",
            Phase = AgentActivityPhase.Tool,
            State = AgentActivityState.Completed,
            ToolName = "Read",
            CreatedAt = now.AddSeconds(1),
            AnchorBlockId = "block-1",
        };

        var trace = AgentActivity.ProcessTraceActivities([quiet, tool, status]);

        Assert.Equal(["status", "tool"], trace.Select(activity => activity.Id));
        Assert.True(AgentActivity.HasRenderableProcessTrace(trace));
        Assert.Equal(["tool"], AgentActivity.ProcessTraceActivities([quiet, tool, status], "block-1").Select(activity => activity.Id));
        Assert.False(AgentActivityPresentationPolicy.ExpandsPermissionByDefault(PermissionRequestKind.Tool));
    }

    [Fact]
    public void AgentToolPresentationClassifierAndInputPreviewMatchMacPolicies()
    {
        Assert.True(AgentToolPresentationClassifier.IsReadTool("read"));
        Assert.True(AgentToolPresentationClassifier.IsSearchTool("grep"));
        Assert.Equal(AgentActivityPhase.Search, AgentToolPresentationClassifier.PhaseForToolName("semantic_search"));
        Assert.Equal(AgentActivityPhase.Command, AgentToolPresentationClassifier.PhaseForToolName("bash"));
        Assert.Equal(AgentActivityPhase.Edit, AgentToolPresentationClassifier.PhaseForToolName("write"));
        Assert.Equal(AgentActivityPhase.Todo, AgentToolPresentationClassifier.PhaseForToolName("todo_write"));
        Assert.Equal(AgentActivityPhase.Subagent, AgentToolPresentationClassifier.PhaseForToolName("task"));
        Assert.Equal(AgentActivityPhase.Tool, AgentToolPresentationClassifier.PhaseForToolName("Read"));

        var preview = AgentToolInputPreview.ActivityDetail(
            "Write",
            """{"file_path":"README.md","content":"hello\nworld"}""");

        Assert.Contains("README.md", preview);
        Assert.Contains("2 lines", preview);
        Assert.Contains("11 bytes", preview);
        Assert.Equal("""{"query":"test"}""", AgentToolInputPreview.ActivityDetail("Grep", """{"query":"test"}"""));

        var call = new ToolCall("call-1", "Read", "{}", ToolCallStatus.Running);
        var result = new ToolResult("call-1", "ok", false);

        Assert.Equal("call-1", call.Id);
        Assert.Equal(ToolCallStatus.Running, call.Status);
        Assert.False(result.IsError);
    }

    [Fact]
    public void AlwaysOnCronAndRunModelsMatchMacDerivedIdentityAndPolling()
    {
        var now = DateTimeOffset.UtcNow;
        var latest = new AlwaysOnCronLatestRun(
            AlwaysOnStatus.Running,
            null,
            now,
            null,
            "latest run",
            now,
            "task-1",
            "out.log",
            "parent",
            "tasks/task-1.jsonl",
            "transcript-1");
        var cron = new AlwaysOnCronJob(
            "cron-1",
            "Review project memory",
            "*/15 * * * *",
            AlwaysOnStatus.Scheduled,
            Recurring: true,
            Durable: true,
            CreatedAt: now.AddHours(-1),
            LastFiredAt: now,
            LatestSessionId: "session-1",
            Permanent: true,
            ManualOnly: false,
            OriginSessionId: "origin-1",
            TranscriptKey: "transcript-1",
            LatestRun: latest);
        var queued = new AlwaysOnRunHistory(
            "run-1",
            "Run discovery",
            "cron",
            AlwaysOnStatus.Queued,
            now,
            "cron-1",
            "",
            null,
            null,
            null);
        var completed = queued with { Status = AlwaysOnStatus.Completed };
        var log = new AlwaysOnRunLog("run-1", "output", Truncated: false, now, 6, AlwaysOnRunLogSource.LogFile);

        Assert.Equal("task-1", latest.Id);
        Assert.True(cron.Recurring);
        Assert.True(cron.Permanent);
        Assert.Same(latest, cron.LatestRun);
        Assert.True(queued.ShouldPollLog);
        Assert.False(completed.ShouldPollLog);
        Assert.Equal("run-1", log.Id);
        Assert.Equal("log-file", log.Source.Id());
    }

    [Fact]
    public void AlwaysOnSessionTargetsAndDiscoveryDedupeMatchMacPolicies()
    {
        var now = DateTimeOffset.UtcNow;
        var origin = AlwaysOnSessionTarget.Origin("session-1");
        var background = AlwaysOnSessionTarget.Background(
            "session-2",
            "session-1",
            "tasks/session-2.jsonl",
            "Background task",
            "summary",
            now,
            "transcript-2",
            "task-2",
            "running",
            "task.log");
        var context = new AlwaysOnDiscoveryContext(
            "2026-05-29T00:00:00Z",
            7,
            new AlwaysOnDiscoveryWorkspace("Demo", @"C:\repo", ["git:dirty"]),
            [new AlwaysOnDiscoveryMemoryItem("MEMORY.md", "2026-05-29T00:00:00Z", "memory")],
            [new AlwaysOnDiscoveryPlanItem("plan-1", "Plan", "ready", "manual", "2026-05-29", "summary")],
            [new AlwaysOnDiscoveryCronItem("cron-1", "scheduled", "*/15 * * * *", true, false, "prompt", "ran")],
            [new AlwaysOnDiscoveryChatItem("chat-1", "summary", "2026-05-29", "user", "assistant")]);
        var dedupe = new AlwaysOnDiscoveryRequestDedupeStore();

        Assert.Equal(AlwaysOnSessionTargetKind.Origin, origin.Kind);
        Assert.Null(origin.ParentSessionId);
        Assert.Equal(AlwaysOnSessionTargetKind.Background, background.Kind);
        Assert.Equal("session-1", background.ParentSessionId);
        Assert.Equal("tasks/session-2.jsonl", background.RelativeTranscriptPath);
        Assert.Equal("Demo", context.Workspace.ProjectName);
        Assert.Equal("git:dirty", Assert.Single(context.Workspace.Signals));

        Assert.False(dedupe.ShouldProcess(null));
        Assert.True(dedupe.ShouldProcess(" request-1 "));
        Assert.False(dedupe.ShouldProcess("request-1"));
        Assert.True(dedupe.ShouldProcess("request-2", maxSize: 1));
        Assert.DoesNotContain("request-1", dedupe.Seen);
        Assert.Equal(["request-2"], dedupe.Order);
    }

    [Fact]
    public void MemorySnapshotsMatchMacDefaultsAndConfigNormalization()
    {
        var defaults = MemorySettingsSnapshot.Defaults;
        var fromConfig = MemorySettingsSnapshot.FromConfigValues(new Dictionary<string, string>
        {
            ["memory.enabled"] = "off",
            ["memory.model"] = " memory ",
            ["memory.reasoningMode"] = "accuracy_first",
            ["memory.autoIndexIntervalMinutes"] = "-5",
            ["memory.autoDreamIntervalMinutes"] = "20000",
            ["memory.captureStrategy"] = "full_session",
            ["memory.includeAssistant"] = "no",
            ["memory.maxMessageChars"] = "0",
            ["memory.heartbeatBatchSize"] = "0",
        });
        var workspace = MemoryWorkspaceSnapshot.Empty;
        var states = MemoryJobState.IdleStates();
        var dashboard = new MemoryDashboardSnapshot(
            0,
            0,
            0,
            null,
            [],
            "",
            [],
            [],
            []);

        Assert.True(defaults.Enabled);
        Assert.Equal("inherit", defaults.Model);
        Assert.Equal(30, defaults.AutoIndexIntervalMinutes);
        Assert.Equal(60, defaults.AutoDreamIntervalMinutes);
        Assert.False(fromConfig.Enabled);
        Assert.Equal("memory", fromConfig.Model);
        Assert.Equal("accuracy_first", fromConfig.ReasoningMode);
        Assert.Equal(30, fromConfig.AutoIndexIntervalMinutes);
        Assert.Equal(10_080, fromConfig.AutoDreamIntervalMinutes);
        Assert.Equal("full_session", fromConfig.CaptureStrategy);
        Assert.False(fromConfig.IncludeAssistant);
        Assert.Equal(1, fromConfig.MaxMessageChars);
        Assert.Equal(1, fromConfig.HeartbeatBatchSize);
        Assert.Equal("MEMORY.md", workspace.ManifestPath);
        Assert.Equal("project", workspace.WorkspaceMode);
        Assert.Equal(MemoryJobPhase.Idle, states[MemoryJobKind.Recall].Phase);
        Assert.Equal(MemorySchedulerSnapshot.Disabled, dashboard.EffectiveScheduler);
        Assert.Equal(MemoryOverview.Empty, dashboard.EffectiveOverview);
        Assert.Equal(MemoryWorkspaceSnapshot.Empty, dashboard.EffectiveWorkspace);
        Assert.Equal(MemoryJobPhase.Idle, dashboard.EffectiveJobStates[MemoryJobKind.Dream].Phase);
    }

    [Fact]
    public void MemoryTraceAndSkillHubModelsExposeMacUiIdentity()
    {
        var now = DateTimeOffset.UtcNow;
        var meta = new MemoryProjectMeta(
            "project-1",
            "Demo",
            "Project memory",
            "active",
            @"C:\repo",
            "projects/demo",
            "project",
            ReadOnly: false,
            UpdatedAt: now);
        var step = new MemoryTraceStep("step-1", "Recall", "Loaded memory", "completed", now);
        var trace = new MemoryTraceRecord(
            "trace-1",
            "Recall trace",
            "completed",
            "manual",
            now,
            new Dictionary<string, string> { ["project"] = "Demo" },
            "context",
            "tools",
            "reply",
            [step]);
        var hardFail = new SkillValidationIssue("missing-skill", "SKILL.md is required");
        var warning = new SkillValidationIssue("large-file", "Large file");
        var validation = new SkillValidationResult(false, [hardFail], [warning], 3, 1200);
        var search = new SkillHubSearchResult("demo-skill", "Demo Skill", 0.97);
        var install = new SkillHubInstallResult(
            true,
            "demo-skill",
            SkillScope.Project,
            @"C:\repo\.codex\skills\demo-skill",
            Installed: true,
            Skill: null,
            Stdout: "ok",
            Stderr: "",
            ExitCode: 0,
            NeedsForce: false);

        Assert.Equal("project-1", meta.Id);
        Assert.Equal("Recall", Assert.Single(trace.Steps).Title);
        Assert.NotEqual(Guid.Empty, hardFail.Id);
        Assert.False(validation.Ok);
        Assert.Equal("missing-skill", Assert.Single(validation.HardFails).Code);
        Assert.Equal("demo-skill", search.Id);
        Assert.Equal(SkillScope.Project, install.Scope);
        Assert.True(install.Installed);
        Assert.False(install.NeedsForce);
    }

    [Fact]
    public void ConfigAndPreferenceHelpersMatchMacStoragePolicies()
    {
        var date = new DateTimeOffset(2026, 5, 29, 23, 30, 0, TimeSpan.FromHours(8));
        var permissionValues = ComposerPermissionModeStorage.Save(ComposerPermissionMode.BypassPermissions, "session-1");
        var uiJson = NativeUIPreferencesStorage.Save(new NativeUIPreferences(
            AutoExpandTools: true,
            ShowRawParameters: true,
            ShowThinking: false,
            AutoScrollToBottom: true,
            SendByCtrlEnter: true,
            SidebarVisible: false));
        var restoredUi = NativeUIPreferencesStorage.StoredPreferences(new Dictionary<string, string>
        {
            [NativeUIPreferencesStorage.StorageKey] = uiJson,
        });
        var legacyUi = NativeUIPreferencesStorage.StoredPreferences(new Dictionary<string, string>
        {
            ["autoExpandTools"] = "true",
            ["showThinking"] = "false",
            ["sidebarVisible"] = "false",
        });
        var workspace = new WorkspaceContext(Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"), "demo", "Demo", @"C:\repo", IsGeneral: false);
        var editor = CodeEditorPreferences.Defaults;

        Assert.Equal("g9claw", PermissionsExportDefaults.Source);
        Assert.Equal("g9claw-permissions-2026-05-29.json", PermissionsExportDefaults.Filename(date));
        Assert.Equal("alwaysOn", G9ClawConfigSection.AlwaysOn.Id());
        Assert.Equal("Always-On", G9ClawConfigSection.AlwaysOn.Label());
        Assert.Equal("Raw YAML", G9ClawConfigSection.Raw.Label());
        Assert.Equal(ComposerPermissionMode.BypassPermissions, ComposerPermissionModeStorage.StoredMode("session-1", permissionValues));
        Assert.Equal(ComposerPermissionMode.BypassPermissions, ComposerPermissionModeStorage.StoredMode(null, permissionValues));
        Assert.True(restoredUi.AutoExpandTools);
        Assert.True(restoredUi.ShowRawParameters);
        Assert.False(restoredUi.ShowThinking);
        Assert.True(restoredUi.SendByCtrlEnter);
        Assert.False(restoredUi.SidebarVisible);
        Assert.True(legacyUi.AutoExpandTools);
        Assert.False(legacyUi.ShowThinking);
        Assert.False(legacyUi.SidebarVisible);
        Assert.Equal("Demo", workspace.DisplayName);
        Assert.False(workspace.IsGeneral);
        Assert.False(editor.WordWrap);
        Assert.True(editor.ShowMinimap);
        Assert.Equal(14, editor.FontSize);
    }

    [Fact]
    public async Task NativeUIPreferencesStoreRoundTripsMacPreferenceShape()
    {
        using var temp = new TempWorkspace();
        var file = Path.Combine(temp.Root, "ui-preferences.json");
        var store = new NativeUIPreferencesStore(file);
        var preferences = new NativeUIPreferences(
            AutoExpandTools: true,
            ShowRawParameters: true,
            ShowThinking: false,
            AutoScrollToBottom: false,
            SendByCtrlEnter: true,
            SidebarVisible: false);

        await store.SaveAsync(preferences);
        var loaded = await store.LoadAsync();

        Assert.Equal(preferences, loaded);
        Assert.Contains("autoExpandTools", await File.ReadAllTextAsync(file));
    }

    [Fact]
    public void WebV2UiSettingsNormalizeSidebarBoundsAndLists()
    {
        var tooSmall = new V2UiSettings(12, SidebarSection.General, null!, null!).Normalize();
        var tooLarge = (tooSmall with { SidebarWidth = 999 }).Normalize();

        Assert.Equal(V2UiSettings.SidebarMinWidth, tooSmall.SidebarWidth);
        Assert.Equal(V2UiSettings.SidebarMaxWidth, tooLarge.SidebarWidth);
        Assert.Empty(tooSmall.ExpandedProjectNames);
        Assert.Empty(tooSmall.CollapsedSessionProjectNames);
        Assert.Equal(SidebarSection.General, tooSmall.SidebarSection);
    }

    [Fact]
    public void WebV2UiSettingsStartupMigratesOversizedLegacySidebar()
    {
        var legacy = new V2UiSettings(420, SidebarSection.General, [], []).NormalizeForStartup();
        var userSized = new V2UiSettings(320, SidebarSection.General, [], []).NormalizeForStartup();

        Assert.Equal(V2UiSettings.SidebarDefaultWidth, legacy.SidebarWidth);
        Assert.Equal(320, userSized.SidebarWidth);
    }

    [Fact]
    public void WebV2SidebarProjectSectionExcludesGeneralAndSortsProjects()
    {
        var now = DateTimeOffset.UtcNow;
        var general = Project("general", "general", now);
        var zeta = Project("zeta", "Zeta", now.AddMinutes(-20));
        var alpha = Project("alpha", "Alpha", now.AddMinutes(-10));

        var byName = V2SidebarProjection.ProjectSection([zeta, general, alpha], ProjectSortOrder.Name);
        var byDate = V2SidebarProjection.ProjectSection([zeta, general, alpha], ProjectSortOrder.Date);

        Assert.Equal(["Alpha", "Zeta"], byName.Select(project => project.DisplayName));
        Assert.Equal(["alpha", "zeta"], byDate.Select(project => project.Name));
        Assert.DoesNotContain(byName, project => project.Name == "general");
        Assert.Same(general, V2SidebarProjection.GeneralProject([zeta, general, alpha]));
    }

    [Fact]
    public void WebV2SidebarSessionRowsFlattenProviderBucketsByActivity()
    {
        var now = DateTimeOffset.UtcNow;
        var project = new WorkspaceProject(
            Guid.NewGuid(),
            "demo",
            "Demo",
            @"C:\Users\tester\demo",
            [Session("g9", SessionProvider.G9Claw, now.AddMinutes(-30))],
            [Session("codex", SessionProvider.Codex, now.AddMinutes(-10))],
            [Session("cursor", SessionProvider.Cursor, now.AddMinutes(-20))],
            [Session("gemini", SessionProvider.Gemini, now.AddMinutes(-40))],
            now.AddHours(-1),
            now.AddMinutes(-10));

        var rows = V2SidebarProjection.SessionRows(project);

        Assert.Equal(["codex", "cursor", "g9", "gemini"], rows.Select(row => row.Session.Id));
        Assert.Equal([SessionProvider.Codex, SessionProvider.Cursor, SessionProvider.G9Claw, SessionProvider.Gemini], rows.Select(row => row.Provider));
    }

    [Fact]
    public void WebV2SidebarSessionIndicatorPrioritizesProcessingThenUnread()
    {
        var session = Session("s1", SessionProvider.G9Claw, DateTimeOffset.UtcNow, SessionState.Failed);

        Assert.Equal(SessionState.Processing, V2SidebarProjection.SessionIndicatorState(
            session,
            new HashSet<string>(["s1"], StringComparer.OrdinalIgnoreCase),
            new HashSet<string>(["s1"], StringComparer.OrdinalIgnoreCase)));
        Assert.Equal(SessionState.Unread, V2SidebarProjection.SessionIndicatorState(
            session,
            new HashSet<string>(StringComparer.OrdinalIgnoreCase),
            new HashSet<string>(["s1"], StringComparer.OrdinalIgnoreCase)));
        Assert.Equal(SessionState.Failed, V2SidebarProjection.SessionIndicatorState(
            session,
            new HashSet<string>(StringComparer.OrdinalIgnoreCase),
            new HashSet<string>(StringComparer.OrdinalIgnoreCase)));
    }

    [Fact]
    public void LegacyConfigLoaderReadsDefaultProviderSettings()
    {
        const string yaml = """
        runtime:
          workspacesRoot: ~/Workspace
        gateway:
          runtimePaths:
            generalCwd: ~/G9Claw/general
        models:
          providers:
            g9claw:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: local-secret
          entries:
            default:
              provider: g9claw
              name: qwen3.6-27b
        """;

        var snapshot = LegacyConfigLoader.Snapshot(yaml);

        Assert.NotNull(snapshot);
        Assert.Equal("http://example.local/v1", snapshot!.BaseUrl);
        Assert.Equal("local-secret", snapshot.ApiKey);
        Assert.Equal("qwen3.6-27b", snapshot.Model);
        Assert.Equal("~/Workspace", snapshot.WorkspacesRoot);
        Assert.Equal("~/G9Claw/general", snapshot.GeneralWorkspacePath);
    }

    [Fact]
    public void NativeConfigServiceResolvesRouterDefaultEntry()
    {
        const string yaml = """
        runtime:
          apiTimeoutMs: 90000
          contextWindow: 120000
          workspacesRoot: C:\Users\tester
        gateway:
          runtimePaths:
            generalCwd: C:\Users\tester\G9Claw\general
        models:
          providers:
            g9claw:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: local-secret
              headers:
                X-Test: enabled
            g9claw_router:
              type: openai-chat
              baseUrl: http://router.local/v1
              apiKey: router-secret
          entries:
            default:
              provider: g9claw
              name: qwen3.6-27b
              contextWindow: 160000
            router_small:
              provider: g9claw_router
              name: qwen3.6-35b-a3b
              contextWindow: 64000
        router:
          routes:
            default:
              model: router_small
        """;

        var snapshot = NativeConfigService.Snapshot(yaml);

        Assert.NotNull(snapshot);
        Assert.Equal("router_small", snapshot!.DefaultEntryId);
        Assert.Equal("http://router.local/v1", snapshot.ProviderConfig.BaseUrl);
        Assert.Equal("qwen3.6-35b-a3b", snapshot.ProviderConfig.Model);
        Assert.Equal("router-secret", snapshot.ApiKey);
        Assert.Equal(90_000, snapshot.ApiTimeoutMs);
        Assert.Equal(64_000, snapshot.ContextWindow);
    }

    [Fact]
    public void NativeConfigServicePrefersAgentMainModelOverRouterDefault()
    {
        const string yaml = """
        models:
          providers:
            edgeclaw:
              type: openai-chat
              baseUrl: http://58.57.119.12:52010/v1
              apiKey: edge-secret
            edgeclaw_router:
              type: openai-chat
              baseUrl: http://router.local/v1
              apiKey: router-secret
          entries:
            default:
              provider: edgeclaw
              name: minimax-m2.7
              contextWindow: 160000
            router_small:
              provider: edgeclaw_router
              name: qwen3.6-27b
              contextWindow: 64000
        agents:
          main:
            model: default
        router:
          routes:
            default:
              model: router_small
        """;

        var snapshot = NativeConfigService.Snapshot(yaml);

        Assert.NotNull(snapshot);
        Assert.Equal("default", snapshot!.DefaultEntryId);
        Assert.Equal("http://58.57.119.12:52010/v1", snapshot.ProviderConfig.BaseUrl);
        Assert.Equal("minimax-m2.7", snapshot.ProviderConfig.Model);
        Assert.Equal("edge-secret", snapshot.ApiKey);
    }

    [Fact]
    public void AgentModelResolverUsesYamlAgentMainModelAndPreflight()
    {
        const string yaml = """
        models:
          providers:
            edgeclaw:
              type: openai-chat
              baseUrl: http://58.57.119.12:52010/v1
              apiKey: sk-real
          entries:
            default:
              provider: edgeclaw
              name: minimax-m2.7
              contextWindow: 160000
        agents:
          main:
            model: default
        """;

        var parsed = NativeConfigYamlCodec.ApplyYaml(AppSettings.Defaults(@"C:\Users\tester"), yaml);
        var resolved = AgentModelResolver.Resolve(parsed.Settings);
        var ok = AgentModelResolver.Preflight(parsed.Settings, "sk-real");
        var masked = AgentModelResolver.Preflight(parsed.Settings, "********");

        Assert.Equal("edgeclaw", resolved.ProviderId);
        Assert.Equal("default", resolved.ModelEntryId);
        Assert.Equal("minimax-m2.7", resolved.ModelName);
        Assert.Equal("default:minimax-m2.7", resolved.DisplayLabel);
        Assert.Equal("http://58.57.119.12:52010/v1/chat/completions", resolved.EndpointUrl.ToString());
        Assert.True(ok.Ok);
        Assert.False(masked.Ok);
        Assert.Contains("API key", masked.Diagnostic);
    }

    [Fact]
    public void AgentModelResolverDoesNotSilentlyFallbackWhenMainModelIsMissing()
    {
        var settings = AppState.NormalizeSettings(AppSettings.Defaults(@"C:\Users\tester") with
        {
            Providers =
            [
                new NativeProviderEntry("g9claw", ProviderApiType.OpenAIChat, "http://example.local/v1", "g9claw-provider-g9claw", [])
            ],
            ModelEntries =
            [
                new NativeModelEntry("default", "g9claw", "qwen3.6-27b", 160000)
            ],
            AgentSettings = new NativeAgentSettings("missing", "default", "{}"),
        });

        var preflight = AgentModelResolver.Preflight(settings, "sk-real");

        Assert.False(preflight.Ok);
        Assert.Contains("missing", preflight.Diagnostic);
        Assert.Contains("models.entries", preflight.Diagnostic);
    }

    [Fact]
    public void OpenAIChatToolCallAccumulatorCombinesStreamingArgumentDeltas()
    {
        var accumulator = new OpenAIChatToolCallAccumulator();

        var first = Apply("""
        {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"Read","arguments":"{\"file"}}]}}]}
        """);
        var second = Apply("""
        {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"_path\":\"README.md\"}"}}]}}]}
        """);
        var done = Apply("""
        {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}
        """);

        Assert.Empty(first);
        Assert.Empty(second);
        var call = Assert.Single(done).ToolCall;
        Assert.NotNull(call);
        Assert.Equal("call_1", call!.Id);
        Assert.Equal("Read", call.Name);
        Assert.Equal("""{"file_path":"README.md"}""", call.InputJson);
        return;

        IReadOnlyList<ProviderStreamEvent> Apply(string json)
        {
            using var doc = JsonDocument.Parse(json);
            return accumulator.Apply(doc.RootElement);
        }
    }

    [Fact]
    public void NativeConfigServiceIgnoresMaskedApiKeysWhenResolvingSecret()
    {
        const string yaml = """
        models:
          providers:
            g9claw:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: ********
          entries:
            default:
              provider: g9claw
              name: qwen3.6-27b
        """;

        var snapshot = NativeConfigService.Snapshot(yaml);

        Assert.NotNull(snapshot);
        Assert.Equal("g9claw-provider-g9claw", snapshot!.ProviderConfig.SecretAccount);
        Assert.Equal("dpapi-secret", NativeConfigService.ResolveApiKey("default", snapshot, "dpapi-secret", ""));
        Assert.Equal("draft-secret", NativeConfigService.ResolveApiKey("default", snapshot, null, "draft-secret"));
    }

    [Fact]
    public void GeneralWorkspacePathFallsBackWhenConfigIsRelative()
    {
        const string home = @"C:\Users\tester";

        Assert.Equal(PathHelpers.NormalizeFullPath(@"C:\Users\tester\G9Claw\general"), AppState.NormalizeGeneralWorkspacePath("general", home));
        Assert.Equal(PathHelpers.NormalizeFullPath(@"C:\Users\tester\G9Claw\general"), AppState.NormalizeGeneralWorkspacePath("  ", home));
        Assert.Equal(PathHelpers.NormalizeFullPath(@"C:\Users\tester\Projects\demo"), AppState.NormalizeGeneralWorkspacePath(@"C:\Users\tester\Projects\demo", home));
    }

    [Fact]
    public void ShellWorkingDirectoryRejectsRelativeOrMissingPaths()
    {
        var relative = Assert.Throws<InvalidOperationException>(() => AgentToolExecutor.ValidatedWorkingDirectory("general"));
        Assert.Contains("absolute path", relative.Message);

        var missing = Assert.Throws<DirectoryNotFoundException>(() => AgentToolExecutor.ValidatedWorkingDirectory($@"C:\g9claw-missing-{Guid.NewGuid():D}"));
        Assert.Contains("does not exist", missing.Message);
    }

    [Fact]
    public void AgentToolExecutorTimeoutRulesMatchMacToolRuntime()
    {
        Assert.Equal(120_000, ShellTimeout("""{}"""));
        Assert.Equal(1_000, ShellTimeout("""{"timeout":250}"""));
        Assert.Equal(2_500, ShellTimeout("""{"timeout":"2500"}"""));
        Assert.Equal(600_000, ShellTimeout("""{"timeout":700000}"""));
        Assert.Equal(2_000, ShellTimeout("""{"timeout_seconds":2}"""));

        Assert.Equal(30_000, AwaitTimeout("""{}"""));
        Assert.Equal(0, AwaitTimeout("""{"timeout":-1}"""));
        Assert.Equal(45_000, AwaitTimeout("""{"timeout":"45000"}"""));
        Assert.Equal(600_000, AwaitTimeout("""{"timeout":700000}"""));
    }

    [Fact]
    public void SkillRuntimeEnvironmentMatchesMacRagConfigMapping()
    {
        var environment = SkillRuntimeEnvironment.Build(
            new Dictionary<string, string>
            {
                ["rag.enabled"] = "yes",
                ["rag.disableBuiltInWebTools"] = "false",
                ["rag.localKnowledge.baseUrl"] = "http://local.example/",
                ["rag.localKnowledge.apiKey"] = "local-key",
                ["rag.localKnowledge.modelName"] = "embed",
                ["rag.localKnowledge.databaseUrl"] = "http://milvus.example/",
                ["rag.localKnowledge.defaultTopK"] = "12",
                ["rag.glmWebSearch.baseUrl"] = "http://glm.example/",
                ["rag.glmWebSearch.apiKey"] = "glm-key",
            },
            new Dictionary<string, string>
            {
                ["PATH"] = @"C:\Tools",
                ["CLAUDE_PLUGIN_ROOT"] = @"C:\legacy",
            },
            pluginRoot: @"C:\plugins\g9claw-rag-plugin");

        Assert.Equal(@"C:\plugins\g9claw-rag-plugin", environment["G9CLAW_PLUGIN_ROOT"]);
        Assert.Equal("1", environment["G9CLAW_RAG_ENABLED"]);
        Assert.Equal("0", environment["G9CLAW_RAG_DISABLE_BUILTIN_WEB_TOOLS"]);
        Assert.Equal("http://local.example", environment["G9CLAW_RAG_LOCAL_KNOWLEDGE_BASE_URL"]);
        Assert.Equal("local-key", environment["G9CLAW_RAG_LOCAL_KNOWLEDGE_API_KEY"]);
        Assert.Equal("embed", environment["G9CLAW_RAG_LOCAL_KNOWLEDGE_MODEL_NAME"]);
        Assert.Equal("http://milvus.example/", environment["G9CLAW_RAG_LOCAL_KNOWLEDGE_DATABASE_URL"]);
        Assert.Equal("http://milvus.example/", environment["G9CLAW_RAG_LOCAL_KNOWLEDGE_MILVUS_URI"]);
        Assert.Equal("12", environment["G9CLAW_RAG_LOCAL_KNOWLEDGE_TOP_K"]);
        Assert.Equal("http://glm.example", environment["G9CLAW_RAG_GLM_WEB_SEARCH_BASE_URL"]);
        Assert.Equal("glm-key", environment["G9CLAW_RAG_GLM_WEB_SEARCH_API_KEY"]);
        Assert.Equal("8", environment["G9CLAW_RAG_GLM_WEB_SEARCH_TOP_K"]);
        Assert.False(environment.ContainsKey("CLAUDE_PLUGIN_ROOT"));
    }

    [Fact]
    public void SkillRuntimeEnvironmentFindsBundledPluginAssetsLikeMac()
    {
        using var temp = new TempWorkspace();
        var pluginRoot = Path.Combine(temp.Root, "Assets", "g9claw-rag-plugin");
        Directory.CreateDirectory(Path.Combine(pluginRoot, "skills", "rag-research"));
        File.WriteAllText(Path.Combine(pluginRoot, "skills", "rag-research", "SKILL.md"), "Use bundled RAG.");

        var resolved = SkillRuntimeEnvironment.PluginRoot(null, null, [temp.Root]);

        Assert.Equal(PathHelpers.NormalizeFullPath(pluginRoot), resolved);
    }

    [Fact]
    public async Task AgentToolExecutorShellReceivesNativeConfigEnvironment()
    {
        using var temp = new TempWorkspace();
        var executor = new AgentToolExecutor();
        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None,
            new Dictionary<string, string>
            {
                ["rag.enabled"] = "true",
                ["rag.glmWebSearch.defaultTopK"] = "5",
            });

        var result = await executor.ExecuteAsync(new AgentToolCall("shell-env", "Shell", """
        {"command":"Write-Output $env:G9CLAW_RAG_ENABLED; Write-Output $env:G9CLAW_RAG_GLM_WEB_SEARCH_TOP_K"}
        """), context);

        Assert.False(result.IsError);
        Assert.Equal(["exit code: 0", "1", "5"], OutputLines(result.Output));
    }

    [Fact]
    public async Task AgentToolExecutorTaskShellReceivesNativeConfigEnvironment()
    {
        using var temp = new TempWorkspace();
        var runStore = new NativeRunStore(Path.Combine(temp.Root, "run-history"));
        var executor = new AgentToolExecutor(runStore: runStore);
        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None,
            new Dictionary<string, string>
            {
                ["rag.enabled"] = "true",
                ["rag.glmWebSearch.defaultTopK"] = "7",
            });

        var foreground = await executor.ExecuteAsync(new AgentToolCall("task-shell-env", "Task", """
        {"type":"shell","prompt":"Write-Output $env:G9CLAW_RAG_ENABLED; Write-Output $env:G9CLAW_RAG_GLM_WEB_SEARCH_TOP_K","run_in_background":false}
        """), context);
        var background = await executor.ExecuteAsync(new AgentToolCall("task-shell-background-env", "Task", """
        {"type":"shell","prompt":"Write-Output $env:G9CLAW_RAG_ENABLED","description":"Background env","run_in_background":true}
        """), context);
        var awaited = await executor.ExecuteAsync(new AgentToolCall("task-shell-background-await", "Await", JsonSerializer.Serialize(new
        {
            task_id = background.TaskId,
            timeout = 5_000,
        })), context);

        Assert.False(foreground.IsError);
        Assert.Equal(["exit code: 0", "1", "7"], OutputLines(foreground.Output));
        Assert.False(background.IsError);
        using (var backgroundJson = JsonDocument.Parse(background.Output))
        {
            Assert.Equal(background.TaskId, backgroundJson.RootElement.GetProperty("task_id").GetString());
            Assert.Equal("running", backgroundJson.RootElement.GetProperty("status").GetString());
            Assert.Equal("Background env", backgroundJson.RootElement.GetProperty("description").GetString());
        }
        Assert.False(awaited.IsError);
        Assert.Equal("Completed", awaited.Diagnostics?["status"]);
        using (var awaitedJson = JsonDocument.Parse(awaited.Output))
        {
            Assert.Equal("completed", awaitedJson.RootElement.GetProperty("status").GetString());
            Assert.Contains("exit code: 0", awaitedJson.RootElement.GetProperty("output").GetString());
            Assert.Contains("1", awaitedJson.RootElement.GetProperty("output").GetString());
        }
    }

    [Fact]
    public async Task AgentToolExecutorReadLintsRunsConfiguredCommandLikeMac()
    {
        using var temp = new TempWorkspace();
        Directory.CreateDirectory(Path.Combine(temp.Root, "src"));
        await File.WriteAllTextAsync(Path.Combine(temp.Root, "src", "file.cs"), "class Demo {}\n");
        var executor = new AgentToolExecutor();
        var noConfigContext = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None);

        var noConfig = await executor.ExecuteAsync(new AgentToolCall("lint-none", "ReadLints", """{"path":"src"}"""), noConfigContext);

        Assert.False(noConfig.IsError);
        using (var noConfigJson = JsonDocument.Parse(noConfig.Output))
        {
            Assert.Equal(0, noConfigJson.RootElement.GetProperty("diagnostics").GetArrayLength());
            Assert.Equal(
                "No native lint.command is configured and no live LSP diagnostics are available.",
                noConfigJson.RootElement.GetProperty("message").GetString());
        }

        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None,
            new Dictionary<string, string>
            {
                ["lint.command"] = "Write-Output \"src/file.cs:2:4: warning: env=$env:G9CLAW_RAG_ENABLED\"; Write-Output \"src/file.cs:3: error: broken\"",
                ["rag.enabled"] = "true",
            });

        var result = await executor.ExecuteAsync(new AgentToolCall("lint", "ReadLints", """
        {"path":"src","severity":"warning","limit":10}
        """), context);

        Assert.False(result.IsError);
        using var json = JsonDocument.Parse(result.Output);
        var root = json.RootElement;
        var diagnostics = root.GetProperty("diagnostics");
        Assert.Equal(1, diagnostics.GetArrayLength());
        var diagnostic = diagnostics[0];
        Assert.Equal("src/file.cs", diagnostic.GetProperty("file").GetString());
        Assert.Equal(2, diagnostic.GetProperty("line").GetInt32());
        Assert.Equal(4, diagnostic.GetProperty("column").GetInt32());
        Assert.Equal("warning", diagnostic.GetProperty("severity").GetString());
        Assert.Equal("env=1", diagnostic.GetProperty("message").GetString());
        Assert.Equal(0, root.GetProperty("exitCode").GetInt32());
        Assert.False(root.GetProperty("truncated").GetBoolean());
    }

    [Fact]
    public void AgentToolExecutorParsesLintDiagnosticsLikeMac()
    {
        var diagnostics = AgentToolExecutor.ParseLintDiagnostics("""
        src/App.swift:2:5: warning: lint warning
        src/B.swift:3: error: broken
        src/C.swift:4: info: skipped
        src/D.swift:5: no explicit level
        """, "error", 10);

        Assert.Equal(2, diagnostics.Count);
        Assert.Equal("src/B.swift", diagnostics[0]["file"]);
        Assert.Equal(3, diagnostics[0]["line"]);
        Assert.Equal(0, diagnostics[0]["column"]);
        Assert.Equal("error", diagnostics[0]["severity"]);
        Assert.Equal("broken", diagnostics[0]["message"]);
        Assert.Equal("src/D.swift", diagnostics[1]["file"]);
        Assert.Equal("error", diagnostics[1]["severity"]);

        var warning = AgentToolExecutor.ParseLintDiagnostics("src/App.swift:2:5: warning: lint warning", null, 1);
        Assert.Equal("warning", warning[0]["severity"]);
        Assert.Equal(5, warning[0]["column"]);
    }

    [Fact]
    public void AgentToolExecutorRipgrepArgumentsMatchMacRuntime()
    {
        using var doc = JsonDocument.Parse("""
        {"output_mode":"content","glob":"*.cs","-i":true,"multiline":true,"type":"cs","context":2,"-B":1,"-A":3}
        """);
        var args = AgentToolExecutor.RipgrepArguments(doc.RootElement, "TODO", @"C:\repo");

        var expected = new[]
        {
            "--color",
            "never",
            "--line-number",
            "--glob",
            "*.cs",
            "-i",
            "-U",
            "--multiline-dotall",
            "--type",
            "cs",
            "-C",
            "2",
            "-B",
            "1",
            "-A",
            "3",
            "--",
            "TODO",
            @"C:\repo",
        };
        Assert.Equal(expected, args);
        Assert.Equal("src/a.cs:10:TODO", AgentToolExecutor.NormalizeRipgrepLine(@"C:\repo\src\a.cs:10:TODO", @"C:\repo"));
    }

    [Fact]
    public async Task AgentToolExecutorAwaitCanReadRunningTaskWithoutBlocking()
    {
        using var temp = new TempWorkspace();
        var runStore = new NativeRunStore(Path.Combine(temp.Root, "run-history"));
        var executor = new AgentToolExecutor(runStore: runStore);
        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None);

        var taskResult = await executor.ExecuteAsync(new AgentToolCall("shell", "Shell", """
        {"command":"Start-Sleep -Seconds 2; Write-Output done","run_in_background":true}
        """), context);
        var awaitResult = await executor.ExecuteAsync(new AgentToolCall("await", "Await", JsonSerializer.Serialize(new
        {
            task_id = taskResult.TaskId,
            block = false,
            timeout = 600_000,
        })), context);

        Assert.False(taskResult.IsError);
        Assert.False(awaitResult.IsError);
        Assert.Equal(taskResult.TaskId, awaitResult.TaskId);
        Assert.Equal("Running", awaitResult.Diagnostics?["status"]);
        using (var runningJson = JsonDocument.Parse(awaitResult.Output))
        {
            Assert.Equal(taskResult.TaskId, runningJson.RootElement.GetProperty("task_id").GetString());
            Assert.Equal("running", runningJson.RootElement.GetProperty("status").GetString());
        }

        var completed = await executor.ExecuteAsync(new AgentToolCall("await-complete", "Await", JsonSerializer.Serialize(new
        {
            task_id = taskResult.TaskId,
            timeout = 5_000,
        })), context);
        Assert.False(completed.IsError);
        using (var completedJson = JsonDocument.Parse(completed.Output))
        {
            Assert.Equal(taskResult.TaskId, completedJson.RootElement.GetProperty("task_id").GetString());
            Assert.Equal("completed", completedJson.RootElement.GetProperty("status").GetString());
            Assert.Contains("exit code: 0", completedJson.RootElement.GetProperty("output").GetString());
            Assert.Contains("done", completedJson.RootElement.GetProperty("output").GetString());
        }
    }

    [Fact]
    public void NativeAgentRuntimeEndpointDoesNotDuplicateChatCompletions()
    {
        var full = NativeAgentRuntime.EndpointUrl("https://openrouter.ai/api/v1/chat/completions", "chat/completions");
        var baseUrl = NativeAgentRuntime.EndpointUrl("http://example.local/v1/", "chat/completions");

        Assert.Equal("https://openrouter.ai/api/v1/chat/completions", full.ToString());
        Assert.Equal("http://example.local/v1/chat/completions", baseUrl.ToString());
    }

    [Fact]
    public void NativeAgentRuntimeNormalizesOpenAIChatStreamEvents()
    {
        using var doc = JsonDocument.Parse("""
        {
          "choices": [
            { "delta": { "content": "hello" } }
          ],
          "usage": {
            "prompt_tokens": 3,
            "completion_tokens": 4,
            "total_tokens": 7
          }
        }
        """);

        var events = NativeAgentRuntime.OpenAIChatEvents(doc.RootElement, 160_000);

        Assert.Contains(events, item => item.Kind == ProviderStreamEventKind.ContentDelta && item.Text == "hello");
        Assert.Contains(events, item => item.Kind == ProviderStreamEventKind.TokenBudget && item.TokenBudget == new TokenBudget(7, 160_000));
    }

    [Fact]
    public void NativeAgentRuntimeNormalizesOpenAIChatNonStreamingMessage()
    {
        using var doc = JsonDocument.Parse("""
        {
          "choices": [
            { "message": { "role": "assistant", "content": "hello from plain json" } }
          ],
          "usage": {
            "prompt_tokens": 5,
            "completion_tokens": 6,
            "total_tokens": 11
          }
        }
        """);

        var events = NativeAgentRuntime.OpenAIChatEvents(doc.RootElement, 250_000);

        Assert.Contains(events, item => item.Kind == ProviderStreamEventKind.ContentDelta && item.Text == "hello from plain json");
        Assert.Contains(events, item => item.Kind == ProviderStreamEventKind.TokenBudget && item.TokenBudget == new TokenBudget(11, 250_000));
    }

    [Fact]
    public async Task ProviderClientBuildsMacShapedAttachmentParts()
    {
        using var temp = new TempWorkspace();
        var notesPath = Path.Combine(temp.Root, "notes.md");
        var pdfPath = Path.Combine(temp.Root, "sample.pdf");
        var imagePath = Path.Combine(temp.Root, "pixel.png");
        var missingPath = Path.Combine(temp.Root, "missing.txt");
        await File.WriteAllTextAsync(notesPath, "alpha\nbeta");
        await File.WriteAllBytesAsync(pdfPath, MinimalPdf("Hello PDF"));
        await File.WriteAllBytesAsync(imagePath, [0x89, 0x50, 0x4E, 0x47]);

        var handler = new CapturingProviderHandler("""
        {"choices":[{"message":{"role":"assistant","content":"ok"}}]}
        """);
        var client = new ProviderClient(new HttpClient(handler));
        var request = new AgentRequest(
            "session-1",
            temp.Root,
            "Analyze attachments",
            [
                new FileAttachment(notesPath, "notes.md", "text/markdown", new FileInfo(notesPath).Length),
                new FileAttachment(pdfPath, "sample.pdf", "application/pdf", new FileInfo(pdfPath).Length),
                new FileAttachment(imagePath, "pixel.png", "image/png", new FileInfo(imagePath).Length),
                new FileAttachment(missingPath, "missing.txt", "text/plain", 0),
            ],
            new ProviderConfig(SessionProvider.G9Claw, ProviderApiType.OpenAIChat, "http://provider.local/v1", "test-model", "secret", []),
            "test-key",
            [],
            120000,
            160000,
            ComposerPermissionMode.Default,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            "default",
            []);

        var events = new List<ProviderStreamEvent>();
        await foreach (var providerEvent in client.StreamAsync(request))
        {
            events.Add(providerEvent);
        }

        Assert.Contains(events, item => item.Kind == ProviderStreamEventKind.ContentDelta && item.Text == "ok");
        using var requestJson = JsonDocument.Parse(handler.Body!);
        var content = requestJson.RootElement
            .GetProperty("messages")[0]
            .GetProperty("content");

        Assert.Equal(JsonValueKind.Array, content.ValueKind);
        Assert.Equal("Analyze attachments", content[0].GetProperty("text").GetString());
        Assert.Contains($"<attachment path=\"{notesPath}\">", content[1].GetProperty("text").GetString());
        Assert.Contains("alpha\nbeta", content[1].GetProperty("text").GetString());
        Assert.Contains($"<attachment path=\"{pdfPath}\">", content[2].GetProperty("text").GetString());
        Assert.Contains("## Page 1", content[2].GetProperty("text").GetString());
        Assert.Contains("Hello PDF", content[2].GetProperty("text").GetString());
        Assert.Equal("image_url", content[3].GetProperty("type").GetString());
        Assert.Equal("data:image/png;base64,iVBORw==", content[3].GetProperty("image_url").GetProperty("url").GetString());
        Assert.Contains("[Attachment diagnostics]", content[4].GetProperty("text").GetString());
        Assert.Contains($"Attachment not found: {missingPath}.", content[4].GetProperty("text").GetString());
    }

    [Fact]
    public void NativeAttachmentResolverAppliesMacLimitsAndDiagnostics()
    {
        using var temp = new TempWorkspace();
        var largeText = Path.Combine(temp.Root, "large.txt");
        var largeImage = Path.Combine(temp.Root, "large.png");
        using (var stream = File.Create(largeText))
        {
            stream.SetLength(NativeAttachmentResolver.MaxTextBytes + 1);
        }
        using (var stream = File.Create(largeImage))
        {
            stream.SetLength(NativeAttachmentResolver.MaxImageBytes + 1);
        }

        var result = NativeAttachmentResolver.OpenAIContentParts(
        [
            new FileAttachment(largeText, "large.txt", "text/plain", new FileInfo(largeText).Length),
            new FileAttachment(largeImage, "large.png", "image/png", new FileInfo(largeImage).Length),
        ]);

        Assert.Single(result.Parts);
        Assert.Equal("text", result.Parts[0]["type"]);
        Assert.Contains("Attachment large.txt is", result.Parts[0]["text"]?.ToString());
        Assert.Contains("Image large.png is", result.Parts[0]["text"]?.ToString());
        Assert.Equal(2, result.Diagnostics.Count(item => item.Severity == AttachmentDiagnosticSeverity.Warning));
    }

    [Fact]
    public async Task ProviderNativeSubagentRunnerUsesReadOnlyNonStreamingChatRequest()
    {
        using var temp = new TempWorkspace();
        var handler = new CapturingProviderHandler("""
        {"choices":[{"message":{"role":"assistant","content":"subagent answer"}}],"usage":{"total_tokens":7}}
        """);
        var runner = new ProviderNativeSubagentRunner(new ProviderClient(new HttpClient(handler)));
        var providerConfig = new ProviderConfig(
            SessionProvider.G9Claw,
            ProviderApiType.OpenAIChat,
            "http://provider.local/v1",
            "test-model",
            "secret",
            []);
        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None,
            ProviderConfig: providerConfig,
            ApiKey: "test-key");

        var output = await runner.RunAsync(
            new NativeSubagentRequest(temp.Root, "Inspect services", "Explore services", "Task type: explore", context),
            CancellationToken.None);

        using (var outputJson = JsonDocument.Parse(output))
        {
            Assert.Equal("Explore services", outputJson.RootElement.GetProperty("description").GetString());
            Assert.Equal("Inspect services", outputJson.RootElement.GetProperty("prompt").GetString());
            Assert.Equal("subagent answer", outputJson.RootElement.GetProperty("result").GetString());
        }

        Assert.Equal(HttpMethod.Post, handler.Request!.Method);
        Assert.Equal("Bearer", handler.Request.Headers.Authorization?.Scheme);
        Assert.Equal("test-key", handler.Request.Headers.Authorization?.Parameter);
        using var requestJson = JsonDocument.Parse(handler.Body!);
        var root = requestJson.RootElement;
        Assert.Equal("test-model", root.GetProperty("model").GetString());
        Assert.False(root.GetProperty("stream").GetBoolean());
        Assert.False(root.TryGetProperty("stream_options", out _));
        Assert.False(root.TryGetProperty("tools", out _));
        Assert.False(root.TryGetProperty("tool_choice", out _));
        var messages = root.GetProperty("messages");
        Assert.Equal("system", messages[0].GetProperty("role").GetString());
        Assert.Contains("read-only subagent", messages[0].GetProperty("content").GetString());
        Assert.Equal("user", messages[1].GetProperty("role").GetString());
        Assert.Contains($"Workspace: {temp.Root}", messages[1].GetProperty("content").GetString());
        Assert.Contains("Task type: explore", messages[1].GetProperty("content").GetString());
    }

    [Fact]
    public async Task ProviderNativeSubagentRunnerRoutesBackgroundSubagentLikeMac()
    {
        using var temp = new TempWorkspace();
        var handler = new CapturingProviderHandler("""
        {"choices":[{"message":{"role":"assistant","content":"background answer"}}]}
        """);
        var runner = new ProviderNativeSubagentRunner(new ProviderClient(new HttpClient(handler)));
        var parentProvider = new ProviderConfig(
            SessionProvider.G9Claw,
            ProviderApiType.OpenAIChat,
            "http://main.local/v1",
            "main-model",
            "main-secret",
            []);
        var rawValues = NativeConfigService.ScalarMap("""
models:
  providers:
    main:
      type: openai-chat
      baseUrl: http://main.local/v1
      apiKey: main-key
    background:
      type: openai-chat
      baseUrl: http://background.local/v1
      apiKey: background-key
  entries:
    default:
      provider: main
      name: main-model
      contextWindow: 160000
    background_agent:
      provider: background
      name: background-model
      contextWindow: 64000
agents:
  main:
    model: default
router:
  enabled: true
  routes:
    default:
      model: default
    background:
      model: background_agent
""");
        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None,
            rawValues,
            ProviderConfig: parentProvider,
            ApiKey: "parent-key",
            ContextWindow: 160_000);

        var output = await runner.RunAsync(
            new NativeSubagentRequest(temp.Root, "Inspect services", "Explore services", "Task type: explore", context),
            CancellationToken.None);

        using (var outputJson = JsonDocument.Parse(output))
        {
            Assert.Equal("background answer", outputJson.RootElement.GetProperty("result").GetString());
        }

        Assert.Equal("http://background.local/v1/chat/completions", handler.Request!.RequestUri!.ToString());
        Assert.Equal("background-key", handler.Request.Headers.Authorization?.Parameter);
        using var requestJson = JsonDocument.Parse(handler.Body!);
        Assert.Equal("background-model", requestJson.RootElement.GetProperty("model").GetString());
        Assert.False(requestJson.RootElement.GetProperty("stream").GetBoolean());
    }

    [Fact]
    public void ProviderRetryPolicyMatchesCodexTransientDefaults()
    {
        var policy = ProviderRetryPolicy.CodexDefault;

        Assert.True(NativeAgentRuntime.RetryDecision(ProviderClientException.Transport("Network request failed: timed out"), 0, policy).ShouldRetry);
        Assert.True(NativeAgentRuntime.RetryDecision(ProviderClientException.HttpError(502, "bad gateway"), 0, policy).ShouldRetry);
        Assert.False(NativeAgentRuntime.RetryDecision(ProviderClientException.HttpError(429, "rate limited"), 0, policy).ShouldRetry);
        Assert.False(NativeAgentRuntime.RetryDecision(ProviderClientException.HttpError(400, "bad request"), 0, policy).ShouldRetry);
        Assert.False(NativeAgentRuntime.RetryDecision(ProviderClientException.StreamInterruptedAfterPartialOutput("lost connection"), 0, policy).ShouldRetry);
    }

    [Fact]
    public void AgentToolSchemasIncludeG9ClawCodeCoreTools()
    {
        var names = AgentToolRegistry.OpenAITools()
            .Select(tool => (Dictionary<string, object?>)tool["function"]!)
            .Select(function => (string)function["name"]!)
            .ToHashSet(StringComparer.Ordinal);
        var canonical = new HashSet<string>([
            "Read",
            "Write",
            "StrReplace",
            "Delete",
            "EditNotebook",
            "Grep",
            "Glob",
            "SemanticSearch",
            "Shell",
            "Await",
            "ReadLints",
            "Skill",
            "TodoWrite",
            "AskQuestion",
            "SwitchMode",
            "Task",
        ], StringComparer.Ordinal);

        Assert.True(canonical.SetEquals(names));
        Assert.DoesNotContain("Bash", names);
        Assert.DoesNotContain("Agent", names);
        Assert.DoesNotContain("Edit", names);
        Assert.DoesNotContain("WebSearch", names);
        Assert.DoesNotContain("Weather", names);

        var taskSchema = AgentToolRegistry.OpenAITools()
            .Select(tool => (Dictionary<string, object?>)tool["function"]!)
            .Single(function => (string)function["name"]! == "Task");
        var taskParameters = (Dictionary<string, object?>)taskSchema["parameters"]!;
        var taskProperties = (Dictionary<string, object?>)taskParameters["properties"]!;
        Assert.Contains("isolation", taskProperties.Keys);
        Assert.Contains("n", taskProperties.Keys);

        var grepSchema = AgentToolRegistry.OpenAITools()
            .Select(tool => (Dictionary<string, object?>)tool["function"]!)
            .Single(function => (string)function["name"]! == "Grep");
        var grepParameters = (Dictionary<string, object?>)grepSchema["parameters"]!;
        var grepProperties = (Dictionary<string, object?>)grepParameters["properties"]!;
        Assert.Contains("-B", grepProperties.Keys);
        Assert.Contains("-A", grepProperties.Keys);
        Assert.Contains("-C", grepProperties.Keys);
        Assert.Contains("context", grepProperties.Keys);
        Assert.Contains("-n", grepProperties.Keys);
        Assert.Contains("type", grepProperties.Keys);
        Assert.Contains("offset", grepProperties.Keys);
        Assert.Contains("multiline", grepProperties.Keys);
    }

    [Fact]
    public void AgentToolNameCanonicalizerKeepsAliasesCompatible()
    {
        Assert.Equal("StrReplace", AgentToolNameCanonicalizer.Canonical("Edit"));
        Assert.Equal("StrReplace", AgentToolNameCanonicalizer.Canonical("MultiEdit"));
        Assert.Equal("Shell", AgentToolNameCanonicalizer.Canonical("Bash"));
        Assert.Equal("Shell", AgentToolNameCanonicalizer.Canonical("run_command"));
        Assert.Equal("Task", AgentToolNameCanonicalizer.Canonical("Agent"));
        Assert.Equal("Task", AgentToolNameCanonicalizer.Canonical("subagent"));
        Assert.Equal("Await", AgentToolNameCanonicalizer.Canonical("TaskOutput"));
        Assert.Equal("AskQuestion", AgentToolNameCanonicalizer.Canonical("AskUserQuestion"));
        Assert.Equal("SwitchMode", AgentToolNameCanonicalizer.Canonical("ExitPlanMode"));
        Assert.Equal("EditNotebook", AgentToolNameCanonicalizer.Canonical("NotebookEdit"));
        Assert.Equal("Weather", AgentToolNameCanonicalizer.Canonical("GetWeather"));
    }

    [Fact]
    public void NativeAgentRuntimeParsesFallbackJsonToolCall()
    {
        const string text = """
        ```json
        {"tool":"Read","input":{"file_path":"README.md"}}
        ```
        """;

        var calls = NativeAgentRuntime.FallbackToolCalls(text);

        Assert.Single(calls);
        Assert.Equal("Read", calls[0].Name);
        Assert.Contains("README.md", calls[0].InputJson);
    }

    [Fact]
    public void NativeAgentRuntimeDoesNotParseMixedMarkdownFallbackToolCall()
    {
        const string text = """
        I need to inspect the file.
        ```json
        {"tool":"Read","input":{"file_path":"README.md"}}
        ```
        """;

        Assert.Empty(NativeAgentRuntime.FallbackToolCalls(text));
    }

    [Fact]
    public void LegacySearchAndWeatherCallsNormalizeToGLMSkill()
    {
        var search = ToolArgumentNormalizer.Normalize(new AgentToolCall("search", "WebSearch", """{"query":"Beijing weather"}"""));
        var weather = ToolArgumentNormalizer.Normalize(new AgentToolCall("weather", "GetWeather", """{"location":"北京"}"""));
        var missing = ToolArgumentNormalizer.Normalize(new AgentToolCall("missing", "Weather", """{"unit":"celsius"}"""));

        Assert.Equal("Skill", search.Call.Name);
        Assert.Equal("Skill", weather.Call.Name);
        Assert.Null(search.RecoveryResult);
        Assert.Null(weather.RecoveryResult);
        Assert.Contains("g9claw-rag:glm-web-search", search.Call.InputJson);
        Assert.Contains("Beijing weather", search.Call.InputJson);
        Assert.Contains("北京 weather", weather.Call.InputJson);
        Assert.Equal("Skill", missing.Call.Name);
        Assert.True(missing.RecoveryResult?.IsError);
    }

    [Fact]
    public async Task LegacyWebFetchReturnsMacDisabledGuidance()
    {
        using var temp = new TempWorkspace();
        var executor = new AgentToolExecutor();
        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None);

        var result = await executor.ExecuteAsync(new AgentToolCall("fetch", "web_fetch", """{"url":"https://example.com"}"""), context);

        Assert.False(result.IsError);
        Assert.Equal("WebFetch", result.ToolName);
        Assert.Equal("WebFetch is disabled. Use Skill with g9claw-rag:rag-research for source-grounded web evidence.", result.Output);
    }

    [Fact]
    public async Task AgentToolExecutorLimitsSuccessfulOutputLikeMac()
    {
        using var temp = new TempWorkspace();
        await File.WriteAllTextAsync(Path.Combine(temp.Root, "large.txt"), new string('a', 25_000));
        var executor = new AgentToolExecutor();
        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None);

        var result = await executor.ExecuteAsync(new AgentToolCall("read-large", "Read", """{"file_path":"large.txt","limit":1}"""), context);

        Assert.False(result.IsError);
        Assert.EndsWith("\n... output truncated ...", result.Output);
        Assert.Equal(20_000 + "\n... output truncated ...".Length, result.Output.Length);
    }

    [Fact]
    public async Task AgentToolExecutorReadHandlesTextNotebookAndImagesLikeMac()
    {
        using var temp = new TempWorkspace();
        await File.WriteAllTextAsync(Path.Combine(temp.Root, "notes.txt"), "alpha\nbeta\ngamma");
        await File.WriteAllTextAsync(Path.Combine(temp.Root, "demo.ipynb"), """
        {"cells":[{"cell_type":"markdown","source":["# Title\n","Body"]},{"cell_type":"code","source":"print(1)"}]}
        """);
        await File.WriteAllBytesAsync(Path.Combine(temp.Root, "sample.pdf"), MinimalPdf("Hello PDF"));
        await File.WriteAllBytesAsync(Path.Combine(temp.Root, "pixel.png"), [0x89, 0x50, 0x4E, 0x47]);
        var executor = new AgentToolExecutor();
        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None);

        var text = await executor.ExecuteAsync(new AgentToolCall("read-text", "Read", """{"file_path":"notes.txt","offset":2,"limit":2}"""), context);
        var notebook = await executor.ExecuteAsync(new AgentToolCall("read-notebook", "Read", """{"file_path":"demo.ipynb"}"""), context);
        var pdf = await executor.ExecuteAsync(new AgentToolCall("read-pdf", "Read", """{"file_path":"sample.pdf","pages":"1"}"""), context);
        var image = await executor.ExecuteAsync(new AgentToolCall("read-image", "Read", """{"file_path":"pixel.png"}"""), context);

        Assert.False(text.IsError);
        Assert.Equal(["2: beta", "3: gamma"], OutputLines(text.Output));
        Assert.False(notebook.IsError);
        Assert.Contains("Notebook demo.ipynb", notebook.Output);
        Assert.Contains("cells: 2", notebook.Output);
        Assert.Contains("## Cell 0 [markdown]", notebook.Output);
        Assert.Contains("# Title\nBody", notebook.Output);
        Assert.False(pdf.IsError);
        Assert.Contains("PDF sample.pdf", pdf.Output);
        Assert.Contains("pages: 1", pdf.Output);
        Assert.Contains("selected: 1", pdf.Output);
        Assert.Contains("## Page 1", pdf.Output);
        Assert.Contains("Hello PDF", pdf.Output);
        Assert.Equal([1, 2, 3, 5], AgentToolExecutor.ParsePdfPages("3-1,5,99", 5));
        Assert.False(image.IsError);
        using var imageJson = JsonDocument.Parse(image.Output);
        Assert.Equal("image", imageJson.RootElement.GetProperty("type").GetString());
        var file = imageJson.RootElement.GetProperty("file");
        Assert.Equal("pixel.png", file.GetProperty("filePath").GetString());
        Assert.Equal("image/png", file.GetProperty("mediaType").GetString());
        Assert.Equal(4, file.GetProperty("originalSize").GetInt32());
        Assert.Equal("iVBORw==", file.GetProperty("base64").GetString());
    }

    [Fact]
    public void ToolArgumentNormalizerTurnsMalformedArgumentsIntoRecoverableToolResult()
    {
        var invocation = ToolArgumentNormalizer.Normalize(new AgentToolCall("call-bad", "Edit", """{file_path:"index.html"}"""));

        Assert.Equal("{}", invocation.Call.InputJson);
        Assert.Equal("call-bad", invocation.RecoveryResult?.CallId);
        Assert.Equal("StrReplace", invocation.RecoveryResult?.ToolName);
        Assert.True(invocation.RecoveryResult?.IsError);
        Assert.Contains("invalid JSON", invocation.RecoveryResult?.Output);
        Assert.Equal("{}", ToolArgumentNormalizer.ProviderSafeInputJson("""{file_path:"index.html"}"""));
    }

    [Fact]
    public void WorkspaceUploadAndPreviewStayInsideWorkspace()
    {
        using var temp = new TempWorkspace();
        var service = new WorkspaceService(temp.Root);
        var source = Path.Combine(temp.Root, "source.txt");
        File.WriteAllText(source, "hello preview");
        var uploads = Directory.CreateDirectory(Path.Combine(temp.Root, "uploads")).FullName;

        var uploaded = service.UploadFile(source, uploads, temp.Root, overwrite: true);
        var preview = service.Preview("uploads/source.txt", temp.Root);

        Assert.Equal(uploaded, preview.Path);
        Assert.Equal(WorkspacePreviewKind.Text, preview.Kind);
        Assert.Equal("hello preview", preview.Text);
        Assert.Throws<InvalidOperationException>(() => service.Preview(@"..\outside.txt", temp.Root));
    }

    [Fact]
    public void PermissionLifecycleCoversAllowDenyAndTimeout()
    {
        var service = new PermissionService();
        var allow = service.Request("s1", "Write", """{"file_path":"a.txt"}""", "file write");
        var deny = service.Request("s1", "Shell", """{"command":"del *"}""", "destructive shell");

        var allowed = service.Resolve(allow.Request.Id, allow: true, PermissionScope.Project);
        var denied = service.Resolve(deny.Request.Id, allow: false);
        var expired = service.Request("s1", "Delete", """{"path":"old"}""", "delete");
        var expiredRecords = service.ExpirePending(TimeSpan.Zero);

        Assert.Equal(PermissionDecision.Allowed, allowed.Decision);
        Assert.Equal(PermissionScope.Project, allowed.GrantedScope);
        Assert.Equal(PermissionDecision.Denied, denied.Decision);
        Assert.Contains(expiredRecords, record => record.Request.Id == expired.Request.Id && record.Decision == PermissionDecision.Expired);
        Assert.Empty(service.Pending("s1"));
    }

    [Fact]
    public void PluginServiceLoadsManifestAssetsAndEnableFlag()
    {
        using var temp = new TempWorkspace();
        var pluginDir = Directory.CreateDirectory(Path.Combine(temp.Root, "plugins", "demo")).FullName;
        Directory.CreateDirectory(Path.Combine(pluginDir, "assets"));
        File.WriteAllText(Path.Combine(pluginDir, "plugin.json"), """
        {"id":"demo","name":"Demo Plugin","version":"1.2.3","enabled":true,"tabs":["demo-tab"]}
        """);
        File.WriteAllText(Path.Combine(pluginDir, "assets", "icon.txt"), "asset");

        var service = new PluginService(Path.Combine(temp.Root, "plugins"));
        var plugin = Assert.Single(service.Load());
        service.SetEnabled("demo", false);
        var disabled = Assert.Single(service.Load());

        Assert.Equal("Demo Plugin", plugin.Name);
        Assert.Equal("1.2.3", plugin.Version);
        Assert.Contains("demo-tab", plugin.Tabs);
        Assert.Contains(plugin.Assets, asset => asset.EndsWith("icon.txt", StringComparison.OrdinalIgnoreCase));
        Assert.False(disabled.Enabled);
    }

    [Fact]
    public void GitServiceCoversBranchDiffDiscardAndUntrackedDelete()
    {
        using var temp = new TempWorkspace();
        var service = new GitService();
        service.Init(temp.Root);
        var file = Path.Combine(temp.Root, "README.md");
        File.WriteAllText(file, "hello");
        var first = service.Commit(temp.Root, "initial", ["README.md"], "G9Claw", "g9claw@example.local");

        File.WriteAllText(file, "hello world");
        File.WriteAllText(Path.Combine(temp.Root, "temp.txt"), "untracked");
        var diff = service.FileDiff(temp.Root, "README.md");
        service.CreateBranch(temp.Root, "feature");
        var branches = service.Branches(temp.Root);
        service.Discard(temp.Root, ["README.md"]);
        service.DeleteUntracked(temp.Root);
        var status = service.Status(temp.Root);

        Assert.False(string.IsNullOrWhiteSpace(first.Sha));
        Assert.Contains("+hello world", diff);
        Assert.Contains("feature", branches.Branches);
        Assert.False(File.Exists(Path.Combine(temp.Root, "temp.txt")));
        Assert.False(status.IsDirty);
    }

    [Fact]
    public void AgentEventNormalizerCoversProviderEvents()
    {
        var content = AgentEventNormalizer.FromProviderEvent("s1", new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: "hello"));
        var tool = AgentEventNormalizer.FromProviderEvent("s1", new ProviderStreamEvent(ProviderStreamEventKind.ToolCall, ToolCall: new AgentToolCall("c1", "Read", "{}")));
        var budget = AgentEventNormalizer.FromProviderEvent("s1", new ProviderStreamEvent(ProviderStreamEventKind.TokenBudget, TokenBudget: new TokenBudget(3, 10)));
        var done = AgentEventNormalizer.FromProviderEvent("s1", new ProviderStreamEvent(ProviderStreamEventKind.Done));

        Assert.Equal(AgentEventKind.ContentDelta, Assert.Single(content).Kind);
        Assert.Equal(AgentEventKind.ToolUse, Assert.Single(tool).Kind);
        Assert.Equal(new TokenBudget(3, 10), Assert.Single(budget).TokenBudget);
        Assert.Equal([AgentEventKind.StreamEnd, AgentEventKind.Complete], done.Select(item => item.Kind));
    }

    [Fact]
    public void TaskMasterServiceDetectsInitializesAndPersistsTasks()
    {
        using var temp = new TempWorkspace();
        var service = new TaskMasterService();

        Assert.False(service.Detect(temp.Root).Detected);
        var initialized = service.Init(temp.Root);
        var task = service.AddTask(temp.Root, "Build Windows app", "Reach native parity");
        var detected = service.Detect(temp.Root);

        Assert.True(initialized.Detected);
        Assert.True(File.Exists(initialized.TasksFile));
        Assert.Equal(task.Id, Assert.Single(detected.Tasks).Id);
    }

    [Fact]
    public void SettingsSecurityMasksSecretsAndMergesLegacyConfig()
    {
        const string yaml = """
        runtime:
          apiTimeoutMs: 90000
          contextWindow: 120000
          workspacesRoot: C:\Users\tester\Workspace
        gateway:
          runtimePaths:
            generalCwd: C:\Users\tester\G9Claw\general
        models:
          providers:
            g9claw:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: sk-1234567890
          entries:
            default:
              provider: g9claw
              name: qwen3.6-27b
        """;
        var native = NativeConfigService.Snapshot(yaml)!;
        var current = AppSettings.Defaults(@"C:\Users\tester");
        var merged = SettingsSecurity.MergeLegacyConfig(current, native);

        Assert.Equal("sk-1...7890", SettingsSecurity.MaskSecret("sk-1234567890"));
        Assert.Equal("http://example.local/v1", merged.ProviderConfig.BaseUrl);
        Assert.Equal(90_000, merged.ApiTimeoutMs);
        Assert.Equal(120_000, merged.ContextWindow);
    }

    [Fact]
    public void NativeSettingsDefaultsNormalizeNewFields()
    {
        var settings = AppState.NormalizeSettings(AppSettings.Defaults(@"C:\Users\tester") with
        {
            EditorSettings = new NativeEditorSettings(true, true, true, 2),
            RouterSettings = new NativeRouterSettings(true, "", new Dictionary<string, string> { ["Fast"] = "qwen" }, -1, -2, -3, -4),
        });

        Assert.Equal(10, settings.EditorSettings.FontSize);
        Assert.Equal("default", settings.RouterSettings.DefaultRoute);
        Assert.Equal(0, settings.RouterSettings.InputPricePerMillion);
        Assert.True(settings.RouterSettings.TierModelEntries.ContainsKey("fast"));
        Assert.True(settings.FeatureSettings.MemoryEnabled);
        Assert.NotEmpty(settings.Providers!);
        Assert.NotEmpty(settings.ModelEntries!);
        Assert.Equal("default", settings.AgentSettings!.MainModelEntryId);
        Assert.Equal(settings.WorkspacesRoot, settings.RuntimeSettings!.WorkspacesRoot);
    }

    [Fact]
    public void NativeSettingsDraftValidatesAndNormalizesPermissions()
    {
        var current = AppSettings.Defaults(@"C:\Users\tester");
        var draft = NativeSettingsDraft.From(current) with
        {
            BaseUrl = "http://example.local/v1",
            Model = " qwen ",
            AllowedTools = ["Shell(git status:*)", "Shell(git status:*)", " "],
            DisallowedTools = ["Delete"],
            RouterInputPricePerMillion = 0.1m,
            RouterOutputPricePerMillion = 0.2m,
        };

        Assert.True(draft.Validate().Valid);
        var applied = draft.ApplyTo(current);

        Assert.Equal("qwen", draft.Model.Trim());
        Assert.NotEmpty(applied.ModelEntries!);
        Assert.Equal(["Shell(git status:*)"], applied.Permissions.AllowedTools);
        Assert.Equal(["Delete"], applied.Permissions.DisallowedTools);
        Assert.Equal(0.1m, applied.RouterSettings.InputPricePerMillion);
        Assert.Equal("default", applied.AgentSettings!.MainModelEntryId);
    }

    [Fact]
    public async Task AppSettingsStoreLoadsOlderJsonWithNewDefaults()
    {
        using var temp = new TempWorkspace();
        var settingsFile = Path.Combine(temp.Root, "settings.json");
        await File.WriteAllTextAsync(settingsFile, """
        {
          "providerConfig": {
            "provider": "G9Claw",
            "apiType": "OpenAIChat",
            "baseUrl": "http://example.local/v1",
            "model": "qwen",
            "secretAccount": "g9claw-default-provider"
          },
          "workspacesRoot": "C:\\Users\\tester",
          "generalWorkspacePath": "C:\\Users\\tester\\G9Claw\\general",
          "apiTimeoutMs": 90000,
          "contextWindow": 160000,
          "projectSortOrder": "Date",
          "colorScheme": "System",
          "language": "Auto"
        }
        """);

        var loaded = await new AppSettingsStore(settingsFile).LoadAsync();

        Assert.NotNull(loaded);
        Assert.Equal(NativeEditorSettings.Defaults, loaded!.EditorSettings);
        Assert.False(loaded.RouterSettings.Enabled);
        Assert.True(loaded.FeatureSettings.MemoryEnabled);
        Assert.NotNull(loaded.ProviderConfig.Headers);
        Assert.NotEmpty(loaded.Providers!);
        Assert.NotEmpty(loaded.ModelEntries!);
    }

    [Fact]
    public void ToolPermissionPolicyUsesAllowDenyAndApproval()
    {
        var settings = new ToolPermissionSettings(["Shell(git status:*)"], ["Delete"], null);

        Assert.Equal(ToolPermissionDecision.Allowed, ToolPermissionPolicy.Decide(
            new AgentToolCall("c1", "Shell", """{"command":"git status --short"}"""),
            settings,
            ComposerPermissionMode.Default));
        Assert.Equal(ToolPermissionDecision.Allowed, ToolPermissionPolicy.Decide(
            new AgentToolCall("c1b", "Shell", """{"command":"git status --short"}"""),
            new ToolPermissionSettings(["Bash(git status:*)"], [], null),
            ComposerPermissionMode.Default));
        Assert.Equal(ToolPermissionDecision.Denied, ToolPermissionPolicy.Decide(
            new AgentToolCall("c2", "Delete", """{"path":"README.md"}"""),
            settings,
            ComposerPermissionMode.Default));
        Assert.Equal(ToolPermissionDecision.RequiresApproval, ToolPermissionPolicy.Decide(
            new AgentToolCall("c3", "Write", """{"file_path":"README.md","content":"x"}"""),
            settings,
            ComposerPermissionMode.Default));
    }

    [Fact]
    public void RoutingUsageAggregatorComputesDashboardTotals()
    {
        var now = DateTimeOffset.UtcNow;
        var records = new[]
        {
            new RoutingUsageRecord("s1", "Demo", "default", "G9Claw", "cheap", "default", 1000, 500, 0.001m, 0.004m, now),
            new RoutingUsageRecord("s2", "Demo", "default", "G9Claw", "cheap", "default", 2000, 1000, 0.002m, 0.006m, now.AddMinutes(-1)),
        };

        var snapshot = RoutingUsageAggregator.Snapshot(records);

        Assert.Equal(2, snapshot.RequestCount);
        Assert.Equal(4500, snapshot.TotalTokens);
        Assert.Equal(0.003m, snapshot.EstimatedCost);
        Assert.Equal(0.010m, snapshot.BaselineCost);
        Assert.Equal(0.007m, snapshot.SavedCost);
        Assert.Equal("cheap", Assert.Single(snapshot.ModelBreakdown).Model);
    }

    [Fact]
    public void RoutingDashboardSessionMatchesMacFallbackTotals()
    {
        var now = DateTimeOffset.UtcNow;
        var byTier = new Dictionary<string, RoutingBucket>(StringComparer.OrdinalIgnoreCase)
        {
            ["SIMPLE"] = new RoutingBucket(2, 100, 20, 5, 125, 3, 0.01m, 0.05m, 0.04m),
        };
        var byModel = new Dictionary<string, RoutingBucket>(StringComparer.OrdinalIgnoreCase)
        {
            ["qwen"] = new RoutingBucket(4, 200, 30, 0, 230, 4, 0.02m, 0.08m, 0.06m),
        };
        var byRole = new Dictionary<string, RoutingBucket>(StringComparer.OrdinalIgnoreCase)
        {
            ["assistant"] = new RoutingBucket(1, 50, 10, 0, 60, 2, 0.01m, 0.03m, 0.02m),
        };
        var entry = new RoutingRequestLogEntry(
            "entry-1",
            now,
            "assistant",
            "SIMPLE",
            "qwen",
            125,
            0.01m,
            0.05m,
            0.04m,
            Query: "ping",
            Scenario: "chat",
            Route: "default",
            Skill: "none");
        var session = new RoutingDashboardSession(
            "session-1",
            "Chat",
            "Demo",
            now,
            125,
            0.01m,
            0.04m,
            Total: null,
            ByTier: byTier,
            ByModel: byModel,
            ByScenario: null,
            ByRole: byRole,
            RequestLog: ["assistant SIMPLE qwen"],
            RequestEntries: [entry]);
        var snapshot = new RoutingDashboardSnapshot(
            RequestCount: 1,
            InputTokens: 100,
            OutputTokens: 25,
            EstimatedCost: 0.01m,
            BaselineCost: 0.05m,
            RecentRoutes: [],
            ModelBreakdown: [],
            TotalProjects: 1,
            TotalSessions: 2,
            RoutedSessions: 1,
            RecentSessions: [session]);

        Assert.Equal(4, session.EffectiveTotal.Count);
        Assert.Equal(4, session.EffectiveTotal.RequestCount);
        Assert.Empty(session.EffectiveByScenario);
        Assert.Equal("entry-1", Assert.Single(session.EffectiveRequestEntries).Id);
        Assert.Equal(1, snapshot.TotalProjects);
        Assert.Equal(2, snapshot.TotalSessions);
        Assert.Equal(1, snapshot.RoutedSessions);
        Assert.Equal("session-1", Assert.Single(snapshot.EffectiveRecentSessions).Id);
    }

    [Fact]
    public void RoutingUsageEstimatorRecordsRouterFallbackMetadata()
    {
        var request = new AgentRequest(
            "s1",
            @"C:\Users\tester\Workspace",
            "hello",
            [],
            new ProviderConfig(
                SessionProvider.G9Claw,
                ProviderApiType.OpenAIChat,
                "http://main.local/v1",
                "qwen3.6-27b",
                "main-secret",
                []),
            "sk-test",
            [],
            120000,
            250000,
            ComposerPermissionMode.Default,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            "default",
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["router.tier"] = "SIMPLE",
                ["router.fallbackFromModelEntry"] = "router_small",
                ["router.fallbackReason"] = "Router-selected model is unavailable.",
                ["router.finalModelEntry"] = "default",
            });

        var record = RoutingUsageEstimator.FromBudget(request, null, new TokenBudget(1500, 250000));

        Assert.Equal("router_small", record.FallbackFromModelEntry);
        Assert.Equal("default", record.FinalModelEntry);
        Assert.Contains("unavailable", record.FallbackReason);
        Assert.Equal("qwen3.6-27b", record.Model);
        Assert.Equal("SIMPLE", record.Tier);
    }

    [Fact]
    public void NativeRoutingClassifierMatchesSwiftTierPolicy()
    {
        Assert.Equal("REASONING", NativeRoutingClassifier.ClassifyTier("any prompt", ChatRunMode.Plan));
        Assert.Equal("SIMPLE", NativeRoutingClassifier.ClassifyTier("ping status", ChatRunMode.Agent));
        Assert.Equal("COMPLEX", NativeRoutingClassifier.ClassifyTier("please implement this multi-file fix", ChatRunMode.Agent));
        Assert.Equal("REASONING", NativeRoutingClassifier.ClassifyTier(
            "please do deep architecture reasoning across the whole system and research the refactor tradeoffs before changing any code",
            ChatRunMode.Agent));
        Assert.Equal("MEDIUM", NativeRoutingClassifier.ClassifyTier(
            "summarize the current session and next steps in detail with enough background context to avoid losing important decisions while keeping the answer concise and organized for handoff",
            ChatRunMode.Agent));
    }

    [Fact]
    public void NativeRouterRuntimeSelectsTierModelWithoutProxy()
    {
        const string yaml = """
models:
  providers:
    main:
      type: openai-chat
      baseUrl: http://main.local/v1
    cheap:
      type: openai-chat
      baseUrl: http://cheap.local/v1
  entries:
    default:
      provider: main
      name: main-model
    router_small:
      provider: cheap
      name: cheap-model
router:
  enabled: true
  routes:
    default:
      model: default
  tokenSaver:
    tiers:
      SIMPLE:
        model: router_small
""";

        var values = NativeConfigService.ScalarMap(yaml);

        Assert.Equal("router_small", NativeRouterRuntime.EntryIdForTier("SIMPLE", values));
        Assert.Equal("default", NativeRouterRuntime.EntryIdForTier("COMPLEX", values));
    }

    [Fact]
    public void NativeRouterRuntimeDecisionMatchesMacRoutingScenarios()
    {
        const string yaml = """
models:
  providers:
    main:
      type: openai-chat
      baseUrl: http://main.local/v1
    router:
      type: openai-chat
      baseUrl: http://router.local/v1
  entries:
    default:
      provider: main
      name: main-model
    router_default:
      provider: router
      name: default-router-model
    simple:
      provider: router
      name: simple-model
    long:
      provider: router
      name: long-model
    background:
      provider: router
      name: background-model
    search:
      provider: router
      name: search-model
    think:
      provider: router
      name: think-model
agents:
  main:
    model: default
router:
  enabled: true
  routes:
    default:
      model: router_default
    longContext:
      model: long
    background:
      model: background
    webSearch:
      model: search
    think:
      model: think
    longContextThreshold: 12
  tokenSaver:
    tiers:
      SIMPLE:
        model: simple
""";

        var values = NativeConfigService.ScalarMap(yaml);

        Assert.Equal(new NativeRouterRuntime.Decision("simple", "tokenSaver", "SIMPLE"),
            NativeRouterRuntime.DecisionForTier("SIMPLE", values));
        Assert.Equal(new NativeRouterRuntime.Decision("long", "longContext", null),
            NativeRouterRuntime.DecisionForTier("COMPLEX", values, new NativeRouterRuntime.RequestSignals(TokenCount: 13)));
        Assert.Equal(new NativeRouterRuntime.Decision("background", "background", null),
            NativeRouterRuntime.DecisionForTier("COMPLEX", values, new NativeRouterRuntime.RequestSignals(IsBackgroundRequest: true)));
        Assert.Equal(new NativeRouterRuntime.Decision("search", "webSearch", null),
            NativeRouterRuntime.DecisionForTier("COMPLEX", values, new NativeRouterRuntime.RequestSignals(HasWebSearchTools: true)));
        Assert.Equal(new NativeRouterRuntime.Decision("think", "think", null),
            NativeRouterRuntime.DecisionForTier("COMPLEX", values, new NativeRouterRuntime.RequestSignals(HasThinking: true)));
        Assert.Equal(new NativeRouterRuntime.Decision("router_default", "default", null),
            NativeRouterRuntime.DecisionForTier("COMPLEX", values));

        values["router.enabled"] = "false";

        Assert.Equal(new NativeRouterRuntime.Decision("default", "default", null),
            NativeRouterRuntime.DecisionForTier("SIMPLE", values));
    }

    [Fact]
    public void NativeRouterRuntimeSignalsIncludeHistoryAttachmentsAndToolsLikeMac()
    {
        using var temp = new TempWorkspace();
        var attachmentPath = Path.Combine(temp.Root, "notes.md");
        File.WriteAllText(attachmentPath, new string('a', 2_000));
        var priorMessages = new List<ChatMessage>
        {
            new(
                Guid.NewGuid(),
                "session-1",
                SessionProvider.G9Claw,
                ChatRole.User,
                [ChatBlock.FromText(new string('h', 1_000))],
                DateTimeOffset.UtcNow,
                false,
                null),
        };
        var attachments = new List<FileAttachment>
        {
            new(attachmentPath, "notes.md", "text/markdown", new FileInfo(attachmentPath).Length),
        };
        var values = NativeConfigService.ScalarMap("""
models:
  providers:
    main:
      type: openai-chat
      baseUrl: http://main.local/v1
    long:
      type: openai-chat
      baseUrl: http://long.local/v1
  entries:
    default:
      provider: main
      name: main-model
    long_context:
      provider: long
      name: long-model
router:
  enabled: true
  routes:
    default:
      model: default
    longContext:
      model: long_context
    longContextThreshold: 300
""");

        var signals = NativeRouterRuntime.SignalsForRequest("short", priorMessages, attachments);
        var imageSignals = NativeRouterRuntime.SignalsForRequest(
            "short",
            [],
            [new FileAttachment(Path.Combine(temp.Root, "image.png"), "image.png", "image/png", 42)]);

        Assert.True(signals.TokenCount > 300);
        Assert.True(imageSignals.TokenCount >= 2_000);
        Assert.Equal(new NativeRouterRuntime.Decision("long_context", "longContext", null),
            NativeRouterRuntime.DecisionForTier("COMPLEX", values, signals));
    }

    [Fact]
    public void AgentModelResolverCanResolveRouterSelectedEntry()
    {
        var settings = AppSettings.Defaults(@"C:\Users\tester") with
        {
            Providers =
            [
                new NativeProviderEntry("main", ProviderApiType.OpenAIChat, "http://main.local/v1", "main-secret", []),
                new NativeProviderEntry("cheap", ProviderApiType.OpenAIChat, "http://cheap.local/v1", "cheap-secret", []),
            ],
            ModelEntries =
            [
                new NativeModelEntry("default", "main", "main-model", 160000),
                new NativeModelEntry("router_small", "cheap", "cheap-model", 64000),
            ],
            AgentSettings = new NativeAgentSettings("default", "default", "{}"),
        };

        var resolved = AgentModelResolver.Resolve(settings, "router_small", "SIMPLE", "router");

        Assert.Equal("cheap", resolved.ProviderId);
        Assert.Equal("router_small", resolved.ModelEntryId);
        Assert.Equal("cheap-model", resolved.ModelName);
        Assert.Equal("SIMPLE", resolved.RouteTier);
        Assert.Equal("router", resolved.RouteSource);
        Assert.Equal("http://cheap.local/v1/chat/completions", resolved.EndpointUrl.ToString());
    }

    [Fact]
    public void RouterFallbackPolicyFallsBackToMainModelWhenRouterModelUnavailable()
    {
        var settings = AppSettings.Defaults(@"C:\Users\tester") with
        {
            Providers =
            [
                new NativeProviderEntry("main", ProviderApiType.OpenAIChat, "http://main.local/v1", "main-secret", []),
                new NativeProviderEntry("router", ProviderApiType.OpenAIChat, "http://router.local/v1", "router-secret", []),
            ],
            ModelEntries =
            [
                new NativeModelEntry("default", "main", "qwen3.6-27b", 250000),
                new NativeModelEntry("router_small", "router", "qwen3.6-35b-a3b", 250000),
            ],
            AgentSettings = new NativeAgentSettings("default", "inherit", "{}"),
        };
        var failedModel = AgentModelResolver.Resolve(settings, "router_small", "SIMPLE", "router");
        var configValues = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["agents.main.model"] = "default",
            ["router.routes.default.model"] = "default",
        };

        var fallback = RouterFallbackPolicy.TryResolve(
            settings,
            configValues,
            failedModel,
            """{"error":{"code":"model_not_found","message":"\u65e0\u53ef\u7528\u6e20\u9053"}}""");

        Assert.NotNull(fallback);
        Assert.Equal("router_small", fallback!.FromModelEntryId);
        Assert.Equal("default", fallback.Model.ModelEntryId);
        Assert.Equal("qwen3.6-27b", fallback.Model.ModelName);
        Assert.Equal("router-fallback", fallback.Model.RouteSource);
    }

    [Fact]
    public void RouterFallbackPolicyDoesNotFallbackForNonRouterOrNonModelErrors()
    {
        var settings = AppSettings.Defaults(@"C:\Users\tester") with
        {
            Providers =
            [
                new NativeProviderEntry("main", ProviderApiType.OpenAIChat, "http://main.local/v1", "main-secret", []),
                new NativeProviderEntry("router", ProviderApiType.OpenAIChat, "http://router.local/v1", "router-secret", []),
            ],
            ModelEntries =
            [
                new NativeModelEntry("default", "main", "main-model", 160000),
                new NativeModelEntry("router_small", "router", "cheap-model", 64000),
            ],
            AgentSettings = new NativeAgentSettings("default", "inherit", "{}"),
        };
        var routerModel = AgentModelResolver.Resolve(settings, "router_small", "SIMPLE", "router");
        var directModel = AgentModelResolver.Resolve(settings, "router_small", "direct", "agent");
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["agents.main.model"] = "default" };

        Assert.True(RouterFallbackPolicy.IsModelUnavailable("\u65e0\u53ef\u7528\u6e20\u9053: no channel available"));
        Assert.Null(RouterFallbackPolicy.TryResolve(settings, values, routerModel, "HTTP 401 unauthorized"));
        Assert.Null(RouterFallbackPolicy.TryResolve(settings, values, directModel, "model_not_found"));
    }

    [Fact]
    public void AppStateKeepsAssistantTextAndToolsInterleaved()
    {
        var state = AppState.CreateDefault();
        var project = state.Projects.First();
        state.SelectProject(project);
        state.CreateSessionForSelectedProject("test");
        var sessionId = state.SelectedSessionId!;
        var call = new AgentToolCall("call-1", "Read", """{"file_path":"README.md"}""");
        var result = new AgentToolResult("call-1", "Read", "content", false);

        state.EnsureStreamingAssistantMessage(sessionId);
        state.AppendStreamingAssistantText(sessionId, "Before ", null);
        state.AppendStreamingAssistantToolCall(sessionId, call);
        state.AppendStreamingAssistantToolResult(sessionId, result);
        state.AppendStreamingAssistantText(sessionId, "after.", new TokenBudget(80, 100));

        var message = Assert.Single(state.CurrentMessages, message => message.Role == ChatRole.Assistant);
        Assert.Equal(
            [ChatBlockKind.Text, ChatBlockKind.ToolCall, ChatBlockKind.ToolResult, ChatBlockKind.Text],
            message.Blocks.Select(block => block.Kind));
        Assert.Equal("Before after.", message.PlainText);
        Assert.Equal(80, message.TokenBudget!.Used);
    }

    [Fact]
    public void AppStateExposesMacParitySessionActivityAndUiState()
    {
        var state = AppState.CreateDefault();
        var project = state.Projects.First();
        state.SelectProject(project);
        var sessionId = state.CreateSessionForSelectedProject("Parity")!.Id;
        var now = DateTimeOffset.UtcNow;
        var activity = new AgentActivity(
            "activity-1",
            sessionId,
            "run-1",
            "Running",
            "",
            AgentActivityPhase.Status,
            AgentActivityState.Running,
            now,
            now);
        var late = new AgentTurnItem(
            "item-2",
            2,
            AgentTurnItemKind.Status,
            AgentTurnItemStatus.Completed,
            "Second",
            "",
            null,
            now,
            now,
            now,
            null,
            null,
            null,
            sessionId,
            "turn-1");
        var early = late with { Id = "item-1", Sequence = 1, Title = "First" };

        state.ActivitiesBySession[sessionId] = [activity];
        state.TurnItemsBySession[sessionId] = [late, early];
        state.MessagesBySession[sessionId].Add(new ChatMessage(
            Guid.NewGuid(),
            sessionId,
            SessionProvider.G9Claw,
            ChatRole.Assistant,
            [ChatBlock.FromText("streaming")],
            now,
            IsStreaming: true,
            TokenBudget: null));
        state.ExpandedToolRowIds.Add("tool-1");
        state.CollapsedToolRowIds.Add("tool-2");
        state.IsSidebarVisible = state.UiPreferences.SidebarVisible;
        state.GitOutput = "git status";
        state.G9ClawConfigText = "runtime:";
        state.ToolRefreshRevision++;
        state.StreamRenderRevision++;
        state.IsDraftSessionVisible = true;

        Assert.Equal("activity-1", Assert.Single(state.CurrentActivities).Id);
        Assert.Equal(["item-1", "item-2"], state.CurrentTurnItems.Select(item => item.Id));
        Assert.True(state.IsCurrentSessionStreaming);
        Assert.Contains("tool-1", state.ExpandedToolRowIds);
        Assert.Contains("tool-2", state.CollapsedToolRowIds);
        Assert.True(state.IsSidebarVisible);
        Assert.Equal("git status", state.GitOutput);
        Assert.Equal("runtime:", state.G9ClawConfigText);
        Assert.Equal(1, state.ToolRefreshRevision);
        Assert.Equal(1, state.StreamRenderRevision);
        Assert.True(state.IsDraftSessionVisible);
    }

    [Fact]
    public void AppStateBeginsNewAssistantMessageForEachTurnAndIgnoresLateEvents()
    {
        var state = AppState.CreateDefault();
        var project = state.Projects.First();
        state.SelectProject(project);
        state.CreateSessionForSelectedProject("test");
        var sessionId = state.SelectedSessionId!;

        var first = state.BeginStreamingAssistantMessage(sessionId, forceNew: true);
        state.AppendStreamingAssistantText(sessionId, first, "first", null);
        var second = state.BeginStreamingAssistantMessage(sessionId, forceNew: true);
        state.AppendStreamingAssistantText(sessionId, first, " late", null);
        state.AppendStreamingAssistantText(sessionId, second, "second", null);
        state.FinishStreamingAssistantMessage(sessionId, second);

        var assistantMessages = state.CurrentMessages.Where(message => message.Role == ChatRole.Assistant).ToList();
        Assert.Equal(2, assistantMessages.Count);
        Assert.Equal("first", assistantMessages[0].PlainText);
        Assert.Equal("second", assistantMessages[1].PlainText);
        Assert.False(assistantMessages[0].IsStreaming);
        Assert.False(assistantMessages[1].IsStreaming);
    }

    [Fact]
    public void AppStateStoresProviderErrorsAsStructuredBlocksAndDedupesByRequest()
    {
        var state = AppState.CreateDefault();
        var project = state.Projects.First();
        state.SelectProject(project);
        state.CreateSessionForSelectedProject("test");
        var sessionId = state.SelectedSessionId!;

        state.EnsureStreamingAssistantMessage(sessionId);
        state.AppendStreamingAssistantProviderError(
            sessionId,
            new ProviderErrorInfo(
                "Provider request failed",
                "first body",
                "router",
                "router_small",
                "qwen3.6-35b-a3b",
                "http://router.local/v1/chat/completions",
                "req-1",
                "SIMPLE"));
        state.AppendStreamingAssistantProviderError(
            sessionId,
            new ProviderErrorInfo(
                "Router fallback",
                "updated body",
                "router",
                "router_small",
                "qwen3.6-35b-a3b",
                "http://router.local/v1/chat/completions",
                "req-1",
                "SIMPLE",
                "router_small",
                "default",
                "Router-selected model is unavailable."));

        var message = Assert.Single(state.CurrentMessages, message => message.Role == ChatRole.Assistant);
        var error = Assert.Single(message.Blocks, block => block.Kind == ChatBlockKind.ProviderError);
        Assert.Equal("Router fallback", error.ProviderError!.Summary);
        Assert.Equal("default", error.ProviderError.FallbackToModelEntry);
        Assert.Empty(message.PlainText);
    }

    [Fact]
    public async Task NativeAgentRunnerContinuesPastSixToolRounds()
    {
        using var temp = new TempWorkspace();
        var provider = new MultiRoundToolProvider(rounds: 8);
        var runner = new NativeAgentRunner(providerClient: provider);
        var request = new AgentRequest(
            "session-1",
            temp.Root,
            "keep using tools",
            [],
            new ProviderConfig(SessionProvider.G9Claw, ProviderApiType.OpenAIChat, "http://provider.local/v1", "test-model", "secret", []),
            "test-key",
            [],
            120000,
            160000,
            ComposerPermissionMode.Default,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            "default",
            []);

        var events = new List<AgentEvent>();
        await foreach (var agentEvent in runner.RunAsync(request))
        {
            events.Add(agentEvent);
        }

        Assert.Equal(9, provider.RequestCount);
        Assert.Equal(8, events.Count(item => item.Kind == AgentEventKind.ToolResult));
        Assert.Contains(events, item => item.Kind == AgentEventKind.ContentDelta && item.Text == "done");
        Assert.DoesNotContain(events, item =>
            item.Kind == AgentEventKind.Error &&
            (item.Text?.Contains("maximum number", StringComparison.OrdinalIgnoreCase) ?? false));
    }

    [Fact]
    public async Task NativeAgentRunnerContinuesAfterFallbackJsonToolCallLikeMac()
    {
        using var temp = new TempWorkspace();
        await File.WriteAllTextAsync(Path.Combine(temp.Root, "README.md"), "fallback file");
        var provider = new FallbackJsonToolProvider();
        var runner = new NativeAgentRunner(providerClient: provider);
        var request = new AgentRequest(
            "session-1",
            temp.Root,
            "read via fallback",
            [],
            new ProviderConfig(SessionProvider.G9Claw, ProviderApiType.OpenAIChat, "http://provider.local/v1", "test-model", "secret", []),
            "test-key",
            [],
            120000,
            160000,
            ComposerPermissionMode.Default,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            "default",
            []);

        var events = new List<AgentEvent>();
        await foreach (var agentEvent in runner.RunAsync(request))
        {
            events.Add(agentEvent);
        }

        Assert.Equal(2, provider.RequestCount);
        Assert.Contains(events, item => item.Kind == AgentEventKind.ToolUse && item.ToolCall?.Name == "Read");
        Assert.Contains(events, item =>
            item.Kind == AgentEventKind.ToolResult &&
            item.ToolResult?.ToolName == "Read" &&
            item.ToolResult.Output.Contains("fallback file", StringComparison.Ordinal));
        Assert.Contains(events, item => item.Kind == AgentEventKind.ContentDelta && item.Text == "done after fallback");
        Assert.Single(provider.SeenToolExchangeCounts, count => count == 1);
    }

    [Fact]
    public async Task NativeAgentRunnerRecoversPartialStreamLikeMac()
    {
        using var temp = new TempWorkspace();
        var provider = new PartialStreamRecoveryProvider();
        var runner = new NativeAgentRunner(providerClient: provider);
        var request = new AgentRequest(
            "session-1",
            temp.Root,
            "continue after partial stream",
            [],
            new ProviderConfig(SessionProvider.G9Claw, ProviderApiType.OpenAIChat, "http://provider.local/v1", "test-model", "secret", []),
            "test-key",
            [],
            120000,
            160000,
            ComposerPermissionMode.Default,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            "default",
            []);

        var events = new List<AgentEvent>();
        await foreach (var agentEvent in runner.RunAsync(request))
        {
            events.Add(agentEvent);
        }

        Assert.Equal(2, provider.RequestCount);
        Assert.Contains(events, item => item.Kind == AgentEventKind.ContentDelta && item.Text == "partial ");
        Assert.Contains(events, item => item.Kind == AgentEventKind.ContentDelta && item.Text == "recovered");
        Assert.Contains(events, item => item.Kind == AgentEventKind.Status && item.Text == "partial_stream_timeout_recovery");
        Assert.Contains(events, item => item.Kind == AgentEventKind.Status && item.Text == "waiting for model response");
        Assert.Contains(provider.RecoveryPrompts, prompt => prompt.Contains("Continue the same task from the latest completed tool result", StringComparison.Ordinal));
        Assert.DoesNotContain(events, item => item.Kind == AgentEventKind.Error);
    }

    [Fact]
    public async Task NativeAgentRunnerPassesProviderContextToTaskSubagentsLikeMac()
    {
        using var temp = new TempWorkspace();
        var providerConfig = new ProviderConfig(
            SessionProvider.G9Claw,
            ProviderApiType.OpenAIChat,
            "http://provider.local/v1",
            "test-model",
            "secret",
            []);
        var subagent = new RecordingSubagentRunner(requiresProviderConfig: true);
        var toolExecutor = new AgentToolExecutor(
            runStore: new NativeRunStore(Path.Combine(temp.Root, "run-history")),
            subagentRunner: subagent);
        var runner = new NativeAgentRunner(
            providerClient: new SingleTaskProvider(),
            toolExecutor: toolExecutor);
        var request = new AgentRequest(
            "session-1",
            temp.Root,
            "delegate work",
            [],
            providerConfig,
            "test-key",
            [],
            120000,
            160000,
            ComposerPermissionMode.BypassPermissions,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            "default",
            new Dictionary<string, string> { ["runtime.maxSubagentDepth"] = "2" });

        var events = new List<AgentEvent>();
        await foreach (var agentEvent in runner.RunAsync(request))
        {
            events.Add(agentEvent);
        }

        var subagentRequest = Assert.Single(subagent.Requests);
        Assert.Equal(providerConfig, subagentRequest.Context.ProviderConfig);
        Assert.Equal("test-key", subagentRequest.Context.ApiKey);
        Assert.Equal(1, subagentRequest.Context.SubagentDepth);
        Assert.Contains(events, item =>
            item.Kind == AgentEventKind.ToolResult &&
            item.ToolResult?.ToolName == "Task" &&
            item.ToolResult.Output.Contains("subagent result for Explore services", StringComparison.Ordinal));
        Assert.Contains(events, item => item.Kind == AgentEventKind.ContentDelta && item.Text == "done");
    }

    [Fact]
    public async Task NativeAgentRunnerCachesRepeatedRootGlobDiscoveryLikeMac()
    {
        using var temp = new TempWorkspace();
        Directory.CreateDirectory(Path.Combine(temp.Root, "src"));
        for (var index = 0; index < 170; index++)
        {
            await File.WriteAllTextAsync(Path.Combine(temp.Root, "src", $"file-{index:000}.txt"), $"file {index}");
        }

        var provider = new RepeatedRootGlobProvider(temp.Root);
        var runner = new NativeAgentRunner(providerClient: provider);
        var request = new AgentRequest(
            "session-1",
            temp.Root,
            "discover files twice",
            [],
            new ProviderConfig(SessionProvider.G9Claw, ProviderApiType.OpenAIChat, "http://provider.local/v1", "test-model", "secret", []),
            "test-key",
            [],
            120000,
            160000,
            ComposerPermissionMode.Default,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            "default",
            []);

        var events = new List<AgentEvent>();
        await foreach (var agentEvent in runner.RunAsync(request))
        {
            events.Add(agentEvent);
        }

        var globResults = events
            .Where(item => item.Kind == AgentEventKind.ToolResult && item.ToolResult?.ToolName == "Glob")
            .Select(item => item.ToolResult!)
            .ToList();

        Assert.Equal(3, provider.RequestCount);
        Assert.Equal(2, globResults.Count);
        Assert.DoesNotContain("Cached workspace discovery", globResults[0].Output);
        Assert.Contains("src/file-000.txt", globResults[0].Output);
        Assert.Contains("workspace discovery truncated for display; 170 total entries", globResults[0].Output);
        Assert.Contains("Cached workspace discovery from earlier Glob **/* (170 entries)", globResults[1].Output);
        Assert.Contains("src/file-000.txt", globResults[1].Output);
        Assert.False(File.Exists(Path.Combine(temp.Root, "src", "file-000.txt")));
    }

    [Fact]
    public async Task NativeAgentRunnerRequiresTodoWriteAfterPlanApprovalLikeMac()
    {
        using var temp = new TempWorkspace();
        var provider = new PlanTodoGateProvider();
        var runner = new NativeAgentRunner(providerClient: provider);
        var request = new AgentRequest(
            "session-1",
            temp.Root,
            "approve and execute plan",
            [],
            new ProviderConfig(SessionProvider.G9Claw, ProviderApiType.OpenAIChat, "http://provider.local/v1", "test-model", "secret", []),
            "test-key",
            [],
            120000,
            160000,
            ComposerPermissionMode.Default,
            ChatRunMode.Plan,
            ToolPermissionSettings.Defaults,
            "default",
            []);
        var options = new NativeAgentRunOptions((permission, _) => Task.FromResult(new PermissionRecord(
            permission,
            PermissionDecision.Allowed,
            permission.Scope,
            DateTimeOffset.UtcNow,
            permission.Kind == PermissionRequestKind.AskUserQuestion ? "approved" : null)));

        var events = new List<AgentEvent>();
        await foreach (var agentEvent in runner.RunAsync(request, options))
        {
            events.Add(agentEvent);
        }

        var results = events
            .Where(item => item.Kind == AgentEventKind.ToolResult)
            .Select(item => item.ToolResult!)
            .ToList();

        Assert.Equal(7, provider.RequestCount);
        Assert.Equal(["AskQuestion", "SwitchMode", "Write", "TodoWrite", "Write", "StrReplace"], results.Select(result => result.ToolName));
        Assert.Equal("approved", results[0].Output);
        Assert.False(results[2].IsError);
        Assert.True(results[2].IsPolicyBlock);
        Assert.Contains("Initialize the execution todo list with TodoWrite", results[2].Output);
        Assert.False(results[4].IsError);
        Assert.False(results[4].IsPolicyBlock);
        Assert.True(results[5].IsPolicyBlock);
        Assert.Contains("Update the todo list with TodoWrite", results[5].Output);
        Assert.Equal("created", await File.ReadAllTextAsync(Path.Combine(temp.Root, "plan.txt")));
    }

    [Fact]
    public async Task NativeAgentRunnerEnforcesPlanModeSafetyLikeMac()
    {
        using var temp = new TempWorkspace();
        var provider = new PlanModeSafetyProvider();
        var permissionRequests = new List<PermissionRequest>();
        var runner = new NativeAgentRunner(providerClient: provider);
        var request = new AgentRequest(
            "session-1",
            temp.Root,
            "plan before mutating",
            [],
            new ProviderConfig(SessionProvider.G9Claw, ProviderApiType.OpenAIChat, "http://provider.local/v1", "test-model", "secret", []),
            "test-key",
            [],
            120000,
            160000,
            ComposerPermissionMode.BypassPermissions,
            ChatRunMode.Plan,
            ToolPermissionSettings.Defaults,
            "default",
            []);
        var options = new NativeAgentRunOptions((permission, _) =>
        {
            permissionRequests.Add(permission);
            return Task.FromResult(new PermissionRecord(
                permission,
                PermissionDecision.Allowed,
                permission.Scope,
                DateTimeOffset.UtcNow,
                permission.Kind == PermissionRequestKind.AskUserQuestion ? "approved" : null));
        });

        var events = new List<AgentEvent>();
        await foreach (var agentEvent in runner.RunAsync(request, options))
        {
            events.Add(agentEvent);
        }

        var results = events
            .Where(item => item.Kind == AgentEventKind.ToolResult)
            .Select(item => item.ToolResult!)
            .ToList();

        Assert.Equal(6, provider.RequestCount);
        Assert.Equal(["Write", "Shell", "SwitchMode", "AskQuestion", "SwitchMode"], results.Select(result => result.ToolName));
        Assert.True(results[0].IsPolicyBlock);
        Assert.Contains("Plan mode skipped this workspace-changing Write tool", results[0].Output);
        Assert.False(results[1].IsError);
        Assert.False(results[1].IsPolicyBlock);
        Assert.True(results[2].IsPolicyBlock);
        Assert.Contains("Plan mode requires AskQuestion before leaving Plan mode", results[2].Output);
        Assert.Equal("approved", results[3].Output);
        Assert.False(results[4].IsError);
        Assert.False(results[4].IsPolicyBlock);
        Assert.Equal([PermissionRequestKind.AskUserQuestion, PermissionRequestKind.ExitPlanMode], permissionRequests.Select(permission => permission.Kind));
        Assert.Equal("Plan approval is required before leaving Plan mode.", permissionRequests[1].Reason);
        Assert.False(File.Exists(Path.Combine(temp.Root, "blocked.txt")));
    }

    [Fact]
    public async Task NativeAgentRunnerUsesDestructivePlanApprovalLikeMac()
    {
        using var temp = new TempWorkspace();
        var target = Path.Combine(temp.Root, "danger.txt");
        await File.WriteAllTextAsync(target, "delete me");
        var provider = new DestructiveDeleteProvider();
        var permissionRequests = new List<PermissionRequest>();
        var runner = new NativeAgentRunner(providerClient: provider);
        var request = new AgentRequest(
            "session-1",
            temp.Root,
            "delete danger file",
            [],
            new ProviderConfig(SessionProvider.G9Claw, ProviderApiType.OpenAIChat, "http://provider.local/v1", "test-model", "secret", []),
            "test-key",
            [],
            120000,
            160000,
            ComposerPermissionMode.BypassPermissions,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            "default",
            []);
        var options = new NativeAgentRunOptions((permission, _) =>
        {
            permissionRequests.Add(permission);
            return Task.FromResult(new PermissionRecord(
                permission,
                PermissionDecision.Allowed,
                permission.Scope,
                DateTimeOffset.UtcNow,
                null));
        });

        var events = new List<AgentEvent>();
        await foreach (var agentEvent in runner.RunAsync(request, options))
        {
            events.Add(agentEvent);
        }

        var result = Assert.Single(events.Where(item => item.Kind == AgentEventKind.ToolResult).Select(item => item.ToolResult!));
        var permission = Assert.Single(permissionRequests);

        Assert.Equal("Delete", result.ToolName);
        Assert.False(result.IsError);
        Assert.Equal(PermissionRequestKind.DestructivePlanApproval, permission.Kind);
        Assert.Equal("Destructive action plan approval is required before deleting workspace files.", permission.Reason);
        Assert.Contains("\"destructiveTool\": \"Delete\"", permission.InputJson);
        Assert.Contains("\"target\": \"danger.txt\"", permission.InputJson);
        Assert.False(File.Exists(target));
    }

    [Fact]
    public async Task NativeAgentRunnerMarksDeletionVerificationErrorsBenignLikeMac()
    {
        using var temp = new TempWorkspace();
        var target = Path.Combine(temp.Root, "gone.txt");
        await File.WriteAllTextAsync(target, "delete me");
        var provider = new DeleteThenReadMissingProvider();
        var runner = new NativeAgentRunner(providerClient: provider);
        var request = new AgentRequest(
            "session-1",
            temp.Root,
            "delete and verify missing file",
            [],
            new ProviderConfig(SessionProvider.G9Claw, ProviderApiType.OpenAIChat, "http://provider.local/v1", "test-model", "secret", []),
            "test-key",
            [],
            120000,
            160000,
            ComposerPermissionMode.BypassPermissions,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            "default",
            []);
        var options = new NativeAgentRunOptions((permission, _) => Task.FromResult(new PermissionRecord(
            permission,
            PermissionDecision.Allowed,
            permission.Scope,
            DateTimeOffset.UtcNow,
            null)));

        var events = new List<AgentEvent>();
        await foreach (var agentEvent in runner.RunAsync(request, options))
        {
            events.Add(agentEvent);
        }

        var results = events
            .Where(item => item.Kind == AgentEventKind.ToolResult)
            .Select(item => item.ToolResult!)
            .ToList();
        var readResult = Assert.Single(results, result => result.ToolName == "Read");
        var completedTurn = events.Last(item => item.Kind == AgentEventKind.TurnCompleted).Turn!;
        var readTurnItems = completedTurn.Items
            .Where(item => item.ToolInvocation?.CallId == "read-missing")
            .ToList();

        Assert.Equal(2, results.Count);
        Assert.True(readResult.IsError);
        Assert.True(readResult.IsBenignVerification);
        Assert.Equal(2, readTurnItems.Count);
        Assert.All(readTurnItems, item => Assert.Equal(AgentTurnItemStatus.Completed, item.Status));
        Assert.All(readTurnItems, item => Assert.False(item.ToolInvocation!.IsError));
    }

    [Fact]
    public async Task NativeAgentRunnerDeduplicatesToolsWithMutationEpochLikeMac()
    {
        using var temp = new TempWorkspace();
        var provider = new DuplicateToolProvider();
        var runner = new NativeAgentRunner(providerClient: provider);
        var request = new AgentRequest(
            "session-1",
            temp.Root,
            "exercise duplicate tool calls",
            [],
            new ProviderConfig(SessionProvider.G9Claw, ProviderApiType.OpenAIChat, "http://provider.local/v1", "test-model", "secret", []),
            "test-key",
            [],
            120000,
            160000,
            ComposerPermissionMode.Default,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            "default",
            []);
        var options = new NativeAgentRunOptions((permission, _) => Task.FromResult(new PermissionRecord(
            permission,
            PermissionDecision.Allowed,
            permission.Scope,
            DateTimeOffset.UtcNow,
            null)));

        var events = new List<AgentEvent>();
        await foreach (var agentEvent in runner.RunAsync(request, options))
        {
            events.Add(agentEvent);
        }

        var results = events
            .Where(item => item.Kind == AgentEventKind.ToolResult)
            .Select(item => item.ToolResult!)
            .ToList();

        Assert.Equal(7, provider.RequestCount);
        Assert.Equal(["Write", "Write", "Read", "StrReplace", "Read"], results.Select(result => result.ToolName));
        Assert.False(results[0].IsPolicyBlock);
        Assert.True(results[1].IsPolicyBlock);
        Assert.Contains("Duplicate tool request skipped", results[1].Output);
        Assert.DoesNotContain(results, result => result.CallId == "read-duplicate");
        Assert.Contains("first", results[2].Output);
        Assert.Contains("changed", results[4].Output);
        Assert.Equal("changed", await File.ReadAllTextAsync(Path.Combine(temp.Root, "dupe.txt")));
    }

    [Fact]
    public void AgentToolDeduplicationPolicyBlocksUnchangedTodoWriteLikeMac()
    {
        var policy = new AgentToolDeduplicationPolicy();
        var first = new AgentToolCall("todo-1", "TodoWrite", """{"todos":[{"content":"ship","status":"pending"}]}""");
        var duplicate = new AgentToolCall("todo-2", "TodoWrite", """{"todos":[{"status":"pending","content":"ship"}]}""");

        Assert.Null(policy.Deduplicate(first));
        policy.Record(first, new AgentToolResult(first.Id, "TodoWrite", "Saved 1 todo item(s).", false));
        var duplicateDecision = policy.Deduplicate(duplicate);

        Assert.NotNull(duplicateDecision);
        Assert.False(duplicateDecision!.Skip);
        Assert.True(duplicateDecision.Result?.IsPolicyBlock);
        Assert.Contains("Todo list is already up to date", duplicateDecision.Result?.Output);
    }

    [Fact]
    public void ContextBudgetPresenterComputesLevelAndCompactionState()
    {
        var unknown = ContextBudgetPresenter.FromBudget(null);
        var attention = ContextBudgetPresenter.FromBudget(new TokenBudget(76, 100));
        var compacting = ContextBudgetPresenter.FromBudget(new TokenBudget(50, 100), "compact stage 2", 2);

        Assert.Null(unknown.Percent);
        Assert.Equal(ContextBudgetLevel.Attention, attention.Level);
        Assert.Equal(76, attention.Percent);
        Assert.Equal(ContextBudgetLevel.Compacting, compacting.Level);
        Assert.Equal("compact stage 2", compacting.CompactStage);
        Assert.Equal(2, compacting.CompactCount);
    }

    [Fact]
    public void NativeI18nResolvesLanguageAndFallsBack()
    {
        Assert.Equal("zh-CN", NativeI18nLanguageResolver.Resolve(AppLanguage.Auto, new System.Globalization.CultureInfo("zh-CN")));
        Assert.Equal("en", NativeI18nLanguageResolver.Resolve(AppLanguage.Auto, new System.Globalization.CultureInfo("fr-FR")));
        Assert.Equal("设置", new StringCatalog(AppLanguage.ChineseSimplified).T("settings.title"));
        Assert.Equal("settings.missing", new StringCatalog(AppLanguage.ChineseSimplified).T("settings.missing"));
    }

    [Fact]
    public void NativeI18nRequiredKeysExistInEnglishAndChinese()
    {
        foreach (var key in StringCatalog.RequiredKeys)
        {
            Assert.True(StringCatalog.HasKey("en", key), $"Missing en key {key}");
            Assert.True(StringCatalog.HasKey("zh-CN", key), $"Missing zh-CN key {key}");
        }
    }

    [Fact]
    public void HeaderLayoutMetricsReservesCaptionButtons()
    {
        var metrics = new HeaderLayoutMetrics(1200, 138);
        var narrow = new HeaderLayoutMetrics(640, 138);
        var veryNarrow = new HeaderLayoutMetrics(260, 138);

        Assert.Equal(150, metrics.EffectiveRightPadding);
        Assert.Equal(80, HeaderLayoutMetrics.CaptionInsetToDips(140, 1.75));
        Assert.True(metrics.TabMaxWidth <= 1200 * 0.72);
        Assert.True(narrow.TabMaxWidth >= 220);
        Assert.True(narrow.TabMaxWidth < metrics.TabMaxWidth);
        Assert.True(veryNarrow.TabMaxWidth <= 260 - veryNarrow.EffectiveRightPadding);
    }

    [Fact]
    public void SettingsOverlayMetricsUseLogicalWindowSize()
    {
        var desktop = new SettingsOverlayMetrics(1440, 900);
        var minimum = new SettingsOverlayMetrics(980, 640);
        var tiny = new SettingsOverlayMetrics(320, 200);

        Assert.Equal(896, desktop.Width);
        Assert.Equal(810, desktop.Height);
        Assert.Equal(896, minimum.Width);
        Assert.Equal(576, minimum.Height);
        Assert.True(tiny.Width <= 320);
        Assert.True(tiny.Height <= 200);
    }

    [Fact]
    public void V2LayoutMetricsUseWebV2LogicalWindowDefaults()
    {
        Assert.Equal(1280, V2LayoutMetrics.DefaultWindowWidth);
        Assert.Equal(840, V2LayoutMetrics.DefaultWindowHeight);
        Assert.Equal(980, V2LayoutMetrics.MinimumWindowWidth);
        Assert.Equal(640, V2LayoutMetrics.MinimumWindowHeight);
    }

    [Fact]
    public void ComposerKeyPolicyHandlesSendNewlineModeToggleAndIme()
    {
        Assert.Equal(ComposerKeyAction.Send, ComposerKeyPolicy.Decide(ComposerKey.Enter, shiftDown: false, controlDown: false, isImeComposing: false, sendByCtrlEnter: false));
        Assert.Equal(ComposerKeyAction.InsertNewLine, ComposerKeyPolicy.Decide(ComposerKey.Enter, shiftDown: true, controlDown: false, isImeComposing: false, sendByCtrlEnter: false));
        Assert.Equal(ComposerKeyAction.ToggleRunMode, ComposerKeyPolicy.Decide(ComposerKey.Tab, shiftDown: true, controlDown: false, isImeComposing: false, sendByCtrlEnter: false));
        Assert.Equal(ComposerKeyAction.None, ComposerKeyPolicy.Decide(ComposerKey.Enter, shiftDown: false, controlDown: false, isImeComposing: true, sendByCtrlEnter: false));
        Assert.Equal(ComposerKeyAction.None, ComposerKeyPolicy.Decide(ComposerKey.Enter, shiftDown: false, controlDown: false, isImeComposing: false, sendByCtrlEnter: true));
        Assert.Equal(ComposerKeyAction.Send, ComposerKeyPolicy.Decide(ComposerKey.Enter, shiftDown: false, controlDown: true, isImeComposing: false, sendByCtrlEnter: true));
    }

    [Fact]
    public void ChatScrollPresenterSticksOnlyWhenUserIsNearBottom()
    {
        var bottom = ChatScrollPresenter.Capture(verticalOffset: 950, extentHeight: 1500, viewportHeight: 520, bottomThreshold: 48);
        var history = ChatScrollPresenter.Capture(verticalOffset: 400, extentHeight: 1500, viewportHeight: 520, bottomThreshold: 48);

        Assert.True(bottom.StickToBottom);
        Assert.Equal(1180, ChatScrollPresenter.TargetOffset(bottom, extentHeight: 1700, viewportHeight: 520));
        Assert.Equal(980, ChatScrollPresenter.TargetOffset(bottom, extentHeight: 1700, viewportHeight: 520, autoScrollToBottom: false));
        Assert.False(history.StickToBottom);
        Assert.Equal(400, ChatScrollPresenter.TargetOffset(history, extentHeight: 1700, viewportHeight: 520));
    }

    [Fact]
    public void ToolInvocationPresenterBuildsInlineProcessSummaries()
    {
        var runningShell = ToolInvocationPresenter.Present(
            new AgentToolCall("call-1", "Shell", """{"command":"dir"}"""),
            null,
            chinese: true);
        var completedRead = ToolInvocationPresenter.Present(
            new AgentToolCall("call-2", "Read", """{"file_path":"README.md"}"""),
            new AgentToolResult("call-2", "Read", "content", false),
            chinese: false);
        var failedSearch = ToolInvocationPresenter.Present(
            new AgentToolCall("call-3", "Grep", """{"pattern":"TODO"}"""),
            new AgentToolResult("call-3", "Grep", "boom", true),
            chinese: false);

        Assert.Equal(ToolInvocationPhase.Command, runningShell.Phase);
        Assert.Equal(ToolInvocationState.Running, runningShell.State);
        Assert.Equal("\u6b63\u5728\u8fd0\u884c: dir", runningShell.Summary);
        Assert.Equal("Read: README.md", completedRead.Summary);
        Assert.Equal("Search failed: TODO", failedSearch.Summary);
    }

    [Fact]
    public void ToolInvocationPresenterAggregatesAdjacentToolsAndKeepsBoundaries()
    {
        var group = ToolInvocationPresenter.PresentGroup(
            [
                (new AgentToolCall("read", "Read", """{"file_path":"a.txt"}"""), new AgentToolResult("read", "Read", "a", false)),
                (new AgentToolCall("grep", "Grep", """{"pattern":"TODO"}"""), new AgentToolResult("grep", "Grep", "b", false)),
            ],
            chinese: false);

        Assert.Equal("read 1 files, searched 1 times", group.Summary);
        Assert.True(ToolInvocationPresenter.IsBoundary("Task"));
        Assert.True(ToolInvocationPresenter.IsBoundary("AskQuestion"));
        Assert.False(ToolInvocationPresenter.IsBoundary("Read"));
    }

    [Fact]
    public void MarkdownPresentationParsesCommonAssistantMarkdown()
    {
        var blocks = MarkdownPresentation.Parse("""
            **Folders:**

            - Desktop
            - Downloads

            ```text
            hello
            ```

            | A | B |
            | - | - |
            | 1 | 2 |
            """);

        Assert.Contains(blocks, block =>
            block.Kind == MarkdownBlockKind.Paragraph &&
            block.Inlines.Any(inline => inline.Kind == MarkdownInlineKind.Strong && inline.Text.Contains("Folders")));
        Assert.Contains(blocks, block =>
            block.Kind == MarkdownBlockKind.List &&
            block.ListItems is { Count: 2 });
        Assert.Contains(blocks, block =>
            block.Kind == MarkdownBlockKind.CodeBlock &&
            block.Code?.Contains("hello", StringComparison.OrdinalIgnoreCase) == true);
        Assert.Contains(blocks, block =>
            block.Kind == MarkdownBlockKind.Table &&
            block.Table?.Rows.Count == 2);
    }

    [Fact]
    public void LucideIconCatalogCoversRequiredWebV2Icons()
    {
        var required = new[]
        {
            "Bot", "Folder", "Sparkles", "BarChart3", "Database", "Radio",
            "PanelLeftClose", "PanelLeftOpen", "Settings", "MessageSquarePlus",
            "Palette", "Shield", "Hand", "FileCog", "LayoutList", "Code", "Save",
            "Paperclip", "Copy",
        };

        foreach (var key in required)
        {
            Assert.True(LucideIconCatalog.HasIcon(key), $"Missing icon {key}");
        }

        Assert.False(LucideIconCatalog.HasIcon("DefinitelyMissing"));
    }

    [Fact]
    public void NativeConfigYamlCodecReadsWebV2ConfigShape()
    {
        const string yaml = """
version: 1
runtime:
  host: 0.0.0.0
  serverPort: 3001
  vitePort: 5173
  proxyPort: 18080
  contextWindow: 160000
  apiTimeoutMs: 120000
  httpsProxy: ""
  databasePath: C:\Users\tester\.cloudcli\auth.db
  workspacesRoot: C:\Users\tester
models:
  providers:
    g9claw:
      type: openai-chat
      baseUrl: http://127.0.0.1:52010/v1
      apiKey: sk-test-provider
      transformer: null
      headers: {}
    g9claw_memory:
      type: openai-chat
      baseUrl: http://127.0.0.1:52010/v1
      apiKey: sk-test-memory
      transformer: null
      headers: {}
  entries:
    default:
      provider: g9claw
      name: qwen3.6-27b
      contextWindow: 250000
    memory:
      provider: g9claw_memory
      name: qwen3.6-27b
      contextWindow: 250000
agents:
  main:
    model: default
    params: {}
  subagents:
    default: inherit
    params: {}
alwaysOn:
  discovery:
    trigger:
      enabled: false
      tickIntervalMinutes: 5
      cooldownMinutes: 60
      dailyBudget: 4
      heartbeatStaleSeconds: 90
      recentUserMsgMinutes: 5
      preferClient: webui
    projects: {}
memory:
  enabled: true
  model: memory
  params: {}
  reasoningMode: answer_first
  autoIndexIntervalMinutes: 1
  autoDreamIntervalMinutes: 2
  captureStrategy: last_turn
  includeAssistant: true
  maxMessageChars: 6000
  heartbeatBatchSize: 30
rag:
  enabled: true
  disableBuiltInWebTools: true
  localKnowledge:
    baseUrl: http://127.0.0.1:52010/v1
    apiKey: ""
    modelName: qwen3-embedding-0.6b
    databaseUrl: http://127.0.0.1:52008/search
    defaultTopK: 10
  glmWebSearch:
    baseUrl: https://api.example.com/web_search
    apiKey: sk-test-search
    defaultTopK: 10
router:
  enabled: true
  log: false
  host: 127.0.0.1
  port: 19080
  routes:
    default:
      model: default
      params: {}
  tokenSaver:
    tiers:
      SIMPLE:
        model: memory
        description: Cheap route
  tokenStats:
    savingsBaselineModel: g9claw,qwen3.6-27b
gateway:
  enabled: false
  home: C:\Users\tester\.g9claw\gateway
  channels:
    telegram:
      enabled: false
      token: gateway-token
""";

        var parsed = NativeConfigYamlCodec.ApplyYaml(AppSettings.Defaults(@"C:\Users\tester"), yaml);

        Assert.Equal(2, parsed.Settings.Providers!.Count);
        Assert.Equal("qwen3.6-27b", parsed.Settings.ProviderConfig.Model);
        Assert.Equal(160000, parsed.Settings.ContextWindow);
        Assert.Contains(parsed.Settings.ModelEntries!, entry => entry.Id == "default" && entry.ContextWindow == 250000);
        Assert.Equal(120000, parsed.Settings.ApiTimeoutMs);
        Assert.Equal("memory", parsed.Settings.MemorySettings!.ModelEntryId);
        Assert.True(parsed.Settings.MemorySettings.IncludeAssistant);
        Assert.True(parsed.Settings.RagSettings!.Enabled);
        Assert.Equal(10, parsed.Settings.RagSettings.LocalKnowledgeDefaultTopK);
        Assert.True(parsed.Settings.RouterSettings.Enabled);
        Assert.Equal("127.0.0.1", parsed.Settings.RouterSettings.Host);
        Assert.Equal(19080, parsed.Settings.RouterSettings.Port);
        Assert.Equal("inherit", parsed.Settings.AgentSettings!.SubagentDefaultModelEntryId);
        Assert.Equal("memory", parsed.Settings.RouterSettings.TierModelEntries["SIMPLE"]);
        Assert.Contains("sk-test-provider", parsed.Secrets.Values);
        Assert.Contains("sk-test-search", parsed.Secrets.Values);
        var exported = NativeConfigYamlCodec.ToYaml(parsed.Settings);
        Assert.DoesNotContain("sk-test-provider", exported);
        Assert.DoesNotContain("sk-test-provider", parsed.Settings.RawConfigDocument!.LastYaml);
        Assert.Contains("********", parsed.Settings.RawConfigDocument.LastYaml);
        Assert.Contains("tokenStats:", parsed.Settings.RawConfigDocument.LastYaml);
        Assert.Contains("tokenSaver:", exported);
        Assert.Contains("telegram:", exported);
        Assert.Contains("tokenStats", exported);
        Assert.DoesNotContain("gateway-token", parsed.Settings.RawConfigDocument.LastYaml);
    }

    [Fact]
    public async Task AgentToolExecutorSearchToolsMatchMacFallbackShape()
    {
        using var temp = new TempWorkspace();
        Directory.CreateDirectory(Path.Combine(temp.Root, "src"));
        Directory.CreateDirectory(Path.Combine(temp.Root, "obj"));
        await File.WriteAllTextAsync(Path.Combine(temp.Root, "src", "a.txt"), "TODO first\nkeep\nTODO second\n");
        await File.WriteAllTextAsync(Path.Combine(temp.Root, "src", "b.txt"), "notes\nTODO third\n");
        await File.WriteAllTextAsync(Path.Combine(temp.Root, "src", "context.txt"), "alpha\nbefore\nHIT focus\nafter\nomega\n");
        await File.WriteAllTextAsync(Path.Combine(temp.Root, "obj", "skip.txt"), "TODO skipped\n");
        var executor = new AgentToolExecutor(preferRipgrep: false);
        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None);

        var grepCount = await executor.ExecuteAsync(new AgentToolCall("grep-count", "Grep", JsonSerializer.Serialize(new
        {
            pattern = "TODO",
            path = ".",
            output_mode = "count",
        })), context);
        var grepContent = await executor.ExecuteAsync(new AgentToolCall("grep-content", "Grep", JsonSerializer.Serialize(new
        {
            pattern = "TODO",
            path = ".",
            output_mode = "content",
            offset = 1,
            head_limit = 1,
        })), context);
        var grepContext = await executor.ExecuteAsync(new AgentToolCall("grep-context", "Grep", JsonSerializer.Serialize(new
        {
            pattern = "HIT",
            path = ".",
            glob = "src/context.txt",
            output_mode = "content",
            context = 1,
            head_limit = 0,
        })), context);
        var grepBeforeAfter = await executor.ExecuteAsync(new AgentToolCall("grep-before-after", "Grep", JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["pattern"] = "HIT",
            ["path"] = ".",
            ["glob"] = "src/context.txt",
            ["output_mode"] = "content",
            ["-B"] = 2,
            ["-A"] = 0,
            ["head_limit"] = 0,
        })), context);
        var glob = await executor.ExecuteAsync(new AgentToolCall("glob", "Glob", JsonSerializer.Serialize(new
        {
            pattern = "**/*.txt",
            path = ".",
        })), context);
        var semantic = await executor.ExecuteAsync(new AgentToolCall("semantic", "SemanticSearch", JsonSerializer.Serialize(new
        {
            query = "TODO third",
            path = ".",
            limit = 1,
        })), context);
        var emptySemantic = await executor.ExecuteAsync(new AgentToolCall("semantic-empty", "SemanticSearch", JsonSerializer.Serialize(new
        {
            query = "x",
        })), context);

        Assert.False(grepCount.IsError);
        Assert.Equal(["src/a.txt:2", "src/b.txt:1"], OutputLines(grepCount.Output));
        Assert.False(grepContent.IsError);
        Assert.Equal("src/a.txt:3:TODO second", grepContent.Output);
        Assert.False(grepContext.IsError);
        Assert.Equal(["src/context.txt:2:before", "src/context.txt:3:HIT focus", "src/context.txt:4:after"], OutputLines(grepContext.Output));
        Assert.False(grepBeforeAfter.IsError);
        Assert.Equal(["src/context.txt:1:alpha", "src/context.txt:2:before", "src/context.txt:3:HIT focus"], OutputLines(grepBeforeAfter.Output));
        Assert.False(glob.IsError);
        Assert.Equal(["src/a.txt", "src/b.txt", "src/context.txt"], OutputLines(glob.Output));
        Assert.False(semantic.IsError);
        using var semanticJson = JsonDocument.Parse(semantic.Output);
        var firstSemanticHit = semanticJson.RootElement.GetProperty("results")[0];
        Assert.Equal("TODO third", semanticJson.RootElement.GetProperty("query").GetString());
        Assert.Equal("src/b.txt", firstSemanticHit.GetProperty("path").GetString());
        Assert.Equal(2, firstSemanticHit.GetProperty("line").GetInt32());
        Assert.Equal(2, firstSemanticHit.GetProperty("score").GetInt32());
        Assert.Equal("TODO third", firstSemanticHit.GetProperty("snippet").GetString());
        Assert.True(emptySemantic.IsError);
        Assert.Contains("SemanticSearch query did not contain searchable terms.", emptySemantic.Output);
    }

    private static string[] OutputLines(string output) =>
        output.Replace("\r\n", "\n").Split('\n', StringSplitOptions.RemoveEmptyEntries);

    private static byte[] MinimalPdf(string text)
    {
        var escaped = text.Replace(@"\", @"\\").Replace("(", @"\(").Replace(")", @"\)");
        var stream = $"BT /F1 18 Tf 72 720 Td ({escaped}) Tj ET";
        var objects = new[]
        {
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n",
            "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
            $"5 0 obj\n<< /Length {Encoding.ASCII.GetByteCount(stream)} >>\nstream\n{stream}\nendstream\nendobj\n",
        };
        var builder = new StringBuilder("%PDF-1.4\n");
        var offsets = new List<int> { 0 };
        foreach (var obj in objects)
        {
            offsets.Add(Encoding.ASCII.GetByteCount(builder.ToString()));
            builder.Append(obj);
        }

        var xrefOffset = Encoding.ASCII.GetByteCount(builder.ToString());
        builder.Append("xref\n0 6\n0000000000 65535 f \n");
        foreach (var offset in offsets.Skip(1))
        {
            builder.Append($"{offset:D10} 00000 n \n");
        }

        builder.Append($"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xrefOffset}\n%%EOF\n");
        return Encoding.ASCII.GetBytes(builder.ToString());
    }

    [Fact]
    public async Task AgentToolExecutorPersistsTodosAndSharesTaskAwaitState()
    {
        using var temp = new TempWorkspace();
        var runStore = new NativeRunStore(Path.Combine(temp.Root, "run-history"));
        var executor = new AgentToolExecutor(runStore: runStore);
        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None);

        var emptyTodoRead = await executor.ExecuteAsync(new AgentToolCall("todo-read-empty", "TodoRead", "{}"), context);
        var todoResult = await executor.ExecuteAsync(new AgentToolCall("todo", "TodoWrite", """
        {"todos":[{"content":"Wire Git UI","status":"in_progress","priority":1,"note":"mac-shape"},{"content":"Add Shell page","status":"pending","priority":2}]}
        """), context);
        var todoRead = await executor.ExecuteAsync(new AgentToolCall("todo-read", "TodoRead", "{}"), context);
        var taskResult = await executor.ExecuteAsync(new AgentToolCall("task", "Task", """
        {"type":"explore","prompt":"Inspect services","description":"Explore services","run_in_background":false}
        """), context);
        var awaitResult = await executor.ExecuteAsync(new AgentToolCall("await", "Await", JsonSerializer.Serialize(new { task_id = taskResult.TaskId })), context);

        Assert.False(emptyTodoRead.IsError);
        Assert.Equal("[]", emptyTodoRead.Output);
        Assert.False(todoResult.IsError);
        Assert.Equal("Todos have been modified successfully. Ensure that you continue to use the todo list to track your progress. Please proceed with the current tasks if applicable.", todoResult.Output);
        Assert.Equal(2, runStore.LoadTodos("session-1").Count);
        Assert.False(todoRead.IsError);
        using (var todosDoc = JsonDocument.Parse(todoRead.Output))
        {
            Assert.Equal(2, todosDoc.RootElement.GetArrayLength());
            Assert.Equal("mac-shape", todosDoc.RootElement[0].GetProperty("note").GetString());
        }
        Assert.False(taskResult.IsError);
        Assert.StartsWith("task-", taskResult.TaskId);
        Assert.False(awaitResult.IsError);
        Assert.Contains("Explore services", awaitResult.Output);
    }

    [Fact]
    public async Task AgentToolExecutorBackgroundTaskReturnsAwaitableJsonLikeMac()
    {
        using var temp = new TempWorkspace();
        var runStore = new NativeRunStore(Path.Combine(temp.Root, "run-history"));
        var executor = new AgentToolExecutor(runStore: runStore);
        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None);

        var started = await executor.ExecuteAsync(new AgentToolCall("background-task", "Task", """
        {"type":"explore","prompt":"Inspect services","description":"Explore services","run_in_background":true}
        """), context);
        var awaited = await executor.ExecuteAsync(new AgentToolCall("background-task-await", "Await", JsonSerializer.Serialize(new
        {
            task_id = started.TaskId,
            timeout = 5_000,
        })), context);

        Assert.False(started.IsError);
        using (var startedJson = JsonDocument.Parse(started.Output))
        {
            Assert.Equal(started.TaskId, startedJson.RootElement.GetProperty("task_id").GetString());
            Assert.Equal("running", startedJson.RootElement.GetProperty("status").GetString());
            Assert.Equal("Explore services", startedJson.RootElement.GetProperty("description").GetString());
        }

        Assert.False(awaited.IsError);
        using var awaitedJson = JsonDocument.Parse(awaited.Output);
        Assert.Equal(started.TaskId, awaitedJson.RootElement.GetProperty("task_id").GetString());
        Assert.Equal("completed", awaitedJson.RootElement.GetProperty("status").GetString());
        Assert.Equal(0, awaitedJson.RootElement.GetProperty("exitCode").GetInt32());
        Assert.Contains("Recorded explore task: Explore services", awaitedJson.RootElement.GetProperty("output").GetString());
    }

    [Fact]
    public async Task AgentToolExecutorTaskWorktreeIsolationMatchesMacRuntime()
    {
        using var temp = new TempWorkspace();
        InitializeGitRepository(temp.Root);
        var executor = new AgentToolExecutor(runStore: new NativeRunStore(Path.Combine(temp.Root, "run-history")));
        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None);

        var isolated = await executor.ExecuteAsync(new AgentToolCall("task-worktree", "Task", """
        {"type":"explore","prompt":"Inspect services","description":"Explore services","isolation":"worktree"}
        """), context);
        var bestOfN = await executor.ExecuteAsync(new AgentToolCall("task-best-of-n", "Task", """
        {"type":"best-of-n-runner","prompt":"Inspect services","n":2}
        """), context);

        Assert.False(isolated.IsError);
        using (var isolatedJson = JsonDocument.Parse(isolated.Output))
        {
            var root = isolatedJson.RootElement;
            var worktree = root.GetProperty("worktree").GetString();
            Assert.Equal("explore", root.GetProperty("type").GetString());
            Assert.Contains("g9claw-worktrees", worktree);
            Assert.False(Directory.Exists(worktree));
            Assert.Contains("Recorded explore task: Explore services", root.GetProperty("result").GetString());
        }

        Assert.False(bestOfN.IsError);
        using var bestJson = JsonDocument.Parse(bestOfN.Output);
        var attempts = bestJson.RootElement.GetProperty("attempts");
        Assert.Equal("best-of-n-runner", bestJson.RootElement.GetProperty("type").GetString());
        Assert.Equal(2, attempts.GetArrayLength());
        Assert.Equal(1, bestJson.RootElement.GetProperty("selectedAttempt").GetInt32());
        Assert.Equal(1, attempts[0].GetProperty("attempt").GetInt32());
        Assert.Contains("Attempt 1 of 2", attempts[0].GetProperty("result").GetString());
    }

    [Fact]
    public async Task AgentToolExecutorTaskRunsConfiguredSubagentLikeMacRuntime()
    {
        using var temp = new TempWorkspace();
        var subagent = new RecordingSubagentRunner(requiresProviderConfig: true);
        var executor = new AgentToolExecutor(subagentRunner: subagent);
        var providerConfig = new ProviderConfig(
            SessionProvider.G9Claw,
            ProviderApiType.OpenAIChat,
            "http://provider.local/v1",
            "test-model",
            "secret",
            []);
        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None,
            new Dictionary<string, string> { ["runtime.maxSubagentDepth"] = "2" },
            ProviderConfig: providerConfig,
            ApiKey: "test-key",
            TimeoutMs: 12_345,
            ContextWindow: 77_000,
            PermissionMode: ComposerPermissionMode.BypassPermissions);

        var result = await executor.ExecuteAsync(new AgentToolCall("task-subagent", "Task", """
        {"type":"explore","prompt":"Inspect services","description":"Explore services"}
        """), context);

        Assert.False(result.IsError);
        var request = Assert.Single(subagent.Requests);
        Assert.Equal(temp.Root, request.WorkspaceRoot);
        Assert.Equal("Inspect services", request.Prompt);
        Assert.Equal("Explore services", request.Description);
        Assert.Equal("Task type: explore", request.ExtraContext);
        Assert.Equal(1, request.Context.SubagentDepth);
        Assert.Equal(providerConfig, request.Context.ProviderConfig);
        Assert.Equal("test-key", request.Context.ApiKey);
        Assert.Equal(12_345, request.Context.TimeoutMs);
        Assert.Equal(77_000, request.Context.ContextWindow);
        Assert.Equal(ComposerPermissionMode.BypassPermissions, request.Context.PermissionMode);
        using var outputJson = JsonDocument.Parse(result.Output);
        Assert.Equal("Explore services", outputJson.RootElement.GetProperty("description").GetString());
        Assert.Equal("Inspect services", outputJson.RootElement.GetProperty("prompt").GetString());
        Assert.Contains("Task type: explore", outputJson.RootElement.GetProperty("result").GetString());
    }

    [Fact]
    public async Task AgentToolExecutorTaskWorktreeSubagentsUseIsolatedWorkspaceLikeMacRuntime()
    {
        using var temp = new TempWorkspace();
        InitializeGitRepository(temp.Root);
        var subagent = new RecordingSubagentRunner();
        var executor = new AgentToolExecutor(
            runStore: new NativeRunStore(Path.Combine(temp.Root, "run-history")),
            subagentRunner: subagent);
        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None);

        var isolated = await executor.ExecuteAsync(new AgentToolCall("task-worktree-subagent", "Task", """
        {"type":"explore","prompt":"Inspect services","description":"Explore services","isolation":"worktree"}
        """), context);
        var bestOfN = await executor.ExecuteAsync(new AgentToolCall("task-best-of-n-subagent", "Task", """
        {"type":"best-of-n-runner","prompt":"Inspect services","n":2}
        """), context);

        Assert.False(isolated.IsError);
        Assert.False(bestOfN.IsError);
        Assert.Equal(3, subagent.Requests.Count);
        var isolatedRequest = subagent.Requests[0];
        Assert.Contains("g9claw-worktrees", isolatedRequest.WorkspaceRoot);
        Assert.Equal(isolatedRequest.WorkspaceRoot, isolatedRequest.Context.WorkspaceRoot);
        Assert.Contains($"Task isolation: git worktree at {isolatedRequest.WorkspaceRoot}", isolatedRequest.ExtraContext);
        Assert.False(Directory.Exists(isolatedRequest.WorkspaceRoot));
        using (var isolatedJson = JsonDocument.Parse(isolated.Output))
        {
            Assert.Equal(isolatedRequest.WorkspaceRoot, isolatedJson.RootElement.GetProperty("worktree").GetString());
            Assert.Contains("subagent result for Explore services", isolatedJson.RootElement.GetProperty("result").GetString());
        }

        using var bestJson = JsonDocument.Parse(bestOfN.Output);
        var attempts = bestJson.RootElement.GetProperty("attempts");
        Assert.Equal(2, attempts.GetArrayLength());
        Assert.Contains("Attempt 1 of 2", subagent.Requests[1].Prompt);
        Assert.Contains("Attempt 2 of 2", subagent.Requests[2].Prompt);
        Assert.Equal("best-of-n 1", subagent.Requests[1].Description);
        Assert.Equal("best-of-n 2", subagent.Requests[2].Description);
        Assert.Contains("g9claw-worktrees", attempts[0].GetProperty("worktree").GetString());
        Assert.Contains("subagent result for best-of-n 1", attempts[0].GetProperty("result").GetString());
    }

    [Fact]
    public async Task AgentToolExecutorTaskValidationMatchesMacRuntime()
    {
        using var temp = new TempWorkspace();
        await File.WriteAllTextAsync(Path.Combine(temp.Root, "not-a-directory.txt"), "file");
        var executor = new AgentToolExecutor();
        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None);

        var missingCwd = await executor.ExecuteAsync(new AgentToolCall("task-missing-cwd", "Task", """
        {"type":"explore","prompt":"Inspect","cwd":"missing"}
        """), context);
        var fileCwd = await executor.ExecuteAsync(new AgentToolCall("task-file-cwd", "Task", """
        {"type":"explore","prompt":"Inspect","cwd":"not-a-directory.txt"}
        """), context);
        var unsupported = await executor.ExecuteAsync(new AgentToolCall("task-unsupported", "Task", """
        {"type":"unsupported","prompt":"Inspect"}
        """), context);
        var generalPurpose = await executor.ExecuteAsync(new AgentToolCall("task-general", "Task", """
        {"type":"general-purpose","prompt":"Inspect"}
        """), context);

        Assert.True(missingCwd.IsError);
        Assert.Contains("Task cwd must be an existing directory: missing", missingCwd.Output);
        Assert.True(fileCwd.IsError);
        Assert.Contains("Task cwd must be an existing directory: not-a-directory.txt", fileCwd.Output);
        Assert.True(unsupported.IsError);
        Assert.Equal("Unsupported Task type: unsupported", unsupported.Output);
        Assert.False(generalPurpose.IsError);
        Assert.Contains("Recorded general-purpose task", generalPurpose.Output);
    }

    [Fact]
    public async Task AgentToolExecutorTaskSubagentDepthMatchesMacRuntime()
    {
        using var temp = new TempWorkspace();
        var executor = new AgentToolExecutor();
        var disabledByConfig = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None,
            new Dictionary<string, string>
            {
                ["runtime.maxSubagentDepth"] = "0",
            });
        var nestedAtLimit = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None,
            SubagentDepth: 1,
            MaxSubagentDepth: 1);
        var nestedAllowed = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None,
            SubagentDepth: 1,
            MaxSubagentDepth: 2);

        var disabled = await executor.ExecuteAsync(new AgentToolCall("task-disabled", "Task", """
        {"type":"generalPurpose","prompt":"Inspect"}
        """), disabledByConfig);
        var exceeded = await executor.ExecuteAsync(new AgentToolCall("task-exceeded", "Task", """
        {"type":"generalPurpose","prompt":"Inspect"}
        """), nestedAtLimit);
        var allowed = await executor.ExecuteAsync(new AgentToolCall("task-allowed", "Task", """
        {"type":"generalPurpose","prompt":"Inspect"}
        """), nestedAllowed);

        Assert.True(disabled.IsError);
        Assert.Equal("subagent_depth_exceeded (depth=0, max=0); nested Task is not allowed.", disabled.Output);
        Assert.True(exceeded.IsError);
        Assert.Equal("subagent_depth_exceeded (depth=1, max=1); nested Task is not allowed.", exceeded.Output);
        Assert.False(allowed.IsError);
        Assert.Equal(0, AgentToolExecutor.MaxSubagentDepth(new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None,
            MaxSubagentDepth: -1)));
    }

    [Fact]
    public async Task AgentSkillToolReadsProjectSkillContent()
    {
        using var temp = new TempWorkspace();
        var service = new SkillService(Path.Combine(temp.Root, "user-skills"));
        service.Create(SkillScope.Project, temp.Root, "demo-skill", "Demo Skill", "Use this for demos.");
        var executor = new AgentToolExecutor();
        var context = new AgentToolExecutionContext(
            "session-1",
            temp.Root,
            ChatRunMode.Agent,
            ToolPermissionSettings.Defaults,
            CancellationToken.None);

        var result = await executor.ExecuteAsync(new AgentToolCall("skill", "Skill", """{"skill":"demo-skill","args":"summarize"}"""), context);

        Assert.False(result.IsError);
        Assert.Contains("Demo Skill", result.Output);
        Assert.Contains("summarize", result.Output);
        Assert.EndsWith("SKILL.md", result.ArtifactPath);
    }

    private static WorkspaceProject Project(string name, string displayName, DateTimeOffset date) => new(
        Guid.NewGuid(),
        name,
        displayName,
        $@"C:\Users\tester\{name}",
        [],
        [],
        [],
        [],
        date,
        date);

    private static ProjectSession Session(
        string id,
        SessionProvider provider,
        DateTimeOffset date,
        SessionState state = SessionState.Idle) => new(
        id,
        provider,
        id,
        "",
        date,
        null,
        date,
        date,
        state);

    private sealed class CapturingProviderHandler(string responseBody) : HttpMessageHandler
    {
        public HttpRequestMessage? Request { get; private set; }
        public string? Body { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Request = request;
            Body = request.Content is null
                ? ""
                : await request.Content.ReadAsStringAsync(cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(responseBody, Encoding.UTF8, "application/json"),
            };
        }
    }

    private sealed class RecordingSubagentRunner(bool requiresProviderConfig = false) : INativeSubagentRunner
    {
        public bool RequiresProviderConfig { get; } = requiresProviderConfig;
        public List<NativeSubagentRequest> Requests { get; } = [];

        public Task<string> RunAsync(NativeSubagentRequest request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Requests.Add(request);
            return Task.FromResult(JsonSerializer.Serialize(new
            {
                description = request.Description,
                prompt = request.Prompt,
                result = $"subagent result for {request.Description}\n{request.ExtraContext}",
            }, new JsonSerializerOptions { WriteIndented = true }));
        }
    }

    private sealed class SingleTaskProvider : IProviderClient
    {
        public async IAsyncEnumerable<ProviderStreamEvent> StreamAsync(
            AgentRequest request,
            [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            await Task.CompletedTask;
            cancellationToken.ThrowIfCancellationRequested();
            if (request.ToolExchanges.Count == 0)
            {
                yield return new ProviderStreamEvent(
                    ProviderStreamEventKind.ToolCall,
                    ToolCall: new AgentToolCall("task", "Task", """
                    {"type":"explore","prompt":"Inspect services","description":"Explore services"}
                    """));
            }
            else
            {
                yield return new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: "done");
                yield return new ProviderStreamEvent(ProviderStreamEventKind.Done);
            }
        }
    }

    private sealed class FallbackJsonToolProvider : IProviderClient
    {
        public int RequestCount { get; private set; }
        public List<int> SeenToolExchangeCounts { get; } = [];

        public async IAsyncEnumerable<ProviderStreamEvent> StreamAsync(
            AgentRequest request,
            [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            RequestCount++;
            SeenToolExchangeCounts.Add(request.ToolExchanges.Count);
            await Task.CompletedTask;
            cancellationToken.ThrowIfCancellationRequested();
            if (request.ToolExchanges.Count == 0)
            {
                yield return new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: """
                ```json
                {"tool":"Read","input":{"file_path":"README.md"}}
                ```
                """);
                yield return new ProviderStreamEvent(ProviderStreamEventKind.Done);
            }
            else
            {
                yield return new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: "done after fallback");
                yield return new ProviderStreamEvent(ProviderStreamEventKind.Done);
            }
        }
    }

    private sealed class PartialStreamRecoveryProvider : IProviderClient
    {
        public int RequestCount { get; private set; }
        public List<string> RecoveryPrompts { get; } = [];

        public async IAsyncEnumerable<ProviderStreamEvent> StreamAsync(
            AgentRequest request,
            [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            RequestCount++;
            await Task.CompletedTask;
            cancellationToken.ThrowIfCancellationRequested();
            if (RequestCount == 1)
            {
                yield return new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: "partial ");
                throw ProviderClientException.StreamInterruptedAfterPartialOutput("lost connection");
            }

            RecoveryPrompts.AddRange(request.PriorMessages.Select(message => message.PlainText));
            yield return new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: "recovered");
            yield return new ProviderStreamEvent(ProviderStreamEventKind.Done);
        }
    }

    private sealed class MultiRoundToolProvider(int rounds) : IProviderClient
    {
        public int RequestCount { get; private set; }

        public async IAsyncEnumerable<ProviderStreamEvent> StreamAsync(
            AgentRequest request,
            [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            RequestCount++;
            await Task.Yield();
            cancellationToken.ThrowIfCancellationRequested();
            if (request.ToolExchanges.Count < rounds)
            {
                yield return new ProviderStreamEvent(
                    ProviderStreamEventKind.ToolCall,
                    ToolCall: new AgentToolCall(
                        $"call-{request.ToolExchanges.Count + 1}",
                        "ReadLints",
                        JsonSerializer.Serialize(new { path = $"round-{request.ToolExchanges.Count + 1}.cs" })));
            }
            else
            {
                yield return new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: "done");
                yield return new ProviderStreamEvent(ProviderStreamEventKind.Done);
            }
        }
    }

    private sealed class RepeatedRootGlobProvider(string workspaceRoot) : IProviderClient
    {
        public int RequestCount { get; private set; }

        public async IAsyncEnumerable<ProviderStreamEvent> StreamAsync(
            AgentRequest request,
            [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            RequestCount++;
            await Task.CompletedTask;
            if (request.ToolExchanges.Count == 0)
            {
                yield return RootGlob("glob-1");
            }
            else if (request.ToolExchanges.Count == 1)
            {
                File.Delete(Path.Combine(workspaceRoot, "src", "file-000.txt"));
                yield return RootGlob("glob-2");
            }
            else
            {
                yield return new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: "done");
                yield return new ProviderStreamEvent(ProviderStreamEventKind.Done);
            }
        }

        private static ProviderStreamEvent RootGlob(string id) =>
            new(
                ProviderStreamEventKind.ToolCall,
                ToolCall: new AgentToolCall(id, "Glob", """{"pattern":"**/*","path":"."}"""));
    }

    private sealed class PlanTodoGateProvider : IProviderClient
    {
        public int RequestCount { get; private set; }

        public async IAsyncEnumerable<ProviderStreamEvent> StreamAsync(
            AgentRequest request,
            [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            RequestCount++;
            await Task.CompletedTask;
            yield return request.ToolExchanges.Count switch
            {
                0 => Tool("question", "AskQuestion", """{"question":"Approve this plan?","options":["Yes"]}"""),
                1 => Tool("switch", "SwitchMode", """{"mode":"agent","plan":"Approved plan"}"""),
                2 => Tool("blocked-write", "Write", """{"file_path":"plan.txt","content":"blocked"}"""),
                3 => Tool("todo", "TodoWrite", """{"todos":[{"content":"write plan file","status":"in_progress","priority":1}]}"""),
                4 => Tool("write", "Write", """{"file_path":"plan.txt","content":"created"}"""),
                5 => Tool("blocked-edit", "StrReplace", """{"file_path":"plan.txt","old_string":"created","new_string":"changed"}"""),
                _ => new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: "done"),
            };
            if (request.ToolExchanges.Count > 5)
            {
                yield return new ProviderStreamEvent(ProviderStreamEventKind.Done);
            }
        }

        private static ProviderStreamEvent Tool(string id, string name, string inputJson) =>
            new(ProviderStreamEventKind.ToolCall, ToolCall: new AgentToolCall(id, name, inputJson));
    }

    private sealed class PlanModeSafetyProvider : IProviderClient
    {
        public int RequestCount { get; private set; }

        public async IAsyncEnumerable<ProviderStreamEvent> StreamAsync(
            AgentRequest request,
            [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            RequestCount++;
            await Task.CompletedTask;
            yield return RequestCount switch
            {
                1 => Tool("blocked-write", "Write", """{"file_path":"blocked.txt","content":"blocked"}"""),
                2 => Tool("read-only-shell", "Shell", """{"command":"pwd"}"""),
                3 => Tool("blocked-switch", "SwitchMode", """{"mode":"agent","plan":"Need approval"}"""),
                4 => Tool("question", "AskQuestion", """{"question":"Approve this plan?","options":["Yes"]}"""),
                5 => Tool("switch", "SwitchMode", """{"mode":"agent","plan":"Approved plan"}"""),
                _ => new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: "done"),
            };
            if (RequestCount > 5)
            {
                yield return new ProviderStreamEvent(ProviderStreamEventKind.Done);
            }
        }

        private static ProviderStreamEvent Tool(string id, string name, string inputJson) =>
            new(ProviderStreamEventKind.ToolCall, ToolCall: new AgentToolCall(id, name, inputJson));
    }

    private sealed class DestructiveDeleteProvider : IProviderClient
    {
        public async IAsyncEnumerable<ProviderStreamEvent> StreamAsync(
            AgentRequest request,
            [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            await Task.CompletedTask;
            if (request.ToolExchanges.Count == 0)
            {
                yield return new ProviderStreamEvent(
                    ProviderStreamEventKind.ToolCall,
                    ToolCall: new AgentToolCall("delete", "Delete", """{"path":"danger.txt"}"""));
            }
            else
            {
                yield return new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: "done");
                yield return new ProviderStreamEvent(ProviderStreamEventKind.Done);
            }
        }
    }

    private sealed class DeleteThenReadMissingProvider : IProviderClient
    {
        public async IAsyncEnumerable<ProviderStreamEvent> StreamAsync(
            AgentRequest request,
            [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            await Task.CompletedTask;
            yield return request.ToolExchanges.Count switch
            {
                0 => Tool("delete", "Delete", """{"path":"gone.txt"}"""),
                1 => Tool("read-missing", "Read", """{"file_path":"gone.txt"}"""),
                _ => new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: "done"),
            };
            if (request.ToolExchanges.Count > 1)
            {
                yield return new ProviderStreamEvent(ProviderStreamEventKind.Done);
            }
        }

        private static ProviderStreamEvent Tool(string id, string name, string inputJson) =>
            new(ProviderStreamEventKind.ToolCall, ToolCall: new AgentToolCall(id, name, inputJson));
    }

    private sealed class DuplicateToolProvider : IProviderClient
    {
        public int RequestCount { get; private set; }

        public async IAsyncEnumerable<ProviderStreamEvent> StreamAsync(
            AgentRequest request,
            [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            RequestCount++;
            await Task.CompletedTask;
            yield return RequestCount switch
            {
                1 => Tool("write-1", "Write", """{"file_path":"dupe.txt","content":"first"}"""),
                2 => Tool("write-duplicate", "Write", """{"file_path":"dupe.txt","content":"first"}"""),
                3 => Tool("read-1", "Read", """{"file_path":"dupe.txt"}"""),
                4 => Tool("read-duplicate", "Read", """{"file_path":"dupe.txt"}"""),
                5 => Tool("replace", "StrReplace", """{"file_path":"dupe.txt","old_string":"first","new_string":"changed"}"""),
                6 => Tool("read-after-mutation", "Read", """{"file_path":"dupe.txt"}"""),
                _ => new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: "done"),
            };
            if (RequestCount > 6)
            {
                yield return new ProviderStreamEvent(ProviderStreamEventKind.Done);
            }
        }

        private static ProviderStreamEvent Tool(string id, string name, string inputJson) =>
            new(ProviderStreamEventKind.ToolCall, ToolCall: new AgentToolCall(id, name, inputJson));
    }

    private static int ShellTimeout(string inputJson)
    {
        using var doc = JsonDocument.Parse(inputJson);
        return AgentToolExecutor.ShellTimeoutMilliseconds(doc.RootElement);
    }

    private static int AwaitTimeout(string inputJson)
    {
        using var doc = JsonDocument.Parse(inputJson);
        return AgentToolExecutor.AwaitTimeoutMilliseconds(doc.RootElement);
    }

    private static void InitializeGitRepository(string cwd)
    {
        File.WriteAllText(Path.Combine(cwd, "README.md"), "demo");
        RunGit(cwd, "init");
        RunGit(cwd, "config", "user.email", "tests@example.com");
        RunGit(cwd, "config", "user.name", "G9Claw Tests");
        RunGit(cwd, "add", "README.md");
        RunGit(cwd, "commit", "-m", "initial");
    }

    private static void RunGit(string cwd, params string[] arguments)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "git",
            WorkingDirectory = cwd,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments)
        {
            psi.ArgumentList.Add(argument);
        }

        using var process = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start git.");
        var stdout = process.StandardOutput.ReadToEnd();
        var stderr = process.StandardError.ReadToEnd();
        if (!process.WaitForExit(30_000))
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch
            {
            }

            throw new TimeoutException($"git {string.Join(' ', arguments)} timed out.");
        }

        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException(string.IsNullOrWhiteSpace(stderr) ? stdout : stderr);
        }
    }

    private sealed class TempWorkspace : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), $"g9claw-win-tests-{Guid.NewGuid():D}");

        public TempWorkspace()
        {
            Directory.CreateDirectory(Root);
        }

        public void Dispose()
        {
            if (Directory.Exists(Root))
            {
                foreach (var path in Directory.EnumerateFileSystemEntries(Root, "*", SearchOption.AllDirectories))
                {
                    File.SetAttributes(path, FileAttributes.Normal);
                }

                Directory.Delete(Root, recursive: true);
            }
        }
    }
}
