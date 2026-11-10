#lang racket/base

;; Online update check — the family pattern (hackdigest), notify-and-open
;; edition. The backend fetches and verifies the Ed25519-signed update
;; manifest published as a release asset
;; (github.com/turlamai/termpilot/releases/latest/download/update-manifest.json),
;; and the frontend banner offers "open the release page". Nothing is ever
;; downloaded or installed: the upgrade mechanism stays the user's hands
;; on an installer — what changed here is the trust chain, from an
;; unsigned site-manifest convenience pointer to a signature the app can
;; actually verify.
;;
;; Two building blocks, chosen deliberately (same reasoning as
;; hackdigest/backend/update.rkt):
;;   - glaze/update provides the signed-manifest schema and JSON
;;     validation. The wrapper format is the family feed
;;     ({schema, payload, signature{ed25519, key_id, value}}) whose
;;     signature covers the exact payload bytes.
;;   - the `crypto` package (pinned to the libcrypto factory) provides
;;     Ed25519 through the libcrypto library that ships inside the Racket
;;     distribution (Windows/macOS) or the host system (Linux — any host
;;     that can run TermPilot has OpenSSH, and OpenSSH links libcrypto).
;;     glaze/signing shells out to the `openssl` CLI instead, which breaks
;;     on stock macOS (LibreSSL) and Windows — FFI, no subprocesses.
;;
;; The legacy plain manifest at termpilot.jrtx.site stays published for
;; 0.8.0-and-older clients, which have no signature verification; this
;; module never reads it.

(require crypto
         (only-in crypto/libcrypto libcrypto-factory)
         glaze/update
         net/base64
         net/url
         racket/port
         racket/string)

;; rivet/distribution pins the provider set to libcrypto at module load
;; and deliberately avoids crypto/all — factory FFIs load at import time
;; and the gmp factory kills packaged runtimes on hosts without libgmp.
(crypto-factories (list libcrypto-factory))

(provide app-identifier
         update-key-id
         update-public-key-b64
         release-page-base
         manifest-url
         embedded-public-key
         ed25519-verify-message
         verify-manifest-signature
         check-update-signed)

;; ---------- release identity ----------

;; application_id inside the signed manifest (glaze build derives the same
;; io.glaze.<name> identifier from --name TermPilot).
(define app-identifier "io.glaze.TermPilot")

;; YYYY-MM of the key's introduction; the scripts reject a signing key
;; that does not match the public key embedded here.
(define update-key-id "termpilot-2026-11")

;; SubjectPublicKeyInfo DER, base64 — generated once by
;; scripts/update-keys.sh. The private half lives outside the repository
;; (and in the CI secret UPDATE_ED25519_PRIVATE_KEY) and never ships.
;; Rotate by shipping a build that trusts the next key before signing
;; releases exclusively with it.
(define update-public-key-b64
  "MCowBQYDK2VwAyEAfwTo59aw5sjY8rm5PUBj5LCVrRFUtoj3ntb4jz5KDY8=")

(define release-page-base
  "https://github.com/turlamai/termpilot/releases")

;; The release pipeline pins artifact URLs to the concrete tag; the
;; manifest itself lives at the moving "latest" location.
;; TERMPILOT_UPDATE_MANIFEST overrides the base for tests and local
;; end-to-end runs (same seam the 0.8.0 site manifest had). An empty
;; value counts as unset (putenv cannot delete entries portably).
(define (manifest-url)
  (define override (getenv "TERMPILOT_UPDATE_MANIFEST"))
  (string-trim
   (if (and (string? override)
            (non-empty-string? (string-trim override)))
       override
       (string-append release-page-base "/latest/download"))
   "/" #:right? #t))

;; ---------- crypto primitives (libcrypto FFI, no CLI) ----------

(define (base64-string->bytes value)
  (base64-decode (string->bytes/utf-8 value)))

(define (embedded-public-key)
  (datum->pk-key (base64-string->bytes update-public-key-b64)
                 'SubjectPublicKeyInfo))

;; Pure Ed25519 over the exact message bytes — the same signature rivet's
;; ed25519-sign produces, so the family feed verifies on both lines.
(define (ed25519-verify-message message signature-b64
                                #:public-key [public-key (embedded-public-key)])
  (define signature
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (base64-string->bytes (string-trim signature-b64))))
  (and signature
       (= (bytes-length signature) 64)
       (pk-verify public-key message signature)))

;; Parse a signed wrapper (glaze/update JSON validation included), then
;; verify the payload signature against the embedded release key. Returns
;; the manifest or raises. #:public-key lets tests inject a fixture key.
(define (verify-manifest-signature input
                                   #:key-id [expected-key-id update-key-id]
                                   #:public-key [public-key (embedded-public-key)])
  (define-values (manifest payload key-id signature)
    (read-signed-update-manifest input))
  (when (and expected-key-id (not (string=? expected-key-id key-id)))
    (raise-arguments-error 'verify-manifest-signature
                           "manifest was signed by an unexpected key"
                           "expected" expected-key-id
                           "actual" key-id))
  (unless (ed25519-verify-message payload signature #:public-key public-key)
    (error 'verify-manifest-signature
           "Ed25519 manifest signature verification failed"))
  manifest)

;; ---------- check ----------

;; Fetches and verifies the signed manifest, selects this platform's
;; artifact, and answers the legacy notification shape
;; ({version, url, notes}) the /api/update/check route and the banner
;; already speak. #f means "no update" (up-to-date, unreachable feed or a
;; verification failure — a failed check degrades to no banner, never to
;; a less-verified one). Never raises.
(define (check-update-signed current-version)
  (define (platform-symbol)
    (case (system-type 'os)
      [(macosx) 'macos]
      [(windows) 'windows]
      [else 'linux]))
  (define (architecture-symbol)
    (case (system-type 'arch)
      [(aarch64 arm64) 'arm64]
      [else 'x64]))
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define url (string-append (manifest-url) "/update-manifest.json"))
    ;; The trust path starts at the URL: TLS-only is not a scheme check,
    ;; and a config override pointing at http:// would downgrade the whole
    ;; chain silently.
    (unless (string-prefix? url "https://")
      (error 'check-update-signed "update manifest URL must use HTTPS"))
    (define in (get-pure-port (string->url url)
                              '("User-Agent: TermPilot-Updater/1")
                              #:redirections 10))
    (define manifest
      (dynamic-wind
        void
        (lambda ()
          ;; Bound the read, not just the verdict: checking the size after
          ;; port->bytes would let a hostile server stream unbounded bytes
          ;; into memory before the cap ever runs.
          (define cap (* 4 1024 1024))
          (define payload
            (let loop ([acc (open-output-bytes)] [total 0])
              (define buffer (make-bytes 65536))
              (define count (read-bytes-avail! buffer in))
              (cond
                [(eof-object? count) (get-output-bytes acc)]
                [else
                 (define next (+ total count))
                 (when (> next cap)
                   (error 'check-update-signed "update manifest exceeds 4 MiB"))
                 (write-bytes buffer acc 0 count)
                 (loop acc next)])))
          (verify-manifest-signature (open-input-bytes payload)))
        (lambda () (close-input-port in))))
    (define config
      (updater-config app-identifier
                      current-version
                      'stable
                      (platform-symbol)
                      (architecture-symbol)
                      (embedded-public-key)
                      update-key-id
                      0
                      (* 800 1024 1024)))
    (define candidate (select-update config manifest))
    (and candidate
         (hasheq 'version
                 (update-manifest-version (update-candidate-manifest candidate))
                 'url
                 (string-append release-page-base
                                "/tag/v"
                                (update-manifest-version
                                 (update-candidate-manifest candidate)))
                 ;; the signed feed carries no prose; the banner does not
                 ;; render notes (bridge type: string | null)
                 'notes #f))))
