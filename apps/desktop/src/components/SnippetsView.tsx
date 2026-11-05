import { useEffect, useState } from 'react';
import { api } from '@termpilot/core';
import { useApp } from '../state/store';
import { Icon } from './Icon';

interface Snippet {
  id: string;
  name: string;
  command: string;
  tags: string[];
}

export default function SnippetsView() {
  const snippets = useApp((s) => s.snippets) as Snippet[];
  const refreshSnippets = useApp((s) => s.refreshSnippets);
  const focusedSessionId = useApp((s) => s.focusedSessionId);
  const tabs = useApp((s) => s.tabs);
  const t = useApp((s) => s.t);
  const [name, setName] = useState('');
  const [command, setCommand] = useState('');
  const [group, setGroup] = useState('');
  const [creating, setCreating] = useState(false);
  const [filling, setFilling] = useState<{
    id: string;
    params: string[];
    broadcast?: boolean;
  } | null>(null);
  const [paramValues, setParamValues] = useState<Record<string, string>>({});

  useEffect(() => {
    void refreshSnippets();
  }, [refreshSnippets]);

  const create = async () => {
    if (!name.trim() || !command.trim()) return;
    try {
      await api.snippetCreate({
        name: name.trim(),
        command: command.trim(),
        tags: group.trim() ? [group.trim()] : [],
      });
      setName('');
      setCommand('');
      setGroup('');
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

  const liveIds = tabs.flatMap((tab) => tab.panes.map((p) => p.sessionId));

  const run = async (snippet: Snippet) => {
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

  // Broadcast: same command to every live session.
  const broadcast = async (snippet: Snippet) => {
    const params = extractParams(snippet.command);
    if (params.length > 0) {
      setFilling({ id: snippet.id, params, broadcast: true });
      setParamValues(Object.fromEntries(params.map((p) => [p, ''])));
      return;
    }
    await sendAll(snippet.command);
  };

  const sendAll = async (cmd: string) => {
    const payload = cmd.endsWith('\n') ? cmd : `${cmd}\n`;
    if (liveIds.length > 0) await api.terminalBroadcast(liveIds, payload);
    setFilling(null);
  };

  // Group by the first tag when a snippet carries one.
  const groups: { name: string; items: Snippet[] }[] = [];
  for (const s of snippets) {
    const g = s.tags[0] ?? '';
    const bucket = groups.find((x) => x.name === g);
    if (bucket) bucket.items.push(s);
    else groups.push({ name: g, items: [s] });
  }

  const renderRow = (s: Snippet) => (
    <div key={s.id} className="snippet-row">
      <div className="snippet-body">
        <span className="host-label">{s.name}</span>
        <code className="snippet-cmd">{s.command}</code>
      </div>
      <div className="snippet-actions">
        <button
          className="btn-icon"
          title={t('snippets.broadcast')}
          disabled={liveIds.length === 0}
          onClick={() => void broadcast(s)}
        >
          <Icon name="wifi" size={13} />
        </button>
        <button
          className="btn-icon"
          title={t('snippets.run')}
          disabled={!focusedSessionId}
          onClick={() => void run(s)}
        >
          <Icon name="zap" size={13} />
        </button>
        <button
          className="btn-icon"
          title={t('common.delete')}
          onClick={() => void remove(s.id)}
        >
          <Icon name="x" size={13} />
        </button>
      </div>
    </div>
  );

  return (
    <div className="sidebar-view">
      <div className="sidebar-scroll">
        {groups.map(({ name: g, items }) => (
          <div key={g || '_ungrouped'}>
            {g && <div className="group-title">{g}</div>}
            {items.map(renderRow)}
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
            <input
              placeholder={t('snippets.group')}
              value={group}
              onChange={(e) => setGroup(e.target.value)}
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
            <h2>{filling.broadcast ? t('snippets.broadcast') : t('snippets.run')}</h2>
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
                  void (filling.broadcast ? sendAll(filled) : send(filled));
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
