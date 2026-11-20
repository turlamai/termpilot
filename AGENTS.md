# TermPilot agent contract

## 家族设计（必读入口）

- 设计/UI 任务先加载 `tlai-product`，必读 `references/policy.md` 与 `references/design-standard.md`（理念、决策规则、UI 验收）。技能缺失时读取 ZCode 真源：macOS/Linux `~/Sync/ZCode/skills/tlai-product/`；Windows `D:/ZCode/skills/tlai-product/`。无法读取须报告规范未核验，不凭记忆跳过。
- 家族规范管共性；本仓现有设计、行为与 token 真源管具体值和产品差异。例外记回原契约，不复制家族规则或新增数值表；已有界面按下一次相关切片渐进对齐。
- 改界面先改原型、落账后实现；按家族 UI 清单与本仓当前技术线的既有门禁验收，原型对照和真实交互证据都要保留；对外宣传使用验收后的实物截图。

## Current owner decision — 2026-11-18 quality-first

This product is in **non-commercial development**. The prior 2026-10/11 product pricing, trial, paid-feature, Free/Pro and family Permit/Commerce rollout decisions are canceled. Do not introduce checkout, subscriptions, activation, commercial entitlement, paid update windows or a paywall. Do not change source-license terms or release signing and identity verification. Prioritize product correctness, reliable native experience, recovery, bilingual README and truthful website claims. The [current family portfolio](https://github.com/turlamai/turlamai.github.io/blob/master/PORTFOLIO.md) governs every slice.


Human-first. Agent-native. Local by design.

Start with `raco glaze inspect --json` and `raco glaze doctor --json`.
Run `raco glaze schema check --json` before merging an API change.

## 实现路由（agent 按任务读真源）

- 实现界面以 `design/prototype/` 为准：对照 HTML/CSS/JS 与实物截图验收，不依赖散文复述。
- Token/几何值真源 = `design/prototype/shared.css`（亮暗成对；无 shared.css 的仓 = design/prototype/ 各页样式）；`design/DESIGN.md` 只记语义名、用途与决策。
- 行为边界与跨平台一致性以 `design/DESIGN.md` 的不变式与平台差异节为准。
- 改界面先改原型再改实现（tlai-product）；动共享层（design/、shared/）先 issue 声明，同 commit 落契约。

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

发布 = 同值四处：仓库根 `VERSION` 文件、`package.json`（含 workspace
各包）的 version、`backend/main.rkt` 的 `app-version`、`CHANGELOG.md`
顶部 `## [version]` 段 → 推 annotated tag `v*`，`release.yml` 三平台
打包并校验一致性。轻量 tag 会被 validate job 拒绝；本地先跑
`bash scripts/check-release-version.sh` 自查（tag 传参时校验四处）。

## Verification floor

- `raco test backend/` — unit + pty smoke (needs no display).
- `raco glaze schema check --json` — API contract.
- `pnpm check && pnpm build` — frontend types + bundle.
- Manual slice: open a local session in the running app and run a
  command end to end before any release tag.
