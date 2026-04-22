import React, { useCallback, useEffect } from 'react';
import ChatInterface from '../../chat/view/ChatInterface';
import AlwaysOnPanel from '../../always-on/view/AlwaysOnPanel';
import FileTree from '../../file-tree/view/FileTree';
import StandaloneShell from '../../standalone-shell/view/StandaloneShell';
import GitPanel from '../../git-panel/view/GitPanel';
import PluginTabContent from '../../plugins/view/PluginTabContent';
import {
  getStoredClaudePermissionMode,
  startClaudeSessionCommand,
} from '../../chat/utils/claudeSessionLauncher';
import type { MainContentProps } from '../types/types';
import { useTaskMaster } from '../../../contexts/TaskMasterContext';
import { useTasksSettings } from '../../../contexts/TasksSettingsContext';
import { useUiPreferences } from '../../../hooks/useUiPreferences';
import { useEditorSidebar } from '../../code-editor/hooks/useEditorSidebar';
import EditorSidebar from '../../code-editor/view/EditorSidebar';
import type { Project } from '../../../types/app';
import { TaskMasterPanel } from '../../task-master';
import MainContentHeader from './subcomponents/MainContentHeader';
import MainContentStateView from './subcomponents/MainContentStateView';
import ErrorBoundary from './ErrorBoundary';

type TaskMasterContextValue = {
  currentProject?: Project | null;
  setCurrentProject?: ((project: Project) => void) | null;
};

type TasksSettingsContextValue = {
  tasksEnabled: boolean;
  isTaskMasterInstalled: boolean | null;
  isTaskMasterReady: boolean | null;
};

function getClaudeProjectStorePath(project: Project): string {
  const projectPath = project.fullPath || project.path || '';
  const unixHomeMatch = projectPath.match(/^(\/Users\/[^/]+|\/home\/[^/]+)/);
  if (unixHomeMatch?.[1]) {
    return `${unixHomeMatch[1]}/.claude/projects/${project.name}`;
  }

  const windowsHomeMatch = projectPath.match(/^([A-Za-z]:\\Users\\[^\\]+)/);
  if (windowsHomeMatch?.[1]) {
    return `${windowsHomeMatch[1]}\\.claude\\projects\\${project.name}`;
  }

  return `~/.claude/projects/${project.name}`;
}

function buildAlwaysOnDiscoveryPrompt(project: Project): string {
  const workspacePath = project.fullPath || project.path || project.name;
  const claudeProjectStorePath = getClaudeProjectStorePath(project);
  const displayName = project.displayName || project.name;

  return [
    `Always-On task discovery for project "${displayName}".`,
    '',
    'Please proactively inspect this project and decide whether there are meaningful follow-up tasks worth proposing.',
    '',
    'Requirements:',
    `1. Inspect the current workspace at \`${workspacePath}\`.`,
    `2. Inspect the 5 most recently modified files under \`${claudeProjectStorePath}\` and use them as additional context for discovery.`,
    '3. Judge whether there are valuable follow-up tasks. If there are none, explain why and stop.',
    '4. If there are worthwhile tasks, create at most 3 cron jobs using CronCreate.',
    '5. Every cron job you create must use `durable: true` and `manualOnly: true` so it appears in Always-On but never runs automatically.',
    '6. Do not execute any cron job or background task right now.',
    '7. In your reply, summarize what you inspected, why each proposed task is valuable, and which cron IDs were created.',
  ].join('\n');
}

function MainContent({
  selectedProject,
  selectedSession,
  activeTab,
  setActiveTab,
  ws,
  sendMessage,
  latestMessage,
  isMobile,
  onMenuClick,
  isLoading,
  onInputFocusChange,
  onSessionActive,
  onSessionInactive,
  onSessionProcessing,
  onSessionNotProcessing,
  processingSessions,
  onReplaceTemporarySession,
  onNavigateToSession,
  onStartNewSession,
  onShowSettings,
  externalMessageUpdate,
}: MainContentProps) {
  const { preferences } = useUiPreferences();
  const { autoExpandTools, showRawParameters, showThinking, autoScrollToBottom, sendByCtrlEnter } = preferences;

  const { currentProject, setCurrentProject } = useTaskMaster() as TaskMasterContextValue;
  const { tasksEnabled, isTaskMasterInstalled } = useTasksSettings() as TasksSettingsContextValue;

  const shouldShowTasksTab = Boolean(tasksEnabled && isTaskMasterInstalled);

  const {
    editingFile,
    editorWidth,
    editorExpanded,
    hasManualWidth,
    resizeHandleRef,
    handleFileOpen,
    handleCloseEditor,
    handleToggleEditorExpand,
    handleResizeStart,
  } = useEditorSidebar({
    selectedProject,
    isMobile,
  });

  useEffect(() => {
    const selectedProjectName = selectedProject?.name;
    const currentProjectName = currentProject?.name;

    if (selectedProject && selectedProjectName !== currentProjectName) {
      setCurrentProject?.(selectedProject);
    }
  }, [selectedProject, currentProject?.name, setCurrentProject]);

  useEffect(() => {
    if (!shouldShowTasksTab && activeTab === 'tasks') {
      setActiveTab('chat');
    }
  }, [shouldShowTasksTab, activeTab, setActiveTab]);

  const handleStartDiscoverySession = useCallback(async () => {
    if (!selectedProject) {
      return;
    }

    onStartNewSession(selectedProject);

    const discoveryPrompt = buildAlwaysOnDiscoveryPrompt(selectedProject);
    const pendingSessionId = startClaudeSessionCommand({
      sendMessage,
      selectedProject,
      command: discoveryPrompt,
      permissionMode: getStoredClaudePermissionMode(selectedSession),
      sessionSummary: `Always-On discovery: ${selectedProject.displayName || selectedProject.name}`,
    });

    onSessionActive?.(pendingSessionId);
  }, [
    onSessionActive,
    onStartNewSession,
    selectedProject,
    selectedSession,
    sendMessage,
  ]);

  if (isLoading) {
    return <MainContentStateView mode="loading" isMobile={isMobile} onMenuClick={onMenuClick} />;
  }

  if (!selectedProject) {
    return <MainContentStateView mode="empty" isMobile={isMobile} onMenuClick={onMenuClick} />;
  }

  return (
    <div className="flex h-full flex-col">
      <MainContentHeader
        activeTab={activeTab}
        setActiveTab={setActiveTab}
        selectedProject={selectedProject}
        selectedSession={selectedSession}
        shouldShowTasksTab={shouldShowTasksTab}
        isMobile={isMobile}
        onMenuClick={onMenuClick}
      />

      <div className="flex min-h-0 flex-1 overflow-hidden">
        <div className={`flex min-h-0 min-w-[200px] flex-col overflow-hidden ${editorExpanded ? 'hidden' : ''} flex-1`}>
          <div className={`h-full ${activeTab === 'chat' ? 'block' : 'hidden'}`}>
            <ErrorBoundary showDetails>
              <ChatInterface
                selectedProject={selectedProject}
                selectedSession={selectedSession}
                ws={ws}
                sendMessage={sendMessage}
                latestMessage={latestMessage}
                onFileOpen={handleFileOpen}
                onInputFocusChange={onInputFocusChange}
                onSessionActive={onSessionActive}
                onSessionInactive={onSessionInactive}
                onSessionProcessing={onSessionProcessing}
                onSessionNotProcessing={onSessionNotProcessing}
                processingSessions={processingSessions}
                onReplaceTemporarySession={onReplaceTemporarySession}
                onNavigateToSession={onNavigateToSession}
                onShowSettings={onShowSettings}
                autoExpandTools={autoExpandTools}
                showRawParameters={showRawParameters}
                showThinking={showThinking}
                autoScrollToBottom={autoScrollToBottom}
                sendByCtrlEnter={sendByCtrlEnter}
                externalMessageUpdate={externalMessageUpdate}
                onShowAllTasks={tasksEnabled ? () => setActiveTab('tasks') : null}
              />
            </ErrorBoundary>
          </div>

          {activeTab === 'files' && (
            <div className="h-full overflow-hidden">
              <FileTree selectedProject={selectedProject} onFileOpen={handleFileOpen} />
            </div>
          )}

          {activeTab === 'always-on' && (
            <div className="h-full overflow-hidden">
              <AlwaysOnPanel
                selectedProject={selectedProject}
                onStartDiscoverySession={handleStartDiscoverySession}
              />
            </div>
          )}

          {activeTab === 'shell' && (
            <div className="h-full w-full overflow-hidden">
              <StandaloneShell
                project={selectedProject}
                session={selectedSession}
                showHeader={false}
                isActive={activeTab === 'shell'}
              />
            </div>
          )}

          {activeTab === 'git' && (
            <div className="h-full overflow-hidden">
              <GitPanel selectedProject={selectedProject} isMobile={isMobile} onFileOpen={handleFileOpen} />
            </div>
          )}

          {shouldShowTasksTab && <TaskMasterPanel isVisible={activeTab === 'tasks'} />}

          <div className={`h-full overflow-hidden ${activeTab === 'preview' ? 'block' : 'hidden'}`} />

          {activeTab.startsWith('plugin:') && (
            <div className="h-full overflow-hidden">
              <PluginTabContent
                pluginName={activeTab.replace('plugin:', '')}
                selectedProject={selectedProject}
                selectedSession={selectedSession}
              />
            </div>
          )}
        </div>

        <EditorSidebar
          editingFile={editingFile}
          isMobile={isMobile}
          editorExpanded={editorExpanded}
          editorWidth={editorWidth}
          hasManualWidth={hasManualWidth}
          resizeHandleRef={resizeHandleRef}
          onResizeStart={handleResizeStart}
          onCloseEditor={handleCloseEditor}
          onToggleEditorExpand={handleToggleEditorExpand}
          projectPath={selectedProject.path}
          fillSpace={activeTab === 'files'}
        />
      </div>
    </div>
  );
}

export default React.memo(MainContent);
