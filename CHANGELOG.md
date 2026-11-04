# Changelog

All notable changes to TermPilot are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[SemVer](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/turlamai/termpilot/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/turlamai/termpilot/releases/tag/v0.1.0
