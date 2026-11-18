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

// Kind-aware address line, mirroring the prototype's addrLabel: serial
// profiles read "device · baud 8N1", ADB the device serial, local the
// shell choice, network user@host:port.
function hostAddr(h: HostProfile): string {
  const kind = h['connection-kind'] ?? 'ssh';
  if (kind === 'serial') {
    const par = (h.parity ?? 'none').toLowerCase();
    const parLetter = par === 'even' ? 'E' : par === 'odd' ? 'O' : par === 'mark' ? 'M' : par === 'space' ? 'S' : 'N';
    return `${h.host} · ${h.port} ${h['data-bits'] ?? 8}${parLetter}${h.stopbits ?? 1}`;
  }
  if (kind === 'adb') return h.host;
  if (kind === 'local')
    return h.shell ? `shell: ${h.shell}` : 'shell: default';
  return `${h.username ? `${h.username}@` : ''}${h.host}${h.port !== 22 ? `:${h.port}` : ''}`;
}

function kindLabel(h: HostProfile): string {
  const kind = h['connection-kind'] ?? 'ssh';
  return { ssh: 'SSH', mosh: 'Mosh', telnet: 'Telnet', tcp: 'TCP', serial: 'Serial', local: 'Local', adb: 'ADB' }[kind] ?? kind;
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
          <span className="kind-badge">{kindLabel(host)}</span>
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

const KIND_FILTERS = ['ALL', 'ssh', 'mosh', 'telnet', 'tcp', 'serial', 'local', 'adb'];

export default function HostsView() {
  const hosts = useApp((s) => s.hosts);
  const hostsLoaded = useApp((s) => s.hostsLoaded);
  const refreshHosts = useApp((s) => s.refreshHosts);
  const openSession = useApp((s) => s.openSession);
  const setView = useApp((s) => s.setView);
  const t = useApp((s) => s.t);
  const [query, setQuery] = useState('');
  const [kindFilter, setKindFilter] = useState('ALL');
  const [creating, setCreating] = useState(false);
  const [creatingKind, setCreatingKind] = useState<string | undefined>(undefined);
  const [importMsg, setImportMsg] = useState('');
  // Rides the store so the ⌘⇧L / Ctrl⇧L shortcut can open it directly.
  const quickOpen = useApp((s) => s.quickConnectOpen);
  const setQuickOpen = useApp((s) => s.setQuickConnect);
  const [quickTarget, setQuickTarget] = useState('');
  const [latencies, setLatencies] = useState<Record<string, number | null>>({});
  const [probing, setProbing] = useState(false);

  const probe = async () => {
    if (hosts.length === 0 || probing) return;
    setProbing(true);
    try {
      // Latency probes are TCP handshakes — serial/local/adb profiles
      // have no network endpoint, so they sit out.
      const targets = hosts
        .filter((h) => ['ssh', 'mosh', 'telnet', 'tcp'].includes(h['connection-kind'] ?? 'ssh'))
        .map((h) => ({ id: h.id, host: h.host, port: h.port }));
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
        (kindFilter === 'ALL' || (h['connection-kind'] ?? 'ssh') === kindFilter) &&
        (!q ||
          h.label.toLowerCase().includes(q) ||
          h.host.toLowerCase().includes(q) ||
          h.tags.some((tag) => tag.toLowerCase().includes(q))),
    );
    const map = new Map<string, HostProfile[]>();
    for (const h of filtered) {
      const g = h['group-name'] || '';
      if (!map.has(g)) map.set(g, []);
      map.get(g)!.push(h);
    }
    return [...map.entries()].sort(([a], [b]) => a.localeCompare(b));
  }, [hosts, query, kindFilter]);

  return (
    <div className="sidebar-view">
      {/* Capability strip: the daily loop the contract centers on. */}
      <div className="workflow-strip">
        <button className="workflow-chip" onClick={() => { setCreatingKind('serial'); setCreating(true); }}>
          {t('workflow.serial')}
        </button>
        <button className="workflow-chip" onClick={() => setView('tools')}>
          {t('workflow.tools')}
        </button>
        <button className="workflow-chip" onClick={() => setView('sftp')}>
          {t('workflow.transfer')}
        </button>
      </div>
      <input
        className="search"
        placeholder={t('hosts.search')}
        value={query}
        onChange={(e) => setQuery(e.target.value)}
      />
      <div className="row kind-filter-row">
        <select
          className="kind-filter"
          value={kindFilter}
          onChange={(e) => setKindFilter(e.target.value)}
          aria-label={t('hosts.kindfilter')}
        >
          {KIND_FILTERS.map((k) => (
            <option key={k} value={k}>
              {k === 'ALL' ? t('hosts.kind.all') : t(`kind.${k}`)}
            </option>
          ))}
        </select>
        <span className="hint">{hosts.length}</span>
      </div>
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
        <button
          className="btn btn-primary btn-block"
          onClick={() => { setCreatingKind(undefined); setCreating(true); }}
        >
          ＋ {t('hosts.new')}
        </button>
        <button className="btn btn-block" onClick={() => setQuickOpen(!quickOpen)}>
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
      {creating && (
        <HostEditor initialKind={creatingKind} onClose={() => setCreating(false)} />
      )}
    </div>
  );
}
