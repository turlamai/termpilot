#lang racket/base

;; TermPilot MCP server (stdio, zero dependencies): a coding agent's
;; terminal-access surface over the same store the app and CLI use.
;; Tools:
;;   list_hosts    -> host labels + addresses
;;   run_command   -> one-shot over the ssh sidecar (exit code honest)
;;   list_snippets -> saved commands
;; Protocol: newline-delimited JSON-RPC 2.0 (MCP stdio transport);
;; initialize / tools/list / tools/call handled, notifications dropped.

(require json
         racket/format
         racket/match
         racket/port
         racket/string
         "backend/store.rkt"
         "backend/ssh.rkt")

(define protocol-version "2024-11-05")

(define server-info
  (hasheq 'name "termpilot" 'version "0.1.0"))

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
           "Run ONE command on a saved host over the system ssh (BatchMode). Returns stdout/stderr and the exit code. Never interactive; agent auth only."
           'inputSchema
           (hasheq 'type "object"
                   'properties
                   (hasheq 'host (hasheq 'type "string"
                                         'description "host label")
                           'command (hasheq 'type "string"
                                            'description "the command line"))
                   'required '("host" "command")))))

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
     (define-values (proc stdout stdin stderr)
       (apply subprocess #f #f #f cmd (append args (list command))))
     (close-output-port stdin)
     (define out (port->string stdout))
     (define err (port->string stderr))
     (define st (subprocess-status proc))
     (text-result
      (format "exit: ~a\nstdout:\n~a\nstderr:\n~a"
              (cond [(not st) "timeout"]
                    [(eq? st 'done) 0]
                    [else st])
              out err))]
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
