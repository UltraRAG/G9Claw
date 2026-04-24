import { AlertCircle, CheckCircle2, FileCog, FolderOpen, RefreshCw, Save } from 'lucide-react';
import { Button } from '../../../../shared/view/ui';
import { useEdgeClawConfig } from '../../../../hooks/useEdgeClawConfig';
import SettingsCard from '../SettingsCard';
import SettingsSection from '../SettingsSection';

function StatusList({ title, items, tone }: { title: string; items: string[]; tone: 'error' | 'warning' }) {
  if (items.length === 0) return null;
  return (
    <div className={tone === 'error' ? 'text-destructive' : 'text-amber-600 dark:text-amber-400'}>
      <div className="mb-1 text-xs font-semibold">{title}</div>
      <ul className="list-disc space-y-1 pl-4 text-xs">
        {items.map((item) => <li key={item}>{item}</li>)}
      </ul>
    </div>
  );
}

function ReloadSummary({ reload }: { reload: Record<string, unknown> | null }) {
  if (!reload) return null;
  return (
    <pre className="max-h-48 overflow-auto rounded-lg bg-muted p-3 text-xs text-muted-foreground">
      {JSON.stringify(reload, null, 2)}
    </pre>
  );
}

export default function EdgeClawConfigTab() {
  const {
    path,
    raw,
    setRaw,
    exists,
    validation,
    reload,
    loading,
    saving,
    opening,
    error,
    message,
    refresh,
    save,
    reloadConfig,
    openFile,
  } = useEdgeClawConfig();

  if (loading) {
    return (
      <div className="flex items-center justify-center py-12 text-sm text-muted-foreground">
        Loading EdgeClaw config...
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <SettingsSection
        title="Unified Config"
        description="Edit ~/.edgeclaw/config.yaml. Saving validates the YAML and reloads affected services."
      >
        <SettingsCard className="space-y-4 p-4">
          <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
            <div className="min-w-0">
              <div className="flex items-center gap-2 text-sm font-medium text-foreground">
                <FileCog className="h-4 w-4" />
                {exists ? 'Config file' : 'Config preview'}
              </div>
              <code className="mt-1 block truncate rounded bg-muted px-2 py-1 text-xs text-muted-foreground">
                {path}
              </code>
            </div>
            <div className="flex flex-wrap gap-2">
              <Button variant="outline" size="sm" onClick={openFile} disabled={opening}>
                <FolderOpen className="mr-1.5 h-3.5 w-3.5" />
                {opening ? 'Opening...' : 'Reveal File'}
              </Button>
              <Button variant="outline" size="sm" onClick={() => void refresh()}>
                <RefreshCw className="mr-1.5 h-3.5 w-3.5" />
                Refresh
              </Button>
            </div>
          </div>

          {validation?.valid ? (
            <div className="flex items-center gap-2 text-xs text-green-600 dark:text-green-400">
              <CheckCircle2 className="h-3.5 w-3.5" />
              Config is valid
            </div>
          ) : (
            <div className="flex items-center gap-2 text-xs text-destructive">
              <AlertCircle className="h-3.5 w-3.5" />
              Config has validation errors
            </div>
          )}

          <StatusList title="Errors" items={validation?.errors ?? []} tone="error" />
          <StatusList title="Warnings" items={validation?.warnings ?? []} tone="warning" />

          {error && <div className="rounded-lg border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">{error}</div>}
          {message && <div className="rounded-lg border border-green-500/30 bg-green-500/10 p-3 text-sm text-green-700 dark:text-green-300">{message}</div>}
        </SettingsCard>
      </SettingsSection>

      <SettingsSection title="YAML">
        <SettingsCard className="overflow-hidden">
          <textarea
            value={raw}
            onChange={(event) => setRaw(event.target.value)}
            spellCheck={false}
            className="min-h-[520px] w-full resize-y border-0 bg-background p-4 font-mono text-xs leading-5 text-foreground outline-none"
          />
        </SettingsCard>
      </SettingsSection>

      <SettingsSection title="Reload Result">
        <SettingsCard className="p-4">
          <ReloadSummary reload={reload} />
          {!reload && <div className="text-sm text-muted-foreground">No reload result yet.</div>}
        </SettingsCard>
      </SettingsSection>

      <div className="sticky bottom-0 flex items-center justify-end gap-2 rounded-xl border border-border bg-card/90 p-3 backdrop-blur">
        <Button variant="outline" size="sm" onClick={reloadConfig} disabled={saving}>
          <RefreshCw className="mr-1.5 h-3.5 w-3.5" />
          Reload Current
        </Button>
        <Button size="sm" onClick={save} disabled={saving}>
          <Save className="mr-1.5 h-3.5 w-3.5" />
          {saving ? 'Saving...' : 'Save & Reload'}
        </Button>
      </div>
    </div>
  );
}
