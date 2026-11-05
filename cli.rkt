#!/usr/bin/env racket
#lang racket/base

;; TermPilot CLI — the deterministic, agent-facing surface (family
;; idiom: exit codes that never lie, JSON on --json, no implicit
;; network). Subcommands:
;;   hosts                 list host profiles (label, address, tags)
;;   run <host> <command>  one-shot command over the ssh sidecar
;;                         (BatchMode; prints stdout, exits non-zero
;;                         with the remote exit code on failure)
;;   snippets              list snippets
;;   transports            which transports are available
;;
;; The MCP server (mcp.rkt) reuses the same store so coding agents get
;; the same truths through either surface.

(require racket/format
         racket/list
         racket/match
         racket/port
         racket/string
         json
         "backend/store.rkt"
         "backend/ssh.rkt")

(define (host-by-ref reference)
  ;; by label, or user@host style quick match
  (or (findf (lambda (h) (string=? (hash-ref h 'label) reference))
             (list-hosts))
      (findf (lambda (h)
               (string=? (format "~a@~a"
                                 (hash-ref h 'username "")
                                 (hash-ref h 'host))
                         reference))
             (list-hosts))
      (error 'run "no host matching ~a" reference)))

(define (cmd-hosts json?)
  (define hosts (list-hosts))
  (if json?
      (write-json (for/list ([h (in-list hosts)])
                    (hasheq 'label (hash-ref h 'label)
                            'host (hash-ref h 'host)
                            'port (hash-ref h 'port 22)
                            'username (hash-ref h 'username "")
                            'group (hash-ref h 'group-name "")
                            'tags (hash-ref h 'tags '()))))
      (for ([h (in-list hosts)])
        (displayln
         (format "~a\t~a@~a:~a\t[~a]"
                 (hash-ref h 'label)
                 (hash-ref h 'username "")
                 (hash-ref h 'host)
                 (hash-ref h 'port 22)
                 (string-join (hash-ref h 'tags '()) ","))))))

(define (cmd-run reference command)
  (define h (host-by-ref reference))
  (define-values (cmd args)
    (ssh-argv
     (hasheq 'host (hash-ref h 'host)
             'port (hash-ref h 'port 22)
             'username (hash-ref h 'username "")
             'auth-type "agent"
             'identity-file (hash-ref h 'identity-file "")
             'strict-host-key (hash-ref h 'strict-host-key "accept-new")
             'jump (hash-ref h 'jump "")
             'keep-alive 0)))
  (define argv (append args (list command)))
  (with-handlers ([exn:fail? (lambda (e)
                               (eprintf "~a\n" (exn-message e))
                               2)])
    ;; No pty needed for a one-shot: plain pipes, blocking to completion.
    (define-values (proc stdout stdin stderr)
      (apply subprocess #f #f #f cmd argv))
    (copy-port stdout (current-output-port))
    (copy-port stderr (current-error-port))
    (define st (subprocess-status proc))
    (cond [(not st) 2]
          [(eq? st 'done) 0]
          [else st])))

(define (cmd-snippets json?)
  (define snippets (list-snippets))
  (if json?
      (write-json (for/list ([s (in-list snippets)])
                    (hasheq 'name (hash-ref s 'name)
                            'command (hash-ref s 'command))))
      (for ([s (in-list snippets)])
        (displayln (format "~a\t~a" (hash-ref s 'name) (hash-ref s 'command))))))

(define (cmd-transports)
  (for ([name (in-list '("ssh" "telnet" "mosh" "serial" "sftp"))])
    (define available
      (case name
        [("serial")
         (if (eq? (system-type 'os) 'windows) "windows-leg" "yes")]
        [else
         (if (find-executable-path (if (string=? name "sftp") "sftp" name))
             "yes" "no")]))
    (displayln (format "~a\t~a" name available))))

(module+ main
  (void (store-init!))
  (define json? (member "--json" (vector->list (current-command-line-arguments))))
  (define argv
    (vector->list
     (current-command-line-arguments)))
  (define positional (filter (lambda (a) (not (string-prefix? a "--"))) argv))
  (define result
    (match positional
      [(list "hosts")
       (cmd-hosts (and json? #t))]
      [(list "snippets")
       (cmd-snippets (and json? #t))]
      [(list "transports")
       (cmd-transports)]
      [(list "run" reference command-parts ...)
       (cmd-run reference (string-join command-parts " "))]
      [(list)
       (displayln "usage: termpilot hosts|snippets|transports|run <host> <command...> [--json]")
       1]
      [_ (displayln "unknown subcommand") 1]))
  (exit (if (exact-integer? result) result 0)))
