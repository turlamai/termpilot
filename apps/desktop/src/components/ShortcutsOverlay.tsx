import { useEffect } from 'react';
import { useApp } from '../state/store';

// Keyboard shortcuts overlay (⌘/). A tool advertises its keyboard
// surface or users never find it. Bindings mirror DESIGN.md §快捷键:
// quick connect is ⌘⇧L / Ctrl⇧L and opens the quick-connect form via
// the store — never by poking DOM buttons by label text (locale-
// dependent and brittle; that was the bug behind the dead shortcut).

const isMac =
  typeof navigator !== 'undefined' &&
  /Mac|iPhone|iPad/.test(navigator.userAgent);

// Display form: ⌘⇧L on macOS, Ctrl⇧L elsewhere (DESIGN.md platform
// table).
const mod = (keys: string): string => (isMac ? `⌘${keys}` : `Ctrl+${keys}`);

export default function ShortcutsOverlay() {
  const open = useApp((s) => s.shortcutsOpen);
  const setOpen = useApp((s) => s.setShortcutsOpen);
  const t = useApp((s) => s.t);
  const setView = useApp((s) => s.setView);
  const setQuickConnect = useApp((s) => s.setQuickConnect);
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
      // Quick connect: ⌘⇧L / Ctrl⇧L per the contract's shortcut table.
      // Goes through the store so it works in every locale.
      if (meta && e.shiftKey && e.key.toLowerCase() === 'l') {
        e.preventDefault();
        setView('hosts');
        setQuickConnect(true);
      }
      if (e.key === 'Escape') setOpen(false);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [setOpen, openSession, setView, setQuickConnect, setPalette, setAiPanel]);

  if (!open) return null;

  const BINDINGS: { keys: string; key: string }[] = [
    { keys: mod('⇧L'), key: 'shortcuts.quick' },
    { keys: mod('K'), key: 'shortcuts.palette' },
    { keys: mod('B'), key: 'shortcuts.ai' },
    { keys: mod('N'), key: 'shortcuts.newlocal' },
    { keys: `${mod('/')} `, key: 'shortcuts.help' },
    { keys: 'Esc', key: 'shortcuts.esc' },
  ];

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
      </div>
    </div>
  );
}
