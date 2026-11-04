#lang racket/base

;; Redaction before anything leaves the machine toward an LLM. Every AI
;; send path calls `redact` last; `redact-preview` returns the same
;; result plus match counts so the UI can show exactly what would be
;; sent (family governance: AI proposes, user disposes, secrets never
;; travel unredacted).

(require racket/contract
         racket/string)

;; Each rule: (list name regex replacement). Patterns use the pregexp
;; dialect (#px): {n} quantifiers and (?i:…) case folding are not
;; available in the plain #rx dialect.
(define rules
  (list
   ;; PEM / OpenSSH private key blocks
   (list "private-key"
         #px"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"
         "[REDACTED:private-key]")
   ;; AWS access key ids
   (list "aws-key" #px"AKIA[0-9A-Z]{16}" "[REDACTED:aws-key]")
   ;; Generic API tokens: sk-…, ghp_…, xoxb-…, Bearer …, long hex/base64
   (list "api-token"
         #px"(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{10,})"
         "[REDACTED:api-token]")
   (list "bearer" #px"(?i:bearer)[ ]+[A-Za-z0-9._~/+=-]{16,}" "[REDACTED:bearer]")
   ;; password= / PASSWORD: assignments (shell + env shapes)
   (list "password-assign"
         #px"(?i:(password|passwd|pwd|secret|token)[ ]*[=:][ ]*[^[:space:]\"']{4,})"
         "[REDACTED:credentials]")
   ;; SSH authorized_keys / public blobs pasted inline are fine, but
   ;; fail2ban-style auth logs may embed passphrases after "passphrase"
   (list "passphrase" #px"(?i:passphrase[ ]*[=:][ ]*[^[:space:]\"']{4,})"
         "[REDACTED:passphrase]")
   ;; Connection strings embedding credentials
   (list "conn-uri"
         #px"[a-z][a-z0-9+.-]*://[^/[:space:]]+:[^@/[:space:]]+@"
         "[REDACTED:connection-string]")))

(struct redacted (text counts) ; counts: list of (list name count)
  #:transparent)

(define (redact str)
  (define counts
    (for/fold ([acc '()])
              ([rule (in-list rules)])
      (define name (car rule))
      (define rx (cadr rule))
      (define replaced (regexp-replace* rx str (caddr rule)))
      (define n
        (length (regexp-match* rx str)))
      (set! str replaced)
      (if (zero? n) acc (cons (list name n) acc))))
  (redacted str counts))

(define (redact-preview str)
  (define r (redact str))
  (hasheq 'text (redacted-text r)
          'counts (redacted-counts r)
          'clean (null? (redacted-counts r))))

(provide (struct-out redacted)
         redact
         redact-preview)
