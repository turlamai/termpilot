# TermPilot agent contract

Human-first. Agent-native. Local by design.

Start with `raco glaze inspect --json` and `raco glaze doctor --json`.
Run `raco glaze schema check --json` before merging an API change.

## Family policy (re-read at every slice boundary)

Record the SHA of each document you worked against:

- Product standard: https://github.com/turlamai/turlamai.github.io/blob/main/docs/PRODUCT-STANDARD.md — SHA:
- Documentation languages: https://github.com/turlamai/turlamai.github.io/blob/main/docs/DOCUMENTATION-LANGUAGES.md — SHA:
- Portfolio: https://github.com/turlamai/turlamai.github.io/blob/main/PORTFOLIO.md — SHA:

## Ownership boundary

- `backend/main.rkt` owns Racket routes, events and window behavior.
- `backend/pty/` owns pseudo terminals. `pty/unix.rkt` bridges through
  script(1) forkpty (a raw pty master fd cannot be integrated with the
  Racket scheduler without freezing the place — do not reintroduce a
  blocking FFI read); `pty/windows.rkt` uses ConPTY and is validated on
  the Windows leg.
- `backend/ssh.rkt` is the transport seam: session establishment lives
  here so the sidecar can be replaced by an in-process stack later.
- `backend/ai/` owns BYOK settings, redaction and LLM calls. API keys
  are held by the backend (0600 settings file) and never enter the
  webview; the UI sees the `__SAVED__` sentinel.
- `apps/desktop/` and `packages/core/` own the web UI and the typed
  bridge. Business logic does not live in the shell.
- `glaze-schema.json` is a reviewed release contract; update it with
  `raco glaze schema write` and review the diff.
- `dist/`, `apps/desktop/dist/`, `compiled/` are generated output.

## AI governance (family invariant)

AI proposes; the user executes. `api/ai/generate` returns a command
draft; `api/ai/explain` explains output. Every send path redacts first
(`backend/ai/redact.rkt`); the UI can preview redaction counts before
sending. No AI path writes credentials, host profiles or runs commands
by itself.

## Release procedure

发布 = 同值三处：`package.json` 的 version、`backend/main.rkt` 的
`app-version`、`CHANGELOG.md` 顶部 `## [version]` 段 → 推 annotated
tag `v*`，`release.yml` 三平台打包并校验一致性。轻量 tag 会被
validate job 拒绝。

## Verification floor

- `raco test backend/` — unit + pty smoke (needs no display).
- `raco glaze schema check --json` — API contract.
- `pnpm check && pnpm build` — frontend types + bundle.
- Manual slice: open a local session in the running app and run a
  command end to end before any release tag.
