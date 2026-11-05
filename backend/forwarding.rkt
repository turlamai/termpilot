#lang racket/base

;; Port forwarding: saved rules + live tunnels. A tunnel is a plain
;; (no-pty) OpenSSH sidecar: `ssh -N -L/-R/-D ...` — pipes only, since
;; -N never touches a terminal. The tunnel registry lives with the
;; session manager's app custodian so tunnels outlive requests; start/
;; stop/status ride typed routes. Rules persist in SQLite
;; (forwarding_rules, created in store init).

(require racket/contract
         racket/format
         racket/match
         racket/random
         racket/string
         "platform.rkt"
         "tunnels-argv.rkt"
         "store.rkt"
         "ssh.rkt")

(struct tunnel (id rule proc stdin stdout stderr alive?)
  #:transparent
  #:mutable)

;; registry: mutable hash id -> tunnel, under one semaphore
(struct registry (lock tunnels))
(define tunnels (registry (make-semaphore 1) (make-hash)))

(define (lock!) (semaphore-wait (registry-lock tunnels)))
(define (unlock!) (semaphore-post (registry-lock tunnels)))

(define (new-id!)
  (bytes->hex-string (crypto-random-bytes 12)))

(define (bytes->hex-string b)
  (apply string-append
         (for/list ([byte (in-bytes b)])
           (~r byte #:base 16 #:min-width 2 #:pad-string "0"))))

;; ---- rules (SQLite) ---------------------------------------------------------

;; ---- tunnels (sidecar processes) ---------------------------------------------

;; Build the ssh argv for one rule. The host profile comes from the
;; host store (agent auth + BatchMode so a tunnel never blocks on a
;; password prompt; tunnels are unattended).
(define (tunnel-argv rule)
  (define kind (hash-ref rule 'kind))
  (define host-id (hash-ref rule 'host-id))
  (define h (or (and (string? host-id) (not (string=? host-id "")) (get-host host-id))
                (error 'tunnel/start "rule has no valid host")))
  (define profile
    (hasheq 'host (hash-ref h 'host)
            'port (hash-ref h 'port 22)
            'username (hash-ref h 'username "")
            'auth-type "agent"
            'identity-file (hash-ref h 'identity-file "")
            'strict-host-key (hash-ref h 'strict-host-key "accept-new")
            'jump (hash-ref h 'jump "")
            'keep-alive (hash-ref h 'keep-alive 0)))
  (define-values (cmd args) (ssh-tunnel-argv profile rule))
  (values cmd args))

(define (start-tunnel! rule)
  (lock!)
  (define existing
    (for/first ([(id t) (in-hash (registry-tunnels tunnels))]
                #:when (string=? (tunnel-id t) (hash-ref rule 'id)))
      t))
  (cond
    [existing (unlock!) (hash 'id (hash-ref rule 'id) 'already-running #t)]
    [else
     (define-values (cmd args) (tunnel-argv rule))
     (define-values (proc stdout stdin stderr)
       (apply subprocess #f #f #f cmd args))
     (define id (hash-ref rule 'id))
     (hash-set! (registry-tunnels tunnels)
                id
                (tunnel id rule proc stdin stdout stderr #t))
     ;; Reap: mark not-alive when the sidecar exits.
     (thread
      (lambda ()
        (subprocess-wait proc)
        (lock!)
        (define t (hash-ref (registry-tunnels tunnels) id #f))
        (when t (set-tunnel-alive?! t #f))
        (unlock!)))
     (unlock!)
     (hash 'id id 'started #t)]))

(define (stop-tunnel! rule-id)
  (lock!)
  (define t (hash-ref (registry-tunnels tunnels) rule-id #f))
  (cond
    [t
     (subprocess-kill (tunnel-proc t) #t)
     (close-output-port (tunnel-stdin t))
     (hash-remove! (registry-tunnels tunnels) rule-id)
     (unlock!)
     (hash 'id rule-id 'stopped #t)]
    [else
     (unlock!)
     (hash 'id rule-id 'running #f)]))

(define (tunnel-status)
  (for/list ([(id t) (in-hash (registry-tunnels tunnels))])
    (hasheq 'id id
            'running (tunnel-alive? t)
            'exit-status
            (let ([st (subprocess-status (tunnel-proc t))])
              (cond [(not st) 'running]
                    [(eq? st 'done) 0]
                    [else st])))))

(define (stop-all!)
  (for ([id (in-hash-keys (registry-tunnels tunnels))])
    (stop-tunnel! id)))

(provide list-rules
         get-rule
         insert-rule!
         delete-rule!
         start-tunnel!
         stop-tunnel!
         tunnel-status
         stop-all!)
