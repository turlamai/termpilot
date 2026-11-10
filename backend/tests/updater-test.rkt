#lang racket/base

;; Updater tests: signed-manifest round trip and selection for the
;; notify-and-open check (backend/updater.rkt). Signature tests run
;; against an ephemeral Ed25519 keypair (OpenSSL 3 CLI is only needed to
;; mint the fixture keys — production verification uses the
;; crypto/libcrypto FFI) and are skipped gracefully where no OpenSSL 3
;; exists. No network is involved.

(require crypto
         glaze/update
         json
         net/base64
         racket/file
         racket/port
         racket/string
         racket/system
         rackunit
         "../updater.rkt")

;; ---- pure helpers ----

(define (platform-symbol)
  (case (system-type 'os)
    [(macosx) 'macos]
    [(windows) 'windows]
    [else 'linux]))

(define (architecture-symbol)
  (case (system-type 'arch)
    [(aarch64 arm64) 'arm64]
    [else 'x64]))

(test-case "platform identity"
  (check-pred symbol? (platform-symbol))
  (check-pred (lambda (s) (member s '(x64 arm64))) (architecture-symbol)))

(test-case "manifest url joins the moving latest release location"
  ;; "" counts as unset (putenv cannot delete entries portably)
  (putenv "TERMPILOT_UPDATE_MANIFEST" "")
  (check-equal? (manifest-url)
                "https://github.com/turlamai/termpilot/releases/latest/download")
  (putenv "TERMPILOT_UPDATE_MANIFEST" "http://127.0.0.1:9/feed/")
  (check-equal? (manifest-url) "http://127.0.0.1:9/feed")
  (putenv "TERMPILOT_UPDATE_MANIFEST" ""))

;; ---- fixture keypair ----

;; OpenSSL 3 is required for Ed25519 (macOS's LibreSSL cannot do it).
(define (find-openssl3)
  (for/or ([candidate (in-list
                       (list "/opt/homebrew/opt/openssl@3/bin/openssl"
                             "/usr/local/opt/openssl@3/bin/openssl"
                             (find-executable-path "openssl")))])
    (define out
      (and candidate
           (with-handlers ([exn:fail? (lambda (_) "")])
             (with-output-to-string (lambda () (system* candidate "version"))))))
    (and (regexp-match? #px"OpenSSL 3" (or out "")) candidate)))

(define openssl (find-openssl3))

(define-values (private-key test-dir)
  (cond
    [openssl
     (define dir (make-temporary-file "tp-update-keys~a" 'directory))
     (define priv (build-path dir "private.der"))
     (define pub (build-path dir "public.pem"))
     ;; OneAsymmetricKey DER — what crypto's datum->pk-key consumes (the
     ;; family scripts convert PEM → DER once at signing time).
     (check-true
      (zero? (system*/exit-code openssl "genpkey" "-algorithm" "ed25519"
                                "-outform" "DER" "-out" (path->string priv)))
      "openssl could not generate an Ed25519 key")
     (check-true
      (zero? (system*/exit-code openssl "pkey" "-in" (path->string priv)
                                "-inform" "DER" "-pubout" "-out" (path->string pub)))
      "openssl could not export the public key")
     (values (datum->pk-key (file->bytes priv) 'OneAsymmetricKey) dir)]
    [else
     (displayln "skip: signed-manifest tests (no OpenSSL 3 found)")
     (values #f #f)]))

;; A minimal valid manifest struct for this platform.
(define (test-manifest [version "9.9.9"])
  (update-manifest
   app-identifier version 1 'stable "2026-11-10T00:00:00Z" "0.0.0" #f #t 100
   (list (update-artifact (platform-symbol) (architecture-symbol)
                          "https://example.invalid/x.zip"
                          (make-string 64 #\a)
                          1234 'zip '() #f)
         (update-artifact 'macos 'x64 "https://example.invalid/y.zip"
                          (make-string 64 #\b) 2345 'zip '() #f)
         (update-artifact 'windows 'x64 "https://example.invalid/w.zip"
                          (make-string 64 #\c) 3456 'zip '() #f)
         (update-artifact 'linux 'x64 "https://example.invalid/l.tar.gz"
                          (make-string 64 #\d) 4567 'targz '() #f))))

(define (payload->wrapper payload signature-bytes [key-id update-key-id])
  (hasheq 'schema 1
          'payload (bytes->string/utf-8 (base64-encode payload #""))
          'signature
          (hasheq 'algorithm "ed25519"
                  'key_id key-id
                  'value (bytes->string/utf-8
                          (base64-encode signature-bytes #"")))))

(define fixture-public-key
  (and private-key
       (datum->pk-key (pk-key->datum private-key 'rkt-public) 'rkt-public)))

(define (wrapper-input wrapper)
  (open-input-bytes (string->bytes/utf-8 (jsexpr->string wrapper))))

(define (verify-fixture input #:key-id [key-id update-key-id])
  (verify-manifest-signature input
                             #:key-id key-id
                             #:public-key fixture-public-key))

;; ---- signed wrapper round trip (the family feed format) ----

(when private-key
  (test-case "verify-manifest-signature accepts a correct signature"
    (define payload (update-manifest->payload-bytes (test-manifest)))
    ;; the payload must pass glaze's own schema validation
    (check-equal?
     (update-manifest-version (payload-bytes->update-manifest payload))
     "9.9.9")
    (define signature (pk-sign private-key payload))
    (define verified
      (verify-fixture (wrapper-input (payload->wrapper payload signature))))
    (check-equal? (update-manifest-version verified) "9.9.9")
    (check-equal? (update-manifest-application-id verified) app-identifier)
    (check-equal? (length (update-manifest-artifacts verified)) 4))

  (test-case "verify-manifest-signature rejects a tampered payload"
    (define payload (update-manifest->payload-bytes (test-manifest)))
    (define signature (pk-sign private-key payload))
    ;; bump the version inside the payload, keep the original signature
    (define tampered (regexp-replace #px"\"version\":\"9\\.9\\.9\""
                                     (bytes->string/utf-8 payload)
                                     "\"version\":\"9.9.10\""))
    (check-exn exn:fail?
               (lambda ()
                 (verify-fixture
                  (wrapper-input
                   (payload->wrapper (string->bytes/utf-8 tampered)
                                     signature))))))

  (test-case "verify-manifest-signature rejects a foreign key id"
    (define payload (update-manifest->payload-bytes (test-manifest)))
    (define signature (pk-sign private-key payload))
    (check-exn exn:fail?
               (lambda ()
                 (verify-fixture
                  (wrapper-input (payload->wrapper payload signature))
                  #:key-id "someone-elses-key"))))

  (test-case "verify-manifest-signature rejects garbage signatures"
    (define payload (update-manifest->payload-bytes (test-manifest)))
    (check-exn exn:fail?
               (lambda ()
                 (verify-fixture
                  (wrapper-input
                   (payload->wrapper payload (make-bytes 64 0)))))))

  (test-case "verify-manifest-signature rejects a wrong key entirely"
    (define other-dir (make-temporary-file "tp-update-other~a" 'directory))
    (define other-priv (build-path other-dir "other.der"))
    (check-true (zero? (system*/exit-code openssl "genpkey" "-algorithm" "ed25519"
                                          "-outform" "DER" "-out" (path->string other-priv))))
    (define other-key (datum->pk-key (file->bytes other-priv) 'OneAsymmetricKey))
    (define payload (update-manifest->payload-bytes (test-manifest)))
    ;; correctly signed — but by a key the app does not embed
    (define signature (pk-sign other-key payload))
    (check-exn exn:fail?
               (lambda ()
                 (verify-fixture
                  (wrapper-input (payload->wrapper payload signature)))))))

;; ---- selection ----

(test-case "select-update picks this platform's artifact"
  (define (config-for version)
    (updater-config app-identifier version 'stable
                    (platform-symbol) (architecture-symbol)
                    #f update-key-id 0 1000))
  (define candidate (select-update (config-for "9.9.8") (test-manifest)))
  (check-true (update-candidate? candidate))
  (check-equal? (update-manifest-version (update-candidate-manifest candidate))
                "9.9.9")
  ;; equal version → not an update
  (check-false (select-update (config-for "9.9.9") (test-manifest)))
  ;; older builds update
  (check-true (update-candidate? (select-update (config-for "0.8.0") (test-manifest)))))

(test-case "select-update rejects a foreign application identity"
  (check-exn exn:fail?
             (lambda ()
               (select-update
                (updater-config "io.glaze.SomeoneElse" "0.8.0" 'stable
                                (platform-symbol) (architecture-symbol)
                                #f update-key-id 0 1000)
                (test-manifest)))))
