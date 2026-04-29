export function buildAlwaysOnDiscoveryPrompt(projectRoot: string): string {
  return [
    `Always-On discovery planning for project at \`${projectRoot}\`.`,
    '',
    'Your job is discovery only.',
    'Inspect the workspace and decide whether there are worthwhile follow-up tasks.',
    '',
    'Requirements:',
    '1. If there is no worthwhile follow-up work, explain why and stop without saving plans.',
    '2. If there is worthwhile work, use `AlwaysOnDiscoveryPlan` to persist up to 3 plans.',
    '3. Every saved plan must include `## Context`, `## Signals Reviewed`, `## Proposed Work`, `## Execution Steps`, `## Verification`, and `## Approval And Execution`.',
    '4. Use `approvalMode: "manual"` unless the work is clearly safe and suitable for auto-execution.',
    '5. Do not call `CronCreate`, do not execute the work now, and do not start background tasks.',
    '6. In your final reply, summarize what you reviewed and which discovery plan IDs were created or updated.',
  ].join('\n')
}
