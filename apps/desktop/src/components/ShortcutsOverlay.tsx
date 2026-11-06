import { useEffect } from 'react';
import { useApp } from '../state/store';

// Keyboard shortcuts overlay (⌘/). A tool advertises its keyboard
// surface or users never find it.

const BINDINGS: { keys: string; key: string }[] = [
  { keys: '⌘K', key: 'shortcuts.palette' },
  { keys: '⌘B', key: 'shortcuts.ai' },
  { keys: '⌘N', key: 'shortcuts.newlocal' },
  { keys: '⌘/ ', key: 'shortcuts.quick' },
];

export default function ShortcutsOverlay() {
  const open = useApp((s) => s.shortcutsOpen);
  const setOpen = useApp((s) => s.setShortcutsOpen);
  const t = useApp((s) => s.t);
  const setView = useApp((s) => s.setView);
  const openSession = useApp((s) => s.openSession);
  const setPalette = useApp((s) => s.setPalette);
  const setAiPanel = useApp((s) => s.setAiPanel);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const meta = e.metaKey || e.ctrlKey;
      if (meta && e.key === '/') {
        e.preventDefault();
        setOpen(!useApp.getState().shortcutsOpen);
      }
      if (meta && e.key.toLowerCase() === 'n') {
        e.preventDefault();
        void openSession({ kind: 'local' });
      }
      if (meta && !e.shiftKey && e.key === 'q') {
        e.preventDefault();
        setView('hosts');
        setTimeout(() => {
          const btn = [...document.querySelectorAll('button')].find(
            (b) => (b.textContent || '').includes('Quick Connect'),
          );
          btn?.click();
        }, 60);
      }
      if (e.key === 'Escape') setOpen(false);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [setOpen, openSession, setView, setPalette, setAiPanel]);

  if (!open) return null;

  return (
    <div className="modal-backdrop" onClick={() => setOpen(false)}>
      <div className="modal shortcuts" onClick={(e) => e.stopPropagation()}>
        <h2>{t('shortcuts.title')}</h2>
        <div className="shortcuts-list">
          {BINDINGS.map(({ keys, key }) => (
            <div key={key} className="shortcut-row">
              <kbd>{keys}</kbd>
              <span>{t(key)}</span>
            </div>
          ))}
        </div>
        <div className="modal-actions">
          <span className="spacer" />
          <button className="btn" onClick={() => setOpen(false)}>
            {t('common.ok')}
          </button>
        </div>
      </div>
    </div>
  );
}
