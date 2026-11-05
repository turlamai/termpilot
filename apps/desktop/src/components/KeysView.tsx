import { useEffect, useState } from 'react';
import { api } from '@termpilot/core';
import { useApp } from '../state/store';
import { confirmDialog } from '../state/feedback';
import { Icon } from './Icon';

interface KeyEntry {
  name: string;
  'has-public': boolean;
  permissions: string;
  bytes: number;
}

interface KeyMeta {
  bits: string;
  fingerprint: string;
  comment: string;
  type: string;
}

export default function KeysView() {
  const t = useApp((s) => s.t);
  const hosts = useApp((s) => s.hosts);
  const refreshHosts = useApp((s) => s.refreshHosts);
  const [keys, setKeys] = useState<KeyEntry[]>([]);
  const [meta, setMeta] = useState<Record<string, KeyMeta>>({});
  const [pubOf, setPubOf] = useState<{ name: string; public: string } | null>(null);
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState('');
  const [type, setType] = useState('ed25519');
  const [passphrase, setPassphrase] = useState('');
  const [error, setError] = useState('');
  const [importing, setImporting] = useState(false);
  const [importName, setImportName] = useState('');
  const [importContent, setImportContent] = useState('');
  const [distributing, setDistributing] = useState<string | null>(null);
  const [distMsg, setDistMsg] = useState('');

  useEffect(() => {
    void refreshHosts();
  }, [refreshHosts]);

  const doImport = async () => {
    if (!importName.trim() || !importContent.trim()) return;
    setError('');
    try {
      await api.keyImport(importName.trim(), importContent);
      setImporting(false);
      setImportName('');
      setImportContent('');
      await refresh();
    } catch (e) {
      setError(String(e).slice(0, 160));
    }
  };

  const distribute = async (keyName: string, hostId: string) => {
    setDistMsg('');
    try {
      const r = await api.keyDistribute(keyName, hostId);
      setDistMsg(r.ok ? `${t('keys.distribute.ok')}: ${r.host}` : `${t('keys.distribute.fail')}: ${r.output.slice(0, 100)}`);
      setDistributing(null);
    } catch (e) {
      setDistMsg(`${t('keys.distribute.fail')}: ${String(e).slice(0, 100)}`);
      setDistributing(null);
    }
  };

  const refresh = async () => {
    const { keys: list } = await api.keysList();
    setKeys(list);
  };

  useEffect(() => {
    void refresh();
  }, []);

  const showMeta = async (name: string) => {
    try {
      const m = await api.keyMeta(name);
      setMeta((prev) => ({ ...prev, [name]: m as never }));
    } catch (e) {
      setError(String(e).slice(0, 140));
    }
  };

  const showPublic = async (name: string) => {
    try {
      setPubOf(await api.keyPublic(name));
    } catch (e) {
      setError(String(e).slice(0, 140));
    }
  };

  const generate = async () => {
    if (!name.trim()) return;
    setError('');
    try {
      await api.keyGenerate(name.trim(), type, passphrase);
      setCreating(false);
      setName('');
      setPassphrase('');
      await refresh();
    } catch (e) {
      setError(String(e).slice(0, 140));
    }
  };

  const remove = async (name: string) => {
    if (!(await confirmDialog(`${t('common.confirm-delete')} (${name})`, { danger: true }))) return;
    try {
      await api.keyDelete(name);
      await refresh();
    } catch (e) {
      setError(String(e).slice(0, 140));
    }
  };

  return (
    <div className="sidebar-view">
      <div className="sidebar-scroll">
        {keys.map((k) => (
          <div key={k.name} className="snippet-row">
            <div className="snippet-body">
              <span className="host-label">🔑 {k.name}</span>
              <code className="snippet-cmd">
                {k.permissions} · {k.bytes}B
                {meta[k.name]
                  ? ` · ${meta[k.name].type} ${meta[k.name].bits} · ${meta[k.name].fingerprint.slice(0, 20)}…`
                  : ''}
              </code>
            </div>
            <div className="snippet-actions">
              {!meta[k.name] && (
                <button className="btn-icon" title="fingerprint" onClick={() => void showMeta(k.name)}>
                  ℹ
                </button>
              )}
              {k['has-public'] && (
                <button
                  className="btn-icon"
                  title="public key"
                  onClick={() => void showPublic(k.name)}
                >
                  🔗
                </button>
              )}
              <button
                className="btn-icon"
                title={t('keys.distribute')}
                onClick={() => setDistributing(k.name)}
              >
                <Icon name="arrow-right-left" size={13} />
              </button>
              <button className="btn-icon" title={t('common.delete')} onClick={() => void remove(k.name)}>
                <Icon name="x" size={13} />
              </button>
            </div>
          </div>
        ))}
        {keys.length === 0 && <p className="hint">{t('keys.placeholder')}</p>}
        {error && <p className="error">{error}</p>}
      </div>

      {importing && (
        <div className="modal-backdrop" onClick={() => setImporting(false)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <h2>{t('keys.import')}</h2>
            <div className="form-grid">
              <label>{t('keys.import.name')}</label>
              <input value={importName} onChange={(e) => setImportName(e.target.value)} placeholder="id_rsa" autoFocus />
              <label>{t('keys.import.content')}</label>
              <textarea
                value={importContent}
                onChange={(e) => setImportContent(e.target.value)}
                rows={6}
                placeholder="-----BEGIN OPENSSH PRIVATE KEY-----"
              />
            </div>
            <div className="modal-actions">
              <span className="spacer" />
              <button className="btn" onClick={() => setImporting(false)}>
                {t('common.cancel')}
              </button>
              <button className="btn btn-primary" onClick={() => void doImport()}>
                {t('common.save')}
              </button>
            </div>
          </div>
        </div>
      )}

      {pubOf && (
        <div className="modal-backdrop" onClick={() => setPubOf(null)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <h2>{pubOf.name} — public key</h2>
            <code className="pub-key">{pubOf.public}</code>
            <div className="modal-actions">
              <button
                className="btn btn-primary"
                onClick={() => void navigator.clipboard.writeText(pubOf.public)}
              >
                {t('ai.copy')}
              </button>
              <span className="spacer" />
              <button className="btn" onClick={() => setPubOf(null)}>
                {t('common.cancel')}
              </button>
            </div>
          </div>
        </div>
      )}

      {distMsg && <p className="hint">{distMsg}</p>}
      {distributing && (
        <div className="modal-backdrop" onClick={() => setDistributing(null)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <h2>{t('keys.distribute')}</h2>
            <div className="picker-list">
              {hosts.map((h) => (
                <button
                  key={h.id}
                  className="picker-row"
                  onClick={() => void distribute(distributing, h.id)}
                >
                  {h.label}
                </button>
              ))}
              {hosts.length === 0 && <p className="hint">{t('hosts.empty')}</p>}
            </div>
          </div>
        </div>
      )}
      <div className="sidebar-actions">
        <button className="btn btn-block" onClick={() => setImporting(true)}>
          {t('keys.import')}
        </button>
        {!creating ? (
          <button className="btn btn-primary btn-block" onClick={() => setCreating(true)}>
            ＋ {t('keys.generate')}
          </button>
        ) : (
          <div className="inline-form">
            <input placeholder={t('keys.name')} value={name} onChange={(e) => setName(e.target.value)} autoFocus />
            <select value={type} onChange={(e) => setType(e.target.value)}>
              <option value="ed25519">Ed25519</option>
              <option value="ecdsa">ECDSA</option>
              <option value="rsa">RSA</option>
            </select>
            <input
              type="password"
              placeholder={t('keys.passphrase')}
              value={passphrase}
              onChange={(e) => setPassphrase(e.target.value)}
            />
            <div className="row">
              <button className="btn btn-primary" onClick={() => void generate()}>
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
