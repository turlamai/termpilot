#lang racket/base

;; OpenSSH sidecar orchestration. The transport seam: everything about
;; *how* an SSH session is established lives behind `ssh-command`, so the
;; sidecar (system OpenSSH) can later be swapped for an in-process stack
;; (libssh2 FFI) without touching sessions, store, or UI.
;;
;; What the sidecar buys us, free: ssh-agent forwarding and lookup,
;; ProxyJump, known_hosts handling, config-file compat, and automatic
;; tracking of new key exchange algorithms via OS updates. Password and
;; passphrase prompts flow through the pty like any real terminal — no
;; fragile prompt sniffing.

(require racket/contract
         racket/path
         racket/string)

;; A host profile as stored by the host manager (subset of fields; a
;; profile may also be ad-hoc, e.g. quick-connect form input).
(define (ssh-argv profile)
  (define host (hash-ref profile 'host))
  (define port (hash-ref profile 'port 22))
  (define user (hash-ref profile 'username #f))
  (define auth-type (hash-ref profile 'auth-type "agent"))
  (define identity-file (hash-ref profile 'identity-file #f))
  (define strict (hash-ref profile 'strict-host-key "accept-new"))
  (define jump (hash-ref profile 'jump #f))
  (define keep-alive (hash-ref profile 'keep-alive 0))
  (define options
    (append
     ;; TOFU by default: first connect records the fingerprint, changed
     ;; keys still hard-fail. Mirrors what Termius users expect.
     (list "-o" (format "StrictHostKeyChecking=~a" strict))
     ;; Keep long sessions alive through NAT/firewall idle drops;
     ;; per-host override wins when nonzero.
     (list "-o" (format "ServerAliveInterval=~a"
                        (if (and (number? keep-alive) (> keep-alive 0))
                            keep-alive
                            30))
          "-o" "ServerAliveCountMax=4")
     (list "-o" "ConnectTimeout=12")
     ;; Agent auth must fail fast instead of falling into a password
     ;; prompt that would never succeed.
     (if (string=? auth-type "agent")
         (list "-o" "BatchMode=yes")
         '())))
  (define argv
    (append
     options
     (if (and jump (string? jump) (not (string=? jump "")))
         (list "-J" jump)
         '())
     (if (not (= port 22)) (list "-p" (number->string port)) '())
     (if (and identity-file (not (string=? identity-file "")))
         (list "-i" identity-file)
         '())))
  (define destination
    (if (and user (not (string=? user "")))
        (format "~a@~a" user host)
        host))
  (values "ssh" (append argv (list destination))))

;; Local-shell spec is the same session machinery with no sidecar.
(define (local-command argv-extra)
  (define shell
    (or (getenv "SHELL")
        (case (system-type 'os)
          [(windows) "powershell.exe"]
          [else "/bin/sh"])))
  (values shell argv-extra))

(provide ssh-argv
         local-command)
