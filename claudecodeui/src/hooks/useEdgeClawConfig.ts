import { useCallback, useEffect, useState } from 'react';
import { authenticatedFetch } from '../utils/api';

type ConfigValidation = {
  valid: boolean;
  errors: string[];
  warnings: string[];
};

type ConfigReload = Record<string, unknown>;

type ConfigResponse = {
  exists: boolean;
  path: string;
  raw: string;
  validation: ConfigValidation;
  reload?: ConfigReload;
};

export function useEdgeClawConfig() {
  const [path, setPath] = useState('');
  const [raw, setRaw] = useState('');
  const [exists, setExists] = useState(false);
  const [validation, setValidation] = useState<ConfigValidation | null>(null);
  const [reload, setReload] = useState<ConfigReload | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [opening, setOpening] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);

  const applyResponse = useCallback((data: ConfigResponse) => {
    setPath(data.path);
    setRaw(data.raw);
    setExists(data.exists);
    setValidation(data.validation);
    setReload(data.reload ?? null);
  }, []);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await authenticatedFetch('/api/config');
      const data = await response.json();
      if (!response.ok) throw new Error(data.error || 'Failed to load config');
      applyResponse(data);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Failed to load config');
    } finally {
      setLoading(false);
    }
  }, [applyResponse]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const save = useCallback(async () => {
    setSaving(true);
    setError(null);
    setMessage(null);
    try {
      const response = await authenticatedFetch('/api/config', {
        method: 'PUT',
        body: JSON.stringify({ raw }),
      });
      const data = await response.json();
      if (!response.ok) throw new Error(data.error || data.validation?.errors?.join(', ') || 'Failed to save config');
      applyResponse(data);
      setMessage('Saved and reloaded');
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Failed to save config');
    } finally {
      setSaving(false);
    }
  }, [applyResponse, raw]);

  const reloadConfig = useCallback(async () => {
    setSaving(true);
    setError(null);
    setMessage(null);
    try {
      const response = await authenticatedFetch('/api/config/reload', { method: 'POST' });
      const data = await response.json();
      if (!response.ok) throw new Error(data.error || 'Failed to reload config');
      applyResponse(data);
      setMessage('Reloaded current config');
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Failed to reload config');
    } finally {
      setSaving(false);
    }
  }, [applyResponse]);

  const openFile = useCallback(async () => {
    setOpening(true);
    setError(null);
    try {
      const response = await authenticatedFetch('/api/config/open', { method: 'POST' });
      const data = await response.json();
      if (!data.success && data.error) throw new Error(data.error);
      setMessage(`Config file: ${data.path}`);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Failed to open config file');
    } finally {
      setOpening(false);
    }
  }, []);

  return {
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
  };
}
