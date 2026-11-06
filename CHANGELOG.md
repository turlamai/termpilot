# Changelog

All notable changes to TermPilot are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[SemVer](https://semver.org/).

## [Unreleased]

## [0.4.0] — 2026-11-06

Commercial completeness, minus signing (deferred by owner decision).

### Added

- Linux distribution matrix complete: AppImage + deb + rpm join the
  tar.gz (toolchains installed in the release pipeline).
- Split panes resize by dragging the divider; pickers navigate with
  arrow keys.
- Session log archive UI in settings (list/download/delete).
- Passphrase-wrapped encrypted export/import (PBKDF2 250k -> AES-GCM,
  self-describing container).
- FIDO2 hardware key generation options (ed25519-sk / ecdsa-sk).
- COMMERCIAL-CHECKLIST.md — the launch gates, signing deferred.

## [0.3.0] — 2026-11-06

The commercial-polish release: a designed system under the tool, and
the update chain.

### Added

- Design tokens: 4pt spacing grid, type scale (caption/body/title),
  semantic surface layers, consistent radii.
- Control system: primary/quiet/danger button hierarchy with designed
  hover/pressed/disabled states; global keyboard focus ring.
- Materials: modal dim+blur and entrance motion; toast notifications;
  promise-based in-app confirm dialogs replace window.confirm/alert.
- Updater: notify-and-open — the release pipeline publishes an update
  manifest to termpilot.jrtx.site, the app checks it (1 h cache,
  semver compare) and offers a dismissible banner. Silent auto-install
  waits for the 1.0 signed chain.
- M2 additions: snippet groups + broadcast run, key import and
  public-key distribution, session summary, failure-evidence export,
  session logging to file.

## [0.2.0] — 2026-11-05

M1 complete: the commercial core. First packaged release — macOS
(arm64/x64), Windows and Linux artifacts from the release pipeline.

### Added — M1 complete (commercial core)

- Product spec (docs/PRODUCT-SPEC.md): Termius-parity feature matrix,
  UI layout, milestone mapping.
- Neutral tool skin: hueless grayscale chrome, dark default, one
  restrained accent; SF-style monochrome icon set; Termius-derived
  pilot-dark terminal theme.
- Commercial UI shell: activity bar (hosts/SFTP/forwarding/snippets/
  keys/known-hosts/settings), group-tree sidebar with search, session
  tabs with split panes, collapsible AI panel, ⌘K command palette,
  bilingual UI (zh/en), light/dark/system theme.
- Hosts: full CRUD (auth, jump chain, startup command, keepalive,
  per-host terminal font size), `~/.ssh/config` import (concrete
  entries only, dedup), JSON export/import.
- Terminal floor: xterm.js with search, clickable links, copy on
  select, reconnect affordance, six theme packs, global + per-host
  font sizes; sessions stream over GLZ1 with scrollback replay.
- Port forwarding: saved rules drive `ssh -N -L/-R/-D` sidecars under
  the app custodian; start/stop/status live in the Forwarding view.
- Key manager: inventory (permissions/size), ssh-keygen generation,
  fingerprint disclosure, public-key-only content, guarded deletion.
- Known-hosts manager: search + index-based atomic removal.
- Transports beyond SSH: telnet and mosh sidecars (availability-
  gated), serial through a one-shot termios configuration with plain
  file ports (baud/parity/stop/data bits; smoke-tested against a pty
  stand-in; read leg validates on hardware), broadcast input with
  per-session results.
- SFTP: batch-mode sidecar operations (list/mkdir/rm/rmdir, inline
  download/upload with a 10 MiB cap) in the file manager view.
- AI governance in the UI: redaction preview before every send, ⌘K
  drafts insert-only (never auto-run), BYOK presets from the backend
  route, connectivity test, 0600 key custody with __SAVED__ sentinel.
- Agent surface: `cli.rkt` (hosts/snippets/transports [--json], one-
  shot run with honest exit codes) and `mcp.rkt` (stdio JSON-RPC MCP
  server: list_hosts, list_snippets, run_command).

## [0.1.0] — 2026-11-04

Project inception. The vertical slice is proven end to end: the Racket
backend streams a real PTY session (script(1) forkpty bridge on Unix,
ConPTY design on Windows) to an xterm.js frontend over GLZ1, with host
and snippet storage, BYOK AI settings with redaction, and the family
product surface (bilingual README, pricing plan, homepage, CI).

### Added

- Glaze backend: hosts/snippets SQLite store, terminal session manager
  with scrollback replay, streaming terminal byte channel, OpenSSH
  sidecar orchestration (`backend/ssh.rkt` seam), AI settings/test/
  generate/explain routes with redaction preview.
- PTY backends: `script(1)` forkpty bridge for macOS/Linux; ConPTY
  backend for Windows (validated on the Windows leg).
- Frontend: Vite + React + TypeScript app with xterm.js terminal view,
  host list, local shell entry; typed bridge with native/HTTP dual
  transport and shared streaming line protocol.
- AI: BYOK provider presets (GLM, DeepSeek, Qwen, Kimi, Doubao,
  SiliconFlow, OpenAI, Anthropic, Ollama) registered into Switchboard;
  0600 settings custody; redaction engine with preview.
- Product surface: bilingual README and pricing plan, architecture
  decision record, agent contract, product homepage, CI and release
  workflows.

[Unreleased]: https://github.com/turlamai/termpilot/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/turlamai/termpilot/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/turlamai/termpilot/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/turlamai/termpilot/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/turlamai/termpilot/releases/tag/v0.1.0
