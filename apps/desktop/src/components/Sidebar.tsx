import { useApp } from '../state/store';
import HostsView from './HostsView';
import SnippetsView from './SnippetsView';
import SettingsView from './SettingsView';
import ForwardView from './ForwardView';
import KeysView from './KeysView';
import TransferView from './TransferView';
import ToolsView from './ToolsView';
import KnownHostsView from './KnownHostsView';

export default function Sidebar() {
  const view = useApp((s) => s.view);

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
      return <TransferView />;
    case 'tools':
      return <ToolsView />;
    case 'keys':
      return <KeysView />;
    case 'known':
      return <KnownHostsView />;
  }
}
