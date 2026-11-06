#lang racket/base

;; SSH key manager: inventory, generation and public-key inspection for
;; keys in the user's ~/.ssh. Private key bytes are NEVER returned —
;; listings expose filename, type and permissions only; the public half
;; (safe by definition) is the only content that crosses the bridge.
;; Generation shells out to ssh-keygen (system OpenSSH, same sidecar
;; policy as sessions). Deletion requires an explicit UI confirmation
;; and is refused for anything outside ~/.ssh.

(require racket/contract
         racket/file
         racket/format
         racket/list
         racket/path
         racket/port
         racket/string
         racket/system)

(provide ssh-dir
         list-keys
         key-meta
         generate-key!
         import-key!
         public-key-of
         distribute-pubkey!
         delete-key!)

;; Import an OpenSSH private key (PEM or new format) by content: write
;; to ~/.ssh/<name> with 0600, derive the public half via
;; `ssh-keygen -y`, and refuse anything that does not parse. The
;; content crosses the bridge once (the UI prompts for it explicitly);
;; it is never echoed back.
(define (import-key! name content)
  (unless (regexp-match? #px"^[A-Za-z0-9._-]+$" name)
    (error 'keys/import "key name must be plain [A-Za-z0-9._-]"))
  (unless (or (string-contains? content "PRIVATE KEY")
              (string-prefix? content "-----BEGIN"))
    (error 'keys/import "content does not look like a private key"))
  (define full (build-path (ssh-dir) name))
  (when (file-exists? full)
    (error 'keys/import "key already exists: ~a" name))
  (unless (directory-exists? (ssh-dir))
    (make-directory* (ssh-dir)))
  (with-output-to-file full
    (lambda () (display (string-ensure-newline content)))
    #:exists 'truncate)
  (file-or-directory-permissions full #o600)
  ;; Derive the public half; a bogus key fails here and is removed.
  (define keygen (or (find-executable-path "ssh-keygen")
                     (error 'keys/import "ssh-keygen not found")))
  (define pub-out
    (with-output-to-string
      (lambda ()
        (with-handlers ([exn:fail? void])
          (system* keygen "-y" "-f" full)))))
  (when (or (string=? (string-trim pub-out) "")
            (not (string-prefix? (string-trim pub-out) "ssh-")))
    (delete-file full)
    (error 'keys/import "key did not parse (ssh-keygen -y failed)"))
  (with-output-to-file (build-path (ssh-dir) (string-append name ".pub"))
    (lambda () (displayln (string-trim pub-out)))
    #:exists 'truncate)
  (hasheq 'name name 'imported #t))

(define (string-ensure-newline s)
  (if (string-suffix? s "
") s (string-append s "
")))

;; Distribute a key's public half to a host (ssh-copy-id semantics,
;; BatchMode so it only works when some other auth already works):
;; install the .ssh dir at the right mode and append the pubkey to
;; authorized_keys atomically, then report what happened.
(define (distribute-pubkey! name profile)
  (define pub (public-key-of name))
  (define ssh (or (find-executable-path "ssh")
                  (error 'keys/distribute "ssh not found")))
  (define host (hash-ref profile 'host))
  (define port (hash-ref profile 'port 22))
  (define user (hash-ref profile 'username ""))
  (define identity-file (hash-ref profile 'identity-file ""))
  (define destination
    (if (string=? user "") host (format "~a@~a" user host)))
  (define remote-script
    "install -d -m 700 ~/.ssh && touch ~/.ssh/authorized_keys && grep -qxF '$PUB' ~/.ssh/authorized_keys || echo '$PUB' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys")
  ;; Pass the pubkey via stdin to keep it out of process listings.
  (define-values (proc stdout stdin stderr)
    (apply subprocess #f #f #f ssh
           (append
            (list "-o" "BatchMode=yes"
                  "-o" (format "StrictHostKeyChecking=~a"
                               (hash-ref profile 'strict-host-key "accept-new"))
                  "-o" "ConnectTimeout=12")
            (if (not (= port 22)) (list "-p" (number->string port)) '())
            (if (not (string=? identity-file ""))
                (list "-i" identity-file)
                '())
            (list destination remote-script))))
  (display pub stdin)
  (close-output-port stdin)
  (define out (port->string stdout))
  (define err (port->string stderr))
  (subprocess-wait proc)
  (define st (subprocess-status proc))
  (values (and st (eq? st 'done))
          (string-append out err)))

(define (ssh-dir)
  (build-path (find-system-path 'home-dir) ".ssh"))

;; Private key candidates: files without extension, matching the
;; conventional id_* names plus user-generated ones (we cannot parse
;; every file; the listing reports what openssh recognizes via -lf).
(define (list-keys)
  (define dir (ssh-dir))
  (unless (directory-exists? dir) '())
  (for/list ([f (in-list (directory-list dir))]
             #:when (file-exists? (build-path dir f))
             #:unless (string-suffix? (path->string f) ".pub")
             #:unless (string-prefix? (path->string f) "known_hosts")
             #:unless (string=? (path->string f) "config")
             #:unless (string=? (path->string f) "authorized_keys"))
    (define full (build-path dir f))
    (define pub (build-path dir (string-append (path->string f) ".pub")))
    (hasheq 'name (path->string f)
            'has-public (file-exists? pub)
            'permissions
            (let ([p (file-or-directory-permissions full 'bits)])
              (~r p #:base 8 #:min-width 4))
            'bytes (if (file-exists? full) (file-size full) 0))))

;; Fingerprint + type via ssh-keygen -lf on the PRIVATE file (openssh
;; derives the public half; works without a .pub file).
(define (key-meta name)
  (define full (build-path (ssh-dir) name))
  (unless (file-exists? full) (error 'keys "no such key: ~a" name))
  (define out
    (with-output-to-string
      (lambda ()
        (with-handlers ([exn:fail? void])
          (system* (find-executable-path "ssh-keygen") "-lf" full)))))
  (define line (first (filter non-empty-string? (string-split out "\n"))))
  ;; "3072 SHA256:xxx comment (RSA)"
  (define parts (string-split line))
  (hasheq 'bits (first parts)
          'fingerprint (second parts)
          'comment (if (> (length parts) 3) (fourth parts) "")
          'type (if (> (length parts) 4) (fifth parts) "")))

(define (generate-key! name type passphrase bits)
  (define full (build-path (ssh-dir) name))
  (when (file-exists? full)
    (error 'keys/generate "key already exists: ~a" name))
  ;; sk types are hardware-resident: ssh-keygen errors when no FIDO2
  ;; key is present, and that error is the honest outcome to surface.
  (unless (member type '("ed25519" "rsa" "ecdsa" "ed25519-sk" "ecdsa-sk"))
    (error 'keys/generate "unsupported type ~a" type))
  (define keygen (or (find-executable-path "ssh-keygen")
                     (error 'keys/generate "ssh-keygen not found")))
  (define args
    (list* "-t" type
           "-f" full
           "-N" (or passphrase "")
           (if (and (string=? type "rsa") (number? bits) (>= bits 2048))
               (list "-b" (number->string bits))
               '())))
  (define ok (with-handlers ([exn:fail? (lambda (_) #f)])
               (apply system* keygen (append '("-q") args))))
  (unless ok (error 'keys/generate "ssh-keygen failed"))
  (file-or-directory-permissions full #o600)
  (hasheq 'name name 'generated #t))

;; Public key content only — never the private half.
(define (public-key-of name)
  (define pub (build-path (ssh-dir) (string-append name ".pub")))
  (unless (file-exists? pub)
    (error 'keys/pub "no public key for ~a (generate or run ssh-keygen -y)" name))
  (string-trim (file->string pub)))

(define (inside-ssh-dir? name)
  (define clean (simple-form-path name))
  (define dir (simple-form-path (ssh-dir)))
  (string-prefix? (path->string clean) (path->string dir)))

(define (delete-key! name)
  (unless (inside-ssh-dir? name)
    (error 'keys/delete "refusing to delete outside ~/.ssh"))
  (define full (build-path (ssh-dir) name))
  (define pub (build-path (ssh-dir) (string-append name ".pub")))
  (when (file-exists? full) (delete-file full))
  (when (file-exists? pub) (delete-file pub))
  (hasheq 'name name 'deleted #t))
