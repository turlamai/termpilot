# TermPilot architecture

Status: accepted, 2026-11-04 · Supersedes: none

## Context

TermPilot is a Termius-class SSH client for the family: cross-platform
desktop, AI-era native, commercial standard. Two framework lines exist:
Rivet (first-party native UI per platform) and Glaze (Racket engine +
shared web UI in system WebViews).

## Decisions

### D1 — Glaze line

The product's hardest control is the terminal emulator. The Rivet line
would require three hand-built native terminal controls (WinUI 3 has
no terminal widget at all), with zero UI sharing. The Glaze line runs
one xterm.js frontend in every platform WebView while the Racket engine
owns sessions, store and AI. The family guidance is explicit: for a
shared HTML/CSS interface, choose Glaze. Consequence: the UI layer is
web tech inside a mandatory native window; there is no browser
fallback.

### D2 — System OpenSSH sidecar as the first transport

Session establishment shells out to the platform `ssh` binary (shipped
with macOS/Linux and Windows 10+). This buys agent auth and forwarding,
ProxyJump, known_hosts handling, config compatibility and automatic
algorithm updates for free, with zero C dependencies. `backend/ssh.rkt`
is the seam: everything above it (sessions, store, UI, AI) talks to an
abstract profile → argv mapping, so an in-process stack (libssh2 FFI)
can replace the sidecar without touching them. Consequence: SFTP and
port forwarding initially ride batch `ssh` invocations; the seam keeps
that swappable.

### D3 — Pseudo terminals through a forkpty bridge (Unix)

A terminal needs a PTY. A raw pty master fd cannot be integrated with
the Racket scheduler: the only ways to read it (blocking FFI call,
custom port with a blocking handler) freeze the entire place —
empirically verified; `unsafe-fd->evt`-based custom ports still hang.
The Unix backend therefore spawns `script(1)` (macOS BSD / util-linux),
which allocates the pty with forkpty(3), makes the child the session
leader with a controlling tty (proper SIGWINCH), and relays bytes over
plain subprocess pipes — real scheduler-integrated ports. Resize goes
`stty -f <slave> rows R cols C`; the kernel delivers SIGWINCH to the
foreground process group (the child). Consequence: one extra process
per session and no direct master fd; acceptable — the transport seam
absorbs future changes. Windows uses ConPTY (`pty/windows.rkt`,
validated on the Windows leg).

### D4 — Sessions outlive requests; one manager

Glaze runs each handler under a per-request custodian that shuts down
on return. Sessions must survive their opening request, so every
session (script child, pipes, pump thread) is spawned under an
app-owned custodian (`session-custodian`). One session manager holds
id → session; a pump thread per session appends child output to a
bounded 512 KiB scrollback ring and broadcasts to streaming subscribers.
Exited sessions linger until the user closes them (exited-tab UX).

### D5 — Streaming shape

Terminal output rides one raw byte stream per session
(`POST /api/terminal/stream`): a single `OK` status line, then pty
bytes until child exit — the same line protocol the family's LLM
streams use, so the bridge parser serves both. Typed invokes handle
input (`api/terminal/input`), resize and lifecycle. Reads use
`read-bytes-avail!` everywhere: `read-bytes` waits for a full buffer
and stalls interactive sessions.

### D6 — AI: BYOK, redact, propose-only

Provider presets (GLM, DeepSeek, Qwen, Kimi, Doubao, SiliconFlow,
OpenAI, Anthropic, Ollama) are registered into Switchboard, the family
LLM layer. Keys live in a 0600 `ai-settings.json` in the app data
directory, held by the backend; the webview only ever sees the
`__SAVED__` sentinel. Every send path redacts first (private keys, AWS
keys, tokens, bearer headers, credential assignments, connection
URIs); a preview route reports what would leave. AI returns command
drafts and explanations; nothing executes without the user.

### D7 — Local by design

Hosts, groups, tags, snippets live in SQLite in the app data directory
(macOS `~/Library/Application Support/termpilot`, Windows `%APPDATA%`,
Linux `~/.config`), exportable. There is no hosted sync service, no
account, no telemetry.

## Milestones

The authoritative feature matrix, UI layout and milestone mapping live
in [docs/PRODUCT-SPEC.md](docs/PRODUCT-SPEC.md) (Termius-parity floor
plus AI-native additions). Summary:

- M0 (this repository): vertical slice — host store, terminal sessions
  over the bridge, BYOK AI settings, site, CI.
- M1: commercial core — host manager, tabs + split view, themes,
  forwarding UI, snippets, ⌘K/explain/redaction UI, export/import,
  in-app updater.
- M2: reach + agent surface — SFTP, serial, telnet, mosh, key and
  known-hosts managers, broadcast input, CLI + MCP, signing.
- M3: commercial chain (Permit/Commerce), encrypted export, Flatpak,
  FIDO2 keygen, COMMERCIAL-CHECKLIST.
