import { useCallback, useEffect, useRef } from 'react';
import { useMatch, useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import ReactDOM from 'react-dom';
import { useWebSocket } from '../../contexts/WebSocketContext';
import { useDeviceSettings } from '../../hooks/useDeviceSettings';
import { useSessionProtection } from '../../hooks/useSessionProtection';
import { useProjectsState } from '../../hooks/useProjectsState';
import Settings from '../settings/view/Settings';
import { normalizeProjectForSettings } from '../sidebar/utils/utils';
import type { SettingsProject } from '../sidebar/types/types';
import type { AppTab, Project } from '../../types/app';
import SidebarV2 from './SidebarV2';
import MainAreaV2 from './MainAreaV2';

type TypedSettingsProps = {
  isOpen: boolean;
  onClose: () => void;
  projects: SettingsProject[];
  initialTab: string;
};

const SettingsComponent = Settings as unknown as (props: TypedSettingsProps) => JSX.Element;

// V2 shell. Reuses the same data hooks as legacy AppContent so chat, discovery,
// auth, and project plumbing keep working unchanged — V2 just reorganizes the
// outer chrome (sidebar + breadcrumb header per prototype/shadcn.html).
export default function AppShellV2() {
  const navigate = useNavigate();
  // Match the four V2 URL shapes and hoist params up. A single wildcard route
  // owns this shell so state survives every URL transition.
  const matchProjectChat = useMatch('/p/:projectName/c/:sessionId');
  const matchProject = useMatch('/p/:projectName');
  const matchLegacySession = useMatch('/session/:sessionId');
  const projectNameParam =
    matchProjectChat?.params.projectName ?? matchProject?.params.projectName ?? undefined;
  const sessionId =
    matchProjectChat?.params.sessionId ?? matchLegacySession?.params.sessionId ?? undefined;
  useTranslation('common');

  const { isMobile } = useDeviceSettings({ trackPWA: false });
  const { ws, sendMessage, latestMessage, isConnected } = useWebSocket();
  const wasConnectedRef = useRef(false);

  const {
    activeSessions,
    processingSessions,
    markSessionAsActive,
    markSessionAsInactive,
    markSessionAsProcessing,
    markSessionAsNotProcessing,
    replaceTemporarySession,
  } = useSessionProtection();

  const {
    selectedProject,
    selectedSession,
    activeTab,
    sidebarOpen,
    isLoadingProjects,
    externalMessageUpdate,
    setActiveTab,
    setSidebarOpen,
    setIsInputFocused,
    setShowSettings,
    openSettings,
    refreshProjectsSilently,
    sidebarSharedProps,
    handleProjectSelect,
    handleSessionSelect,
    handleNewSession,
  } = useProjectsState({
    sessionId,
    navigate,
    latestMessage,
    isMobile,
    activeSessions,
  });

  // Sync URL projectName -> selectedProject for deep links like /p/:projectName.
  // When the URL also carries a session id (/p/.../c/:sessionId or
  // /session/:sessionId) we let useProjectsState own the resolution because
  // it sets BOTH the project and the session in one effect, avoiding a race
  // where this hook would clear the session via handleProjectSelect.
  useEffect(() => {
    if (!projectNameParam) return;
    if (sessionId) return;
    if (selectedProject?.name === projectNameParam) return;
    const target = sidebarSharedProps.projects.find((p) => p.name === projectNameParam);
    if (target) {
      handleProjectSelect(target);
      // handleProjectSelect unconditionally navigates to '/' — put the URL back.
      navigate(`/p/${encodeURIComponent(projectNameParam)}`, { replace: true });
    }
  }, [
    projectNameParam,
    sessionId,
    selectedProject?.name,
    sidebarSharedProps.projects,
    handleProjectSelect,
    navigate,
  ]);

  useEffect(() => {
    window.refreshProjects = refreshProjectsSilently;
    return () => {
      if (window.refreshProjects === refreshProjectsSilently) {
        delete window.refreshProjects;
      }
    };
  }, [refreshProjectsSilently]);

  useEffect(() => {
    window.openSettings = openSettings;
    return () => {
      if (window.openSettings === openSettings) {
        delete window.openSettings;
      }
    };
  }, [openSettings]);

  useEffect(() => {
    if (typeof navigator === 'undefined' || !('serviceWorker' in navigator)) {
      return undefined;
    }

    const handleServiceWorkerMessage = (event: MessageEvent) => {
      const message = event.data;
      if (!message || message.type !== 'notification:navigate') return;

      if (typeof message.provider === 'string' && message.provider.trim()) {
        localStorage.setItem('selected-provider', message.provider);
      }

      setActiveTab('chat');
      setSidebarOpen(false);
      void refreshProjectsSilently();

      if (typeof message.sessionId === 'string' && message.sessionId) {
        navigate(`/session/${message.sessionId}`);
        return;
      }
      navigate('/');
    };

    navigator.serviceWorker.addEventListener('message', handleServiceWorkerMessage);
    return () => {
      navigator.serviceWorker.removeEventListener('message', handleServiceWorkerMessage);
    };
  }, [navigate, refreshProjectsSilently, setActiveTab, setSidebarOpen]);

  useEffect(() => {
    const isReconnect = isConnected && !wasConnectedRef.current;
    if (isReconnect) {
      wasConnectedRef.current = true;
    } else if (!isConnected) {
      wasConnectedRef.current = false;
    }

    if (isConnected && selectedSession?.id) {
      sendMessage({
        type: 'get-pending-permissions',
        sessionId: selectedSession.id,
      });
    }
  }, [isConnected, selectedSession?.id, sendMessage]);

  const onShowSettings = useCallback(() => setShowSettings(true), [setShowSettings]);
  const onCloseSettings = useCallback(() => setShowSettings(false), [setShowSettings]);
  const onMenuClick = useCallback(() => setSidebarOpen(true), [setSidebarOpen]);

  const handleSelectProject = useCallback(
    (project: Project) => {
      handleProjectSelect(project);
      navigate(`/p/${encodeURIComponent(project.name)}`);
    },
    [handleProjectSelect, navigate],
  );

  const handleSelectSession = useCallback(
    (project: Project, sessId: string) => {
      if (project.name !== selectedProject?.name) {
        handleProjectSelect(project);
      }
      const target = [
        ...(project.sessions ?? []),
        ...(project.codexSessions ?? []),
        ...(project.cursorSessions ?? []),
        ...(project.geminiSessions ?? []),
      ].find((s) => s.id === sessId);
      if (target) {
        handleSessionSelect(target);
      } else {
        navigate(`/session/${sessId}`);
      }
      setActiveTab('chat');
    },
    [handleProjectSelect, handleSessionSelect, navigate, selectedProject?.name, setActiveTab],
  );

  const handleSelectTab = useCallback(
    (tab: AppTab) => {
      setActiveTab(tab);
    },
    [setActiveTab],
  );

  const handleStartNewSession = useCallback(
    (project: Project | null) => {
      if (project) {
        handleNewSession(project);
        navigate(`/p/${encodeURIComponent(project.name)}`);
        setActiveTab('chat');
      } else if (selectedProject) {
        handleNewSession(selectedProject);
        setActiveTab('chat');
      } else {
        // No project context yet — land on /, MainContent's empty state
        // will prompt the user to create or pick a project.
        navigate('/');
      }
    },
    [handleNewSession, navigate, selectedProject, setActiveTab],
  );

  const sidebar = (
    <SidebarV2
      projects={sidebarSharedProps.projects}
      selectedProject={selectedProject}
      selectedSession={selectedSession}
      activeTab={activeTab}
      isLoading={isLoadingProjects}
      onSelectTab={handleSelectTab}
      onSelectProject={handleSelectProject}
      onSelectSession={handleSelectSession}
      onStartNewSession={handleStartNewSession}
      onShowSettings={onShowSettings}
    />
  );

  return (
    <div className="ui-v2 fixed inset-0 flex bg-white font-sans text-neutral-900 dark:bg-neutral-950 dark:text-neutral-100">
      {!isMobile ? (
        sidebar
      ) : (
        <div
          className={`fixed inset-0 z-50 flex transition-opacity duration-150 ease-out ${
            sidebarOpen ? 'visible opacity-100' : 'invisible opacity-0'
          }`}
        >
          <button
            type="button"
            className="fixed inset-0 bg-black/40 backdrop-blur-sm"
            onClick={() => setSidebarOpen(false)}
            aria-label="Close sidebar"
          />
          <div
            className={`relative h-full w-[85vw] max-w-sm transform transition-transform duration-150 ${
              sidebarOpen ? 'translate-x-0' : '-translate-x-full'
            }`}
            onClick={(e) => e.stopPropagation()}
          >
            {sidebar}
          </div>
        </div>
      )}

      <main className="flex min-w-0 flex-1 flex-col">
        <MainAreaV2
          selectedProject={selectedProject}
          selectedSession={selectedSession}
          activeTab={activeTab}
          setActiveTab={setActiveTab}
          ws={ws}
          sendMessage={sendMessage}
          latestMessage={latestMessage}
          isMobile={isMobile}
          onMenuClick={onMenuClick}
          isLoading={isLoadingProjects}
          onInputFocusChange={setIsInputFocused}
          onSessionActive={markSessionAsActive}
          onSessionInactive={markSessionAsInactive}
          onSessionProcessing={markSessionAsProcessing}
          onSessionNotProcessing={markSessionAsNotProcessing}
          processingSessions={processingSessions}
          onReplaceTemporarySession={replaceTemporarySession}
          onNavigateToSession={(sid: string) => navigate(`/session/${sid}`)}
          onStartNewSession={handleNewSession}
          onShowSettings={onShowSettings}
          externalMessageUpdate={externalMessageUpdate}
        />
      </main>

      {sidebarSharedProps.showSettings
        ? ReactDOM.createPortal(
            <SettingsComponent
              isOpen={sidebarSharedProps.showSettings}
              onClose={onCloseSettings}
              projects={sidebarSharedProps.projects.map(normalizeProjectForSettings)}
              initialTab={sidebarSharedProps.settingsInitialTab || 'agents'}
            />,
            document.body,
          )
        : null}
    </div>
  );
}
