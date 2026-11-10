# Contributing to TermPilot

Thank you for looking under the hood. TermPilot is free software
(AGPL-3.0, see [LICENSE](LICENSE)): by submitting a pull request you
agree your contribution is licensed under AGPL-3.0.

## Ground rules

1. **The glaze schema is the contract.** `glaze.rktd` and
   `glaze-schema.json` own the reviewed application contract between
   the Racket backend and the hosts. Run `raco glaze schema check
   --json` before merging an API change; update the baseline only with
   `raco glaze schema write` and review the diff.
2. **Ownership boundaries are fixed.** `backend/main.rkt` owns routes,
   events and window behavior; `backend/pty/` owns pseudo terminals
   (Unix bridges through script(1) forkpty — never reintroduce a
   blocking FFI read; Windows uses ConPTY); `backend/ssh.rkt` is the
   transport seam; `backend/ai/` owns BYOK settings, redaction and LLM
   calls; `apps/desktop/` and `packages/core/` own the web UI and the
   typed bridge. Business logic does not live in the shell.
3. **AI proposes; the user executes.** Every AI send path redacts
   first (`backend/ai/redact.rkt`), the preview shows what would
   leave, and no AI path writes credentials, host profiles or runs
   commands by itself. API keys are held by the backend and never
   enter the webview.
4. **Credentials stay in OpenSSH's hands.** Private key bytes never
   cross the bridge; password/passphrase prompts flow through the real
   PTY, never sniffed or stored. A session, tunnel or SFTP change that
   weakens host key verification defaults is a bug.
5. **Fail honestly.** Exit codes never lie; a failed check surfaces
   what failed and what to do next. No silent fallbacks — packaging
   steps `test -f` their installer outputs for exactly this reason.
6. **Bilingual is one product.** `README.zh-CN.md` keeps reciprocal
   updates with `README.md`; API/protocol identifiers and commands
   stay unchanged.
7. **Tests pin contracts.** If you change behavior a test covers,
   change the test in the same commit and say why.

## Before you push

```bash
raco test backend/                                 # unit + pty smoke
raco glaze schema check --json                     # API contract
pnpm check && pnpm build                           # frontend types + bundle
bash scripts/check-release-version.sh              # version consistency gate
```

These mirror the CI jobs. First-time setup installs the pinned Glaze
(`1fd99a5`) and Switchboard (`50a03c6`) packages. The Windows ConPTY
path compiles in its own CI job and is validated on the Windows leg;
if you touch `backend/pty/` or platform packaging, say whether you
were able to build locally, and open a real local session end to end
before any release tag.

## Reporting issues

Include: OS + version, TermPilot version, installation shape (DMG /
portable zip / MSI / deb / rpm / AppImage / tar.gz),
steps to reproduce, and for session issues the connection type (SSH /
local / telnet / mosh / serial / SFTP) plus the terminal output.
Security issues go through [SECURITY.md](SECURITY.md), not public
issues.
