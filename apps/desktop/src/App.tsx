import { useEffect, useRef, useState } from 'react';
import { useApp } from './state/store';
import ActivityBar from './components/ActivityBar';
import Sidebar from './components/Sidebar';
import TabBar from './components/TabBar';
import AiPanel from './components/AiPanel';
import CommandPalette from './components/CommandPalette';
import TerminalPane from './TerminalPane';
import { Icon } from './components/Icon';
import FeedbackLayer from './components/FeedbackLayer';
import UpdateBanner from './components/UpdateBanner';

export default function App() {
  const tabs = useApp((s) => s.tabs);
  const activeTabId = useApp((s) => s.activeTabId);
  const focusedSessionId = useApp((s) => s.focusedSessionId);
  const closePane = useApp((s) => s.closePane);
  const reconnectPane = useApp((s) => s.reconnectPane);
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
  // Split-pane sizing: flex-grow per pane, adjusted by the drag handle
  // between neighbors. Local to the session; resets when it closes.
  const [paneSizes, setPaneSizes] = useState<Record<string, number>>({});
  const dragRef = useRef<{ left: string; right: string; startX: number; leftW: number; rightW: number } | null>(null);

  const startResize = (e: React.PointerEvent, leftId: string, rightId: string) => {
    e.preventDefault();
    (e.target as HTMLElement).setPointerCapture(e.pointerId);
    dragRef.current = {
      left: leftId,
      right: rightId,
      startX: e.clientX,
      leftW: paneSizes[leftId] ?? 1,
      rightW: paneSizes[rightId] ?? 1,
    };
  };
  const moveResize = (e: React.PointerEvent) => {
    const d = dragRef.current;
    if (!d) return;
    const total = d.leftW + d.rightW;
    const delta = (e.clientX - d.startX) / (window.innerWidth / total);
    const leftW = Math.max(0.2, Math.min(total - 0.2, d.leftW + delta));
    setPaneSizes((prev) => ({
      ...prev,
      [d.left]: leftW,
      [d.right]: total - leftW,
    }));
  };

  return (
    <div className="app">
      <ActivityBar />
      <div className="sidebar">
        <Sidebar />
      </div>
      <main className="main">
        <UpdateBanner />
        <TabBar />
        {activeTab ? (
          <div className="terminals">
            {activeTab.panes.map((pane, i) => (
              <div
                className="pane-slot"
                key={pane.sessionId}
                style={{ flexGrow: paneSizes[pane.sessionId] ?? 1 }}
              >
                <TerminalPane
                  key={`${pane.sessionId}:${useApp.getState().termThemeId}:${useApp.getState().termFontSize}`}
                  sessionId={pane.sessionId}
                  focused={pane.sessionId === focusedSessionId}
                  onClose={() => closePane(activeTab.id, pane.sessionId)}
                  onReconnect={() =>
                    void reconnectPane(activeTab.id, pane.sessionId)
                  }
                />
                {i < activeTab.panes.length - 1 && (
                  <div
                    className="pane-resize"
                    onPointerDown={(e) =>
                      startResize(e, pane.sessionId, activeTab.panes[i + 1].sessionId)
                    }
                    onPointerMove={moveResize}
                    onPointerUp={() => (dragRef.current = null)}
                  />
                )}
              </div>
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
      <FeedbackLayer />
      {/* Floating AI panel opener when collapsed */}
      {!aiPanelOpen && (
        <button className="ai-fab" title="AI (⌘B)" aria-label="AI" onClick={() => setAiPanel(true)}>
          <Icon name="sparkles" size={18} />
        </button>
      )}
    </div>
  );
}
