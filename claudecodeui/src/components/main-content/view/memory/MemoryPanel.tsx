import type { Project } from '../../../../types/app';
import { useTranslation } from 'react-i18next';
import { AUTH_TOKEN_STORAGE_KEY } from '../../../auth/constants';

type MemoryPanelProps = {
  selectedProject: Project | null;
};

function normalizeMemoryLocale(language: string | undefined): 'zh' | 'en' {
  return language === 'zh-CN' ? 'zh' : 'en';
}

const MEMORY_PANEL_TEXT: Record<'zh' | 'en', {
  emptyProject: string;
  unavailable: string;
  title: string;
}> = {
  zh: {
    emptyProject: '请选择一个项目查看 Memory。',
    unavailable: '身份验证和项目上下文准备完成后，Memory 面板才可用。',
    title: 'Memory 面板',
  },
  en: {
    emptyProject: 'Select a project to inspect memory.',
    unavailable: 'Memory dashboard is unavailable until auth and project context are ready.',
    title: 'Memory Dashboard',
  },
};

function buildMemoryDashboardUrl(project: Project, locale: 'zh' | 'en'): string | null {
  const token = localStorage.getItem(AUTH_TOKEN_STORAGE_KEY);
  const projectPath = project.fullPath || project.path;

  if (!projectPath) {
    return null;
  }

  const params = new URLSearchParams({ projectPath, locale });
  if (token) {
    params.set('token', token);
  }

  return `/memory-dashboard/index.html?${params.toString()}`;
}

export default function MemoryPanel({ selectedProject }: MemoryPanelProps) {
  const { i18n } = useTranslation();
  const memoryLocale = normalizeMemoryLocale(i18n.language);
  const text = MEMORY_PANEL_TEXT[memoryLocale];

  if (!selectedProject) {
    return (
      <div className="flex h-full items-center justify-center text-sm text-muted-foreground">
        {text.emptyProject}
      </div>
    );
  }

  const dashboardUrl = buildMemoryDashboardUrl(selectedProject, memoryLocale);
  if (!dashboardUrl) {
    return (
      <div className="flex h-full items-center justify-center text-sm text-muted-foreground">
        {text.unavailable}
      </div>
    );
  }

  return (
    <div className="h-full w-full bg-background">
      <iframe
        key={`${selectedProject.fullPath || selectedProject.path || 'memory'}:${memoryLocale}`}
        title={text.title}
        src={dashboardUrl}
        className="h-full w-full border-0"
      />
    </div>
  );
}
