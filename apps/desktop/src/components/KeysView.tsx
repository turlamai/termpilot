import { useEffect, useState } from 'react';
import { api } from '@termpilot/core';
import { useApp } from '../state/store';

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
  const [keys, setKeys] = useState<KeyEntry[]>([]);
  const [meta, setMeta] = useState<Record<string, KeyMeta>>({});
  const [pubOf, setPubOf] = useState<{ name: string; public: string } | null>(null);
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState('');
  const [type, setType] = useState('ed25519');
  const [passphrase, setPassphrase] = useState('');
  const [error, setError] = useState('');

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
    if (!window.confirm(`${t('common.confirm-delete')} (${name})`)) return;
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
              <button className="btn-icon" title={t('common.delete')} onClick={() => void remove(k.name)}>
                ✕
              </button>
            </div>
          </div>
        ))}
        {keys.length === 0 && <p className="hint">{t('keys.placeholder')}</p>}
        {error && <p className="error">{error}</p>}
      </div>

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

      <div className="sidebar-actions">
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
