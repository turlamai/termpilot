import { useEffect, useState } from 'react';
import { api } from '@termpilot/core';
import { Icon } from './Icon';

// Update banner: the app checks the published manifest (cached server-
// side, 1 h TTL) and offers notify-and-open — no silent install until
// the 1.0 signed chain exists.

interface UpdateInfo {
  current: string;
  available: boolean;
  version: string | null;
  url: string | null;
}

export default function UpdateBanner() {
  const [info, setInfo] = useState<UpdateInfo | null>(null);
  const [dismissed, setDismissed] = useState('');

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const r = await api.updateCheck();
        if (!cancelled && r.available && r.version && r.url) setInfo(r);
      } catch {
        // update check is best-effort
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const { version, url } = info ?? {};
  if (!info || !version || !url || dismissed === version) return null;

  return (
    <div className="update-banner">
      <Icon name="rotate-cw" size={13} />
      <span>
        TermPilot {version} available
        <span className="update-banner-current"> — current {info.current}</span>
      </span>
      <a className="btn btn-primary" href={url} target="_blank" rel="noreferrer">
        Get it
      </a>
      <button className="btn-icon" aria-label="Dismiss" onClick={() => setDismissed(version)}>
        <Icon name="x" size={13} />
      </button>
    </div>
  );
}
