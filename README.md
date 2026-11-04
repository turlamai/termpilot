# TermPilot

**English** · [中文](README.zh-CN.md)

The AI-native SSH client for macOS, Windows and Linux.

[![CI](https://github.com/turlamai/termpilot/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/termpilot/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/turlamai/termpilot)](https://github.com/turlamai/termpilot/releases) [![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

> 📖 **Product homepage**: [termpilot.jrtx.site](https://termpilot.jrtx.site)

TermPilot is a local-first desktop SSH client: host management with groups
and tags, real terminal sessions over the system OpenSSH (agent auth,
ProxyJump and known_hosts work out of the box), snippets, port forwarding,
and an AI assistant that drafts commands and explains output — with your
own model API key, redacted before anything leaves the machine.

**Human-first. Agent-native. Local by design.**

## Start here

TermPilot is in early development (v0.1.0). The architecture is proven —
the Racket backend streams a real PTY session to an xterm.js frontend over
GLZ1 — and the first release is on the way. What ships today in the
repository is the working vertical slice: host store, terminal sessions,
BYOK AI settings with redaction.

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
