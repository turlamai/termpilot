// Serial monitor controls: the per-pane serial affordances from the
// embedded-workspace contract — HEX/text send modes, line endings,
// encoding guard, send history (100 kept / 10 shown), interval send
// (100–60000 ms, captures its message at start), RX/TX byte counters,
// and BREAK/DTR/RTS behind explicit confirmation. Live only on serial
// panes; everything rides the session's normal input path. The pane
// owns incoming formatting (HEX view / pause buffering) by reading the
// current prefs from the store — no stale closures.

import { useEffect, useRef, useState } from 'react';
import { api } from '@termpilot/core';
import { useApp, type SerialPrefs } from '../state/store';
import { confirmDialog, toast } from '../state/feedback';

const ENDINGS: Record<SerialPrefs['ending'], string> = {
  none: '',
  lf: '\n',
  cr: '\r',
  crlf: '\r\n',
};

const ENDING_LABELS: Record<SerialPrefs['ending'], string> = {
  none: 'None',
  lf: 'LF',
  cr: 'CR',
  crlf: 'CRLF',
};

// 16 bytes per row, classic offset+hex+ascii gutter; bytes ride the
// display verbatim — never interpreted as terminal control text.
const HEX_ROW = 16;

export function hexDump(chunk: string, startOffset: number): string {
  const bytes = new TextEncoder().encode(chunk);
  const lines: string[] = [];
  for (let i = 0; i < bytes.length; i += HEX_ROW) {
    const row = bytes.subarray(i, i + HEX_ROW);
    const hex = [...row].map((b) => b.toString(16).padStart(2, '0').toUpperCase()).join(' ');
    const ascii = [...row]
      .map((b) => (b >= 0x20 && b < 0x7f ? String.fromCharCode(b) : '.'))
      .join('');
    lines.push(
      `${(startOffset + i).toString(16).padStart(8, '0')}  ${hex.padEnd(HEX_ROW * 3 - 1, ' ')}  |${ascii}|`,
    );
  }
  return lines.join('\r\n');
}

export function hexToBytes(text: string): Uint8Array | null {
  const clean = text.replace(/\s+/g, '');
  if (!/^(?:[0-9a-fA-F]{2})+$/.test(clean)) return null;
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

// Host-profile defaults for a fresh serial session: encoding and line
// ending come from the saved profile; everything else starts neutral.
export function serialDefaultsFromHost(host: {
  encoding?: string;
  'line-ending'?: string;
} | undefined): Partial<SerialPrefs> {
  return {
    encoding: host?.encoding === 'ascii' ? 'ascii' : 'utf-8',
    ending: (host?.['line-ending'] as SerialPrefs['ending']) ?? 'crlf',
  };
}

interface SerialControlsProps {
  sessionId: string;
  flowControl: string;
  disabled: boolean;
  onSend: (payload: { text?: string; bytes?: Uint8Array }) => Promise<boolean>;
}

export default function SerialControls({
  sessionId,
  flowControl,
  disabled,
  onSend,
}: SerialControlsProps) {
  const prefs = useApp((s) => s.serial[sessionId]);
  const setSerial = useApp((s) => s.setSerial);
  const countTx = useApp((s) => s.countSerialTx);
  const pushHistory = useApp((s) => s.pushSerialHistory);
  const t = useApp((s) => s.t);
  const [input, setInput] = useState('');
  const [timing, setTiming] = useState(false);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const inputRef = useRef('');

  inputRef.current = input;

  // The interval capture: one snapshot of the input at start time, per
  // the contract ("捕获启动时的消息内容"); stops on unmount.
  useEffect(() => {
    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
  }, []);

  // Disconnected panes stop their timers immediately.
  useEffect(() => {
    if (disabled && timerRef.current) {
      clearInterval(timerRef.current);
      timerRef.current = null;
      setTiming(false);
    }
  }, [disabled]);

  const sendNow = async (text: string): Promise<boolean> => {
    const p = useApp.getState().serial[sessionId];
    if (!p) return false;
    if (p.sendMode === 'hex') {
      const bytes = hexToBytes(text);
      if (!bytes) {
        toast(t('serial.err.hex'), { error: true });
        return false;
      }
      const ok = await onSend({ bytes });
      if (ok) countTx(sessionId, bytes.length);
      return ok;
    }
    if (p.encoding === 'ascii' && /[^\x00-\x7F]/.test(text)) {
      toast(t('serial.err.ascii'), { error: true });
      return false;
    }
    const full = text + ENDINGS[p.ending];
    const ok = await onSend({ text: full });
    if (ok) countTx(sessionId, new TextEncoder().encode(full).length);
    return ok;
  };

  const send = async () => {
    const text = input;
    if (!text.trim()) return;
    const ok = await sendNow(text);
    if (ok) {
      pushHistory(sessionId, text);
      setInput('');
    }
  };

  const toggleTimer = () => {
    if (timerRef.current) {
      clearInterval(timerRef.current);
      timerRef.current = null;
      setTiming(false);
      return;
    }
    const text = inputRef.current;
    if (!text.trim()) {
      toast(t('serial.err.timer-empty'), { error: true });
      return;
    }
    const iv = prefs?.intervalMs ?? 1000;
    if (!Number.isInteger(iv) || iv < 100 || iv > 60000) {
      toast(t('serial.err.timer-range'), { error: true });
      return;
    }
    void sendNow(text);
    timerRef.current = setInterval(() => {
      void sendNow(text);
    }, iv);
    setTiming(true);
    toast(t('serial.timer-started'));
  };

  const signal = async (name: 'break' | 'dtr' | 'rts') => {
    if (
      !(await confirmDialog(
        t('serial.signal-confirm').replace('{SIGNAL}', name.toUpperCase()),
        { danger: name === 'break' },
      ))
    )
      return;
    try {
      const r = await api.serialSignal(sessionId, name);
      toast(`${name.toUpperCase()} · ${r.result}`);
    } catch (e) {
      toast(String(e).slice(0, 160), { error: true });
    }
  };

  if (!prefs) return null;
  const rtsLocked = flowControl === 'rtscts';

  return (
    <div className="serial-controls">
      <div className="serial-row">
        <label className="mini">
          {t('serial.recv')}
          <button
            className={`chip ${prefs.hexView ? 'active' : ''}`}
            onClick={() => setSerial(sessionId, { hexView: !prefs.hexView })}
          >
            {prefs.hexView ? 'HEX' : 'TXT'}
          </button>
        </label>
        <label className="mini">
          {t('serial.ending')}
          <select
            value={prefs.ending}
            onChange={(e) => setSerial(sessionId, { ending: e.target.value as SerialPrefs['ending'] })}
          >
            {(Object.keys(ENDING_LABELS) as SerialPrefs['ending'][]).map((k) => (
              <option key={k} value={k}>
                {ENDING_LABELS[k]}
              </option>
            ))}
          </select>
        </label>
        <label className="mini">
          {t('serial.encoding')}
          <select
            value={prefs.encoding}
            onChange={(e) => setSerial(sessionId, { encoding: e.target.value as SerialPrefs['encoding'] })}
          >
            <option value="utf-8">UTF-8</option>
            <option value="ascii">ASCII</option>
          </select>
        </label>
        <span className="serial-counters mono">
          RX {prefs.rx} B · TX {prefs.tx} B
        </span>
      </div>
      <div className="serial-row">
        <label className="mini">
          {t('serial.sendmode')}
          <select
            value={prefs.sendMode}
            onChange={(e) => setSerial(sessionId, { sendMode: e.target.value as SerialPrefs['sendMode'] })}
          >
            <option value="text">{t('serial.text')}</option>
            <option value="hex">HEX</option>
          </select>
        </label>
        <label className="mini grow">
          {t('serial.history')}
          <select
            value=""
            onChange={(e) => {
              if (e.target.value) setInput(e.target.value);
            }}
          >
            <option value="">{t('serial.history.pick')}</option>
            {prefs.history
              .slice(-10)
              .reverse()
              .map((h, i) => (
                <option key={`${i}:${h.slice(0, 24)}`} value={h}>
                  {h.slice(0, 48)}
                </option>
              ))}
          </select>
        </label>
        <label className="mini">
          {t('serial.interval')}
          <input
            type="number"
            min={100}
            max={60000}
            value={prefs.intervalMs}
            onChange={(e) => setSerial(sessionId, { intervalMs: Number(e.target.value) || 1000 })}
          />
        </label>
        <button className={`btn ${timing ? 'btn-danger' : ''}`} disabled={disabled} onClick={toggleTimer}>
          {timing ? t('serial.timer-stop') : t('serial.timer-start')}
        </button>
      </div>
      <div className="serial-row">
        <input
          className="serial-input mono grow"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') void send();
          }}
          placeholder={prefs.sendMode === 'hex' ? t('serial.hex.placeholder') : t('serial.text.placeholder')}
          disabled={disabled}
          spellCheck={false}
        />
        <button className="btn btn-primary" disabled={disabled} onClick={() => void send()}>
          {t('serial.send')}
        </button>
      </div>
      <div className="serial-row serial-signals">
        <button className="btn" disabled={disabled} onClick={() => void signal('break')}>
          BREAK
        </button>
        <button className="btn" disabled={disabled} onClick={() => void signal('dtr')}>
          DTR
        </button>
        <button
          className="btn"
          disabled={disabled || rtsLocked}
          title={rtsLocked ? t('serial.rts-locked') : undefined}
          onClick={() => void signal('rts')}
        >
          RTS
        </button>
        <span className="hint">{rtsLocked ? t('serial.rts-locked') : t('serial.signal-hint')}</span>
      </div>
    </div>
  );
}
