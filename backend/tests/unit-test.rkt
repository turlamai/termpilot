#lang racket/base

;; Unit tests for the pure backend units: redaction, provider presets,
;; ssh argv composition. The pty layer is exercised by the e2e smoke
;; (it needs a real terminal and child process).

(require rackunit
         racket/list
         racket/string
         "../ai/redact.rkt"
         "../ai/providers.rkt"
         "../ssh.rkt"
         "../session.rkt")

;; ---- redaction -------------------------------------------------------------

(check-equal? (redacted-text (redact "hello world")) "hello world"
              "clean text passes through untouched")

(check-equal? (redacted-text (redact "AKIAIOSFODNN7EXAMPLE is a key"))
              "[REDACTED:aws-key] is a key")

(let* ([pem (string-append
             "-----BEGIN OPENSSH PRIVATE KEY-----\n"
             "b3BlbnNzaC1rZXktdjEAAAAA\n"
             "-----END OPENSSH PRIVATE KEY-----\n"
             "after")]
       [out (redacted-text (redact pem))])
  (check-false (string-contains? out "b3BlbnNzaC1rZXk")
               "pem body must not survive redaction")
  (check-true (string-contains? out "after")))

(check-equal? (redacted-text (redact "export PASSWORD=hunter2 now"))
              "export [REDACTED:credentials] now")

(check-equal? (redacted-text
               (redact "mysql://admin:s3cret@db.example.com/x"))
              "[REDACTED:connection-string]db.example.com/x")

(check-equal? (redacted-text (redact "sk-abcdefghijklmnop1234567890 tail"))
              "[REDACTED:api-token] tail")

;; preview reports counts and cleanliness
(let ([p (redact-preview "AKIAIOSFODNN7EXAMPLE")])
  (check-equal? (hash-ref p 'clean) #f)
  (check-equal? (length (hash-ref p 'counts)) 1))

;; every rule name appears in the replacement marker
(define (probe-text rule)
  (case rule
    [(private-key) "-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----"]
    [(aws-key) "AKIAIOSFODNN7EXAMPLE"]
    [(api-token) "sk-abcdefghijklmnop1234567890"]
    [(bearer) "bearer abcdefghijklmnopqrstuvwxyz123456"]
    [(password-assign) "token: supersecretvalue"]
    [(passphrase) "passphrase = supersecretvalue"]
    [(conn-uri) "https://u:p@example.com/x"]))

(for ([rule (in-list '(private-key aws-key api-token bearer
                                   password-assign passphrase conn-uri))])
  (check-true
   (string-contains? (redacted-text (redact (probe-text rule)))
                     "[REDACTED:")
   "rule marker must fire"))

;; ---- provider presets ------------------------------------------------------

(check-true (and (andmap (lambda (p)
                           (and (string? (preset-id p))
                                (string? (preset-model p))
                                (member (preset-kind p)
                                        '("openai" "anthropic" "ollama"))))
                         provider-presets)
                 #t)
            "every preset is well-formed")

(check-not-false (find-preset "glm") "glm preset exists")
(check-false (find-preset "nope") "unknown preset is #f")
(check-equal? (preset-kind (find-preset "anthropic")) "anthropic")
(check-equal? (preset-kind (find-preset "ollama")) "ollama")

;; ---- ssh argv --------------------------------------------------------------

(let-values ([(cmd argv)
              (ssh-argv (hasheq 'host "example.com"
                                'port 2222
                                'username "root"
                                'auth-type "agent"))])
  (check-equal? cmd "ssh")
  (check-equal? (last argv) "root@example.com")
  (check-not-false (member "-p" argv) "custom port must be set")
  (check-not-false (member "BatchMode=yes" argv)
                 "agent auth must not fall into an interactive prompt"))

(let-values ([(cmd argv)
              (ssh-argv (hasheq 'host "example.com"
                                'identity-file "~/.keys/id_ed25519"
                                'strict-host-key "yes"))])
  (check-equal? (last argv) "example.com")
  (check-not-false (member "-i" argv))
  (check-not-false (member "StrictHostKeyChecking=yes" argv)))

(let-values ([(cmd argv) (ssh-argv (hasheq 'host "example.com"))])
  (check-equal? (last argv) "example.com")
  (check-false (member "-p" argv) "default port 22 stays implicit")
  (check-not-false (member "StrictHostKeyChecking=accept-new" argv)
                 "TOFU is the default posture"))

;; ---- local shell -----------------------------------------------------------

(let-values ([(cmd args) (local-command '())])
  (check-true (string? cmd))
  (check-true (null? args)))

;; ---- session ring (pure parts) ---------------------------------------------

;; open-session/e2e covers live sessions; here just the empty manager.
(let ([m (make-manager)])
  (check-equal? (list-sessions m) '()))

;; ---- ssh config import -----------------------------------------------------

(require racket/file
         racket/runtime-path)
(define-runtime-path ssh-config-mod "../ssh-config.rkt")

(define tmpcfg (make-temporary-file "tpcfg-~a"))
(with-output-to-file tmpcfg
  #:exists 'replace
  (lambda ()
    (displayln "Host web\n  HostName 10.0.0.5\n  User admin\n  Port 2222\n  ProxyJump bastion")
    (displayln "Host * !web\n  Compression yes")
    (displayln "Host bastion\n  HostName 10.0.0.1")))
(define parse-ssh-config (dynamic-require ssh-config-mod 'parse-ssh-config))
(define parsed (parse-ssh-config tmpcfg))
(check-equal? (length parsed) 2 "wildcard and negation patterns excluded")
(define web (findf (lambda (h) (string=? (hash-ref h 'label) "web")) parsed))
(check-equal? (hash-ref web 'host) "10.0.0.5")
(check-equal? (hash-ref web 'port) 2222)
(check-equal? (hash-ref web 'username) "admin")
(check-equal? (hash-ref web 'jump) "bastion")
(delete-file tmpcfg)
