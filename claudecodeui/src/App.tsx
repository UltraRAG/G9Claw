import { BrowserRouter as Router, Route, Routes } from 'react-router-dom';
import { I18nextProvider } from 'react-i18next';
import { ThemeProvider } from './contexts/ThemeContext';
import { AuthProvider, ProtectedRoute } from './components/auth';
import { TaskMasterProvider } from './contexts/TaskMasterContext';
import { TasksSettingsProvider } from './contexts/TasksSettingsContext';
import { WebSocketProvider } from './contexts/WebSocketContext';
import { PluginsProvider } from './contexts/PluginsContext';
import AppContent from './components/app/AppContent';
import AppShellV2 from './components/app-shell/AppShellV2';
import { isUiV2Enabled } from './hooks/useIsUiV2';
import i18n from './i18n/config.js';

function V2Routes() {
  // Single wildcard so URL changes don't remount the shell. Params are
  // resolved inside AppShellV2 via useMatch so navigation between
  // /, /p/:name, /p/:name/c/:id, and /session/:id preserves all state.
  return (
    <Routes>
      <Route path="*" element={<AppShellV2 />} />
    </Routes>
  );
}

function LegacyRoutes() {
  return (
    <Routes>
      <Route path="/" element={<AppContent />} />
      <Route path="/session/:sessionId" element={<AppContent />} />
    </Routes>
  );
}

export default function App() {
  const useV2 = isUiV2Enabled();

  return (
    <I18nextProvider i18n={i18n}>
      <ThemeProvider>
        <AuthProvider>
          <WebSocketProvider>
            <PluginsProvider>
              <TasksSettingsProvider>
                <TaskMasterProvider>
                  <ProtectedRoute>
                    <Router basename={window.__ROUTER_BASENAME__ || ''}>
                      {useV2 ? <V2Routes /> : <LegacyRoutes />}
                    </Router>
                  </ProtectedRoute>
                </TaskMasterProvider>
              </TasksSettingsProvider>
            </PluginsProvider>
          </WebSocketProvider>
        </AuthProvider>
      </ThemeProvider>
    </I18nextProvider>
  );
}
