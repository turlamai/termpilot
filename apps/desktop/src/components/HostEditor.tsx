import { useState } from 'react';
import { api, type HostProfile } from '@termpilot/core';
import { useApp } from '../state/store';
import { confirmDialog } from '../state/feedback';

interface HostEditorProps {
  host?: HostProfile; // present = edit mode
  onClose: () => void;
}

export default function HostEditor({ host, onClose }: HostEditorProps) {
  const refreshHosts = useApp((s) => s.refreshHosts);
  const t = useApp((s) => s.t);
  const [label, setLabel] = useState(host?.label ?? '');
  const [hostName, setHostName] = useState(host?.host ?? '');
  const [port, setPort] = useState(String(host?.port ?? 22));
  const [username, setUsername] = useState(host?.username ?? '');
  const [authType, setAuthType] = useState(host?.['auth-type'] ?? 'agent');
  const [identityFile, setIdentityFile] = useState(host?.['identity-file'] ?? '');
  const [groupName, setGroupName] = useState(host?.['group-name'] ?? '');
  const [tags, setTags] = useState((host?.tags ?? []).join(', '));
  const [notes, setNotes] = useState(host?.notes ?? '');
  const [strict, setStrict] = useState(host?.['strict-host-key'] ?? 'accept-new');
  const [jump, setJump] = useState(host?.jump ?? '');
  const [startupSnippet, setStartupSnippet] = useState(host?.['startup-snippet'] ?? '');
  const [keepAlive, setKeepAlive] = useState(String(host?.['keep-alive'] ?? 0));
  const [fontSize, setFontSize] = useState(String(host?.['font-size'] ?? 0));
  const [connKind, setConnKind] = useState(host?.['connection-kind'] ?? 'ssh');
  const [baud, setBaud] = useState('115200');
  const [parity, setParity] = useState('none');
  const [stopBits, setStopBits] = useState('1');
  const [error, setError] = useState('');

  // Duplicate: create a copy named "<label> (copy)" without closing.
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

  const save = async () => {
    if (!label.trim() || !hostName.trim()) {
      setError(t('common.save') + ': label/host');
      return;
    }
    const payload: Partial<HostProfile> = {
      label: label.trim(),
      host: hostName.trim(),
      username: username.trim(),
      'auth-type': authType,
      'identity-file': identityFile.trim(),
      'group-name': groupName.trim(),
      tags: tags
        .split(',')
        .map((x) => x.trim())
        .filter(Boolean),
      notes,
      'strict-host-key': strict,
      jump: jump.trim(),
      'startup-snippet': startupSnippet,
      'keep-alive': Number(keepAlive) || 0,
      'font-size': Number(fontSize) || 0,
      'connection-kind': connKind,
      // serial line params ride the host form; for serial, the port
      // column holds the line speed (the profile's "port" is the baud)
      ...(connKind === 'serial'
        ? { port: Number(baud) || 115200, parity, stopbits: Number(stopBits) || 1 }
        : { port: Number(port) || 22 }),
    };
    try {
      if (host) {
        await api.hostUpdate(host.id, payload);
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

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <h2>{host ? t('host.edit') : t('host.new')}</h2>
        <div className="form-grid">
          <label>{t('host.kind')}</label>
          <select value={connKind} onChange={(e) => setConnKind(e.target.value)}>
            <option value="ssh">SSH</option>
            <option value="telnet">Telnet</option>
            <option value="mosh">Mosh</option>
            <option value="serial">Serial</option>
          </select>
          <label>{t('host.label')}</label>
          <input value={label} onChange={(e) => setLabel(e.target.value)} autoFocus />
          <label>{connKind === 'serial' ? t('host.device') : t('host.host')}</label>
          <input
            value={hostName}
            onChange={(e) => setHostName(e.target.value)}
            placeholder={connKind === 'serial' ? '/dev/ttyUSB0' : ''}
          />
          {connKind === 'serial' ? (
            <>
              <label>{t('host.baud')}</label>
              <select value={baud} onChange={(e) => setBaud(e.target.value)}>
                {['1200', '2400', '4800', '9600', '19200', '38400', '57600', '115200', '230400'].map((b) => (
                  <option key={b} value={b}>{b}</option>
                ))}
              </select>
              <label>{t('host.parity')}</label>
              <select value={parity} onChange={(e) => setParity(e.target.value)}>
                <option value="none">none</option>
                <option value="even">even</option>
                <option value="odd">odd</option>
              </select>
              <label>{t('host.stopbits')}</label>
              <select value={stopBits} onChange={(e) => setStopBits(e.target.value)}>
                <option value="1">1</option>
                <option value="2">2</option>
              </select>
            </>
          ) : (
            <>
              <label>{t('host.port')}</label>
              <input type="number" value={port} onChange={(e) => setPort(e.target.value)} />
            </>
          )}
          <label>{t('host.username')}</label>
          <input value={username} onChange={(e) => setUsername(e.target.value)} />
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
          <label>{t('hosts.group')}</label>
          <input value={groupName} onChange={(e) => setGroupName(e.target.value)} />
          <label>Tags</label>
          <input
            value={tags}
            onChange={(e) => setTags(e.target.value)}
            placeholder="prod, web"
          />
          <label>{t('host.strict')}</label>
          <select value={strict} onChange={(e) => setStrict(e.target.value)}>
            <option value="accept-new">{t('host.strict.accept-new')}</option>
            <option value="yes">{t('host.strict.yes')}</option>
            <option value="no">{t('host.strict.no')}</option>
          </select>
          <label>{t('host.jump')}</label>
          <input
            value={jump}
            onChange={(e) => setJump(e.target.value)}
            placeholder="bastion"
          />
          <label>{t('host.startup')}</label>
          <input
            value={startupSnippet}
            onChange={(e) => setStartupSnippet(e.target.value)}
          />
          <label>{t('host.keepalive')}</label>
          <input
            type="number"
            value={keepAlive}
            onChange={(e) => setKeepAlive(e.target.value)}
            placeholder="30"
          />
          <label>{t('host.fontsize')}</label>
          <input
            type="number"
            value={fontSize}
            onChange={(e) => setFontSize(e.target.value)}
            placeholder="13"
          />
          <label>{t('host.notes')}</label>
          <textarea value={notes} onChange={(e) => setNotes(e.target.value)} rows={2} />
        </div>
        {error && <p className="error">{error}</p>}
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
            {t('common.save')}
          </button>
        </div>
      </div>
    </div>
  );
}
