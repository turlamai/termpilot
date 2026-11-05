import { useEffect, useMemo, useState } from 'react';
import { useApp } from '../state/store';
import { api, type HostProfile } from '@termpilot/core';
import HostEditor from './HostEditor';
import { Icon } from './Icon';

function hostAddr(h: HostProfile): string {
  return `${h.username ? `${h.username}@` : ''}${h.host}${h.port !== 22 ? `:${h.port}` : ''}`;
}

function HostRow({ host }: { host: HostProfile }) {
  const openSession = useApp((s) => s.openSession);
  const t = useApp((s) => s.t);
  const [editing, setEditing] = useState(false);

  return (
    <div className="host-row">
      <button
        className="host-btn"
        title={`${hostAddr(host)} — ${t('hosts.connect')}`}
        onClick={() => void openSession({ 'host-id': host.id })}
      >
        <span className="host-label">{host.label}</span>
        <span className="host-addr">{hostAddr(host)}</span>
      </button>
      <button className="btn-icon" title={t('common.edit')} onClick={() => setEditing(true)}>
        <Icon name="pencil" size={13} />
      </button>
      {editing && <HostEditor host={host} onClose={() => setEditing(false)} />}
    </div>
  );
}

export default function HostsView() {
  const hosts = useApp((s) => s.hosts);
  const hostsLoaded = useApp((s) => s.hostsLoaded);
  const refreshHosts = useApp((s) => s.refreshHosts);
  const openSession = useApp((s) => s.openSession);
  const t = useApp((s) => s.t);
  const [query, setQuery] = useState('');
  const [creating, setCreating] = useState(false);
  const [importMsg, setImportMsg] = useState('');

  const importConfig = async () => {
    try {
      const r = await api.hostsImportConfig();
      setImportMsg(`${r.imported} imported / ${r.skipped} skipped`);
      await refreshHosts();
    } catch (e) {
      setImportMsg(String(e).slice(0, 120));
    }
  };

  useEffect(() => {
    if (!hostsLoaded) void refreshHosts();
  }, [hostsLoaded, refreshHosts]);

  const groups = useMemo(() => {
    const q = query.trim().toLowerCase();
    const filtered = hosts.filter(
      (h) =>
        !q ||
        h.label.toLowerCase().includes(q) ||
        h.host.toLowerCase().includes(q) ||
        h.tags.some((tag) => tag.toLowerCase().includes(q)),
    );
    const map = new Map<string, HostProfile[]>();
    for (const h of filtered) {
      const g = h['group-name'] || '';
      if (!map.has(g)) map.set(g, []);
      map.get(g)!.push(h);
    }
    return [...map.entries()].sort(([a], [b]) => a.localeCompare(b));
  }, [hosts, query]);

  return (
    <div className="sidebar-view">
      <input
        className="search"
        placeholder={t('hosts.search')}
        value={query}
        onChange={(e) => setQuery(e.target.value)}
      />
      <div className="sidebar-scroll">
        {groups.map(([group, list]) => (
          <div key={group} className="host-group">
            {group && <div className="group-title">{group}</div>}
            {list.map((h) => (
              <HostRow key={h.id} host={h} />
            ))}
          </div>
        ))}
        {hostsLoaded && hosts.length === 0 && (
          <p className="hint">{t('hosts.empty')}</p>
        )}
      </div>
      {importMsg && <p className="hint">{importMsg}</p>}
      <div className="sidebar-actions">
        <button className="btn btn-primary btn-block" onClick={() => setCreating(true)}>
          ＋ {t('hosts.new')}
        </button>
        <button className="btn btn-block" onClick={() => void importConfig()}>
          {t('hosts.import')}
        </button>
        <button
          className="btn btn-block"
          onClick={() => void openSession({ kind: 'local' })}
        >
          {t('tabs.new-local')}
        </button>
      </div>
      {creating && <HostEditor onClose={() => setCreating(false)} />}
    </div>
  );
}
