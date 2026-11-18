// External debug tools view: GDB / OpenOCD / ADB launch flows from the
// embedded-workspace contract. The exact parameter array is previewed
// and confirmed before launch — nothing is concatenated into a shell
// string — and a launched tool is an ordinary session (stream, input,
// logging, close all reuse the terminal routes). OpenOCD extras: the
// telnet console and the RTT port open as plain TCP sessions with an
// editable port (9090 is only the conventional default — it must match
// the external service config).

import { useState } from 'react';
import { api, type ToolConfig } from '@termpilot/core';
import { useApp } from '../state/store';
import { toast } from '../state/feedback';

type Tool = 'gdb' | 'openocd' | 'adb';

interface Preview {
  tool: string;
  executable: string;
  args: string[];
}

export default function ToolsView() {
  const t = useApp((s) => s.t);
  const openSession = useApp((s) => s.openSession);
  const setView = useApp((s) => s.setView);
  const [tool, setTool] = useState<Tool>('gdb');
  const [exe, setExe] = useState({ gdb: 'arm-none-eabi-gdb', openocd: 'openocd', adb: 'adb' });
  const [elf, setElf] = useState('build/firmware.elf');
  const [target, setTarget] = useState('127.0.0.1:3333');
  const [adapter, setAdapter] = useState('interface/cmsis-dap.cfg');
  const [board, setBoard] = useState('target/stm32f4x.cfg');
  const [serial, setSerial] = useState('');
  const [rttPort, setRttPort] = useState('9090');
  const [preview, setPreview] = useState<Preview | null>(null);

  const config = (): ToolConfig => {
    if (tool === 'gdb')
      return { tool, executable: exe.gdb, elf, target };
    if (tool === 'openocd')
      return { tool, executable: exe.openocd, adapter, board };
    return { tool, executable: exe.adb, serial: serial.trim() };
  };

  const doPreview = async () => {
    try {
      setPreview(await api.toolsPreview(config()));
    } catch (e) {
      toast(String(e).slice(0, 160), { error: true });
    }
  };

  const launch = async (cfg?: ToolConfig) => {
    // Launch opens a real tool session; attach it as a workspace tab.
    const body = cfg ?? config();
    try {
      const session = await api.toolsStart(body);
      useApp.getState().attachSession(session);
      toast(`${t('tools.started')}: ${session.label}`);
    } catch (e) {
      toast(String(e).slice(0, 160), { error: true });
    }
  };

  // OpenOCD console / RTT: plain TCP sessions on loopback.
  const openTcp = async (port: number, label: string) => {
    try {
      await openSession({ kind: 'tcp', host: '127.0.0.1', port, label });
    } catch (e) {
      toast(String(e).slice(0, 160), { error: true });
    }
  };

  return (
    <div className="sidebar-view">
      <div className="protocol-rail" role="group" aria-label={t('tools.pick')}>
        {(['gdb', 'openocd', 'adb'] as Tool[]).map((tl) => (
          <button
            key={tl}
            className={`chip ${tool === tl ? 'active' : ''}`}
            onClick={() => setTool(tl)}
          >
            {tl.toUpperCase()}
          </button>
        ))}
      </div>
      <p className="hint">{t('tools.privacy')}</p>

      <div className="inline-form">
        <label className="mini">
          {t('tools.exe')}
          <input
            value={exe[tool]}
            onChange={(e) => setExe({ ...exe, [tool]: e.target.value })}
            spellCheck={false}
          />
        </label>
        {tool === 'gdb' && (
          <>
            <label className="mini">
              {t('tools.elf')}
              <input value={elf} onChange={(e) => setElf(e.target.value)} spellCheck={false} />
            </label>
            <label className="mini">
              {t('tools.target')}
              <input value={target} onChange={(e) => setTarget(e.target.value)} spellCheck={false} />
            </label>
          </>
        )}
        {tool === 'openocd' && (
          <>
            <label className="mini">
              {t('tools.adapter')}
              <input value={adapter} onChange={(e) => setAdapter(e.target.value)} spellCheck={false} />
            </label>
            <label className="mini">
              {t('tools.board')}
              <input value={board} onChange={(e) => setBoard(e.target.value)} spellCheck={false} />
            </label>
          </>
        )}
        {tool === 'adb' && (
          <label className="mini">
            {t('tools.serial')}
            <input
              value={serial}
              onChange={(e) => setSerial(e.target.value)}
              placeholder="DEMO-ADB-001"
              spellCheck={false}
            />
          </label>
        )}
      </div>

      <div className="sidebar-actions">
        <button className="btn btn-primary btn-block" onClick={() => void doPreview()}>
          {t('tools.preview')}
        </button>
        {tool === 'openocd' && (
          <>
            <button className="btn btn-block" onClick={() => void openTcp(4444, 'OpenOCD telnet')}>
              {t('tools.console')}
            </button>
            <div className="row">
              <input
                className="search"
                type="number"
                value={rttPort}
                onChange={(e) => setRttPort(e.target.value)}
                aria-label={t('tools.rtt-port')}
              />
              <button
                className="btn btn-block"
                onClick={() => {
                  const p = Number(rttPort);
                  if (!Number.isInteger(p) || p < 1 || p > 65535) {
                    toast(t('host.err.port'), { error: true });
                    return;
                  }
                  void openTcp(p, `RTT :${p}`);
                }}
              >
                {t('tools.rtt')}
              </button>
            </div>
          </>
        )}
        {tool === 'adb' && (
          <button
            className="btn btn-block"
            onClick={() => setView('sftp')}
          >
            {t('tools.adb-files')}
          </button>
        )}
      </div>

      {preview && (
        <div className="modal-backdrop" onClick={() => setPreview(null)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <h2>{t('tools.preview.title')}</h2>
            <p className="hint">{t('tools.preview.note')}</p>
            <pre className="draft-code mono">
              {JSON.stringify({ executable: preview.executable, args: preview.args }, null, 2)}
            </pre>
            <div className="modal-actions">
              <span className="spacer" />
              <button className="btn" onClick={() => setPreview(null)}>
                {t('common.cancel')}
              </button>
              <button
                className="btn btn-primary"
                onClick={() => {
                  const cfg = config();
                  setPreview(null);
                  void launch(cfg);
                }}
              >
                {t('tools.start')}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
