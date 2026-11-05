# TermPilot product spec

Status: draft v2, 2026-11-05 · Owner: this repository

Design baseline: Termius (commercial SSH client) — full feature parity
as the floor, exceeded with AI-native capability. This document owns
the feature matrix, the UI layout and the milestone mapping.
ARCHITECTURE.md owns the technical decisions behind them.

## 1. Connection types (parity matrix)

Termius ships six connection types. TermPilot ships the same six, each
through the same session machinery (one pty or serial byte stream per
session, one scrollback ring, one streaming channel):

| Type | Termius | TermPilot | Engine note |
|---|---|---|---|
| SSH | ✓ | ✓ (v0.1) | sidecar OpenSSH; agent/ProxyJump/known_hosts free |
| Local terminal | ✓ | ✓ (v0.1) | `$SHELL` on a pty |
| Telnet | ✓ | M1 | `telnet` sidecar when present; doctor checks |
| Mosh | ✓ | M1 | `mosh` sidecar; doctor checks; UDP note in UI |
| Serial | ✓ | M2 | device + termios (baud/parity/stop/flow); no forkpty needed — configure the fd once, then plain file ports |
| SFTP | ✓ | M2 | file browser over the transport seam |

Rule: the transport seam (`backend/ssh.rkt`, to become
`backend/transports/`) maps a connection profile to `command + args`
(for sidecars) or a serial spec (device path + line parameters). UI
never knows which binary serves a session.

## 2. Terminal (parity floor)

- Tabs + split view (2×2, drag to rearrange) — M1
- Themes (family warm palette set, import xterm.js themes) + per-host
  font/size override — M1
- Search in terminal, clickable links, copy-on-select — M1
- Scrollback ring (done: 512 KiB, replay on re-attach)
- Session logging to file (per-host opt-in) — M2
- Broadcast input (type once, fans out to the selected sessions) — M2
- Reconnect on drop + keepalive (done: ServerAliveInterval) — M1 polish

## 3. Hosts, keys, forwarding, snippets (parity floor)

- Hosts: groups, tags, search, `~/.ssh/config` import, jump chains,
  per-host overrides (auth, strict host key, startup snippet, encoding,
  keepalive, terminal profile) — M1
- Known-hosts manager: view/search, remove stale entries — M2
- Keys: generate Ed25519/ECDSA/RSA; import OpenSSH/PEM; public-key
  distribution to hosts; agent status view — M2
  (FIDO2 `ed25519-sk` keys work through the sidecar when the hardware
  key is present; keygen for `-sk` types follows the sidecar, M3)
- Port forwarding: local/remote/dynamic rules, per-host binding,
  start/stop with session, rules list view — M1
- Snippets: groups, parameter placeholders (`{{var}}` filled on run),
  run in current session or broadcast; AI may draft a snippet, the user
  saves it — M1

## 4. AI-native additions (beyond Termius)

Termius has none of these. They are the product's reason to exist and
follow the family governance (AI proposes, user executes; redact
before send; BYOK only):

| Capability | Surface | Milestone |
|---|---|---|
| ⌘K command bar: NL → command draft → preview → insert into the focused terminal (never auto-run) | overlay palette | M1 |
| Selection explain / error diagnose: selected output → what happened, why, next step | side panel | M1 |
| Redaction preview: before any send, show counts and masked shapes | side panel + toast | M1 (engine done) |
| AI-drafted snippets: save an assistant answer as a snippet | snippet editor | M1 |
| Session summary: long session → digest for handover/issue text | side panel | M2 |
| Failure evidence export: bounded, fingerprinted diagnostics for coding agents (family idiom) | CLI | M2 |
| Deterministic JSON CLI + MCP server: list hosts, run one-shot commands, manage snippets — for coding agents | CLI/MCP | M2 |

## 5. Sync, vault, teams

Termius monetizes an encrypted cloud vault. TermPilot stays local by
design: no hosted sync service. Parity is met differently —

- Local data lives in SQLite, export/import as versioned JSON — M1
- Hosts/keys/snippets folder is sync-agnostic: point it at any file
  sync (Resilio family style) — M2
- Encrypted export (passphrase-wrapped) for backup — M3
- Teams/sharing: out of scope until the commercial chain (M3+) decides
  otherwise; no vault servers are planned

## 6. UI layout

Single-window, activity bar + sidebar + tab/terminal area + AI panel —
the Termius grammar, with an AI column the user can collapse.

```
┌──┬──────────────────┬────────────────────────────────────────┐
│ A│ Sidebar          │ [tab][tab][tab][+]        ⌘K          │
│ c│  ┌────────────┐  ├────────────────────────────────────────┤
│ t│  │ search     │  │                                        │
│ i│  └────────────┘  │   terminal pane (split view)           │
│ v│  ▾ PROD          │   ┌──────────────────┬───────────────┐ │
│ i│    web-1         │   │                  │               │ │
│ t│    db-1          │   │                  │               │ │
│ y│  ▾ STAGING       │   └──────────────────┴───────────────┘ │
│  │    ci-1          │────────────────────────────────────────│
│ b│                  │ AI panel (collapsible)                 │
│ a│ ──────────────   │  ⌘K drafts → [insert][copy][discard]   │
│ r│  New Host        │  selection explain / diagnosis         │
│  │  New Tunnel      │  redaction preview before send         │
│ 🖥│  New Snippet     │  session digest (M2)                   │
│ 📁│                  │                                        │
│ ⇄│                  │                                        │
│ ⚡│                  │                                        │
│ 🔑│                  │                                        │
│ 🛡│                  │                                        │
│ ⚙│                  │                                        │
└──┴──────────────────┴────────────────────────────────────────┘
```

- **Activity bar (A)**: Hosts, SFTP, Forwarding, Snippets, Keys,
  Known-hosts, Settings — one view per concern (Termius pattern).
- **Sidebar**: view-specific list (tree for hosts, rules table for
  forwarding, grouped list for snippets) with search/filter on top and
  the view's "New …" action at the bottom.
- **Tab bar**: sessions as tabs; drag to split; split panes resizable;
  the tab shows kind (SSH/local/serial/telnet/mosh) as an icon + label.
- **⌘K**: opens the AI command palette over the focused terminal; draft
  insertion requires explicit user action; Esc discards.
- **AI panel**: never auto-opens; redaction preview is inline; keys are
  never shown (the `__SAVED__` sentinel comes from the backend).
- **Settings**: connection profiles, terminal (theme/font/scrollback),
  AI (provider preset, model, redact toggle, connectivity test), about.

Platform conventions follow each OS (native shortcuts, menus); the
interaction logic is identical on macOS/Windows/Linux per the family
standard.

## 7. Milestone mapping (supersedes the ARCHITECTURE.md list)

- **M1 — commercial core**: host manager (groups/tags/config import/
  jump chains/per-host overrides), tabs + split view, themes/fonts,
  search/links/copy-on-select, forwarding UI, snippets (groups/
  parameters), ⌘K + explain + redaction UI, export/import JSON,
  in-app updater, reconnect/keepalive polish.
- **M2 — reach + agent surface**: SFTP browser, serial connections,
  telnet + mosh sidecars, known-hosts manager, key manager (gen/
  import/distribute), broadcast input, session logging, session
  digest, CLI + MCP, signing + notarization.
- **M3 — commercial chain**: Permit/Commerce entitlements + trial,
  encrypted export, Flatpak bundle, FIDO2 keygen (`-sk`), COMMERCIAL-
  CHECKLIST, mobile roadmap note (pending the family mobile host).

Each milestone keeps the family gates: `raco test` green, schema check
green, three-platform CI green, docs updated in the same slice.
