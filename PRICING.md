# TermPilot product and pricing plan

**English** · [简体中文](PRICING.zh-CN.md)

## Launch status and implementation boundaries

- Policy version: `2026-11-v1`, 2026-11-04. TermPilot is in early
  development (v0.1.0) with no users. **Prices are launch targets, not
  live offers or claims that the listed features are implemented.**
- Entitlements cover delivered platforms only. Commercial plans do not
  change the LICENSE of released source. Source use, modification and
  redistribution rights are separate from official products, updates
  and services.
- Security fixes and reading, backing up or exporting your own data
  (hosts, snippets, sessions) must never require another purchase.
  BYOK model keys, payment-provider secrets and issuer private keys
  have different owners and must stay separated.

## Decision

**One purchase for the complete official desktop product**

Launch target: **¥168 / US$24; optional 12-month update renewal:
¥68 / US$10**. CNY and USD are independently set regional targets, not
an exchange-rate conversion.

Rationale follows the family reference (Taskly): daily professional use
and long-lived local data fit a single complete purchase; it avoids an
artificial Free/Pro feature matrix — and specifically an "AI tax".
BYOK AI features (command drafting, output explanation) remain part of
the complete product, not a subscription: the user pays their own
provider, our cost is zero, and charging monthly for an AI label adds
nothing.

## Free and paid scope

Free / evaluation: development previews stay free; no payment
restrictions are added to previews. The stable commercial edition has
a full 14-day trial. After the trial, host management, snippets and
standard-format export of all local data remain available. Terminal
sessions, port forwarding and AI assistance are part of the complete
product, not separately priced extras. Source remains AGPL-3.0.

Paid: one named user, covering the complete official macOS, Windows
and Linux desktop product on platforms actually delivered, with 12
months of new-version eligibility. A future mobile edition (pending
the family's mobile host) and any hosted service are not bundled
promises.

## Purchase, trial and updates

Same terms as the family standard: purchase includes 12 months of
new-version eligibility; versions obtained in the window remain usable
afterwards. Optional renewal adds 12 months from
`max(payment time, current updates_through)` — no automatic charge, no
back-billing. One named user on their own computers; no hardware
fingerprint; offline seat limits are contractual, not enforced by
phone-home. There is no lifetime-all-future-updates plan.

Trial expiry preserves host management, snippets and export. Do not
presell codes before technical and platform gates pass. After a
successful payment, Commerce issues Permit credentials idempotently.

## Authorization decision for implementation

Decision revision: `2026-11-auth-1` (2026-11-04). Signed Protocol v1
`entitlement`, verified locally through the public `permit` facade;
`activation_required=false`, `installation_id=null`; no activation
leases, no periodic online checks, no hardware binding, no device cap.
`use_expires_at=null`; `updates_through` is the paid update cutoff;
`feature_policy="published-through"`. Opaque stable person subject,
never an email address as the authorization key. Renewal keeps
`entitlement_id`, bumps `revision`, replaces the full snapshot.
Follow Permit's normative entitlement semantics; this document owns
product policy, not a second wire protocol.
