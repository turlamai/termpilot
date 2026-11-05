import { useEffect, useState } from 'react';
import { api } from '@termpilot/core';
import { useApp } from '../state/store';

interface KnownEntry {
  index: number;
  host: string;
  keytype: string;
  comment: string;
}

export default function KnownHostsView() {
  const t = useApp((s) => s.t);
  const [entries, setEntries] = useState<KnownEntry[]>([]);
  const [query, setQuery] = useState('');

  const refresh = async () => {
    const { entries: list } = await api.knownList();
    setEntries(list);
  };

  useEffect(() => {
    void refresh();
  }, []);

  const remove = async (index: number) => {
    if (!window.confirm(t('common.confirm-delete'))) return;
    await api.knownRemove(index);
    await refresh();
  };

  const q = query.trim().toLowerCase();
  const filtered = entries.filter(
    (e) =>
      !q ||
      e.host.toLowerCase().includes(q) ||
      e.keytype.toLowerCase().includes(q),
  );

  return (
    <div className="sidebar-view">
      <input
        className="search"
        placeholder={t('hosts.search')}
        value={query}
        onChange={(e) => setQuery(e.target.value)}
      />
      <div className="sidebar-scroll">
        {filtered.map((e) => (
          <div key={e.index} className="snippet-row">
            <div className="snippet-body">
              <span className="host-label">{e.host}</span>
              <code className="snippet-cmd">{e.keytype}</code>
            </div>
            <div className="snippet-actions">
              <button
                className="btn-icon"
                title={t('common.delete')}
                onClick={() => void remove(e.index)}
              >
                ✕
              </button>
            </div>
          </div>
        ))}
        {entries.length === 0 && <p className="hint">{t('known.placeholder')}</p>}
      </div>
    </div>
  );
}
