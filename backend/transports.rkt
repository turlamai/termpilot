#lang racket/base

;; The transport seam (sessions half): a connection profile -> command +
;; args, for every connection kind. Sessions, UI and store never know
;; which binary serves a session; adding a transport is one case here.

(require racket/contract
         racket/format
         racket/path
         racket/string)

;; ---- ssh (sidecar OpenSSH) ---------------------------------------------------
;; see ssh.rkt — ssh-argv stays the source for SSH profiles.

;; ---- telnet ------------------------------------------------------------------
;; `telnet host port`. Present on Linux/legacy; macOS ships no telnet —
;; doctor surfaces its absence; the UI offers the kind only when
;; available (checked via api/doctor/transports).

(define (telnet-argv host port)
  (values "telnet"
          (if (and port (not (= port 23)))
              (list host (number->string port))
              (list host))))

;; ---- mosh --------------------------------------------------------------------
;; `mosh user@host` (ports negotiated by mosh itself over UDP; the ssh
;; bootstrap rides the normal ssh path, so agent/keys work). Server-side
;; mosh must be installed — the client prints actionable errors.

(define (mosh-argv profile)
  (define host (hash-ref profile 'host))
  (define user (hash-ref profile 'username ""))
  (define port (hash-ref profile 'port 22))
  (define destination
    (if (string=? user "") host (format "~a@~a" user host)))
  (define ssh-opts
    (if (not (= port 22)) (list "--ssh=ssh -p ~a" (number->string port)) '()))
  (values "mosh" (append ssh-opts (list destination))))

;; ---- serial ------------------------------------------------------------------
;; Serial is NOT a sidecar: the backend opens the device file directly
;; and configures the line (baud/parity/stop/flow) once via termios —
;; see serial.rkt. This function only normalizes the profile.

;; ---- dispatch ----------------------------------------------------------------

;; profile fields: connection-kind (ssh|telnet|mosh|local), host, port,
;; username, auth-type, identity-file, strict-host-key, jump, keep-alive.
;; Returns (values kind command args label).
(define (open-command profile)
  (case (hash-ref profile 'connection-kind "ssh")
    [(telnet)
     (telnet-argv (hash-ref profile 'host "?")
                  (hash-ref profile 'port 23))]
    [(mosh)
     (mosh-argv profile)]
    [else
     ;; ssh and everything unspecified keep the sidecar path
     (void)]))

(provide telnet-argv
         mosh-argv
         open-command)
