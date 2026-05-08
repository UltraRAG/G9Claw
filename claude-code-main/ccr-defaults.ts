/**
 * Default Router configuration for 9GClaw's embedded CCR integration.
 *
 * These defaults are intentionally expressed in EdgeClaw model-entry ids
 * where possible. buildCcrConfigFromEdgeClawConfig resolves them to
 * provider,model pairs after merging user config.
 */

export const DEFAULT_TOKEN_SAVER = {
  enabled: false,
  judgeModel: 'default',
  defaultTier: 'MEDIUM',
  subagentPolicy: 'inherit',
  tiers: {
    SIMPLE: {
      model: 'default',
      description: 'Simple Q&A, file reads, greetings, small edits',
    },
    MEDIUM: {
      model: 'default',
      description: 'Moderate coding, single-file edits, explanations',
    },
    COMPLEX: {
      model: 'default',
      description: 'Multi-step coding, architecture, large refactors',
    },
    REASONING: {
      model: 'default',
      description: 'Deep reasoning, novel algorithms, security analysis',
    },
  },
  rules: [
    'Short prompts (<20 words) -> SIMPLE',
    'Single-file edits, code review -> MEDIUM',
    'Multi-file tasks, refactoring -> COMPLEX',
    'Novel architecture, deep analysis -> REASONING',
    'RAG, cited research, web/local knowledge synthesis, or source-backed reports -> REASONING',
    'HTML/webpage/dashboard generation that requires research or citations -> REASONING',
    'Military, DARPA, intelligence, operational assessment, or future capability analysis -> REASONING',
  ],
} as const;

export const DEFAULT_AUTO_ORCHESTRATE = {
  enabled: false,
  triggerTiers: ['COMPLEX', 'REASONING'],
  mainAgentModel: 'default',
  skillPath: '~/.claude/prompts/auto-orchestrate.md',
  slimSystemPrompt: true,
  allowedTools: ['Agent', 'Read', 'Grep', 'Glob', 'TodoRead', 'TodoWrite'],
  subagentMaxTokens: 48000,
} as const;

export const DEFAULT_ROUTER_CONFIG = {
  tokenSaver: DEFAULT_TOKEN_SAVER,
  autoOrchestrate: DEFAULT_AUTO_ORCHESTRATE,
} as const;
