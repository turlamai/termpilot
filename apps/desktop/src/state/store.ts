// App state (zustand): active view, theme/language, hosts, snippets,
// tabs with panes, focused session, and the AI panel. Session output
// rings live here so the AI palette can use recent terminal context.

import { create } from 'zustand';
import { api, type HostProfile } from '@termpilot/core';
import { detectLang, translate, type Lang } from '../i18n';

export type ViewId =
  | 'hosts'
  | 'sftp'
  | 'forward'
  | 'snippets'
  | 'keys'
  | 'known'
  | 'settings';

export type Theme = 'light' | 'dark' | 'system';

export interface Pane {
  sessionId: string;
  label: string;
  kind: string; // ssh | local | telnet | mosh | serial
  hostId?: string; // set when opened from a host (reconnect, overrides)
}

export interface Tab {
  id: string;
  panes: Pane[];
}

interface OutputRing {
  chunks: string[];
  size: number;
}

const RING_CHUNKS = 64;

let idSeq = 0;
const nextId = () => `t${Date.now().toString(36)}${(idSeq++).toString(36)}`;

function detectTheme(): Theme {
  const stored = localStorage.getItem('termpilot-theme');
  if (stored === 'light' || stored === 'dark' || stored === 'system') {
    return stored;
  }
  // A terminal tool defaults to its dark skin; system-follow stays
  // opt-in for people who want it.
  return 'dark';
}

export interface AppState {
  view: ViewId;
  lang: Lang;
  theme: Theme;

  hosts: HostProfile[];
  hostsLoaded: boolean;
  snippets: { id: string; name: string; command: string }[];
  presets: {
    id: string;
    label: string;
    model: string;
    'base-url': string;
    kind: string;
  }[];

  tabs: Tab[];
  activeTabId: string | null;
  focusedSessionId: string | null;

  aiPanelOpen: boolean;
  paletteOpen: boolean;
  shortcutsOpen: boolean;
  outputRings: Record<string, OutputRing>;
  selections: Record<string, string>; // sessionId -> selected text
  broadcastTabs: Record<string, boolean>; // tabId -> broadcasting
  termThemeId: string;
  termFontSize: number;

  setView: (v: ViewId) => void;
  setLang: (l: Lang) => void;
  setTheme: (t: Theme) => void;
  t: (key: string) => string;

  refreshHosts: () => Promise<void>;
  refreshSnippets: () => Promise<void>;
  refreshPresets: () => Promise<void>;

  openSession: (
    spec:
      | { 'host-id': string; label?: string }
      | { kind: 'local'; label?: string }
      | { host: string; port?: number; username?: string; label?: string },
    opts?: { split?: boolean },
  ) => Promise<void>;
  closePane: (tabId: string, sessionId: string) => void;
  closeTab: (tabId: string) => void;
  reorderTabs: (from: number, to: number) => void;
  toggleBroadcast: (tabId: string) => void;
  focusSession: (sessionId: string) => void;

  setAiPanel: (open: boolean) => void;
  setPalette: (open: boolean) => void;
  setShortcutsOpen: (open: boolean) => void;
  setTermPrefs: (themeId: string, fontSize: number) => void;
  reconnectPane: (tabId: string, sessionId: string) => Promise<void>;
  appendOutput: (sessionId: string, text: string) => void;
  setPaneTitle: (sessionId: string, title: string) => void;
  setSelection: (sessionId: string, text: string) => void;
  recentOutput: (sessionId: string, maxChars?: number) => string;
}

export const useApp = create<AppState>((set, get) => ({
  view: 'hosts',
  lang: detectLang(),
  theme: detectTheme(),

  hosts: [],
  hostsLoaded: false,
  snippets: [],
  presets: [],

  tabs: [],
  activeTabId: null,
  focusedSessionId: null,

  aiPanelOpen: false,
  paletteOpen: false,
  shortcutsOpen: false,
  outputRings: {},
  selections: {},
  broadcastTabs: {},
  termThemeId: localStorage.getItem('termpilot-termtheme') ?? 'pilot-dark',
  termFontSize: Number(localStorage.getItem('termpilot-fontsize') ?? 13) || 13,

  setView: (v) => set({ view: v }),

  setLang: (l) => {
    localStorage.setItem('termpilot-lang', l);
    set({ lang: l });
  },

  setTheme: (t) => {
    localStorage.setItem('termpilot-theme', t);
    set({ theme: t });
  },

  t: (key) => translate(get().lang, key),

  refreshHosts: async () => {
    try {
      const { hosts } = await api.hostsList();
      set({ hosts, hostsLoaded: true });
    } catch {
      set({ hostsLoaded: true });
    }
  },

  refreshSnippets: async () => {
    try {
      const { snippets } = await api.snippetsList();
      set({ snippets });
    } catch {
      // backend absent (vite-only dev); leave empty
    }
  },

  refreshPresets: async () => {
    try {
      const { presets } = await api.aiPresets();
      set({ presets });
    } catch {
      // backend absent; settings view falls back to typed-in values
    }
  },

  openSession: async (spec, opts) => {
    const active = get().tabs.find((t) => t.id === get().activeTabId);
    const splitInto = opts?.split && active ? active : null;
    try {
      const body =
        'host-id' in spec
          ? { 'host-id': spec['host-id'], cols: 120, rows: 30 }
          : 'host' in spec
            ? // quick connect: direct profile, nothing saved
              {
                host: spec.host,
                port: spec.port ?? 22,
                username: spec.username ?? '',
                label: spec.label ?? spec.host,
                cols: 120,
                rows: 30,
              }
            : { kind: 'local', cols: 120, rows: 30 };
      const session = await api.terminalOpen(body);
      const hostId = 'host-id' in spec ? spec['host-id'] : undefined;
      const pane: Pane = {
        sessionId: session.id,
        label: session.label,
        kind: session.kind,
        hostId,
      };
      // Startup command: sent into the session right after it opens.
      if (hostId) {
        const host = get().hosts.find((h) => h.id === hostId);
        const snippet = host?.['startup-snippet']?.trim();
        if (snippet) {
          setTimeout(() => {
            void api
              .terminalInput(session.id, snippet.endsWith('\n') ? snippet : `${snippet}\n`)
              .catch(() => undefined);
          }, 600);
        }
      }
      if (splitInto) {
        set({
          tabs: get().tabs.map((t) =>
            t.id === splitInto.id ? { ...t, panes: [...t.panes, pane] } : t,
          ),
          focusedSessionId: pane.sessionId,
        });
      } else {
        const tab: Tab = { id: nextId(), panes: [pane] };
        set({
          tabs: [...get().tabs, tab],
          activeTabId: tab.id,
          focusedSessionId: pane.sessionId,
        });
      }
    } catch (e) {
      console.error('open session failed', e);
    }
  },

  closePane: (tabId, sessionId) => {
    void api.terminalClose(sessionId).catch(() => undefined);
    const tabs = get()
      .tabs.map((t) =>
        t.id === tabId
          ? { ...t, panes: t.panes.filter((p) => p.sessionId !== sessionId) }
          : t,
      )
      .filter((t) => t.panes.length > 0);
    const activeTabId =
      tabs.find((t) => t.id === get().activeTabId)?.id ?? tabs.at(-1)?.id ?? null;
    set({ tabs, activeTabId });
    if (get().focusedSessionId === sessionId) {
      set({ focusedSessionId: activeTabId ? (tabs.find((t) => t.id === activeTabId)?.panes.at(-1)?.sessionId ?? null) : null });
    }
  },

  toggleBroadcast: (tabId) => {
    set({
      broadcastTabs: {
        ...get().broadcastTabs,
        [tabId]: !get().broadcastTabs[tabId],
      },
    });
  },

  reorderTabs: (from, to) => {
    const tabs = [...get().tabs];
    const [moved] = tabs.splice(from, 1);
    tabs.splice(to, 0, moved);
    set({ tabs });
  },

  closeTab: (tabId) => {
    const tab = get().tabs.find((t) => t.id === tabId);
    if (!tab) return;
    for (const p of tab.panes) {
      void api.terminalClose(p.sessionId).catch(() => undefined);
    }
    const tabs = get().tabs.filter((t) => t.id !== tabId);
    const activeTabId =
      get().activeTabId === tabId
        ? (tabs.at(-1)?.id ?? null)
        : get().activeTabId;
    set({ tabs, activeTabId });
  },

  focusSession: (sessionId) => set({ focusedSessionId: sessionId }),

  setAiPanel: (open) => set({ aiPanelOpen: open }),
  setPalette: (open) => set({ paletteOpen: open }),
  setShortcutsOpen: (open) => set({ shortcutsOpen: open }),

  setTermPrefs: (themeId, fontSize) => {
    localStorage.setItem('termpilot-termtheme', themeId);
    localStorage.setItem('termpilot-fontsize', String(fontSize));
    set({ termThemeId: themeId, termFontSize: fontSize });
  },

  reconnectPane: async (tabId, sessionId) => {
    const tab = get().tabs.find((t) => t.id === tabId);
    const old = tab?.panes.find((p) => p.sessionId === sessionId);
    if (!tab || !old) return;
    // Close the dead pane, then open a fresh one into the same tab.
    const hadPanes = tab.panes.length > 1;
    get().closePane(tabId, sessionId);
    await get().openSession(
      old.hostId
        ? { 'host-id': old.hostId, label: old.label }
        : { kind: 'local', label: old.label },
      { split: hadPanes && get().tabs.some((t) => t.id === tabId) },
    );
  },

  setPaneTitle: (sessionId, title) => {
    if (!title.trim()) return;
    set({
      tabs: get().tabs.map((t) => ({
        ...t,
        panes: t.panes.map((p) =>
          p.sessionId === sessionId ? { ...p, label: title } : p,
        ),
      })),
    });
  },

  appendOutput: (sessionId, text) => {
    if (!text) return;
    const rings = { ...get().outputRings };
    const ring = rings[sessionId] ?? { chunks: [], size: 0 };
    const chunks = [...ring.chunks, text];
    while (chunks.length > RING_CHUNKS) chunks.shift();
    rings[sessionId] = { chunks, size: ring.size + text.length };
    set({ outputRings: rings });
  },

  setSelection: (sessionId, text) => {
    set({ selections: { ...get().selections, [sessionId]: text } });
  },

  recentOutput: (sessionId, maxChars = 6000) => {
    const ring = get().outputRings[sessionId];
    if (!ring) return '';
    return ring.chunks.join('').slice(-maxChars);
  },
}));
