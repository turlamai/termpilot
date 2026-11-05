import { useState } from 'react';
import { useApp } from '../state/store';

const KIND_ICON: Record<string, string> = {
  ssh: '🖥',
  local: '⌂',
  telnet: '☎',
  mosh: '📶',
  serial: '🔌',
};

export default function TabBar() {
  const tabs = useApp((s) => s.tabs);
  const activeTabId = useApp((s) => s.activeTabId);
  const closeTab = useApp((s) => s.closeTab);
  const openSession = useApp((s) => s.openSession);
  const hosts = useApp((s) => s.hosts);
  const t = useApp((s) => s.t);
  const [splitting, setSplitting] = useState(false);

  const activeTab = tabs.find((x) => x.id === activeTabId);

  return (
    <div className="tab-bar">
      <div className="tabs">
        {tabs.map((tab) => {
          const first = tab.panes[0];
          const title =
            tab.panes.length > 1
              ? `${first.label} +${tab.panes.length - 1}`
              : first.label;
          return (
            <div
              key={tab.id}
              className={`tab ${tab.id === activeTabId ? 'active' : ''}`}
              onClick={() => useApp.setState({ activeTabId: tab.id })}
            >
              <span className="tab-icon">{KIND_ICON[first.kind] ?? '🖥'}</span>
              <span className="tab-title">{title}</span>
              <button
                className="btn-icon"
                title={t('common.close')}
                onClick={(e) => {
                  e.stopPropagation();
                  closeTab(tab.id);
                }}
              >
                ✕
              </button>
            </div>
          );
        })}
      </div>
      <div className="tab-actions">
        <button className="btn-icon" title={t('tabs.new-local')} onClick={() => void openSession({ kind: 'local' })}>
          ＋
        </button>
        <button
          className="btn-icon"
          title={t('common.split')}
          disabled={!activeTab}
          onClick={() => setSplitting(true)}
        >
          ⫿
        </button>
      </div>
      {splitting && (
        <div className="modal-backdrop" onClick={() => setSplitting(false)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <h2>{t('common.split')}</h2>
            <div className="picker-list">
              <button
                className="picker-row"
                onClick={() => {
                  setSplitting(false);
                  void openSession({ kind: 'local' }, { split: true });
                }}
              >
                ⌂ {t('common.local')}
              </button>
              {hosts.map((h) => (
                <button
                  key={h.id}
                  className="picker-row"
                  onClick={() => {
                    setSplitting(false);
                    void openSession({ 'host-id': h.id }, { split: true });
                  }}
                >
                  🖥 {h.label}
                </button>
              ))}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
