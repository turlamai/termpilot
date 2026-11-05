// Terminal pane: one xterm.js instance bound to one backend session.
// Output rides the streaming byte channel (api/terminal/stream); input
// and resize ride the typed invoke routes. The pane reports selection
// changes and output text into the app store (AI panel + palette).

import '@xterm/xterm/css/xterm.css';
import { useEffect, useRef } from 'react';
import { FitAddon } from '@xterm/addon-fit';
import { Terminal } from '@xterm/xterm';
import { api, apiStream } from '@termpilot/core';
import { useApp, type AppState } from './state/store';

interface TerminalPaneProps {
  sessionId: string;
  focused: boolean;
  onClose: () => void;
}

export default function TerminalPane({
  sessionId,
  focused,
  onClose,
}: TerminalPaneProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const closedRef = useRef(false);
  const label = useApp((s: AppState) => {
    for (const tab of s.tabs) {
      const pane = tab.panes.find((x) => x.sessionId === sessionId);
      if (pane) return pane.label;
    }
    return sessionId;
  });
  const appendOutput = useApp((s: AppState) => s.appendOutput);
  const setSelection = useApp((s: AppState) => s.setSelection);
  const focusSession = useApp((s: AppState) => s.focusSession);

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
        appendOutput(sessionId, chunk);
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

    // Selection reporting for the AI panel.
    const selSub = term.onSelectionChange(() => {
      setSelection(sessionId, term.getSelection());
    });
    const focusIn = () => focusSession(sessionId);
    container.addEventListener('focusin', focusIn);

    return () => {
      closedRef.current = true;
      abort.abort();
      observer.disconnect();
      container.removeEventListener('focusin', focusIn);
      selSub.dispose();
      resizeSub.dispose();
      inputSub.dispose();
      term.dispose();
      void api.terminalClose(sessionId).catch(() => undefined);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId]);

  return (
    <div className={`terminal-pane ${focused ? 'focused' : ''}`} onMouseDown={() => focusSession(sessionId)}>
      <div className="terminal-pane-bar">
        <span className="terminal-pane-title">{label}</span>
        <button className="btn-icon" title="Close" onClick={onClose}>
          ✕
        </button>
      </div>
      <div className="terminal-pane-body" ref={containerRef} />
    </div>
  );
}
