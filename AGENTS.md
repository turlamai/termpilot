# TermPilot agent contract

Human-first. Agent-native. Local by design.

Start with `raco glaze inspect --json` and `raco glaze doctor --json`.
Run `raco glaze schema check --json` before merging an API change.

## 实现路由（agent 按任务读真源）

- 实现界面以 `design/prototype/` 为准：对照 HTML/CSS/JS 与实物截图验收，不依赖散文复述。
- Token/几何值真源 = `design/prototype/shared.css`（亮暗成对；无 shared.css 的仓 = design/prototype/ 各页样式）；`design/DESIGN.md` 只记语义名、用途与决策。
- 行为边界与跨平台一致性以 `design/DESIGN.md` 的不变式与平台差异节为准。
- 改界面先改原型再改实现（tlai-prototype-flow）；动共享层（design/、shared/）先 issue 声明，同 commit 落契约。

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

## 设计流程（原型先行）

所有 UI 开发与界面改造一律先原型后代码：brief → `design/DESIGN.md`
视觉契约 → HTML 原型 → 按 HIG 基准评审通过才开工；改界面先改原型再改
代码。契约与原型放本仓 `design/`（尚未建立时随首个 UI 切片建立），
实物截图验收后才能作为对外宣传素材。
