import { useState } from 'react';
import { api, type HostProfile } from '@termpilot/core';
import { useApp } from '../state/store';

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
  const [error, setError] = useState('');

  const save = async () => {
    if (!label.trim() || !hostName.trim()) {
      setError(t('common.save') + ': label/host');
      return;
    }
    const payload: Partial<HostProfile> = {
      label: label.trim(),
      host: hostName.trim(),
      port: Number(port) || 22,
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
    if (!window.confirm(t('common.confirm-delete'))) return;
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
          <label>{t('host.label')}</label>
          <input value={label} onChange={(e) => setLabel(e.target.value)} autoFocus />
          <label>{t('host.host')}</label>
          <input value={hostName} onChange={(e) => setHostName(e.target.value)} />
          <label>{t('host.port')}</label>
          <input type="number" value={port} onChange={(e) => setPort(e.target.value)} />
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
