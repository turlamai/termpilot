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
         public-key-of
         delete-key!)

(define (ssh-dir)
  (build-path (find-system-path 'home-dir) ".ssh"))

;; Private key candidates: files without extension, matching the
;; conventional id_* names plus user-generated ones (we cannot parse
;; every file; the listing reports what openssh recognizes via -lf).
(define (list-keys)
  (define dir (ssh-dir))
  (unless (directory-exists? dir) '())
  (for/list ([f (in-list (directory-list dir))]
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
  (unless (member type '("ed25519" "rsa" "ecdsa"))
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
