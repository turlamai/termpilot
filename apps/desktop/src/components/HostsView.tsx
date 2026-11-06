import { useEffect, useMemo, useState } from 'react';
import { useApp } from '../state/store';
import { api, type HostProfile } from '@termpilot/core';
import HostEditor from './HostEditor';
import { Icon } from './Icon';

function latencyClass(ms: number | null | undefined): string {
  return ms === undefined
    ? ''
    : ms === null
      ? 'lat-bad'
      : ms < 100
        ? 'lat-fast'
        : ms < 500
          ? 'lat-mid'
          : 'lat-slow';
}

function hostAddr(h: HostProfile): string {
  return `${h.username ? `${h.username}@` : ''}${h.host}${h.port !== 22 ? `:${h.port}` : ''}`;
}

function HostRow({
  host,
  latency,
}: {
  host: HostProfile;
  latency?: number | null;
}) {
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
        <span className="host-label">
          {host.label}
          {latency !== undefined && (
            <span className={`lat-badge ${latencyClass(latency)}`}>
              {latency === null ? '×' : `${latency}ms`}
            </span>
          )}
        </span>
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
  const [quickOpen, setQuickOpen] = useState(false);
  const [quickTarget, setQuickTarget] = useState('');
  const [latencies, setLatencies] = useState<Record<string, number | null>>({});
  const [probing, setProbing] = useState(false);

  const probe = async () => {
    if (hosts.length === 0 || probing) return;
    setProbing(true);
    try {
      const targets = hosts.map((h) => ({
        id: h.id,
        host: h.host,
        port: h['connection-kind'] === 'serial' ? 0 : h.port,
      }));
      const r = await api.hostsProbe(targets);
      const map: Record<string, number | null> = {};
      for (const item of r.results) map[item.id] = item.ms;
      setLatencies((prev) => ({ ...prev, ...map }));
    } catch {
      // probing is best-effort
    }
    setProbing(false);
  };



  // "user@host:port" — user and port optional.
  const quickConnect = async () => {
    const raw = quickTarget.trim();
    if (!raw) return;
    let username = '';
    let hostPort = raw;
    if (raw.includes('@')) {
      [username, hostPort] = raw.split('@', 2);
    }
    let port = 22;
    let host = hostPort;
    if (hostPort.includes(':')) {
      const parts = hostPort.split(':');
      host = parts[0];
      port = Number(parts[1]) || 22;
    }
    if (!host) return;
    await openSession({
      host,
      port,
      username,
      label: username ? `${username}@${host}` : host,
    });
    setQuickOpen(false);
    setQuickTarget('');
  };

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
              <HostRow key={h.id} host={h} latency={latencies[h.id]} />
            ))}
          </div>
        ))}
        {hostsLoaded && hosts.length === 0 && (
          <p className="hint">{t('hosts.empty')}</p>
        )}
      </div>
      {importMsg && <p className="hint">{importMsg}</p>}
      {quickOpen && (
        <div className="inline-form">
          <input
            placeholder={t('hosts.quick.placeholder')}
            value={quickTarget}
            onChange={(e) => setQuickTarget(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') void quickConnect();
              if (e.key === 'Escape') setQuickOpen(false);
            }}
            autoFocus
          />
          <p className="hint">{t('hosts.quick.hint')}</p>
          <div className="row">
            <button className="btn btn-primary" onClick={() => void quickConnect()}>
              {t('hosts.connect')}
            </button>
            <button className="btn" onClick={() => setQuickOpen(false)}>
              {t('common.cancel')}
            </button>
          </div>
        </div>
      )}
      <div className="sidebar-actions">
        <button className="btn btn-primary btn-block" onClick={() => setCreating(true)}>
          ＋ {t('hosts.new')}
        </button>
        <button className="btn btn-block" onClick={() => setQuickOpen((v) => !v)}>
          {t('hosts.quick')}
        </button>
        <button className="btn btn-block" onClick={() => void importConfig()}>
          {t('hosts.import')}
        </button>
        <button className="btn btn-block" disabled={probing} onClick={() => void probe()}>
          {probing ? t('hosts.probing') : t('hosts.probe')}
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
