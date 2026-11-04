// Bridge to the TermPilot Racket backend.
//
// Two transports behind one interface (same shape the family uses):
//  - native: the page runs on the controlled glaze:// origin; calls ride
//    the GLZ1 message handler (window.__glz1, injected at document
//    start). No TCP port exists in production.
//  - http: the page is served by the loopback server (vite dev, the
//    explicit HTTP adapter) and talks plain relative fetch.
//
// Streaming routes keep a line protocol on both transports: the first
// line is `OK` (then raw bytes) or `ERR <status> <message>`.

type OnDelta = (text: string) => void;

interface Glz1 {
  invoke(
    path: string,
    args?: unknown,
    opts?: { method?: string; timeoutMs?: number }
  ): Promise<unknown>;
  invokeStream(
    path: string,
    args?: unknown,
    opts?: { method?: string; onDelta?: OnDelta; signal?: AbortSignal }
  ): Promise<string>;
}

declare global {
  interface Window {
    __glz1?: Glz1;
  }
}

function nativeBridge(): Glz1 | null {
  return (typeof window !== 'undefined' && window.__glz1) || null;
}

let probe: Promise<boolean> | null = null;

/** True once a backend answers — native bridge present, or /api/health ok. */
export function hasBackend(): Promise<boolean> {
  if (!probe) {
    const g = nativeBridge();
    probe = g
      ? Promise.resolve(true)
      : fetch('/api/health', { method: 'POST' })
          .then((r) => r.ok)
          .catch(() => false);
  }
  return probe;
}

/** POST JSON to the backend; returns the parsed response. */
export async function apiPost<T>(path: string, body?: unknown): Promise<T> {
  const g = nativeBridge();
  if (g) {
    return (await g.invoke(path, body ?? {})) as T;
  }
  const res = await fetch(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body ?? {}),
  });
  if (!res.ok) {
    const detail = await res.text();
    throw new Error(`${path} failed: ${res.status} ${detail.slice(0, 200)}`);
  }
  return (await res.json()) as T;
}

/**
 * Stream raw bytes after the status line. Resolves with the status-line
 * message ("OK") once the stream ends; deltas fire per chunk.
 */
export function apiStream(
  path: string,
  body: unknown,
  onDelta: OnDelta,
  signal?: AbortSignal,
): Promise<string> {
  const g = nativeBridge();
  if (g) {
    // The native channel delivers the handler's bytes verbatim as chunk
    // frames; the first chunk begins with the status line.
    let headerDone = false;
    let carry = '';
    return g.invokeStream(path, body ?? {}, {
      onDelta: (chunk: string) => {
        if (!headerDone) {
          carry += chunk;
          const nl = carry.indexOf('\n');
          if (nl < 0) return; // still inside the status line
          const status = carry.slice(0, nl).trim();
          headerDone = true;
          if (!status.startsWith('OK')) {
            throw new Error(status || 'stream failed');
          }
          const rest = carry.slice(nl + 1);
          carry = '';
          if (rest) onDelta(rest);
        } else {
          onDelta(chunk);
        }
      },
      signal,
    });
  }
  // HTTP: fetch + ReadableStream, same line protocol.
  return (async () => {
    const res = await fetch(path, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body ?? {}),
      signal,
    });
    if (!res.ok || !res.body) {
      throw new Error(`${path} failed: ${res.status}`);
    }
    const reader = res.body.getReader();
    const decoder = new TextDecoder('utf-8');
    let headerDone = false;
    let carry = '';
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      const chunk = decoder.decode(value, { stream: true });
      if (!headerDone) {
        carry += chunk;
        const nl = carry.indexOf('\n');
        if (nl < 0) continue;
        const status = carry.slice(0, nl).trim();
        headerDone = true;
        if (!status.startsWith('OK')) {
          throw new Error(status || 'stream failed');
        }
        const rest = carry.slice(nl + 1);
        if (rest) onDelta(rest);
      } else {
        onDelta(chunk);
      }
    }
    if (!headerDone) throw new Error('stream ended before status line');
    return 'OK';
  })();
}

// ---- typed helpers over the backend routes -------------------------------

export interface HostProfile {
  id: string;
  label: string;
  host: string;
  port: number;
  username: string;
  'auth-type': string;
  'identity-file': string;
  'group-name': string;
  tags: string[];
  notes: string;
  'strict-host-key': string;
  'sort-order': number;
}

export interface SessionInfo {
  id: string;
  kind: string;
  label: string;
}

export const api = {
  health: () => apiPost<{ ok: boolean; version: string }>('/api/health'),
  hostsList: () =>
    apiPost<{ hosts: HostProfile[] }>('/api/hosts/list'),
  hostCreate: (host: Partial<HostProfile>) =>
    apiPost<HostProfile>('/api/hosts/create', { host }),
  hostUpdate: (id: string, host: Partial<HostProfile>) =>
    apiPost<HostProfile>('/api/hosts/update', { id, host }),
  hostDelete: (id: string) =>
    apiPost<{ ok: boolean }>('/api/hosts/delete', { id }),
  snippetsList: () =>
    apiPost<{ snippets: { id: string; name: string; command: string }[] }>(
      '/api/snippets/list',
    ),
  terminalOpen: (body: {
    'host-id'?: string;
    kind?: string;
    host?: string;
    port?: number;
    username?: string;
    label?: string;
    cols: number;
    rows: number;
  }) => apiPost<SessionInfo>('/api/terminal/open', body),
  terminalInput: (id: string, data: string) =>
    apiPost<{ ok: boolean }>('/api/terminal/input', { id, data }),
  terminalResize: (id: string, cols: number, rows: number) =>
    apiPost<{ ok: boolean }>('/api/terminal/resize', { id, cols, rows }),
  terminalClose: (id: string) =>
    apiPost<{ ok: boolean }>('/api/terminal/close', { id }),
  sessionsList: () => apiPost<{ sessions: SessionInfo[] }>('/api/sessions/list'),
  aiSettings: () =>
    apiPost<{
      provider: string;
      model: string;
      'base-url': string;
      'api-key': string;
      'redact-enabled': boolean;
    }>('/api/ai/settings'),
  aiSettingsSave: (body: {
    provider: string;
    model: string;
    'base-url': string;
    'api-key': string;
    'redact-enabled': boolean;
  }) => apiPost<Record<string, unknown>>('/api/ai/settings/save', body),
  aiSettingsTest: () =>
    apiPost<{ ok: boolean; message: string }>('/api/ai/settings/test'),
  aiGenerate: (intent: string, hostContext?: string, terminal?: string) =>
    apiPost<{ command: string }>('/api/ai/generate', {
      intent,
      'host-context': hostContext ?? '',
      terminal: terminal ?? '',
    }),
  aiExplain: (output: string) =>
    apiPost<{ text: string }>('/api/ai/explain', { output }),
};
