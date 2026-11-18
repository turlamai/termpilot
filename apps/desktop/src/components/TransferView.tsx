// Transfer view: the seven-protocol transfer surface from the embedded
// workspace contract. SFTP keeps the interactive directory browser;
// SCP / X-Y-ZMODEM / TFTP / ADB run as staged queue jobs — target,
// direction, path and file are confirmed before anything starts, and
// the queue shows honest states (running / done / failed / cancelled)
// from the backend job registry. Upload bytes stay in view memory so
// retry can re-stage them; nothing is faked to look like progress.

import { useEffect, useRef, useState } from 'react';
import { api, type TransferJob, type HostProfile } from '@termpilot/core';
import { useApp } from '../state/store';
import { toast } from '../state/feedback';
import SftpBrowser from './SftpBrowser';

const MODES = ['SFTP', 'SCP', 'XMODEM', 'YMODEM', 'ZMODEM', 'TFTP', 'ADB'] as const;
type Mode = (typeof MODES)[number];

const SERIAL_MODES: Mode[] = ['XMODEM', 'YMODEM', 'ZMODEM'];

// Protocol → compatible target kinds, mirroring the design contract:
// serial protocols bind serial profiles, ADB binds ADB, SFTP/SCP bind
// SSH-class connections, TFTP any plain network endpoint.
function validTargets(mode: Mode, hosts: HostProfile[]): HostProfile[] {
  const kindOf = (h: HostProfile) => h['connection-kind'] ?? 'ssh';
  if (SERIAL_MODES.includes(mode)) return hosts.filter((h) => kindOf(h) === 'serial');
  if (mode === 'ADB') return hosts.filter((h) => kindOf(h) === 'adb');
  if (mode === 'SFTP' || mode === 'SCP') return hosts.filter((h) => ['ssh', 'mosh'].includes(kindOf(h)));
  return hosts.filter((h) => ['ssh', 'telnet', 'tcp'].includes(kindOf(h)));
}

const MODE_HELP: Record<Mode, { zh: string; en: string }> = {
  SFTP: {
    zh: '通过 SSH 管理目录，支持权限编辑与双向传输。',
    en: 'Manage directories over SSH with permission edits and two-way transfer.',
  },
  SCP: {
    zh: '按明确源路径与目标路径复制，目标需提供相应 SSH / SCP 能力。',
    en: 'Copies by explicit source and target path; the target needs SSH/SCP.',
  },
  XMODEM: {
    zh: '目标先进入接收状态，再开始串口传输；不携带文件名。',
    en: 'The target must enter receive mode first; no filename is carried.',
  },
  YMODEM: {
    zh: '常用于 Bootloader，目标需先启动 YMODEM 接收。',
    en: 'Common with bootloaders; start YMODEM receive on the target first.',
  },
  ZMODEM: {
    zh: '双方需具备相容的 sz / rz 能力，并使用原始数据通道。',
    en: 'Both ends need compatible sz/rz over a raw data channel.',
  },
  TFTP: {
    zh: '仅在可信实验网络使用；目标需具备 TFTP 客户端或服务端。',
    en: 'Trusted lab networks only; the target needs a TFTP client/server.',
  },
  ADB: {
    zh: '依赖 Android Platform Tools 与设备授权。',
    en: 'Depends on Android Platform Tools and device authorization.',
  },
};

interface Staged {
  mode: Mode;
  hostId: string;
  direction: 'upload' | 'download';
  path: string;
  name: string;
  bytes: Uint8Array | null;
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

export default function TransferView() {
  const hosts = useApp((s) => s.hosts);
  const lang = useApp((s) => s.lang);
  const t = useApp((s) => s.t);
  const [mode, setMode] = useState<Mode>('SFTP');
  const [hostId, setHostId] = useState('');
  const [direction, setDirection] = useState<'upload' | 'download'>('upload');
  const [path, setPath] = useState('/');
  const [staged, setStaged] = useState<Staged | null>(null);
  const [jobs, setJobs] = useState<TransferJob[]>([]);
  const [error] = useState('');
  // Upload bytes live here between stage and start / retry; never
  // logged, never displayed, dropped when the view unmounts.
  const stagedBytes = useRef<Map<string, Uint8Array>>(new Map());
  const fetched = useRef<Set<string>>(new Set());
  const jobsRef = useRef<TransferJob[]>([]);

  const targets = validTargets(mode, hosts);
  useEffect(() => {
    if (!targets.some((h) => h.id === hostId)) setHostId(targets[0]?.id ?? '');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode, hosts]);

  const refresh = async () => {
    try {
      const r = await api.transferStatus();
      setJobs(r.jobs);
      jobsRef.current = r.jobs;
      // Finished downloads land as a real file save; fetched once.
      for (const j of r.jobs) {
        if (j.status === 'done' && j.direction === 'download' && !fetched.current.has(j.id)) {
          fetched.current.add(j.id);
          try {
            const b64 = await api.transferResult(j.id);
            saveBase64As(j.name.endsWith('.zip') ? j.name : `dl-${j.name}`, b64);
          } catch {
            toast(t('transfer.result-gone'), { error: true });
          }
        }
      }
    } catch {
      // status is best-effort (backend absent in vite-only dev)
    }
  };

  // Poll the queue while the view lives (the registry view is cheap).
  useEffect(() => {
    void refresh();
    const iv = setInterval(() => void refresh(), 1000);
    return () => clearInterval(iv);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const prepare = (file?: File, downloadName?: string) => {
    if (!hostId) {
      toast(t('transfer.err.no-target'), { error: true });
      return;
    }
    const isSerial = SERIAL_MODES.includes(mode);
    setStaged({
      mode,
      hostId,
      direction,
      path: isSerial ? t('transfer.serial-stream') : path || '/',
      name: file ? file.name : downloadName || 'firmware.bin',
      bytes: file ? null : null,
    });
    if (file) {
      // Read once at stage time; retry reuses the same bytes.
      void file.arrayBuffer().then((buf) => {
        stagedBytes.current.set('pending', new Uint8Array(buf));
      });
    }
  };

  const startStaged = async () => {
    if (!staged) return;
    const bytes = stagedBytes.current.get('pending') ?? undefined;
    try {
      await api.transferStart({
        mode: staged.mode.toLowerCase(),
        direction: staged.direction,
        'host-id': staged.hostId,
        'remote-path': staged.path,
        name: staged.name,
        ...(bytes ? { data: bytes } : {}),
      });
      if (bytes) stagedBytes.current.set('last', bytes);
      stagedBytes.current.delete('pending');
      setStaged(null);
      void refresh();
    } catch (e) {
      toast(String(e).slice(0, 160), { error: true });
    }
  };

  const cancel = async (id: string) => {
    try {
      await api.transferCancel(id);
      void refresh();
    } catch (e) {
      toast(String(e).slice(0, 140), { error: true });
    }
  };

  const retry = async (j: TransferJob) => {
    try {
      const bytes = stagedBytes.current.get('last');
      await api.transferRetry(j.id, j.direction === 'upload' ? bytes : undefined);
      fetched.current.delete(j.id);
      void refresh();
    } catch (e) {
      toast(String(e).slice(0, 140), { error: true });
    }
  };

  const help = MODE_HELP[mode][lang];

  return (
    <div className="sidebar-view">
      <div className="protocol-rail" role="group" aria-label={t('transfer.mode')}>
        {MODES.map((m) => (
          <button
            key={m}
            className={`chip ${mode === m ? 'active' : ''}`}
            onClick={() => setMode(m)}
          >
            {m}
          </button>
        ))}
      </div>
      <p className="hint">{help}</p>

      {mode === 'SFTP' ? (
        <SftpBrowser />
      ) : (
        <>
          <div className="row">
            <select value={hostId} onChange={(e) => setHostId(e.target.value)}>
              <option value="">{t('transfer.target')}…</option>
              {targets.map((h) => (
                <option key={h.id} value={h.id}>
                  {h.label}
                </option>
              ))}
            </select>
            <select
              value={direction}
              onChange={(e) => setDirection(e.target.value as 'upload' | 'download')}
            >
              <option value="upload">{t('transfer.upload')}</option>
              <option value="download">{t('transfer.download')}</option>
            </select>
          </div>
          {!SERIAL_MODES.includes(mode) && (
            <input
              className="search"
              placeholder={t('transfer.path')}
              value={path}
              onChange={(e) => setPath(e.target.value)}
            />
          )}
          {SERIAL_MODES.includes(mode) && (
            <p className="hint">{t('transfer.receiver-ready')}</p>
          )}
          <div className="sidebar-actions">
            {direction === 'upload' ? (
              <label className={`btn btn-primary btn-block ${hostId ? '' : 'disabled'}`}>
                ⬆ {t('transfer.prepare')}
                <input
                  type="file"
                  style={{ display: 'none' }}
                  onChange={(e) => {
                    const f = e.target.files?.[0];
                    if (f) prepare(f);
                    e.target.value = '';
                  }}
                />
              </label>
            ) : (
              <button
                className="btn btn-primary btn-block"
                disabled={!hostId}
                onClick={() => prepare(undefined, 'firmware.bin')}
              >
                ⤓ {t('transfer.prepare')}
              </button>
            )}
          </div>
        </>
      )}

      <div className="sidebar-scroll">
        <div className="group-title">{t('transfer.queue')}</div>
        {jobs.map((j) => (
          <div key={j.id} className="snippet-row">
            <div className="snippet-body">
              <span className="host-label">
                {j.name}
                <span className="kind-badge">{j.mode}</span>
                <span className={`kind-badge status-${j.status}`}>{t(`transfer.status.${j.status}`)}</span>
              </span>
              <span className="host-addr">
                {j.direction} · {j.target} · {j.path}
              </span>
              {j.detail && <code className="snippet-cmd">{j.detail}</code>}
            </div>
            <div className="snippet-actions">
              {j.status === 'running' ? (
                <button className="btn-icon" title={t('transfer.cancel')} onClick={() => void cancel(j.id)}>
                  ✕
                </button>
              ) : j.status === 'failed' || j.status === 'cancelled' ? (
                <button className="btn-icon" title={t('transfer.retry')} onClick={() => void retry(j)}>
                  ↻
                </button>
              ) : null}
            </div>
          </div>
        ))}
        {jobs.length === 0 && <p className="hint">{t('transfer.queue.empty')}</p>}
      </div>
      {error && <p className="error">{error}</p>}

      {staged && (
        <div className="modal-backdrop" onClick={() => setStaged(null)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <h2>{t('transfer.prepare.title')}</h2>
            <p className="hint">
              {staged.mode} · {staged.direction === 'upload' ? t('transfer.upload') : t('transfer.download')} ·{' '}
              {hosts.find((h) => h.id === staged.hostId)?.label} · {staged.path}
            </p>
            {staged.direction === 'download' && (
              <div className="inline-form">
                <FileNameInput initial={staged.name} onChange={(v) => setStaged({ ...staged, name: v })} />
              </div>
            )}
            <label className="check">
              <input type="checkbox" id="receiver-ready" />
              {SERIAL_MODES.includes(staged.mode)
                ? t('transfer.ready.serial')
                : t('transfer.ready.plain')}
            </label>
            <div className="modal-actions">
              <span className="spacer" />
              <button className="btn" onClick={() => setStaged(null)}>
                {t('common.cancel')}
              </button>
              <button
                className="btn btn-primary"
                onClick={() => {
                  const ready = (document.getElementById('receiver-ready') as HTMLInputElement)?.checked;
                  if (!ready) {
                    toast(t('transfer.err.not-ready'), { error: true });
                    return;
                  }
                  if (/[\\/]/.test(staged.name)) {
                    toast(t('transfer.err.name'), { error: true });
                    return;
                  }
                  void startStaged();
                }}
              >
                {t('transfer.start')}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function FileNameInput({ initial, onChange }: { initial: string; onChange: (v: string) => void }) {
  const [v, setV] = useState(initial);
  return (
    <input
      className="search"
      value={v}
      onChange={(e) => {
        setV(e.target.value);
        onChange(e.target.value);
      }}
      placeholder="firmware.bin"
      autoFocus
    />
  );
}
