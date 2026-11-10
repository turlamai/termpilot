# Security Policy

TermPilot is local-first: hosts, snippets and settings live in a local
SQLite database in the app data directory, SSH sessions run through
the system OpenSSH, and private keys stay in `~/.ssh` where OpenSSH
put them. Reports are taken seriously and handled quickly.

## Reporting a vulnerability

Email **security@jrtx.site** (or open a GitHub security advisory on this
repository). Include reproduction steps, affected versions, and your
assessment of impact. You will get an acknowledgment within 72 hours.

Please do not open public issues for security problems.

## Scope

In scope:

- SSH credential handling: the key manager's view of `~/.ssh`
  (`backend/keys.rkt` — private key bytes are never returned across
  the bridge, listings expose filename/type/permissions only,
  generation shells out to `ssh-keygen`, deletion is refused for
  anything outside `~/.ssh`) and the authentication profiles in the
  host store (`backend/store.rkt` — auth-type, identity-file paths).
  Password and passphrase prompts must flow through the real PTY to
  the user, never be sniffed, logged or stored.
- Host key verification: the `StrictHostKeyChecking` policy TermPilot
  passes to OpenSSH (per-profile, default `accept-new` — TOFU; changed
  keys hard-fail), and the known-hosts manager's inventory and removal
  of `~/.ssh/known_hosts` (`backend/knownhosts.rkt` — hashed `|1|`
  entries are listed with the hash intact, removal matches whole
  entries and never corrupts the file).
- The update check: the Ed25519-signed manifest fetched from
  `https://github.com/turlamai/termpilot/releases/latest/download/update-manifest.json`
  and verified against the public key embedded in
  `backend/updater.rkt` (wrapper schema + key id via `glaze/update`,
  signature via the crypto package's libcrypto FFI). The check is
  **notify-and-open only** (a banner linking to the release page) and
  nothing is downloaded or installed automatically. Any move toward
  auto-install is a bug; so is degrading the check to accept an
  unsigned manifest, a foreign key id, or an HTTP (non-TLS) feed. The
  unsigned manifest at termpilot.jrtx.site serves 0.8.0-and-older
  clients only and is never read by the current backend.
- The AI send path: the BYOK API key lives in a 0600 settings file in
  the app data directory, is held by the Racket backend and never
  enters the webview; every outbound AI request passes redaction
  (`backend/ai/redact.rkt`), and the redaction preview must show
  exactly what leaves the machine.
- The host/backend boundary: hosts render; the Racket backend
  (`backend/main.rkt`, contract in `glaze.rktd` / `glaze-schema.json`)
  decides. Crypto, policy or credential handling sneaking into a host
  is a bug.

Out of scope: vulnerabilities in the system OpenSSH, in
`ssh-keygen`, or in the OS credential/agent infrastructure
(ssh-agent, Keychain, Windows Credential Manager) — those belong to
their upstreams; social engineering; physical access.

## Design notes reviewers should know

- **The engine owns no listening network port.** The production
  transport is the native GLZ1 page in the embedded webview; the HTTP
  adapter is a development surface gated by `GLAZE_API_TOKEN` on
  loopback. Outbound network is: the SSH/SFTP connections you initiate
  (via the OpenSSH sidecar), the LLM endpoint you configured, and the
  update check.
- **TermPilot never speaks the SSH protocol itself.** Sessions,
  tunnels, forwarding and SFTP all execute the system OpenSSH as a
  sidecar, so host key verification, agent forwarding, ProxyJump and
  config-file semantics are exactly the OpenSSH implementation the OS
  ships and updates.
- **Auth is agent-first and fails fast.** Agent auth runs with
  `BatchMode=yes` so it can never fall into an interactive password
  prompt on the machine's behalf; interactive password/passphrase
  entry happens only through the visible terminal session.
- **Local data is plain SQLite and plain files** (`termpilot.db`, the
  settings file, session records) under the platform data directory,
  protected by OS user permissions — not encrypted. Nothing here is
  telemetry: host lists, snippets and session output stay on disk and
  are never uploaded anywhere. The AI send path is the one place
  content leaves the machine, redacted and previewed.
- **The update feed is the trust root for update notifications.** The
  manifest is an Ed25519-signed wrapper (family feed format:
  `{schema, payload, signature{ed25519, key_id, value}}`) published as
  a GitHub release asset; the backend verifies the signature against
  the embedded public key and the pinned key id (`termpilot-2026-11`)
  before trusting anything inside it. The private key exists only in
  the `UPDATE_ED25519_PRIVATE_KEY` CI secret and locally outside the
  repository. Releases also publish a checked `SHA256SUMS` covering
  every payload and build-provenance attestations. Do not represent
  the update banner as more than it is: a verified notification, not
  an install.

## Supported versions

Security fixes land on `main` first and ship with the next tagged
release. During the 0.x preview there is no LTS branch.
