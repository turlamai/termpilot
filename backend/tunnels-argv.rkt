#lang racket/base

;; The transport seam's tunnel half: a rule + host profile -> the
;; `ssh -N` argv. Kept beside ssh.rkt so a future in-process stack can
;; serve both sessions and tunnels through one seam.

(require racket/contract
         racket/string)

;; kinds: local (-L bind:port:remote_host:remote_port)
;;        remote (-R bind:port:remote_host:remote_port)
;;        dynamic (-D bind:port)  (SOCKS; remote_* unused)
(define (ssh-tunnel-argv profile rule)
  (define host (hash-ref profile 'host))
  (define port (hash-ref profile 'port 22))
  (define user (hash-ref profile 'username ""))
  (define identity-file (hash-ref profile 'identity-file ""))
  (define strict (hash-ref profile 'strict-host-key "accept-new"))
  (define jump (hash-ref profile 'jump ""))
  (define keep-alive (hash-ref profile 'keep-alive 0))
  (define kind (hash-ref rule 'kind))
  (define bind-host (hash-ref rule 'bind-host ""))
  (define local-port (hash-ref rule 'local-port))
  (define remote-host (hash-ref rule 'remote-host ""))
  (define remote-port (hash-ref rule 'remote-port 0))
  (define bind
    (if (and (string? bind-host) (not (string=? bind-host "")))
        (format "~a:~a" bind-host local-port)
        (format "~a" local-port)))
  (define spec
    (case kind
      [("local")
       (format "~a:~a:~a" bind remote-host remote-port)]
      [("remote")
       (format "~a:~a:~a" bind remote-host remote-port)]
      [("dynamic") bind]
      [else (error 'tunnel "unknown rule kind ~a" kind)]))
  (define flag
    (case kind
      [("local") "-L"]
      [("remote") "-R"]
      [("dynamic") "-D"]))
  (define options
    (append
     '("-N" "-o" "ExitOnForwardFailure=yes")
     (list "-o" (format "StrictHostKeyChecking=~a" strict))
     (list "-o" (format "ServerAliveInterval=~a" (if (> keep-alive 0) keep-alive 30))
           "-o" "ServerAliveCountMax=4")
     ;; Tunnels are unattended: fail fast without a prompt.
     '("-o" "BatchMode=yes")
     (if (and jump (not (string=? jump ""))) (list "-J" jump) '())
     (if (not (= port 22)) (list "-p" (number->string port)) '())
     (if (not (string=? identity-file "")) (list "-i" identity-file) '())))
  (define destination
    (if (and user (not (string=? user "")))
        (format "~a@~a" user host)
        host))
  (values "ssh" (append options (list flag spec destination))))

(provide ssh-tunnel-argv)
