// Terminal view: one xterm.js instance bound to one backend session.
// Output rides the streaming byte channel (api/terminal/stream); input
// and resize ride the typed invoke routes.

import '@xterm/xterm/css/xterm.css';
import { useEffect, useRef } from 'react';
import { FitAddon } from '@xterm/addon-fit';
import { Terminal } from '@xterm/xterm';
import { api, apiStream } from '@termpilot/core';

interface TerminalViewProps {
  sessionId: string;
  onClose: () => void;
  onOutput?: (text: string) => void;
}

export default function TerminalView({
  sessionId,
  onClose,
  onOutput,
}: TerminalViewProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const closedRef = useRef(false);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const term = new Terminal({
      cursorBlink: true,
      fontFamily:
        'ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace',
      fontSize: 13,
      theme: {
        background: '#1a1917',
        foreground: '#e8e5e0',
        cursor: '#e8e5e0',
        selectionBackground: '#4a4a4a',
      },
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(container);
    try {
      fit.fit();
    } catch {
      // zero-size container during transitions; resize lands later
    }

    const abort = new AbortController();

    // Output: the streaming channel replays scrollback, then live bytes.
    apiStream(
      '/api/terminal/stream',
      { id: sessionId },
      (chunk) => {
        term.write(new TextEncoder().encode(chunk));
        onOutput?.(chunk);
      },
      abort.signal,
    ).catch((err: unknown) => {
      if (!closedRef.current) {
        term.write(
          `\r\n\x1b[31m[session stream ended: ${String(err)}]\x1b[0m\r\n`,
        );
      }
    });

    // Input.
    const inputSub = term.onData((data) => {
      void api.terminalInput(sessionId, data).catch(() => undefined);
    });

    // Resize.
    const resizeSub = term.onResize(({ cols, rows }) => {
      void api.terminalResize(sessionId, cols, rows).catch(() => undefined);
    });
    const observer = new ResizeObserver(() => {
      try {
        fit.fit();
      } catch {
        // container collapsed
      }
    });
    observer.observe(container);

    return () => {
      closedRef.current = true;
      abort.abort();
      observer.disconnect();
      resizeSub.dispose();
      inputSub.dispose();
      term.dispose();
      void api.terminalClose(sessionId).catch(() => undefined);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId]);

  return (
    <div className="terminal-pane">
      <div className="terminal-pane-bar">
        <span className="terminal-pane-title">{sessionId}</span>
        <button className="btn btn-ghost" onClick={onClose}>
          ✕
        </button>
      </div>
      <div className="terminal-pane-body" ref={containerRef} />
    </div>
  );
}
