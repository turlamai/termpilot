import { useEffect, useState } from 'react';
import { api } from '@termpilot/core';
import { useApp } from '../state/store';
import { toast } from '../state/feedback';
import { confirmDialog } from '../state/feedback';

interface SftpEntry {
  name: string;
  dir: boolean;
  size: number | null;
  perms: string;
}

// Blob download helper: base64 (GBytes wire) -> binary blob link.
function saveBase64As(name: string, b64: string) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const url = URL.createObjectURL(new Blob([bytes]));
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  a.click();
  URL.revokeObjectURL(url);
}

export default function SftpView() {
  const hosts = useApp((s) => s.hosts);
  const t = useApp((s) => s.t);
  const [hostId, setHostId] = useState('');
  const [cwd, setCwd] = useState('.');
  const [entries, setEntries] = useState<SftpEntry[]>([]);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [uploadCwd, setUploadCwd] = useState('');

  useEffect(() => {
    if (hosts.length > 0 && !hostId) setHostId(hosts[0].id);
  }, [hosts, hostId]);

  const load = async (path: string) => {
    if (!hostId) return;
    setBusy(true);
    setError('');
    try {
      const r = await api.sftpList(hostId, path);
      setEntries(r.entries);
      setCwd(path);
      setUploadCwd(path);
    } catch (e) {
      setError(String(e).slice(0, 160));
    }
    setBusy(false);
  };

  const fmtSize = (n: number | null) =>
    n === null || n === undefined
      ? ''
      : n > 1048576
        ? `${(n / 1048576).toFixed(1)}M`
        : n > 1024
          ? `${(n / 1024).toFixed(0)}K`
          : `${n}B`;

  const download = async (e: SftpEntry) => {
    const path = cwd === '.' ? e.name : `${cwd}/${e.name}`;
    setBusy(true);
    try {
      const b64 = await api.sftpDownload(hostId, path);
      saveBase64As(e.name, b64);
    } catch (err) {
      setError(String(err).slice(0, 160));
    }
    setBusy(false);
  };

  const upload = async (file: File) => {
    if (!file) return;
    const path = uploadCwd === '.' ? file.name : `${uploadCwd}/${file.name}`;
    setBusy(true);
    try {
      const bytes = new Uint8Array(await file.arrayBuffer());
      await api.sftpUpload(hostId, path, bytes);
      await load(uploadCwd);
    } catch (err) {
      setError(String(err).slice(0, 160));
    }
    setBusy(false);
  };

  const uploadFiles = async (files: FileList) => {
    for (const file of Array.from(files)) {
      try {
        const path = cwd === '.' ? file.name : `${cwd}/${file.name}`;
        const bytes = new Uint8Array(await file.arrayBuffer());
        await api.sftpUpload(hostId, path, bytes);
      } catch (err) {
        toast(`${file.name}: ${String(err).slice(0, 100)}`, { error: true });
      }
    }
    await load(cwd);
  };

  return (
    <div
      className="sidebar-view sftp-dropzone"
      onDragOver={(e) => {
        if (hostId && uploadCwd) e.preventDefault();
      }}
      onDrop={(e) => {
        if (!hostId || !uploadCwd || e.dataTransfer.files.length === 0) return;
        e.preventDefault();
        void uploadFiles(e.dataTransfer.files);
      }}
    >
      <div className="row">
        <select value={hostId} onChange={(e) => { setHostId(e.target.value); setCwd('.'); }}>
          <option value="">{t('view.hosts')}…</option>
          {hosts.map((h) => (
            <option key={h.id} value={h.id}>{h.label}</option>
          ))}
        </select>
        <code className="sftp-cwd">{cwd}</code>
      </div>
      <div className="sidebar-scroll">
        {entries.map((e) => (
          <div key={e.name} className="snippet-row">
            <div className="snippet-body">
              <button
                className="host-btn"
                onClick={() =>
                  e.dir ? void load(cwd === '.' ? e.name : `${cwd}/${e.name}`) : void download(e)
                }
              >
                <span className="host-label">{e.dir ? '📁' : '📄'} {e.name}</span>
                <span className="host-addr">{e.perms} · {fmtSize(e.size)}</span>
              </button>
            </div>
            <div className="snippet-actions">
              <button
                className="btn-icon"
                title={t('common.delete')}
                onClick={async () => {
                  if (!(await confirmDialog(t('common.confirm-delete'), { danger: true }))) return;
                  const path = cwd === '.' ? e.name : `${cwd}/${e.name}`;
                  try {
                    if (e.dir) await api.sftpRmdir(hostId, path);
                    else await api.sftpDelete(hostId, path);
                    await load(cwd);
                  } catch (err) {
                    setError(String(err).slice(0, 160));
                  }
                }}
              >
                ✕
              </button>
            </div>
          </div>
        ))}
        {entries.length === 0 && !busy && (
          <p className="hint">{hostId ? t('sftp.empty') : t('sftp.placeholder')}</p>
        )}
        {error && <p className="error">{error}</p>}
      </div>
      <div className="sidebar-actions">
        <div className="row">
          <button
            className="btn"
            disabled={!hostId || cwd === '.'}
            onClick={() => void load(cwd.split('/').slice(0, -1).join('/') || '.')}
          >
            ⬆
          </button>
          <button
            className="btn"
            disabled={!hostId}
            onClick={async () => {
              const name = window.prompt(t('sftp.mkdir'), 'new-dir');
              if (!name) return;
              const path = cwd === '.' ? name : `${cwd}/${name}`;
              try {
                await api.sftpMkdir(hostId, path);
                await load(cwd);
              } catch (err) {
                setError(String(err).slice(0, 160));
              }
            }}
          >
            ＋📁
          </button>
          <label className={`btn ${hostId && uploadCwd ? '' : 'disabled'}`}>
            ⬆ {t('sftp.upload')}
            <input
              type="file"
              style={{ display: 'none' }}
              onChange={(e) => {
                const f = e.target.files?.[0];
                if (f) void upload(f);
                e.target.value = '';
              }}
            />
          </label>
        </div>
      </div>
    </div>
  );
}
