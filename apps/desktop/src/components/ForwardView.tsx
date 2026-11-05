import { useEffect, useState } from 'react';
import { api, type ForwardRule } from '@termpilot/core';
import { useApp } from '../state/store';
import { confirmDialog, toast } from '../state/feedback';

export default function ForwardView() {
  const hosts = useApp((s) => s.hosts);
  const refreshHosts = useApp((s) => s.refreshHosts);
  const t = useApp((s) => s.t);
  const [rules, setRules] = useState<ForwardRule[]>([]);
  const [running, setRunning] = useState<Record<string, boolean>>({});
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState('');
  const [kind, setKind] = useState<'local' | 'remote' | 'dynamic'>('local');
  const [hostId, setHostId] = useState('');
  const [bindHost, setBindHost] = useState('');
  const [localPort, setLocalPort] = useState('');
  const [remoteHost, setRemoteHost] = useState('');
  const [remotePort, setRemotePort] = useState('');

  const refresh = async () => {
    await refreshHosts();
    const { rules: list } = await api.forwardRules();
    setRules(list);
    try {
      const st = await api.forwardStatus();
      const map: Record<string, boolean> = {};
      for (const tun of st.tunnels) map[tun.id] = tun.running;
      setRunning(map);
    } catch {
      // status is best-effort
    }
  };

  useEffect(() => {
    void refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const hostLabel = (id: string) =>
    hosts.find((h) => h.id === id)?.label ?? id;

  const ruleSpec = (r: ForwardRule) =>
    r.kind === 'dynamic'
      ? `SOCKS5 :${r['local-port']}`
      : `${r['bind-host'] || 'localhost'}:${r['local-port']} → ${r['remote-host']}:${r['remote-port']}`;

  const create = async () => {
    if (!name.trim() || !hostId || !localPort) return;
    await api.forwardCreate({
      name: name.trim(),
      kind,
      'host-id': hostId,
      'bind-host': bindHost.trim(),
      'local-port': Number(localPort),
      'remote-host': remoteHost.trim(),
      'remote-port': Number(remotePort) || 0,
    });
    setCreating(false);
    setName('');
    setLocalPort('');
    setRemoteHost('');
    setRemotePort('');
    await refresh();
  };

  const remove = async (id: string) => {
    if (!(await confirmDialog(t('common.confirm-delete'), { danger: true }))) return;
    await api.forwardDelete(id);
    await refresh();
  };

  return (
    <div className="sidebar-view">
      <div className="sidebar-scroll">
        {rules.map((r) => (
          <div key={r.id} className="snippet-row">
            <div className="snippet-body">
              <span className="host-label">
                {running[r.id] ? '🟢 ' : ''}
                {r.name}
              </span>
              <code className="snippet-cmd">
                {r.kind} · {hostLabel(r['host-id'])} · {ruleSpec(r)}
              </code>
            </div>
            <div className="snippet-actions">
              {running[r.id] ? (
                <button
                  className="btn-icon"
                  title="Stop"
                  onClick={async () => {
                    await api.forwardStop(r.id);
                    await refresh();
                  }}
                >
                  ⏹
                </button>
              ) : (
                <button
                  className="btn-icon"
                  title="Start"
                  onClick={async () => {
                    try {
                      await api.forwardStart(r.id);
                      await refresh();
                    } catch (e) {
                      toast(String(e).slice(0, 140), { error: true });
                    }
                  }}
                >
                  ▶
                </button>
              )}
              <button className="btn-icon" title={t('common.delete')} onClick={() => void remove(r.id)}>
                ✕
              </button>
            </div>
          </div>
        ))}
        {rules.length === 0 && <p className="hint">{t('forward.placeholder')}</p>}
      </div>
      <div className="sidebar-actions">
        {!creating ? (
          <button className="btn btn-primary btn-block" onClick={() => setCreating(true)}>
            ＋ {t('forward.new')}
          </button>
        ) : (
          <div className="inline-form">
            <input placeholder={t('forward.name')} value={name} onChange={(e) => setName(e.target.value)} autoFocus />
            <select value={kind} onChange={(e) => setKind(e.target.value as 'local' | 'remote' | 'dynamic')}>
              <option value="local">Local (-L)</option>
              <option value="remote">Remote (-R)</option>
              <option value="dynamic">Dynamic SOCKS (-D)</option>
            </select>
            <select value={hostId} onChange={(e) => setHostId(e.target.value)}>
              <option value="">{t('view.hosts')}…</option>
              {hosts.map((h) => (
                <option key={h.id} value={h.id}>
                  {h.label}
                </option>
              ))}
            </select>
            <input placeholder={t('forward.bindhost')} value={bindHost} onChange={(e) => setBindHost(e.target.value)} />
            <input placeholder={t('forward.localport')} type="number" value={localPort} onChange={(e) => setLocalPort(e.target.value)} />
            {kind !== 'dynamic' && (
              <>
                <input placeholder={t('forward.remotehost')} value={remoteHost} onChange={(e) => setRemoteHost(e.target.value)} />
                <input placeholder={t('forward.remoteport')} type="number" value={remotePort} onChange={(e) => setRemotePort(e.target.value)} />
              </>
            )}
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
    </div>
  );
}
