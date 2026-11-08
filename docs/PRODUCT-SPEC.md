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
| SSH | ✓ | ✓ shipped | sidecar OpenSSH; agent/ProxyJump/known_hosts free |
| Local terminal | ✓ | ✓ shipped | `$SHELL` on a pty |
| Telnet | ✓ | ✓ shipped | `telnet` sidecar, availability-gated (doctor/transports) |
| Mosh | ✓ | ✓ shipped | `mosh` sidecar, availability-gated |
| Serial | ✓ | ✓ shipped | one-shot termios config + plain file ports (read leg validates on hardware) |
| SFTP | ✓ | ✓ shipped | batch-mode sidecar; inline transfers ≤10 MiB; recursive directory upload |

Rule: the transport seam (`backend/ssh.rkt`, to become
`backend/transports/`) maps a connection profile to `command + args`
(for sidecars) or a serial spec (device path + line parameters). UI
never knows which binary serves a session.

## 2. Terminal (parity floor)

- Tabs + split view — ✓ shipped (drag-rearrange pending)
- Themes (six packs) + global and per-host font size — ✓ shipped
- Search in terminal, clickable links, copy-on-select — ✓ shipped
- Scrollback ring — ✓ shipped (512 KiB, replay on re-attach)
- Session logging to file (per-host opt-in) — M2
- Broadcast input — ✓ shipped (per-session results)
- Reconnect on drop + keepalive override — ✓ shipped

## 3. Hosts, keys, forwarding, snippets (parity floor)

- Hosts: groups, tags, search, `~/.ssh/config` import, jump chains,
  per-host overrides (auth, strict host key, startup snippet, keepalive,
  terminal font) — ✓ shipped
- Known-hosts manager: view/search, remove stale entries — ✓ shipped
- Keys: generate Ed25519/ECDSA/RSA, fingerprint disclosure, public-key
  inspection, guarded deletion — ✓ shipped (public-key distribution to
  hosts: M2; import OpenSSH/PEM: M2)
- Port forwarding: local/remote/dynamic rules, per-host binding,
  start/stop with session, rules list view — ✓ shipped
- Snippets: parameter placeholders (`{{var}}` filled on run), run in
  current session — ✓ shipped (groups + broadcast run: M2)

## 4. AI-native additions (beyond Termius)

Termius has none of these. They are the product's reason to exist and
follow the family governance (AI proposes, user executes; redact
before send; BYOK only):

| Capability | Surface | Milestone |
|---|---|---|
| ⌘K command bar: NL → command draft → preview → insert into the focused terminal (never auto-run) | overlay palette | ✓ shipped |
| Selection explain / error diagnose | side panel | ✓ shipped |
| Redaction preview before every send | side panel + palette | ✓ shipped |
| AI-drafted snippets | snippet editor + ⌘K save-as-snippet | ✓ shipped |
| Session summary: long session → digest for handover/issue text | side panel + CLI/MCP | ✓ shipped |
| Failure evidence export (bounded, fingerprinted) | pane export + CLI + MCP | ✓ shipped |
| Deterministic CLI + MCP server | cli.rkt / mcp.rkt | ✓ shipped |

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
