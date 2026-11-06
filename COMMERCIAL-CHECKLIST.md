# TermPilot commercial checklist

Engineering gates before charging money. Mirrors the family reference
(taskly); checked items are done, deferred items name their owner and
trigger. Policy owner: PRICING.md (decision `2026-11-auth-1`).

## 1. License model

- [x] Source stays AGPL-3.0; commercial rights live in official
      distribution, updates and services — never by changing the
      source license.
- [x] No Free/Pro feature matrix; one complete purchase (¥168 / US$24
      launch target) with BYOK AI explicitly NOT paywalled.
- [ ] Permit/Commerce integration — deferred until first sale plans
      are real. No activation, accounts or phone-home before that
      (family rule: free products stay outside the commercial chain).

## 2. Distribution and updates

- [x] GitHub Releases only (winget/Homebrew declined; AUR/Snap/stores
      declined) — Linux = tar.gz + deb + rpm + AppImage; macOS =
      DMG + zip; Windows = zip.
- [x] Update chain: notify-and-open (release pipeline publishes
      update-manifest.json → Pages → in-app banner with semver check).
- [ ] **Signing and notarization — deferred by owner decision, needs
      credentials**: macOS Developer ID + notarization (Apple
      Developer Program), Windows Authenticode certificate, then
      `--sign` in the release jobs. Until then the DMG/MSI trigger
      Gatekeeper/SmartScreen warnings — say so in the release notes.
- [ ] Signed auto-install updates (glaze updater with Ed25519
      manifests) — after signing exists; notify-and-open is the
      deliberate pre-signing shape.
- [ ] Flatpak bundle — after first paid milestone (family matrix
      lists it; AppImage covers the portable need meanwhile).

## 3. Platform gates

- [ ] macOS notarization (see 2).
- [ ] Windows Authenticode (see 2).
- [ ] Linux: desktop entry + icons ship via glaze packaging ✓;
      Flathub submission deferred with Flatpak.

## 4. Privacy and support surface

- [x] Local by design: no telemetry, no accounts, no phone-home
      (update check fetches a static manifest — no user data leaves).
- [x] BYOK keys never leave the machine; 0600 custody; AI sends are
      redacted with preview.
- [ ] Privacy policy + terms pages on the site — before checkout
      exists (family standard: publish refund/cancellation rules,
      currency/tax totals before sales).
- [ ] Support scope statement (asynchronous issue handling, purchased
      version) — before sales.

## 5. Quality gates per release

- [x] `raco test` (unit + pty + serial smoke), schema check, three-
      platform CI green, packaged-binary HTTP smoke.
- [ ] Native-UI E2E per platform (rivet-line grade; currently manual
      browser acceptance on the HTTP adapter).
- [ ] Crash-free session over ≥48h personal use before tagging.
