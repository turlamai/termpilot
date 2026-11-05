import { useEffect, useState } from 'react';
import { api } from '@termpilot/core';
import { useApp } from '../state/store';

export default function SnippetsView() {
  const snippets = useApp((s) => s.snippets);
  const refreshSnippets = useApp((s) => s.refreshSnippets);
  const focusedSessionId = useApp((s) => s.focusedSessionId);
  const t = useApp((s) => s.t);
  const [name, setName] = useState('');
  const [command, setCommand] = useState('');
  const [creating, setCreating] = useState(false);
  const [filling, setFilling] = useState<{ id: string; params: string[] } | null>(null);
  const [paramValues, setParamValues] = useState<Record<string, string>>({});

  useEffect(() => {
    void refreshSnippets();
  }, [refreshSnippets]);

  const create = async () => {
    if (!name.trim() || !command.trim()) return;
    try {
      await api.snippetCreate({ name: name.trim(), command: command.trim(), tags: [] });
      setName('');
      setCommand('');
      setCreating(false);
      await refreshSnippets();
    } catch (e) {
      console.error(e);
    }
  };

  const remove = async (id: string) => {
    if (!window.confirm(t('common.confirm-delete'))) return;
    try {
      await api.snippetDelete(id);
      await refreshSnippets();
    } catch (e) {
      console.error(e);
    }
  };

  const extractParams = (cmd: string): string[] => {
    const out = new Set<string>();
    for (const m of cmd.matchAll(/\{\{\s*([\w.-]+)\s*\}\}/g)) out.add(m[1]);
    return [...out];
  };

  const run = async (snippet: { id: string; command: string }) => {
    if (!focusedSessionId) return;
    const params = extractParams(snippet.command);
    if (params.length > 0) {
      setFilling({ id: snippet.id, params });
      setParamValues(Object.fromEntries(params.map((p) => [p, ''])));
      return;
    }
    await send(snippet.command);
  };

  const send = async (cmd: string) => {
    await api.terminalInput(focusedSessionId!, cmd.endsWith('\n') ? cmd : `${cmd}\n`);
    setFilling(null);
  };

  return (
    <div className="sidebar-view">
      <div className="sidebar-scroll">
        {snippets.map((s) => (
          <div key={s.id} className="snippet-row">
            <div className="snippet-body">
              <span className="host-label">{s.name}</span>
              <code className="snippet-cmd">{s.command}</code>
            </div>
            <div className="snippet-actions">
              <button
                className="btn-icon"
                title={t('snippets.run')}
                disabled={!focusedSessionId}
                onClick={() => void run(s)}
              >
                ▶
              </button>
              <button
                className="btn-icon"
                title={t('common.delete')}
                onClick={() => void remove(s.id)}
              >
                ✕
              </button>
            </div>
          </div>
        ))}
        {snippets.length === 0 && <p className="hint">{t('snippets.empty')}</p>}
        <p className="hint">{t('snippets.param-hint')}</p>
      </div>
      <div className="sidebar-actions">
        {!creating ? (
          <button className="btn btn-primary btn-block" onClick={() => setCreating(true)}>
            ＋ {t('snippets.new')}
          </button>
        ) : (
          <div className="inline-form">
            <input
              placeholder={t('snippets.name')}
              value={name}
              onChange={(e) => setName(e.target.value)}
              autoFocus
            />
            <input
              placeholder={t('snippets.command')}
              value={command}
              onChange={(e) => setCommand(e.target.value)}
            />
            <div className="row">
              <button className="btn btn-primary" onClick={() => void create()}>
                {t('common.save')}
              </button>
              <button className="btn" onClick={() => setCreating(false)}>
                {t('common.cancel')}
              </button>
            </div>
          </div>
        )}
      </div>
      {filling && (
        <div className="modal-backdrop" onClick={() => setFilling(null)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <h2>{t('snippets.run')}</h2>
            {filling.params.map((p) => (
              <div key={p} className="form-grid">
                <label>{p}</label>
                <input
                  value={paramValues[p] ?? ''}
                  onChange={(e) =>
                    setParamValues({ ...paramValues, [p]: e.target.value })
                  }
                />
              </div>
            ))}
            <div className="modal-actions">
              <span className="spacer" />
              <button className="btn" onClick={() => setFilling(null)}>
                {t('common.cancel')}
              </button>
              <button
                className="btn btn-primary"
                onClick={() => {
                  const snippet = snippets.find((s) => s.id === filling.id)!;
                  const filled = snippet.command.replace(
                    /\{\{\s*([\w.-]+)\s*\}\}/g,
                    (_, k) => paramValues[k] ?? '',
                  );
                  void send(filled);
                }}
              >
                {t('common.ok')}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
