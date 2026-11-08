# TermPilot

**English** · [中文](README.zh-CN.md)

The AI-native SSH client for macOS, Windows and Linux.

[![CI](https://github.com/turlamai/termpilot/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/termpilot/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/turlamai/termpilot)](https://github.com/turlamai/termpilot/releases) [![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

> 📖 **Product homepage**: [termpilot.jrtx.site](https://termpilot.jrtx.site)

TermPilot is a local-first desktop SSH client at Termius feature
parity or better: six connection types (SSH, local terminal, telnet,
mosh, serial, SFTP), host management with groups and tags, real
terminal sessions over the system OpenSSH (agent auth, ProxyJump and
known_hosts work out of the box), snippets, port forwarding, and an AI
assistant that drafts commands and explains output — with your own
model API key, redacted before anything leaves the machine.

**Human-first. Agent-native. Local by design.**

## Start here

TermPilot is in early development (v0.6.0 development preview). The architecture is proven —
the Racket backend streams a real PTY session to an xterm.js frontend over
GLZ1 — and what ships in the repository today is the working product
core: all six connection types, host/key/forwarding/snippet management,
the AI panel with redaction, and the agent surface below.

- Product spec (feature matrix + UI layout): [docs/PRODUCT-SPEC.md](docs/PRODUCT-SPEC.md)
- Architecture: [ARCHITECTURE.md](ARCHITECTURE.md)
- Development: [AGENTS.md](AGENTS.md)
- Pricing intent: [PRICING.md](PRICING.md) · [中文](PRICING.zh-CN.md)

## How it works

```
apps/desktop   Vite + React + TypeScript frontend, xterm.js terminal
backend/       Racket CS engine on Glaze (GLZ1 typed RPC + streams)
  pty/         pseudo terminals: script(1) forkpty bridge (Unix),
               ConPTY (Windows)
  ssh.rkt      OpenSSH sidecar orchestration — the transport seam
  ai/          BYOK presets, redaction, Switchboard LLM calls
  store.rkt    hosts / snippets on SQLite
packages/core  shared TypeScript bridge (typed RPC + streaming client)
```

- **Real terminals** — a pseudo terminal per session, so ssh agent
  prompts, TUI programs and password prompts behave exactly as in a
  native terminal.
- **The system OpenSSH as the transport** — agent forwarding, ProxyJump,
  config-file compatibility and new key exchange algorithms come free.
  The engine layer is a clean seam: an in-process SSH stack can replace
  the sidecar later without touching sessions, store or UI.
- **AI that proposes, never executes** — command drafts and output
  explanations flow into the terminal only when you send them. Every AI
  send path is redacted (private keys, tokens, credentials) and the
  redaction preview shows exactly what would leave the machine.
- **Your keys, your provider** — BYOK with presets for GLM, DeepSeek,
  Qwen, Kimi, Doubao, SiliconFlow, OpenAI, Anthropic and local Ollama.
  Keys live in a 0600 settings file inside the app data directory, are
  held by the Racket backend and never enter the webview.

## Agent surface

Agent-native means coding agents get the same truths as the UI, through
a deterministic CLI and an MCP server (stdio JSON-RPC) — both over the
same local store, no network unless you invoke `run`, exit codes that
never lie, JSON on `--json`:

```bash
racket cli.rkt hosts --json                      # host profiles
racket cli.rkt run web-1 "systemctl is-active nginx"   # one-shot over system ssh
                                                 #   add --timeout N to bound it (exit 124)
racket cli.rkt logs                              # session-log files (opt-in logging)
racket cli.rkt evidence web-1-0000000001.log     # bounded tail + sha1 — the citable failure dump
echo "<output>" | racket cli.rkt summarize -     # handover digest (BYOK key required)
racket mcp.rkt                                   # MCP: list_hosts, run_command, list_snippets,
                                                 #      list_logs, failure_evidence, session_summary
```

Evidence and summaries are the agent feedback loop: after a failed
`run`, `evidence` yields a bounded, fingerprinted dump an agent can
cite; `summarize` condenses a long session for handover. Both work
from the on-disk session logs the app writes on opt-in.

## Development

```bash
pnpm install
pnpm build          # frontend → apps/desktop/dist
raco glaze dev      # native window (or TERMPILOT_TRANSPORT=http)
raco test backend/  # unit + pty smoke tests
raco glaze schema check
```

## License

[AGPL-3.0](LICENSE) — the source stays open and copyleft. Official
distribution, updates and services are separate rights; see
[PRICING.md](PRICING.md) for the commercial model intent.
