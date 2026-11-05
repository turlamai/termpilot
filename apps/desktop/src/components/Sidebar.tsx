import { useApp } from '../state/store';
import HostsView from './HostsView';
import SnippetsView from './SnippetsView';
import SettingsView from './SettingsView';
import ForwardView from './ForwardView';
import KeysView from './KeysView';
import KnownHostsView from './KnownHostsView';

// Placeholder views for milestones later in M1/M2 (see PRODUCT-SPEC.md).
function Placeholder({ text }: { text: string }) {
  return (
    <div className="sidebar-view">
      <p className="hint">{text}</p>
    </div>
  );
}

export default function Sidebar() {
  const view = useApp((s) => s.view);
  const t = useApp((s) => s.t);

  switch (view) {
    case 'hosts':
      return <HostsView />;
    case 'snippets':
      return <SnippetsView />;
    case 'settings':
      return <SettingsView />;
    case 'forward':
      return <ForwardView />;
    case 'sftp':
      return <Placeholder text={t('sftp.placeholder')} />;
    case 'keys':
      return <KeysView />;
    case 'known':
      return <KnownHostsView />;
  }
}
