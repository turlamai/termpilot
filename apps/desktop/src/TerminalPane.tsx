// Terminal pane: one xterm.js instance bound to one backend session.
// Output rides the streaming byte channel; input and resize ride typed
// invokes. Theme/font come from the app settings (per-host font-size
// override wins). Includes in-pane search, clickable links, copy on
// select, and a reconnect affordance when the stream ends. Theme or
// font changes re-key the whole pane (xterm options are immutable here
// by design — a fresh instance is simpler and leak-free).

import '@xterm/xterm/css/xterm.css';
import { useCallback, useEffect, useRef, useState } from 'react';
import { FitAddon } from '@xterm/addon-fit';
import { SearchAddon } from '@xterm/addon-search';
import { WebLinksAddon } from '@xterm/addon-web-links';
import { Terminal } from '@xterm/xterm';
import { api, apiStream, findTermTheme } from '@termpilot/core';
import { useApp, type AppState } from './state/store';
import { Icon } from './components/Icon';

export interface TerminalPaneProps {
  sessionId: string;
  focused: boolean;
  onClose: () => void;
  onReconnect?: () => void;
}

export default function TerminalPane({
  sessionId,
  focused,
  onClose,
  onReconnect,
}: TerminalPaneProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const closedRef = useRef(false);
  const searchRef = useRef<HTMLInputElement>(null);
  const addonRef = useRef<SearchAddon | null>(null);
  const [streamEnded, setStreamEnded] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const [searchText, setSearchText] = useState('');
  const [copied, setCopied] = useState(false);
  const [logging, setLogging] = useState(false);
  const [evidenceSaved, setEvidenceSaved] = useState(false);

  const saveEvidence = async () => {
    try {
      const ev = await api.terminalEvidence(sessionId);
      const blob = new Blob(
        [JSON.stringify(ev, null, 2)],
        { type: 'application/json' },
      );
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `termpilot-evidence-${ev.sha1.slice(0, 8)}.json`;
      a.click();
      URL.revokeObjectURL(url);
      setEvidenceSaved(true);
      setTimeout(() => setEvidenceSaved(false), 1200);
    } catch {
      // evidence export is best-effort
    }
  };

  const pane = useApp(
    (s: AppState) =>
      s.tabs.flatMap((tab) => tab.panes).find((p) => p.sessionId === sessionId),
  );
  const label = pane?.label ?? sessionId;
  const tabsInTab = useApp(
    (s: AppState) =>
      s.tabs.find((t) => t.panes.some((p) => p.sessionId === sessionId))
        ?.panes.length ?? 1,
  );
  const fontSize = useApp((s: AppState) => s.termFontSize);
  const themeId = useApp((s: AppState) => s.termThemeId);
  const hostFontSize = useApp((s: AppState) => {
    if (!pane?.hostId) return 0;
    return s.hosts.find((h) => h.id === pane.hostId)?.['font-size'] ?? 0;
  });
  const appendOutput = useApp((s: AppState) => s.appendOutput);
  const setSelection = useApp((s: AppState) => s.setSelection);
  const focusSession = useApp((s: AppState) => s.focusSession);
  const setPaneTitle = useApp((s: AppState) => s.setPaneTitle);
  const t = useApp((s: AppState) => s.t);

  // OSC 0/2 window-title extraction: sequences may split across chunks,
  // so the extractor keeps a carry between writes and strips partial
  // tails from what it hands the terminal-independent title watcher.
  const oscRef = useRef('');
  const extractTitle = (chunk: string): string | null => {
    oscRef.current += chunk;
    const buf = oscRef.current;
    const m = buf.match(/\u001b\][012];([^\u0007\u001b]*)(?:\u0007|\u001b\\)/);
    oscRef.current = buf.slice(-32); // keep a tail for split sequences
    return m ? m[1].trim() : null;
  };

  const effectiveFontSize = hostFontSize > 0 ? hostFontSize : fontSize;

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const term = new Terminal({
      cursorBlink: true,
      fontSize: effectiveFontSize || 13,
      fontFamily:
        'ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace',
      theme: findTermTheme(themeId).theme as never,
    });
    const fit = new FitAddon();
    const search = new SearchAddon();
    addonRef.current = search;
    term.loadAddon(fit);
    term.loadAddon(search);
    term.loadAddon(new WebLinksAddon());
    term.open(container);
    try {
      fit.fit();
    } catch {
      // zero-size container during transitions; resize lands later
    }

    const abort = new AbortController();

    apiStream(
      '/api/terminal/stream',
      { id: sessionId },
      (chunk) => {
        term.write(new TextEncoder().encode(chunk));
        appendOutput(sessionId, chunk);
        const title = extractTitle(chunk);
        if (title) setPaneTitle(sessionId, title);
      },
      abort.signal,
    )
      .catch((err: unknown) => {
        if (!closedRef.current) {
          term.write(
            `\r\n\x1b[31m[session stream ended: ${String(err)}]\x1b[0m\r\n`,
          );
        }
      })
      .finally(() => {
        if (!closedRef.current) setStreamEnded(true);
      });

    const inputSub = term.onData((data) => {
      void api.terminalInput(sessionId, data).catch(() => undefined);
    });

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

    // Copy on select: the selection lands in the clipboard as soon as it
    // is made (terminal convention); the pane shows a brief confirmation.
    const selSub = term.onSelectionChange(() => {
      const text = term.getSelection();
      setSelection(sessionId, text);
      if (text.trim()) {
        void navigator.clipboard
          .writeText(text)
          .then(() => {
            setCopied(true);
            setTimeout(() => setCopied(false), 900);
          })
          .catch(() => undefined);
      }
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
      search.dispose();
      term.dispose();
      void api.terminalClose(sessionId).catch(() => undefined);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId, themeId, effectiveFontSize]);

  const runSearch = useCallback(
    (dir: 'next' | 'prev') => {
      if (!addonRef.current || !searchText) return;
      if (dir === 'next') addonRef.current.findNext(searchText);
      else addonRef.current.findPrevious(searchText);
    },
    [searchText],
  );

  return (
    <div
      className={`terminal-pane ${focused ? 'focused' : ''}`}
      onMouseDown={() => focusSession(sessionId)}
    >
      <div className="terminal-pane-bar">
        {tabsInTab > 1 && <span className="terminal-pane-title">{label}</span>}
        <span className="terminal-pane-tools">
          {copied && <span className="hint">{t('terminal.copied')}</span>}
          {searchOpen && (
            <span className="terminal-search">
              <input
                ref={searchRef}
                value={searchText}
                placeholder={t('terminal.search')}
                onChange={(e) => setSearchText(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') runSearch(e.shiftKey ? 'prev' : 'next');
                  if (e.key === 'Escape') {
                    addonRef.current?.clearDecorations();
                    setSearchOpen(false);
                  }
                }}
                autoFocus
              />
            </span>
          )}
          <button
            className="btn-icon"
            title={t('terminal.search')}
            aria-label={t('terminal.search')}
            onClick={() => setSearchOpen((v) => !v)}
          >
            <Icon name="search" size={13} />
          </button>
          <button
            className="btn-icon"
            title={logging ? 'Stop logging' : 'Log session to file'}
            onClick={() => {
              if (logging) {
                void api.terminalLogStop(sessionId);
                setLogging(false);
              } else {
                void api.terminalLogStart(sessionId);
                setLogging(true);
              }
            }}
          >
            <Icon name={logging ? 'circle-dot' : 'circle'} size={13} />
          </button>
          <button
            className="btn-icon"
            title={t('terminal.evidence')}
            onClick={() => void saveEvidence()}
          >
            <Icon name="shield" size={13} />
          </button>
          {evidenceSaved && <span className="hint">✓</span>}
          {streamEnded && onReconnect && (
            <button
              className="btn-icon"
              title={t('terminal.reconnect')}
              onClick={onReconnect}
            >
              <Icon name="rotate-cw" size={13} />
            </button>
          )}
          <button className="btn-icon" title="Close" onClick={onClose}>
            <Icon name="x" size={13} />
          </button>
        </span>
      </div>
      <div className="terminal-pane-body" ref={containerRef} />
    </div>
  );
}
