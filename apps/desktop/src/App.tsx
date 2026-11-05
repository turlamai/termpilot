import { useEffect } from 'react';
import { useApp } from './state/store';
import ActivityBar from './components/ActivityBar';
import Sidebar from './components/Sidebar';
import TabBar from './components/TabBar';
import AiPanel from './components/AiPanel';
import CommandPalette from './components/CommandPalette';
import TerminalPane from './TerminalPane';

export default function App() {
  const tabs = useApp((s) => s.tabs);
  const activeTabId = useApp((s) => s.activeTabId);
  const focusedSessionId = useApp((s) => s.focusedSessionId);
  const closePane = useApp((s) => s.closePane);
  const aiPanelOpen = useApp((s) => s.aiPanelOpen);
  const setAiPanel = useApp((s) => s.setAiPanel);
  const setPalette = useApp((s) => s.setPalette);
  const theme = useApp((s) => s.theme);
  const refreshHosts = useApp((s) => s.refreshHosts);

  // Global keys: ⌘K palette, ⌘B AI panel toggle.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        setPalette(true);
      }
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'b') {
        e.preventDefault();
        setAiPanel(!useApp.getState().aiPanelOpen);
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [setPalette, setAiPanel]);

  // Theme on <html>, following the site pattern (system default).
  useEffect(() => {
    const apply = () => {
      const effective =
        theme === 'system'
          ? matchMedia('(prefers-color-scheme: dark)').matches
            ? 'dark'
            : 'light'
          : theme;
      document.documentElement.dataset.theme = effective;
    };
    apply();
    const mq = matchMedia('(prefers-color-scheme: dark)');
    mq.addEventListener('change', apply);
    return () => mq.removeEventListener('change', apply);
  }, [theme]);

  // First load: hosts + welcome tab content.
  useEffect(() => {
    void refreshHosts();
  }, [refreshHosts]);

  const activeTab = tabs.find((t) => t.id === activeTabId);

  return (
    <div className="app">
      <ActivityBar />
      <div className="sidebar">
        <Sidebar />
      </div>
      <main className="main">
        <TabBar />
        {activeTab ? (
          <div className="terminals">
            {activeTab.panes.map((pane) => (
              <TerminalPane
                key={pane.sessionId}
                sessionId={pane.sessionId}
                focused={pane.sessionId === focusedSessionId}
                onClose={() => closePane(activeTab.id, pane.sessionId)}
              />
            ))}
          </div>
        ) : (
          <div className="welcome">
            <h2>TermPilot</h2>
            <p>
              The AI-native SSH client. Connect from the Hosts view, or
              press ⌘K anywhere.
            </p>
          </div>
        )}
      </main>
      {aiPanelOpen && <AiPanel />}
      <CommandPalette />
      {/* Floating AI panel opener when collapsed */}
      {!aiPanelOpen && (
        <button className="ai-fab" title="AI (⌘B)" onClick={() => setAiPanel(true)}>
          ✦
        </button>
      )}
    </div>
  );
}
