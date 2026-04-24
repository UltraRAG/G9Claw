// Single source of truth for the V2 UI feature flag.
// Vite inlines VITE_* env vars at build time; we also honor ?uiV2=1 at runtime
// so reviewers can toggle without rebuilding.
function readQueryFlag(): boolean {
  if (typeof window === 'undefined') return false;
  try {
    const params = new URLSearchParams(window.location.search);
    const v = params.get('uiV2');
    if (v == null) return false;
    return v === '1' || v === 'true';
  } catch {
    return false;
  }
}

function readEnvFlag(): boolean {
  const raw = (import.meta as ImportMeta & { env?: Record<string, string | undefined> }).env?.VITE_UI_V2;
  return raw === 'true' || raw === '1';
}

export function isUiV2Enabled(): boolean {
  return readEnvFlag() || readQueryFlag();
}

export function useIsUiV2(): boolean {
  // Flag is static for a given page load; no need to subscribe.
  return isUiV2Enabled();
}
