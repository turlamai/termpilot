import { useState } from 'react';
import { api } from '@termpilot/core';
import { useApp } from '../state/store';
import { Icon } from './Icon';

interface RedactPreview {
  counts: [string, number][];
  clean: boolean;
}

export default function AiPanel() {
  const setAiPanel = useApp((s) => s.setAiPanel);
  const focusedSessionId = useApp((s) => s.focusedSessionId);
  const selections = useApp((s) => s.selections);
  const t = useApp((s) => s.t);

  const [explanation, setExplanation] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [preview, setPreview] = useState<RedactPreview | null>(null);
  const [pendingText, setPendingText] = useState('');

  const selection = focusedSessionId
    ? (selections[focusedSessionId] ?? '')
    : '';

  const explain = async (text: string) => {
    if (!text.trim()) return;
    setBusy(true);
    setError('');
    setExplanation('');
    try {
      const p = await api.aiRedactPreview(text);
      setPreview({ counts: p.counts, clean: p.clean });
      setPendingText(text);
    } catch (e) {
      setError(String(e));
    }
    setBusy(false);
  };

  const confirmSend = async () => {
    setBusy(true);
    setError('');
    try {
      const r = await api.aiExplain(pendingText);
      setExplanation(r.text);
      setPreview(null);
      setPendingText('');
    } catch (e) {
      setError(String(e));
    }
    setBusy(false);
  };

  return (
    <aside className="ai-panel">
      <div className="ai-panel-bar">
        <span>{t('ai.panel')}</span>
        <button className="btn-icon" onClick={() => setAiPanel(false)}>
          <Icon name="x" size={13} />
        </button>
      </div>
      <div className="ai-panel-body">
        <button
          className="btn btn-block"
          disabled={!selection.trim() || busy}
          onClick={() => void explain(selection)}
        >
          {t('ai.explain.selection')}
        </button>

        {preview && (
          <div className="ai-redact">
            <div className="ai-redact-title">{t('ai.redact-preview')}</div>
            {preview.clean ? (
              <span className="hint">{t('ai.redact.clean')}</span>
            ) : (
              <ul>
                {preview.counts.map(([name, n]) => (
                  <li key={name}>
                    <code>{name}</code> ×{n}
                  </li>
                ))}
              </ul>
            )}
            <div className="row">
              <button className="btn btn-primary" disabled={busy} onClick={() => void confirmSend()}>
                {t('ai.confirm-send')}
              </button>
              <button className="btn" onClick={() => setPreview(null)}>
                {t('common.cancel')}
              </button>
            </div>
          </div>
        )}

        {busy && <p className="hint">{t('ai.thinking')}</p>}
        {error && <p className="error">{t('ai.error')}: {error}</p>}
        {explanation && <div className="ai-answer">{explanation}</div>}

        {!explanation && !busy && !preview && (
          <p className="hint">{t('ai.empty')}</p>
        )}
      </div>
    </aside>
  );
}
