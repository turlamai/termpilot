import { useCallback, useEffect, useState } from 'react';
import { api, type HostProfile } from '@termpilot/core';
import TerminalView from './TerminalView';

interface AppProps {
  // injected by the smoke/selftest harness
  selftest?: boolean;
}

export default function App(_props: AppProps) {
  const [hosts, setHosts] = useState<HostProfile[]>([]);
  const [activeSessions, setActiveSessions] = useState<string[]>([]);
  const [backendOk, setBackendOk] = useState<boolean | null>(null);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    try {
      const { hosts: list } = await api.hostsList();
      setHosts(list);
      setBackendOk(true);
      setError('');
    } catch (e) {
      setBackendOk(false);
      setError(String(e));
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const openTerminal = useCallback(
    async (host?: HostProfile) => {
      try {
        const session = await api.terminalOpen(
          host
            ? {
                'host-id': host.id,
                cols: 120,
                rows: 30,
              }
            : { kind: 'local', cols: 120, rows: 30 },
        );
        setActiveSessions((s) => [...s, session.id]);
      } catch (e) {
        setError(String(e));
      }
    },
    [],
  );

  const closeTerminal = useCallback((id: string) => {
    setActiveSessions((s) => s.filter((x) => x !== id));
  }, []);

  return (
    <div className="app">
      <aside className="sidebar">
        <div className="sidebar-header">
          <h1>TermPilot</h1>
          <span className="version">v0.1.0</span>
        </div>
        <button className="btn btn-primary" onClick={() => void openTerminal()}>
          Local Shell
        </button>
        <div className="host-list">
          {hosts.map((h) => (
            <div key={h.id} className="host-row">
              <button
                className="host-btn"
                onClick={() => void openTerminal(h)}
              >
                <span className="host-label">{h.label}</span>
                <span className="host-addr">
                  {h.username ? `${h.username}@` : ''}
                  {h.host}
                </span>
              </button>
            </div>
          ))}
          {hosts.length === 0 && (
            <p className="hint">No hosts yet. Backend is {String(backendOk)}.</p>
          )}
        </div>
        {error && <p className="error">{error}</p>}
      </aside>
      <main className="main">
        {activeSessions.length === 0 ? (
          <div className="welcome">
            <h2>TermPilot</h2>
            <p>
              The AI-native SSH client. Open a local shell or pick a host on
              the left.
            </p>
          </div>
        ) : (
          <div className="terminals">
            {activeSessions.map((id) => (
              <TerminalView
                key={id}
                sessionId={id}
                onClose={() => closeTerminal(id)}
              />
            ))}
          </div>
        )}
      </main>
    </div>
  );
}
