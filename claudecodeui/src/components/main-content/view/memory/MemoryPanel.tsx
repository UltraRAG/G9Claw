import type { Project } from '../../../../types/app';
import { AUTH_TOKEN_STORAGE_KEY } from '../../../auth/constants';

type MemoryPanelProps = {
  selectedProject: Project | null;
};

function buildMemoryDashboardUrl(project: Project): string | null {
  const token = localStorage.getItem(AUTH_TOKEN_STORAGE_KEY);
  const projectPath = project.fullPath || project.path;

  if (!projectPath) {
    return null;
  }

  const params = new URLSearchParams({ projectPath });
  if (token) {
    params.set('token', token);
  }

  return `/memory-dashboard/index.html?${params.toString()}`;
}

export default function MemoryPanel({ selectedProject }: MemoryPanelProps) {
  if (!selectedProject) {
    return (
      <div className="flex h-full items-center justify-center text-sm text-muted-foreground">
        Select a project to inspect memory.
      </div>
    );
  }

  const dashboardUrl = buildMemoryDashboardUrl(selectedProject);
  if (!dashboardUrl) {
    return (
      <div className="flex h-full items-center justify-center text-sm text-muted-foreground">
        Memory dashboard is unavailable until auth and project context are ready.
      </div>
    );
  }

  return (
    <div className="h-full w-full bg-background">
      <iframe
        title="Memory Dashboard"
        src={dashboardUrl}
        className="h-full w-full border-0"
      />
    </div>
  );
}
