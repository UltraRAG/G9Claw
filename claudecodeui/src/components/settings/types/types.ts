import type { Dispatch, SetStateAction } from 'react';

// Settings was trimmed to two tabs (Appearance + Config). The agents/git/api/
// tasks/notifications/plugins/router/about tabs and their MCP form modals
// were removed wholesale — see git history for the prior shape if you ever
// need to recover the multi-provider surface.
export type SettingsMainTab = 'appearance' | 'config';

export type ProjectSortOrder = 'name' | 'date';
export type SaveStatus = 'success' | 'error' | null;

export type SettingsProject = {
  name: string;
  displayName?: string;
  fullPath?: string;
  path?: string;
};

export type CodeEditorSettingsState = {
  theme: 'dark' | 'light';
  wordWrap: boolean;
  showMinimap: boolean;
  lineNumbers: boolean;
  fontSize: string;
};

export type SettingsProps = {
  isOpen: boolean;
  onClose: () => void;
  projects?: SettingsProject[];
  initialTab?: string;
};

export type SetState<T> = Dispatch<SetStateAction<T>>;
