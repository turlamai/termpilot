#lang racket/base

;; TermPilot MCP server (stdio, zero dependencies): a coding agent's
;; terminal-access surface over the same store the app and CLI use.
;; Tools:
;;   list_hosts       -> host labels + addresses
;;   run_command      -> one-shot over the ssh sidecar (exit code honest)
;;   list_snippets    -> saved commands
;;   list_logs        -> session-log files written by opt-in logging
;;   failure_evidence -> bounded tail + sha1 of one session log
;;   session_summary  -> handover digest of terminal output through
;;                       the governed AI path (redacted; errors
;;                       honestly when no API key is configured)
;; Protocol: newline-delimited JSON-RPC 2.0 (MCP stdio transport);
;; initialize / tools/list / tools/call handled, notifications dropped.

(require json
         racket/format
         racket/match
         racket/port
         racket/string
         "backend/store.rkt"
         "backend/ssh.rkt"
         "backend/session.rkt"
         "backend/ai/ai.rkt"
         "backend/evidence.rkt"
         "backend/runproc.rkt")

(define protocol-version "2024-11-05")

(define server-info
  (hasheq 'name "termpilot" 'version "0.3.0"))

(define (tool-list)
  (list
   (hasheq 'name "list_hosts"
           'description "List saved SSH host profiles (label, address, tags)."
           'inputSchema (hasheq 'type "object" 'properties (hasheq)))
   (hasheq 'name "list_snippets"
           'description "List saved command snippets (name + command)."
           'inputSchema (hasheq 'type "object" 'properties (hasheq)))
   (hasheq 'name "run_command"
           'description
           "Run ONE command on a saved host over the system ssh (BatchMode). Returns stdout/stderr and the exit code; a timeout reports honestly instead of hanging. Never interactive; agent auth only."
           'inputSchema
           (hasheq 'type "object"
                   'properties
                   (hasheq 'host (hasheq 'type "string"
                                         'description "host label")
                           'command (hasheq 'type "string"
                                            'description "the command line")
                           'timeout (hasheq 'type "integer"
                                            'description "kill the command after this many seconds (default 300)"))
                   'required '("host" "command")))
   (hasheq 'name "list_logs"
           'description
           "List session-log files (opt-in terminal logging from the app). Feed a name to failure_evidence."
           'inputSchema (hasheq 'type "object" 'properties (hasheq)))
   (hasheq 'name "failure_evidence"
           'description
           "Citable failure evidence for one session log: the bounded recent tail plus its sha1 fingerprint (.log raw output or .cast recordings)."
           'inputSchema
           (hasheq 'type "object"
                   'properties
                   (hasheq 'name (hasheq 'type "string"
                                         'description "session-log file name from list_logs"))
                   'required '("name")))
   (hasheq 'name "session_summary"
           'description
           "Handover digest of a terminal session excerpt (what was done, changes, errors, follow-ups). Redaction applies before the LLM call; requires a configured AI key."
           'inputSchema
           (hasheq 'type "object"
                   'properties
                   (hasheq 'text (hasheq 'type "string"
                                         'description "the terminal output excerpt"))
                   'required '("text")))))

(define (text-result text)
  (hasheq 'content (list (hasheq 'type "text" 'text text))))

(define (handle-call name params)
  (case name
    [("list_hosts")
     (define hosts (list-hosts))
     (text-result
      (if (null? hosts)
          "no hosts saved"
          (string-join
           (for/list ([h (in-list hosts)])
             (format "~a -> ~a@~a:~a [~a]"
                     (hash-ref h 'label)
                     (hash-ref h 'username "")
                     (hash-ref h 'host)
                     (hash-ref h 'port 22)
                     (string-join (hash-ref h 'tags '()) ",")))
           "\n")))]
    [("list_snippets")
     (define snippets (list-snippets))
     (text-result
      (if (null? snippets)
          "no snippets saved"
          (string-join
           (for/list ([s (in-list snippets)])
             (format "~a: ~a" (hash-ref s 'name) (hash-ref s 'command)))
           "\n")))]
    [("run_command")
     (define reference (hash-ref params 'host ""))
     (define command (hash-ref params 'command ""))
     (define timeout
       (let ([t (hash-ref params 'timeout 300)])
         (unless (and (exact-integer? t) (>= t 1) (<= t 86400))
           (error 'run_command "timeout must be an integer, 1..86400"))
         t))
     (define h
       (or (findf (lambda (x)
                    (string=? (hash-ref x 'label) reference))
                  (list-hosts))
           (error 'run_command "no host matching ~a" reference)))
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
     (define-values (code out err timed-out?)
       (run-command-with-timeout
        (append (list cmd) args (list command)) timeout))
     (text-result
      (if timed-out?
          (format "timeout: killed after ~a s\nstdout:\n~a\nstderr:\n~a"
                  timeout out err)
          (format "exit: ~a\nstdout:\n~a\nstderr:\n~a"
                  code out err)))]
    [("list_logs")
     (define logs (list-log-files))
     (text-result
      (if (null? logs)
          "no session logs (logging is opt-in per session in the app)"
          (string-join
           (for/list ([l (in-list logs)])
             (format "~a (~a bytes)" (hash-ref l 'name) (hash-ref l 'bytes)))
           "\n")))]
    [("failure_evidence")
     ;; Same seam as the CLI: the name is validated against the
     ;; session-logs directory, never an arbitrary path.
     (define name (hash-ref params 'name ""))
     (define ev (evidence-from-log-bytes "" name (read-log-file name)))
     (text-result
      (format "~a  sha1: ~a  bytes: ~a\n~a"
              name (hash-ref ev 'sha1) (hash-ref ev 'bytes)
              (hash-ref ev 'output)))]
    [("session_summary")
     (define text (hash-ref params 'text ""))
     (unless (has-llm-key?)
       (error 'session_summary
              "no AI API key configured — set one in the app's AI settings"))
     (define r (summarize-session text))
     (text-result (hash-ref r 'text))]
    [else (error 'tools/call "unknown tool ~a" name)]))

(define (reply id result)
  (write-json (hasheq 'jsonrpc "2.0" 'id id 'result result))
  (newline))

(define (reply-error id code message)
  (write-json (hasheq 'jsonrpc "2.0" 'id id
                      'error (hasheq 'code code 'message message)))
  (newline))

(module+ main
  (void (store-init!))
  (let loop ()
    (define line (read-line))
    (unless (eof-object? line)
      (define msg
        (with-handlers ([exn:fail? (lambda (_) #f)])
          (string->jsexpr line)))
      (when msg
        (define method (hash-ref msg 'method #f))
        (define id (hash-ref msg 'id #f))
        (match method
          ["initialize"
           (reply id
                  (hasheq 'protocolVersion protocol-version
                          'capabilities (hasheq 'tools (hasheq))
                          'serverInfo server-info))]
          ["notifications/initialized" (void)]
          ["tools/list"
           (reply id (hasheq 'tools (tool-list)))]
          ["tools/call"
           (define params (hash-ref msg 'params (hasheq)))
           (define name (hash-ref params 'name))
           (with-handlers
             ([exn:fail?
               (lambda (e)
                 (when id
                   (reply-error id -32000 (exn-message e))))])
             (define result
               (handle-call name (hash-ref params 'arguments (hasheq))))
             (when id
               (reply id (hasheq 'tools result))))]
          ["ping" (reply id (hasheq))]
          [_ (void)]))
      (loop))))
