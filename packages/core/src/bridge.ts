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
  jump: string;
  'startup-snippet': string;
  'keep-alive': number;
  'font-size': number;
  'connection-kind': string;
  parity?: string;
  stopbits?: number;
}

export interface KeyEntry {
  name: string;
  'has-public': boolean;
  permissions: string;
  bytes: number;
}

export interface KeyMeta {
  bits: string;
  fingerprint: string;
  comment: string;
  type: string;
}

export interface KnownEntry {
  index: number;
  host: string;
  keytype: string;
  comment: string;
}

export interface ForwardRule {
  id: string;
  name: string;
  kind: 'local' | 'remote' | 'dynamic';
  'host-id': string;
  'bind-host': string;
  'local-port': number;
  'remote-host': string;
  'remote-port': number;
  'created-at': number;
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
  hostsImportConfig: () =>
    apiPost<{ imported: number; skipped: number }>('/api/hosts/import-config'),
  dataExport: () =>
    apiPost<{
      version: string;
      'exported-at': number;
      hosts: unknown[];
      snippets: unknown[];
    }>('/api/data/export'),
  dataImport: (data: unknown) =>
    apiPost<{ hosts: number; snippets: number }>('/api/data/import', { data }),
  forwardRules: () =>
    apiPost<{
      rules: ForwardRule[];
    }>('/api/forward/rules'),
  forwardCreate: (rule: Omit<ForwardRule, 'id' | 'created-at'>) =>
    apiPost<ForwardRule>('/api/forward/create', { rule }),
  forwardDelete: (id: string) =>
    apiPost<{ ok: boolean }>('/api/forward/delete', { id }),
  forwardStart: (id: string) =>
    apiPost<{ started?: boolean; 'already-running'?: boolean }>(
      '/api/forward/start',
      { id },
    ),
  forwardStop: (id: string) =>
    apiPost<{ stopped?: boolean; running?: boolean }>('/api/forward/stop', { id }),
  forwardStatus: () =>
    apiPost<{ tunnels: { id: string; running: boolean }[] }>(
      '/api/forward/status',
    ),
  sftpList: (hostId: string, path: string) =>
    apiPost<{
      path: string;
      entries: { name: string; dir: boolean; size: number | null; perms: string }[];
    }>('/api/sftp/list', { 'host-id': hostId, path }),
  sftpMkdir: (hostId: string, path: string) =>
    apiPost<{ ok: boolean }>('/api/sftp/mkdir', { 'host-id': hostId, path }),
  sftpDelete: (hostId: string, path: string) =>
    apiPost<{ ok: boolean }>('/api/sftp/delete', { 'host-id': hostId, path }),
  sftpRmdir: (hostId: string, path: string) =>
    apiPost<{ ok: boolean }>('/api/sftp/rmdir', { 'host-id': hostId, path }),
  sftpDownload: (hostId: string, path: string) =>
    apiPost<string>('/api/sftp/download', { 'host-id': hostId, path }),
  sftpUpload: (hostId: string, path: string, data: Uint8Array) =>
    apiPost<{ ok: boolean }>(
      '/api/sftp/upload',
      {
        'host-id': hostId,
        path,
        data: btoa(String.fromCharCode(...data)),
      },
    ),
  keysList: () =>
    apiPost<{ keys: KeyEntry[] }>('/api/keys/list'),
  keyMeta: (name: string) =>
    apiPost<KeyMeta>('/api/keys/meta', { name }),
  keyGenerate: (name: string, type: string, passphrase?: string) =>
    apiPost<{ name: string; generated: boolean }>(
      '/api/keys/generate',
      { name, type, passphrase: passphrase ?? '' },
    ),
  keyPublic: (name: string) =>
    apiPost<{ name: string; public: string }>('/api/keys/public', { name }),
  keyDelete: (name: string) =>
    apiPost<{ name: string; deleted: boolean }>('/api/keys/delete', { name }),
  knownList: () =>
    apiPost<{ entries: KnownEntry[] }>('/api/known/list'),
  knownRemove: (index: number) =>
    apiPost<{ removed: number; remaining: number }>('/api/known/remove', { index }),
  snippetsList: () =>
    apiPost<{ snippets: { id: string; name: string; command: string; tags: string[] }[] }>(
      '/api/snippets/list',
    ),
  snippetCreate: (snippet: {
    name: string;
    command: string;
    tags?: string[];
  }) => apiPost<{ id: string }>('/api/snippets/create', { snippet }),
  snippetDelete: (id: string) =>
    apiPost<{ ok: boolean }>('/api/snippets/delete', { id }),
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
  terminalBroadcast: (ids: string[], data: string) =>
    apiPost<{ sent: number; results: { id: string; ok: boolean }[] }>(
      '/api/terminal/broadcast',
      { ids, data },
    ),
  doctorTransports: () =>
    apiPost<{
      ssh: boolean;
      telnet: boolean;
      mosh: boolean | string;
      serial: boolean | string;
      'ssh-keygen': boolean;
    }>('/api/doctor/transports'),
  terminalLogStart: (id: string) =>
    apiPost<{ path: string }>('/api/terminal/log/start', { id }),
  terminalLogStop: (id: string) =>
    apiPost<{ ok: boolean }>('/api/terminal/log/stop', { id }),
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
  aiPresets: () =>
    apiPost<{
      presets: {
        id: string;
        label: string;
        model: string;
        'base-url': string;
        kind: string;
      }[];
    }>('/api/ai/presets'),
  aiSettingsSave: (body: {
    provider: string;
    model: string;
    'base-url': string;
    'api-key': string;
    'redact-enabled': boolean;
  }) => apiPost<Record<string, unknown>>('/api/ai/settings/save', body),
  aiSettingsTest: () =>
    apiPost<{ ok: boolean; message: string }>('/api/ai/settings/test'),
  aiRedactPreview: (text: string) =>
    apiPost<{
      text: string;
      counts: [string, number][];
      clean: boolean;
    }>('/api/ai/redact-preview', { text }),
  aiGenerate: (intent: string, hostContext?: string, terminal?: string) =>
    apiPost<{ command: string }>('/api/ai/generate', {
      intent,
      'host-context': hostContext ?? '',
      terminal: terminal ?? '',
    }),
  aiExplain: (output: string) =>
    apiPost<{ text: string }>('/api/ai/explain', { output }),
};
