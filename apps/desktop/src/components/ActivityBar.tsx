import { useApp, type ViewId } from '../state/store';
import { Icon, type IconName } from './Icon';

const ITEMS: { id: ViewId; icon: IconName }[] = [
  { id: 'hosts', icon: 'monitor' },
  { id: 'sftp', icon: 'folder' },
  { id: 'forward', icon: 'arrow-right-left' },
  { id: 'snippets', icon: 'zap' },
  { id: 'keys', icon: 'key-round' },
  { id: 'known', icon: 'shield' },
  { id: 'settings', icon: 'sliders' },
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
          aria-label={t(`view.${id}`)}
        >
          <Icon name={icon} size={19} />
        </button>
      ))}
    </nav>
  );
}
