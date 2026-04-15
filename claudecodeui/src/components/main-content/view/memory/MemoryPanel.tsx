import type { Project } from '../../../../types/app';

type MemoryPanelProps = {
  selectedProject: Project | null;
};

function buildMemoryDashboardUrl(project: Project): string | null {
  const token = localStorage.getItem('auth-token');
  const projectPath = project.fullPath || project.path;

  if (!token || !projectPath) {
    return null;
  }

  const params = new URLSearchParams({
    token,
    projectPath,
  });

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
