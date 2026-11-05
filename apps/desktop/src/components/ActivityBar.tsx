import { useApp, type ViewId } from '../state/store';

const ITEMS: { id: ViewId; icon: string }[] = [
  { id: 'hosts', icon: '🖥' },
  { id: 'sftp', icon: '📁' },
  { id: 'forward', icon: '⇄' },
  { id: 'snippets', icon: '⚡' },
  { id: 'keys', icon: '🔑' },
  { id: 'known', icon: '🛡' },
  { id: 'settings', icon: '⚙' },
];

export default function ActivityBar() {
  const view = useApp((s) => s.view);
  const setView = useApp((s) => s.setView);
  const t = useApp((s) => s.t);

  return (
    <nav className="activity-bar">
      {ITEMS.map(({ id, icon }) => (
        <button
          key={id}
          className={`activity-item ${view === id ? 'active' : ''}`}
          onClick={() => setView(id)}
          title={t(`view.${id}`)}
        >
          {icon}
        </button>
      ))}
    </nav>
  );
}
