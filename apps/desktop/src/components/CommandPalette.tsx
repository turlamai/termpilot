import { useEffect, useRef, useState } from 'react';
import { api } from '@termpilot/core';
import { useApp } from '../state/store';
import { toast } from '../state/feedback';
import { Icon } from './Icon';

// The ⌘K palette: natural language → command draft, with redaction
// preview of the terminal context that will be sent. The draft is
// inserted into the focused terminal only on explicit user action and
// never executed — the user reviews it and presses Enter themselves.

export default function CommandPalette() {
  const paletteOpen = useApp((s) => s.paletteOpen);
  const setPalette = useApp((s) => s.setPalette);
  const focusedSessionId = useApp((s) => s.focusedSessionId);
  const tabs = useApp((s) => s.tabs);
  const hosts = useApp((s) => s.hosts);
  const recentOutput = useApp((s) => s.recentOutput);
  const setAiPanel = useApp((s) => s.setAiPanel);
  const openSession = useApp((s) => s.openSession);
  const t = useApp((s) => s.t);

  const [intent, setIntent] = useState('');
  const [draft, setDraft] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [redactions, setRedactions] = useState<[string, number][] | null>(null);
  // Two-step guard (DESIGN.md §AI): the redaction preview must be
  // confirmed before the model is called — generate rides only on the
  // explicit second click.
  const [preview, setPreview] = useState<{
    text: string;
    counts: [string, number][];
    clean: boolean;
  } | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (paletteOpen) {
      setIntent('');
      setDraft('');
      setError('');
      setRedactions(null);
      setPreview(null);
      setTimeout(() => inputRef.current?.focus(), 30);
    }
  }, [paletteOpen]);

  if (!paletteOpen) return null;

  const focusedTab = tabs.find((tab) =>
    tab.panes.some((p) => p.sessionId === focusedSessionId),
  );
  const focusedPane = focusedTab?.panes.find((p) => p.sessionId === focusedSessionId);
  const host = focusedPane
    ? hosts.find(
        (h) => h.label === focusedPane.label || focusedPane.label.includes(h.host),
      )
    : undefined;
  const hostContext = host ? `${host.username ? `${host.username}@` : ''}${host.host}` : '';

  // Step 1: redaction preview only — no model call yet.
  const doPreview = async () => {
    if (!intent.trim()) return;
    setBusy(true);
    setError('');
    setDraft('');
    setPreview(null);
    try {
      const terminal = recentOutput(focusedSessionId ?? '', 4000);
      if (terminal.trim()) {
        setPreview(await api.aiRedactPreview(terminal));
      } else {
        // Nothing to leak: an empty preview still needs the explicit
        // confirm click, keeping one consistent flow.
        setPreview({ text: '', counts: [], clean: true });
      }
    } catch (e) {
      setError(String(e));
    }
    setBusy(false);
  };

  // Step 2: explicit confirm — now the model is called. The backend
  // redacts again on its side; the preview showed the user what that
  // looks like.
  const doGenerate = async () => {
    if (!intent.trim()) return;
    setBusy(true);
    setError('');
    try {
      const terminal = recentOutput(focusedSessionId ?? '', 4000);
      const r = await api.aiGenerate(intent, hostContext, terminal);
      setDraft(r.command);
      setRedactions(preview?.counts.length ? preview.counts : []);
    } catch (e) {
      setError(String(e));
    }
    setBusy(false);
  };

  const insert = async () => {
    if (!draft || !focusedSessionId) return;
    await api.terminalInput(focusedSessionId, draft);
    setPalette(false);
  };

  // Keep the draft: save it as a snippet named after the intent. The
  // snippet is inert until the user runs it, so governance holds.
  const saveAsSnippet = async () => {
    if (!draft) return;
    const name = (intent.trim() || draft).slice(0, 40);
    try {
      await api.snippetCreate({ name, command: draft, tags: ['ai'] });
      toast(t('ai.saved-snippet'));
      setPalette(false);
    } catch (e) {
      toast(`${t('ai.error')}: ${String(e).slice(0, 120)}`, { error: true });
    }
  };

  return (
    <div className="palette-backdrop" onClick={() => setPalette(false)}>
      <div className="palette" onClick={(e) => e.stopPropagation()}>
        {/* Empty state: the palette doubles as a launcher. */}
        {!intent && !draft && hosts.length > 0 && (
          <div className="palette-hosts">
            {hosts.slice(0, 6).map((h) => (
              <button
                key={h.id}
                className="picker-row"
                onClick={() => {
                  setPalette(false);
                  void openSession({ 'host-id': h.id });
                }}
              >
                <Icon name="square-terminal" size={14} /> {h.label}
              </button>
            ))}
          </div>
        )}

        <div className="palette-input-row">
          <span className="palette-prefix">⌘K</span>
          <input
            ref={inputRef}
            value={intent}
            placeholder={t('ai.palette.placeholder')}
            onChange={(e) => {
              setIntent(e.target.value);
              // A new intent invalidates the confirmed preview.
              if (preview) setPreview(null);
            }}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !draft) {
                if (preview) void doGenerate();
                else void doPreview();
              }
              if (e.key === 'Escape') setPalette(false);
            }}
          />
          {!draft && !preview && (
            <button
              className="btn btn-primary"
              disabled={busy || !intent.trim()}
              onClick={() => void doPreview()}
            >
              {busy ? t('ai.thinking') : t('ai.preview')}
            </button>
          )}
          {!draft && preview && (
            <button
              className="btn btn-primary"
              disabled={busy || !intent.trim()}
              onClick={() => void doGenerate()}
            >
              {busy ? t('ai.thinking') : t('ai.generate-confirm')}
            </button>
          )}
        </div>

        {preview && !draft && (
          <div className="palette-redactions">
            {preview.clean
              ? t('ai.redact.clean')
              : `${t('ai.redact-preview')}: ${preview.counts
                  .map(([name, n]) => `${name}×${n}`)
                  .join(' · ')}`}
            {preview.text && (
              <pre className="draft-code">{preview.text.slice(0, 400)}</pre>
            )}
            <p className="hint">{t('ai.step-hint')}</p>
          </div>
        )}

        {redactions !== null && redactions.length > 0 && (
          <div className="palette-redactions">
            {t('ai.redact-preview')}:{' '}
            {redactions.map(([name, n]) => (
              <code key={name}>
                {name}×{n}{' '}
              </code>
            ))}
          </div>
        )}

        {error && <p className="error">{t('ai.error')}: {error}</p>}

        {draft && (
          <div className="palette-draft">
            <code>{draft}</code>
            <div className="row">
              <button className="btn btn-primary" disabled={!focusedSessionId} onClick={() => void insert()}>
                {t('ai.insert')}
              </button>
              <button
                className="btn"
                onClick={() => void navigator.clipboard.writeText(draft)}
              >
                {t('ai.copy')}
              </button>
              <button className="btn" title={t('ai.save-snippet')} onClick={() => void saveAsSnippet()}>
                <Icon name="sparkles" size={13} /> {t('ai.save-snippet')}
              </button>
              <button
                className="btn"
                onClick={() => {
                  setAiPanel(true);
                  setPalette(false);
                }}
              >
                {t('ai.discard')}
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
