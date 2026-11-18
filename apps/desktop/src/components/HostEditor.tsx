import { useEffect, useState } from 'react';
import { api, type HostProfile } from '@termpilot/core';
import { useApp } from '../state/store';
import { confirmDialog, toast } from '../state/feedback';

// Connection kinds and their type-specific config, per the embedded
// workspace contract: serial and SSH are peers; telnet/tcp are plain
// network terminals (no encryption); local shells carry shell + cwd;
// adb carries a device serial. The host column doubles as the serial
// device path / ADB serial, and for serial profiles the port column
// carries the baud (same convention the transport seam consumes).
const KINDS: { id: string; labelKey: string; defaultPort?: number }[] = [
  { id: 'ssh', labelKey: 'kind.ssh', defaultPort: 22 },
  { id: 'mosh', labelKey: 'kind.mosh', defaultPort: 22 },
  { id: 'telnet', labelKey: 'kind.telnet', defaultPort: 23 },
  { id: 'tcp', labelKey: 'kind.tcp', defaultPort: 9000 },
  { id: 'serial', labelKey: 'kind.serial' },
  { id: 'local', labelKey: 'kind.local' },
  { id: 'adb', labelKey: 'kind.adb' },
];

const NETWORK_KINDS = ['ssh', 'mosh', 'telnet', 'tcp'];
const NO_ENCRYPTION_KINDS = ['telnet', 'tcp'];

interface HostEditorProps {
  host?: HostProfile; // present = edit mode
  initialKind?: string; // serial quick-start opens here
  onClose: () => void;
}

export default function HostEditor({ host, initialKind, onClose }: HostEditorProps) {
  const refreshHosts = useApp((s) => s.refreshHosts);
  const t = useApp((s) => s.t);
  const tabs = useApp((s) => s.tabs);
  const [label, setLabel] = useState(host?.label ?? '');
  const [hostName, setHostName] = useState(host?.host ?? '');
  const [port, setPort] = useState(String(host?.port ?? defaultPort(host, initialKind)));
  const [username, setUsername] = useState(host?.username ?? '');
  const [authType, setAuthType] = useState(host?.['auth-type'] ?? 'agent');
  const [identityFile, setIdentityFile] = useState(host?.['identity-file'] ?? '');
  const [groupName, setGroupName] = useState(host?.['group-name'] ?? '');
  const [notes, setNotes] = useState(host?.notes ?? '');
  const [strict, setStrict] = useState(host?.['strict-host-key'] ?? 'accept-new');
  const [jump, setJump] = useState(host?.jump ?? '');
  const [startupSnippet, setStartupSnippet] = useState(host?.['startup-snippet'] ?? '');
  const [keepAlive, setKeepAlive] = useState(String(host?.['keep-alive'] ?? 0));
  const [fontSize, setFontSize] = useState(String(host?.['font-size'] ?? 0));
  const [connKind, setConnKind] = useState(host?.['connection-kind'] ?? initialKind ?? 'ssh');
  const [dataBits, setDataBits] = useState(String(host?.['data-bits'] ?? 8));
  const [parity, setParity] = useState(host?.parity ?? 'none');
  const [stopBits, setStopBits] = useState(String(host?.stopbits ?? 1));
  const [flowControl, setFlowControl] = useState(host?.['flow-control'] ?? 'none');
  const [encoding, setEncoding] = useState(host?.encoding ?? 'utf-8');
  const [lineEnding, setLineEnding] = useState(host?.['line-ending'] ?? 'crlf');
  const [shell, setShell] = useState(host?.shell ?? '');
  const [cwd, setCwd] = useState(host?.cwd ?? '');
  const [ports, setPorts] = useState<{ path: string; label: string }[]>([]);
  const [error, setError] = useState('');
  const [errorField, setErrorField] = useState('');

  // Real device enumeration for the serial path input (no fake list).
  useEffect(() => {
    if (connKind !== 'serial') return;
    void api
      .serialPorts()
      .then((r) => setPorts(r.ports.filter((p) => p.path)))
      .catch(() => setPorts([]));
  }, [connKind]);

function defaultPort(h: HostProfile | undefined, kind: string | undefined): number {
  if (h) return h.port;
  const k = kind ?? 'ssh';
  // serial carries the baud in the port column; adb carries no port.
  if (k === 'serial') return 115200;
  if (k === 'adb' || k === 'local') return 0;
  return KINDS.find((x) => x.id === k)?.defaultPort ?? 22;
}

  const setKind = (k: string) => {
    setConnKind(k);
    setError('');
    setErrorField('');
    const def = KINDS.find((x) => x.id === k)?.defaultPort;
    if (def) setPort(String(def));
    // Switching kinds keeps name and group; the address column means
    // something different per kind, so clear a now-invalid value.
    if (k === 'serial' || k === 'adb') setPort('115200');
  };

  const duplicate = async () => {
    if (!host) return;
    try {
      await api.hostCreate({
        ...host,
        label: `${host.label} (copy)`,
      } as Partial<HostProfile>);
      await refreshHosts();
      onClose();
    } catch (e) {
      setError(String(e));
    }
  };

  const fieldError = (key: string, msg: string) => {
    setError(msg);
    setErrorField(key);
  };

  const save = async () => {
    if (!label.trim()) {
      fieldError('label', t('host.err.name'));
      return;
    }
    const kind = connKind;
    const payload: Partial<HostProfile> = {
      label: label.trim(),
      'group-name': groupName.trim(),
      notes,
      // 0 = follow the global size; otherwise the contract's 11–24.
      'font-size': (() => {
        const n = Number(fontSize);
        return Number.isInteger(n) && n >= 11 && n <= 24 ? n : 0;
      })(),
      'connection-kind': kind,
    };
    if (kind === 'serial') {
      if (!hostName.trim()) {
        fieldError('host', t('host.err.device'));
        return;
      }
      const baud = Number(port);
      if (!Number.isInteger(baud) || baud < 50 || baud > 4000000) {
        fieldError('port', t('host.err.baud'));
        return;
      }
      payload.host = hostName.trim();
      payload.port = baud;
      payload.username = '';
      payload['data-bits'] = clampInt(dataBits, 5, 8) ?? 8;
      payload.parity = parity;
      // 1 / 1.5 / 2 per the contract; 1.5 depends on driver support
      // (termios can only express 1 or 2 stop bits).
      payload.stopbits = [1, 1.5, 2].includes(Number(stopBits))
        ? Number(stopBits)
        : 1;
      payload['flow-control'] = flowControl;
      payload.encoding = encoding;
      payload['line-ending'] = lineEnding;
    } else if (kind === 'local') {
      payload.host = 'localhost';
      payload.port = 0;
      payload.username = 'local';
      payload.shell = shell;
      payload.cwd = cwd.trim();
    } else if (kind === 'adb') {
      if (!hostName.trim()) {
        fieldError('host', t('host.err.serial'));
        return;
      }
      payload.host = hostName.trim();
      payload.port = 0;
      payload.username = 'shell';
    } else {
      const addr = hostName.trim();
      if (!addr || /[\s/]/.test(addr)) {
        fieldError('host', t('host.err.addr'));
        return;
      }
      const p = Number(port);
      if (!Number.isInteger(p) || p < 1 || p > 65535) {
        fieldError('port', t('host.err.port'));
        return;
      }
      if (NETWORK_KINDS.includes(kind) && kind !== 'telnet' && kind !== 'tcp' && !username.trim()) {
        fieldError('username', t('host.err.user'));
        return;
      }
      if (kind === 'telnet' || kind === 'tcp') {
        payload.username = '';
      } else {
        payload.username = username.trim();
      }
      payload.host = addr;
      payload.port = p;
      payload['auth-type'] = authType;
      payload['identity-file'] = identityFile.trim();
      payload['strict-host-key'] = strict;
      payload.jump = jump.trim();
      payload['startup-snippet'] = startupSnippet;
      payload['keep-alive'] = Number(keepAlive) || 0;
    }
    try {
      if (host) {
        await api.hostUpdate(host.id, payload);
        // The design contract: an open session keeps its old channel —
        // editing never silently retypes a live connection. Close the
        // panes bound to this host so the next connect uses the new
        // parameters.
        const stale = tabs
          .flatMap((tb) => tb.panes)
          .filter((p) => p.hostId === host.id);
        for (const p of stale) {
          void api.terminalClose(p.sessionId).catch(() => undefined);
        }
        useApp.setState({
          tabs: useApp
            .getState()
            .tabs.map((tb) => ({
              ...tb,
              panes: tb.panes.filter((p) => p.hostId !== host.id),
            }))
            .filter((tb) => tb.panes.length > 0),
        });
        if (stale.length) toast(t('host.saved-reconnect'));
      } else {
        await api.hostCreate(payload);
      }
      await refreshHosts();
      onClose();
    } catch (e) {
      setError(String(e));
    }
  };

  const remove = async () => {
    if (!host) return;
    if (!(await confirmDialog(t('common.confirm-delete'), { danger: true }))) return;
    try {
      await api.hostDelete(host.id);
      await refreshHosts();
      onClose();
    } catch (e) {
      setError(String(e));
    }
  };

  const isSSHFamily = connKind === 'ssh' || connKind === 'mosh';
  const isSerial = connKind === 'serial';
  const isPlainNetwork = NO_ENCRYPTION_KINDS.includes(connKind);

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <h2>{host ? t('host.edit') : t('host.new')}</h2>
        <div className="form-grid">
          <label>{t('host.kind')}</label>
          <select value={connKind} onChange={(e) => setKind(e.target.value)}>
            {KINDS.map((k) => (
              <option key={k.id} value={k.id}>
                {t(k.labelKey)}
              </option>
            ))}
          </select>
          <label>{t('host.label')}</label>
          <input
            value={label}
            onChange={(e) => setLabel(e.target.value)}
            className={errorField === 'label' ? 'invalid' : ''}
            autoFocus
          />
          <label>{t('hosts.group')}</label>
          <input value={groupName} onChange={(e) => setGroupName(e.target.value)} />

          {isSerial ? (
            <>
              <label>{t('host.device')}</label>
              <div className="row">
                <input
                  value={hostName}
                  onChange={(e) => setHostName(e.target.value)}
                  placeholder="/dev/ttyUSB0"
                  list="serial-ports"
                  className={errorField === 'host' ? 'invalid' : ''}
                />
                <datalist id="serial-ports">
                  {ports.map((p) => (
                    <option key={p.path} value={p.path}>
                      {p.label}
                    </option>
                  ))}
                </datalist>
                <button className="btn" onClick={() => {
                  void api
                    .serialPorts()
                    .then((r) => {
                      setPorts(r.ports.filter((p) => p.path));
                      toast(`${r.ports.length} · ${t('host.devices-refreshed')}`);
                    })
                    .catch(() => toast(t('host.devices-fail'), { error: true }));
                }}>
                  {t('host.refresh')}
                </button>
              </div>
              <label>{t('host.baud')}</label>
              <input
                type="number"
                value={port}
                onChange={(e) => setPort(e.target.value)}
                className={errorField === 'port' ? 'invalid' : ''}
              />
              <label>{t('host.databits')}</label>
              <select value={dataBits} onChange={(e) => setDataBits(e.target.value)}>
                {['5', '6', '7', '8'].map((b) => (
                  <option key={b} value={b}>{b}</option>
                ))}
              </select>
              <label>{t('host.parity')}</label>
              <select value={parity} onChange={(e) => setParity(e.target.value)}>
                <option value="none">none</option>
                <option value="even">even</option>
                <option value="odd">odd</option>
                <option value="mark">mark</option>
                <option value="space">space</option>
              </select>
              <label>{t('host.stopbits')}</label>
              <select value={stopBits} onChange={(e) => setStopBits(e.target.value)}>
                <option value="1">1</option>
                <option value="1.5">1.5</option>
                <option value="2">2</option>
              </select>
              <label>{t('host.flow')}</label>
              <select value={flowControl} onChange={(e) => setFlowControl(e.target.value)}>
                <option value="none">none</option>
                <option value="rtscts">RTS/CTS</option>
                <option value="xonxoff">XON/XOFF</option>
              </select>
              <label>{t('host.encoding')}</label>
              <select value={encoding} onChange={(e) => setEncoding(e.target.value)}>
                <option value="utf-8">UTF-8</option>
                <option value="ascii">ASCII</option>
              </select>
              <label>{t('host.lineending')}</label>
              <select value={lineEnding} onChange={(e) => setLineEnding(e.target.value)}>
                <option value="none">{t('host.ending.none')}</option>
                <option value="lf">LF</option>
                <option value="cr">CR</option>
                <option value="crlf">CRLF</option>
              </select>
            </>
          ) : connKind === 'local' ? (
            <>
              <label>{t('host.shell')}</label>
              <select value={shell} onChange={(e) => setShell(e.target.value)}>
                <option value="">{t('host.shell.default')}</option>
                <option value="bash">bash</option>
                <option value="zsh">zsh</option>
                <option value="powershell">PowerShell</option>
                <option value="cmd">cmd</option>
              </select>
              <label>{t('host.cwd')}</label>
              <input value={cwd} onChange={(e) => setCwd(e.target.value)} placeholder={t('host.cwd.placeholder')} />
            </>
          ) : connKind === 'adb' ? (
            <>
              <label>{t('host.serial')}</label>
              <input
                value={hostName}
                onChange={(e) => setHostName(e.target.value)}
                placeholder="DEMO-ADB-001"
                className={errorField === 'host' ? 'invalid' : ''}
              />
            </>
          ) : (
            <>
              <label>{t('host.host')}</label>
              <input
                value={hostName}
                onChange={(e) => setHostName(e.target.value)}
                placeholder={isSSHFamily ? 'IP / hostname' : 'IP / hostname'}
                className={errorField === 'host' ? 'invalid' : ''}
              />
              <label>{t('host.port')}</label>
              <input
                type="number"
                value={port}
                onChange={(e) => setPort(e.target.value)}
                className={errorField === 'port' ? 'invalid' : ''}
              />
              {isSSHFamily && (
                <>
                  <label>{t('host.username')}</label>
                  <input
                    value={username}
                    onChange={(e) => setUsername(e.target.value)}
                    className={errorField === 'username' ? 'invalid' : ''}
                  />
                  <label>{t('host.auth')}</label>
                  <select value={authType} onChange={(e) => setAuthType(e.target.value)}>
                    <option value="agent">{t('auth.agent')}</option>
                    <option value="password">{t('auth.password')}</option>
                    <option value="key">{t('auth.key')}</option>
                  </select>
                  {authType === 'key' && (
                    <>
                      <label>{t('host.identity')}</label>
                      <input
                        value={identityFile}
                        onChange={(e) => setIdentityFile(e.target.value)}
                        placeholder="~/.ssh/id_ed25519"
                      />
                    </>
                  )}
                  <label>{t('host.strict')}</label>
                  <select value={strict} onChange={(e) => setStrict(e.target.value)}>
                    <option value="accept-new">{t('host.strict.accept-new')}</option>
                    <option value="yes">{t('host.strict.yes')}</option>
                    <option value="no">{t('host.strict.no')}</option>
                  </select>
                  <label>{t('host.jump')}</label>
                  <input value={jump} onChange={(e) => setJump(e.target.value)} placeholder="bastion" />
                  <label>{t('host.startup')}</label>
                  <input value={startupSnippet} onChange={(e) => setStartupSnippet(e.target.value)} />
                  <label>{t('host.keepalive')}</label>
                  <input type="number" value={keepAlive} onChange={(e) => setKeepAlive(e.target.value)} placeholder="30" />
                </>
              )}
            </>
          )}

          {isPlainNetwork && (
            <div className="form-note" style={{ gridColumn: '1 / -1' }}>
              {t('host.no-encryption')}
            </div>
          )}
          {isSerial && (
            <div className="form-note" style={{ gridColumn: '1 / -1' }}>
              {t('host.serial-note')}
            </div>
          )}
          <label>{t('host.fontsize')}</label>
          <input
            type="number"
            value={fontSize}
            onChange={(e) => setFontSize(e.target.value)}
            placeholder="14"
          />
          {!isSerial && !connKind.startsWith('local') && connKind !== 'adb' && (
            <>
              <label>{t('host.notes')}</label>
              <textarea value={notes} onChange={(e) => setNotes(e.target.value)} rows={2} />
            </>
          )}
        </div>
        {error && (
          <p className="error" role="alert">
            {error}
          </p>
        )}
        <div className="modal-actions">
          {host && (
            <button className="btn btn-danger" onClick={() => void remove()}>
              {t('common.delete')}
            </button>
          )}
          {host && (
            <button className="btn" onClick={() => void duplicate()}>
              {t('host.duplicate')}
            </button>
          )}
          <span className="spacer" />
          <button className="btn" onClick={onClose}>
            {t('common.cancel')}
          </button>
          <button className="btn btn-primary" onClick={() => void save()}>
            {host ? t('common.save') : t('host.save-connect')}
          </button>
        </div>
      </div>
    </div>
  );
}

function clampInt(v: string, lo: number, hi: number): number | null {
  const n = Number(v);
  if (!Number.isInteger(n) || n < lo || n > hi) return null;
  return n;
}
