import { useState } from 'react';
import {
  Activity,
  Check,
  Plus,
  RotateCcw,
  Save,
  Server,
  Trash2,
  X,
  Zap,
} from 'lucide-react';
import SettingsSection from '../SettingsSection';
import SettingsCard from '../SettingsCard';
import SettingsToggle from '../SettingsToggle';
import { Button } from '../../../../shared/view/ui';
import { useRouterSettings } from '../../../../hooks/useRouterSettings';
import type { CCRConfig, CCRProvider, CCRTier } from '../../../../hooks/useRouterSettings';

const TIER_COLORS: Record<string, string> = {
  SIMPLE: 'bg-green-500/15 text-green-700 dark:text-green-400',
  MEDIUM: 'bg-blue-500/15 text-blue-700 dark:text-blue-400',
  COMPLEX: 'bg-orange-500/15 text-orange-700 dark:text-orange-400',
  REASONING: 'bg-purple-500/15 text-purple-700 dark:text-purple-400',
};

function TierBadge({ tier }: { tier: string }) {
  return (
    <span className={`inline-flex items-center rounded-md px-2 py-0.5 text-xs font-medium ${TIER_COLORS[tier] || 'bg-muted text-muted-foreground'}`}>
      {tier}
    </span>
  );
}

function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(n);
}

function formatCost(n: number): string {
  if (n < 0.01) return `$${n.toFixed(4)}`;
  return `$${n.toFixed(2)}`;
}

// ---------------------------------------------------------------------------
// Sub-components
// ---------------------------------------------------------------------------

function StatusSection({ health, summary, onResetStats }: {
  health: ReturnType<typeof useRouterSettings>['health'];
  summary: ReturnType<typeof useRouterSettings>['summary'];
  onResetStats: () => void;
}) {
  const isUp = health?.status === 'ok';

  return (
    <SettingsSection title="Router Status">
      <SettingsCard>
        <div className="flex items-center justify-between p-4">
          <div className="flex items-center gap-3">
            <div className={`h-2.5 w-2.5 rounded-full ${isUp ? 'bg-green-500' : 'bg-red-500'}`} />
            <div>
              <p className="text-sm font-medium text-foreground">
                {isUp ? 'Running' : 'Offline'}
              </p>
              <p className="text-xs text-muted-foreground">
                {health?.embedded ? `Embedded on port ${health.port}` : 'External or not started'}
              </p>
            </div>
          </div>
          {isUp && summary?.lifetime?.total && (
            <div className="flex items-center gap-4 text-xs text-muted-foreground">
              <span>{summary.lifetime.total.requestCount} requests</span>
              <span>{formatTokens(summary.lifetime.total.totalTokens)} tokens</span>
              <span>{formatCost(summary.lifetime.total.estimatedCost)}</span>
              <Button variant="ghost" size="sm" onClick={onResetStats} className="h-7 gap-1 text-xs">
                <RotateCcw className="h-3 w-3" /> Reset
              </Button>
            </div>
          )}
        </div>
        {isUp && summary?.lifetime?.byTier && (
          <div className="border-t border-border px-4 py-3">
            <div className="flex flex-wrap gap-3">
              {Object.entries(summary.lifetime.byTier).map(([tier, bucket]) => (
                <div key={tier} className="flex items-center gap-2">
                  <TierBadge tier={tier} />
                  <span className="text-xs text-muted-foreground">
                    {bucket.requestCount}req / {formatTokens(bucket.totalTokens)} / {formatCost(bucket.estimatedCost)}
                  </span>
                </div>
              ))}
            </div>
          </div>
        )}
      </SettingsCard>
    </SettingsSection>
  );
}

function ProviderRow({ provider, onChange, onDelete }: {
  provider: CCRProvider;
  onChange: (p: CCRProvider) => void;
  onDelete: () => void;
}) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div className="p-4">
      <div className="flex items-center justify-between">
        <button type="button" className="flex items-center gap-2 text-left" onClick={() => setExpanded(!expanded)}>
          <Server className="h-4 w-4 text-muted-foreground" />
          <span className="text-sm font-medium text-foreground">{provider.name}</span>
          <span className="text-xs text-muted-foreground">({provider.models.length} models)</span>
        </button>
        <div className="flex items-center gap-2">
          <Button variant="ghost" size="sm" onClick={onDelete} className="h-7 w-7 p-0 text-muted-foreground hover:text-destructive">
            <Trash2 className="h-3.5 w-3.5" />
          </Button>
        </div>
      </div>
      {expanded && (
        <div className="mt-3 space-y-3 pl-6">
          <label className="block">
            <span className="text-xs text-muted-foreground">API Base URL</span>
            <input
              type="text"
              value={provider.api_base_url}
              onChange={(e) => onChange({ ...provider, api_base_url: e.target.value })}
              className="mt-1 block w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm text-foreground"
            />
          </label>
          <label className="block">
            <span className="text-xs text-muted-foreground">API Key</span>
            <input
              type="password"
              value={provider.api_key}
              onChange={(e) => onChange({ ...provider, api_key: e.target.value })}
              placeholder="sk-..."
              className="mt-1 block w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm text-foreground"
            />
          </label>
          <label className="block">
            <span className="text-xs text-muted-foreground">Models (comma-separated)</span>
            <input
              type="text"
              value={provider.models.join(', ')}
              onChange={(e) => onChange({ ...provider, models: e.target.value.split(',').map((s) => s.trim()).filter(Boolean) })}
              className="mt-1 block w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm text-foreground"
            />
          </label>
        </div>
      )}
    </div>
  );
}

function ProvidersSection({ config, onChange }: { config: CCRConfig; onChange: (c: CCRConfig) => void }) {
  const providers = config.Providers || [];

  const updateProvider = (idx: number, p: CCRProvider) => {
    const next = [...providers];
    next[idx] = p;
    onChange({ ...config, Providers: next });
  };

  const deleteProvider = (idx: number) => {
    onChange({ ...config, Providers: providers.filter((_, i) => i !== idx) });
  };

  const addProvider = () => {
    onChange({
      ...config,
      Providers: [...providers, { name: 'new-provider', api_base_url: '', api_key: '', models: [] }],
    });
  };

  return (
    <SettingsSection title="Providers" description="Upstream LLM API providers for model routing.">
      <SettingsCard divided>
        {providers.map((p, i) => (
          <ProviderRow key={`${p.name}-${i}`} provider={p} onChange={(up) => updateProvider(i, up)} onDelete={() => deleteProvider(i)} />
        ))}
        <div className="p-3">
          <Button variant="ghost" size="sm" onClick={addProvider} className="gap-1 text-xs">
            <Plus className="h-3.5 w-3.5" /> Add Provider
          </Button>
        </div>
      </SettingsCard>
    </SettingsSection>
  );
}

function TokenSaverSection({ config, onChange }: { config: CCRConfig; onChange: (c: CCRConfig) => void }) {
  const ts = config.Router?.tokenSaver;
  if (!ts) return null;

  const updateTS = (patch: Partial<typeof ts>) => {
    onChange({ ...config, Router: { ...config.Router, tokenSaver: { ...ts, ...patch } } });
  };

  const updateTier = (tierName: string, patch: Partial<CCRTier>) => {
    const tiers = { ...ts.tiers };
    tiers[tierName] = { ...tiers[tierName], ...patch };
    updateTS({ tiers });
  };

  return (
    <SettingsSection title="TokenSaver" description="Classify request complexity and route to cost-appropriate models.">
      <SettingsCard>
        <div className="flex items-center justify-between p-4">
          <div className="flex items-center gap-2">
            <Zap className="h-4 w-4 text-muted-foreground" />
            <span className="text-sm font-medium text-foreground">Enable TokenSaver</span>
          </div>
          <SettingsToggle checked={ts.enabled} onChange={(v) => updateTS({ enabled: v })} ariaLabel="Toggle TokenSaver" />
        </div>
        {ts.enabled && (
          <div className="space-y-4 border-t border-border p-4">
            <div className="grid grid-cols-2 gap-3">
              <label className="block">
                <span className="text-xs text-muted-foreground">Judge Provider</span>
                <input
                  type="text"
                  value={ts.judgeProvider}
                  onChange={(e) => updateTS({ judgeProvider: e.target.value })}
                  className="mt-1 block w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm text-foreground"
                />
              </label>
              <label className="block">
                <span className="text-xs text-muted-foreground">Judge Model</span>
                <input
                  type="text"
                  value={ts.judgeModel}
                  onChange={(e) => updateTS({ judgeModel: e.target.value })}
                  className="mt-1 block w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm text-foreground"
                />
              </label>
            </div>
            <label className="block">
              <span className="text-xs text-muted-foreground">Default Model</span>
              <input
                type="text"
                value={config.Router.default || ''}
                onChange={(e) => onChange({ ...config, Router: { ...config.Router, default: e.target.value } })}
                className="mt-1 block w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm text-foreground"
              />
            </label>
            <div className="space-y-3">
              <span className="text-xs font-medium text-muted-foreground">Tier → Model Mapping</span>
              {Object.entries(ts.tiers).map(([tierName, tier]) => (
                <div key={tierName} className="flex items-start gap-3">
                  <div className="w-24 pt-1.5">
                    <TierBadge tier={tierName} />
                  </div>
                  <div className="flex-1 space-y-1.5">
                    <input
                      type="text"
                      value={tier.model}
                      onChange={(e) => updateTier(tierName, { model: e.target.value })}
                      placeholder="provider,model"
                      className="block w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm text-foreground"
                    />
                    <input
                      type="text"
                      value={tier.description}
                      onChange={(e) => updateTier(tierName, { description: e.target.value })}
                      placeholder="Description"
                      className="block w-full rounded-md border border-border bg-background px-2 py-1 text-xs text-muted-foreground"
                    />
                  </div>
                </div>
              ))}
            </div>
            {ts.rules && (
              <label className="block">
                <span className="text-xs text-muted-foreground">Classification Rules (one per line)</span>
                <textarea
                  value={ts.rules.join('\n')}
                  onChange={(e) => updateTS({ rules: e.target.value.split('\n').filter((l) => l.trim()) })}
                  rows={5}
                  className="mt-1 block w-full rounded-md border border-border bg-background px-3 py-1.5 font-mono text-xs text-foreground"
                />
              </label>
            )}
          </div>
        )}
      </SettingsCard>
    </SettingsSection>
  );
}

function AutoOrchestrateSection({ config, onChange }: { config: CCRConfig; onChange: (c: CCRConfig) => void }) {
  const ao = config.Router?.autoOrchestrate;
  if (!ao) return null;

  const updateAO = (patch: Partial<typeof ao>) => {
    onChange({ ...config, Router: { ...config.Router, autoOrchestrate: { ...ao, ...patch } } });
  };

  return (
    <SettingsSection title="AutoOrchestrate" description="Inject orchestration prompts and filter tools for complex tasks.">
      <SettingsCard>
        <div className="flex items-center justify-between p-4">
          <div className="flex items-center gap-2">
            <Activity className="h-4 w-4 text-muted-foreground" />
            <span className="text-sm font-medium text-foreground">Enable AutoOrchestrate</span>
          </div>
          <SettingsToggle checked={ao.enabled} onChange={(v) => updateAO({ enabled: v })} ariaLabel="Toggle AutoOrchestrate" />
        </div>
        {ao.enabled && (
          <div className="space-y-3 border-t border-border p-4">
            <label className="block">
              <span className="text-xs text-muted-foreground">Trigger Tiers (comma-separated)</span>
              <input
                type="text"
                value={ao.triggerTiers.join(', ')}
                onChange={(e) => updateAO({ triggerTiers: e.target.value.split(',').map((s) => s.trim()).filter(Boolean) })}
                className="mt-1 block w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm text-foreground"
              />
            </label>
            <label className="block">
              <span className="text-xs text-muted-foreground">Main Agent Model</span>
              <input
                type="text"
                value={ao.mainAgentModel}
                onChange={(e) => updateAO({ mainAgentModel: e.target.value })}
                className="mt-1 block w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm text-foreground"
              />
            </label>
            <label className="block">
              <span className="text-xs text-muted-foreground">Skill Path</span>
              <input
                type="text"
                value={ao.skillPath || ''}
                onChange={(e) => updateAO({ skillPath: e.target.value || undefined })}
                placeholder="/path/to/auto-orchestrate.md"
                className="mt-1 block w-full rounded-md border border-border bg-background px-3 py-1.5 text-sm text-foreground"
              />
            </label>
            <div className="flex items-center justify-between">
              <span className="text-xs text-muted-foreground">Slim System Prompt</span>
              <SettingsToggle
                checked={ao.slimSystemPrompt ?? false}
                onChange={(v) => updateAO({ slimSystemPrompt: v })}
                ariaLabel="Toggle slim system prompt"
              />
            </div>
          </div>
        )}
      </SettingsCard>
    </SettingsSection>
  );
}

// ---------------------------------------------------------------------------
// Main tab component
// ---------------------------------------------------------------------------

export default function RouterSettingsTab() {
  const {
    config,
    setConfig,
    health,
    summary,
    loading,
    saving,
    saveConfig,
    saveResult,
    resetStats,
  } = useRouterSettings();

  if (loading) {
    return (
      <div className="flex items-center justify-center py-12 text-sm text-muted-foreground">
        Loading router settings...
      </div>
    );
  }

  if (!config) {
    return (
      <SettingsSection title="Router">
        <SettingsCard>
          <div className="p-4 text-sm text-muted-foreground">
            CCR configuration not found. Set <code className="rounded bg-muted px-1 py-0.5 text-xs">router.enabled: true</code> in <code className="rounded bg-muted px-1 py-0.5 text-xs">~/.edgeclaw/config.yaml</code> (Settings &gt; Unified Config).
          </div>
        </SettingsCard>
      </SettingsSection>
    );
  }

  return (
    <div className="space-y-6">
      <StatusSection health={health} summary={summary} onResetStats={resetStats} />
      <ProvidersSection config={config} onChange={setConfig} />
      <TokenSaverSection config={config} onChange={setConfig} />
      <AutoOrchestrateSection config={config} onChange={setConfig} />

      {/* Save bar */}
      <div className="sticky bottom-0 flex items-center justify-between rounded-xl border border-border bg-card/90 p-3 backdrop-blur">
        <div className="text-xs">
          {saveResult && (
            <span className={`flex items-center gap-1 ${saveResult.success ? 'text-green-600 dark:text-green-400' : 'text-destructive'}`}>
              {saveResult.success ? <Check className="h-3.5 w-3.5" /> : <X className="h-3.5 w-3.5" />}
              {saveResult.message}
            </span>
          )}
        </div>
        <Button
          size="sm"
          onClick={() => saveConfig(config)}
          disabled={saving}
          className="gap-1.5"
        >
          <Save className="h-3.5 w-3.5" />
          {saving ? 'Saving...' : 'Save & Restart'}
        </Button>
      </div>
    </div>
  );
}
