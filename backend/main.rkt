#lang racket/base

;; TermPilot backend — the Racket engine behind the web terminal UI.
;; Serves the built React frontend from apps/desktop/dist and the /api
;; surface: host/snippet store, pty terminal sessions over the ssh
;; sidecar (or a local shell), and BYOK AI assistance.
;;
;; Run:  pnpm --filter @termpilot/desktop build   (once)
;;       racket backend/main.rkt
;; Dev:  raco glaze dev  /  TERMPILOT_TRANSPORT=http for the HTTP adapter.

;; Explicit glaze module imports (the legacy `glaze` facade is a
;; compatibility shim; its deprecated re-exports are removed in 0.19.0).
(require glaze/app        ; run-app
         glaze/api        ; GET, POST, streaming-response
         glaze/api-macros ; define-api-routes
         glaze/events     ; make-event-bus
         glaze/types      ; GString, GInt64, GValue, GBytes
         net/base64
         glaze/window     ; webview? / title for the selftest
         json
         racket/format
         racket/list
         racket/match
         racket/port
         racket/runtime-path
         racket/set
         racket/string
         "ai/ai.rkt"
         "evidence.rkt"
         "forwarding.rkt"
         "keys.rkt"
         "knownhosts.rkt"
         "sftp.rkt"
         "probes.rkt"
         "session.rkt"
         "ssh-config.rkt"
         "transports.rkt"
         "ssh.rkt"
         "store.rkt"
         "updater.rkt")   ; signed update check (Ed25519 release-asset manifest)

;; The route list schema tooling reads (glaze.rktd points here).
(provide api)

;; Keep in sync with package.json and CHANGELOG.md; the release
;; workflow's validate job fails the tag if they disagree.
(define app-version "0.8.0")

;; net/base64 in Racket 9.3 ships only the stream encoder; a compact
;; standard-table decoder for the GBytes payloads (base64 strings).
(define b64-alphabet
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(define (b64-value c)
  (define idx (index-of (string->list b64-alphabet) c))
  (or (and idx (- (length (string->list b64-alphabet)) (length (member c (string->list b64-alphabet)))))
      0))

(define (base64-decode s)
  (define clean (string-trim s))
  (define chars (string->list (string-trim clean #:left? #f #:right? #t "=")))
  (define vals
    (for/list ([c (in-list chars)]) (b64-value c)))
  (define (slice4 lst)
    (if (null? lst)
        '()
        (let-values ([(head tail) (split-at lst (min 4 (length lst)))])
          (cons head (slice4 tail)))))
  (define out
    (for/list ([chunk (in-list (slice4 vals))])
      (case (length chunk)
        [(4)
         (define v (+ (* (list-ref chunk 0) 262144)
                      (* (list-ref chunk 1) 4096)
                      (* (list-ref chunk 2) 64)
                      (list-ref chunk 3)))
         (list (arithmetic-shift v -16) (bitwise-and (arithmetic-shift v -8) 255) (bitwise-and v 255))]
        [(3)
         (define v (+ (* (list-ref chunk 0) 262144) (* (list-ref chunk 1) 4096) (* (list-ref chunk 2) 64)))
         (list (arithmetic-shift v -16) (bitwise-and (arithmetic-shift v -8) 255))]
        [(2)
         (define v (+ (* (list-ref chunk 0) 262144) (* (list-ref chunk 1) 4096)))
         (list (arithmetic-shift v -16))]
        [else '()])))
  (list->bytes (append* out)))

;; ---- updates ----------------------------------------------------------------

;; Commercial baseline: notify-and-open (not silent auto-install —
;; unsigned auto-install is how update systems become attack surface).
;; The check verifies the Ed25519-signed manifest published as a release
;; asset (backend/updater.rkt); a failed check degrades to no banner,
;; never to a less-verified one. The legacy plain manifest at
;; termpilot.jrtx.site stays up for 0.8.0-and-older clients only.
(define update-box (box #f)) ; (cons checked-at info-or-false)

(define (update-check)
  (define cached (unbox update-box))
  (define ttl 3600)
  (cond
    [(and cached
          (< (- (current-seconds) (car cached)) ttl))
     (cdr cached)]
    [else
     (define info
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (check-update-signed app-version)))
     (set-box! update-box (cons (current-seconds) info))
     info]))

(define (hash-merge a b)
  (for/fold ([acc a]) ([(k v) (in-hash b)]) (hash-set acc k v)))

;; One session manager for the whole app; sessions are process-local.
(define sessions (make-manager))

;; Sessions must OUTLIVE the request that opened them: glaze runs each
;; handler under a per-request custodian that shuts down on return,
;; which would kill the session's script child and pipes. Spawn every
;; session (and its pump thread) under this app-owned custodian instead.
(define session-custodian (make-custodian))

;; ---- helpers ---------------------------------------------------------------

;; Merge a stored host into the ssh profile the sidecar consumes.
(define (host-profile h)
  (hasheq 'host (hash-ref h 'host)
          'port (hash-ref h 'port 22)
          'username (hash-ref h 'username "")
          'auth-type (hash-ref h 'auth-type "agent")
          'identity-file (hash-ref h 'identity-file "")
          'strict-host-key (hash-ref h 'strict-host-key "accept-new")
          'jump (hash-ref h 'jump "")
          'keep-alive (hash-ref h 'keep-alive 0)))

;; Build the session spec (command + args + label) for a terminal open
;; request: hostId, a free-form quick-connect profile, or kind:"local"
;; for a local shell tab.
(define (open-spec body)
  (define host-id (hash-ref body 'host-id #f))
  (cond
    [(equal? (hash-ref body 'kind "ssh") "local")
     (define-values (command args) (local-command '()))
     (hasheq 'kind "local" 'label "local" 'command command 'args args)]
    [(string? host-id)
     (define h (or (get-host host-id)
                   (error 'terminal/open "unknown host ~a" host-id)))
     (define spec-h (hash-merge h body))
     (case (hash-ref spec-h 'connection-kind "ssh")
       [(telnet)
        (define-values (c a)
          (telnet-argv (hash-ref spec-h 'host "?")
                       (hash-ref spec-h 'port 23)))
        (hasheq 'kind "telnet" 'label (hash-ref h 'label)
                'command c 'args a)]
       [(mosh)
        (define-values (c a) (mosh-argv (host-profile spec-h)))
        (hasheq 'kind "mosh" 'label (hash-ref h 'label)
                'command c 'args a)]
       [(serial)
        ;; No sidecar: serial sessions open the device directly. The
        ;; spec uses a serial:// pseudo-command the session manager
        ;; resolves; see session.rkt.
        (hasheq 'kind "serial"
                'label (hash-ref h 'label)
                'device (hash-ref spec-h 'host)
                'baud (hash-ref spec-h 'port 115200))]
       [else
        (define-values (command args) (ssh-argv (host-profile spec-h)))
        (hasheq 'kind "ssh" 'label (hash-ref h 'label)
                'command command 'args args)])]
    [else
     (define-values (command args) (ssh-argv (host-profile body)))
     (hasheq 'kind "ssh"
             'label (or (hash-ref body 'label #f)
                        (format "~a" (hash-ref body 'host "?")))
             'command command
             'args args)]))

;; Terminal output rides the streaming channel as raw bytes after a
;; single "OK\n" status line (same line protocol family products use for
;; LLM streams, so one bridge parser serves all streams; errors arrive
;; as "ERR <status> <message>" instead of opening the byte stream).
(define (terminal-stream-streaming-response mgr id)
  (streaming-response
   (lambda (out)
     (define-values (pipe pw) (make-pipe))
     (define-values (s replay) (attach-session! mgr id pw))
     (cond
       [(not s)
        (displayln "ERR 404 unknown session" out)]
       [else
        (displayln "OK" out)
        (when (> (bytes-length replay) 0)
          (write-bytes replay out)
          (flush-output out))
        ;; Drain until the pump closes our pipe (child exit or cancel).
        ;; read-bytes-avail!: deliver whatever arrives — read-bytes
        ;; would wait to fill 64 KiB and stall an interactive stream.
        (let loop ()
          (define buf (make-bytes 65536))
          (define n (read-bytes-avail! buf pipe))
          (unless (eof-object? n)
            (when (and (number? n) (> n 0))
              (write-bytes buf out 0 n)
              (flush-output out))
            (loop)))]))
   #:mime #"application/octet-stream"))

;; ---- routes ----------------------------------------------------------------

(define-api-routes api
  ;; health
  [(POST "api/health" #:returns (grecord "Health" "ok" GString
                                         "version" GString))
   (health)
   (hasheq 'ok #t 'version app-version)]

  ;; hosts
  [(POST "api/hosts/list" #:returns GValue)
   (hosts-list)
   (hasheq 'hosts (list-hosts))]
  [(POST "api/hosts/create" #:returns GValue)
   (hosts-create [host hash?])
   (insert-host! host)]
  [(POST "api/hosts/update" #:returns GValue)
   (hosts-update [id string?] [host hash?])
   (update-host! id host)]
  [(POST "api/hosts/delete" #:returns GValue)
   (hosts-delete [id string?])
   (delete-host! id)]

  ;; config import + data export/import
  [(POST "api/hosts/import-config" #:returns GValue)
   (hosts-import-config)
   (define path
     (build-path (find-system-path 'home-dir) ".ssh" "config"))
   (unless (file-exists? path)
     (error 'hosts/import-config "no ~/.ssh/config found"))
   (define profiles (parse-ssh-config path))
   (define existing
     (list->set (map (lambda (h) (hash-ref h 'label)) (list-hosts))))
   (define fresh
     (for/list ([p (in-list profiles)]
                #:unless (set-member? existing (hash-ref p 'label)))
       (insert-host!
        (hash-merge p
                    (hasheq 'group-name "imported" 'tags '("imported"))))))
   (hasheq 'imported (length fresh)
           'skipped (- (length profiles) (length fresh)))]
  [(POST "api/data/export" #:returns GValue)
   (data-export)
   (hasheq 'version app-version
           'exported-at (current-seconds)
           'hosts (list-hosts)
           'snippets (list-snippets))]
  [(POST "api/data/import" #:returns GValue)
   (data-import [data hash?])
   ;; Replace-all: the UI confirms before calling. Snippets first (no
   ;; foreign keys), then hosts.
   (for ([s (in-list (list-snippets))])
     (delete-snippet! (hash-ref s 'id)))
   (for ([h (in-list (list-hosts))])
     (delete-host! (hash-ref h 'id)))
   (for ([h (in-list (hash-ref data 'hosts '()))])
     (insert-host! h))
   (for ([sn (in-list (hash-ref data 'snippets '()))])
     (insert-snippet! sn))
   (hasheq 'hosts (length (hash-ref data 'hosts '()))
           'snippets (length (hash-ref data 'snippets '())))]

  ;; forwarding rules + tunnels
  [(POST "api/forward/rules" #:returns GValue)
   (forward-rules)
   (hasheq 'rules (list-rules))]
  [(POST "api/forward/create" #:returns GValue)
   (forward-create [rule hash?])
   (insert-rule! rule)]
  [(POST "api/forward/delete" #:returns GValue)
   (forward-delete [id string?])
   (stop-tunnel! id) ; stop first if running
   (delete-rule! id)]
  [(POST "api/forward/start" #:returns GValue)
   (forward-start [id string?])
   (define rule (or (get-rule id) (error 'forward/start "unknown rule")))
   (parameterize ([current-custodian session-custodian])
     (start-tunnel! rule))]
  [(POST "api/forward/stop" #:returns GValue)
   (forward-stop [id string?])
   (stop-tunnel! id)]
  [(POST "api/forward/status" #:returns GValue)
   (forward-status)
   (hasheq 'tunnels (tunnel-status))]

  ;; Latency probe: parallel TCP-handshake timings for the listed
  ;; hosts (no auth, per-host timeout). Unreachable -> ms: #f.
  [(POST "api/hosts/probe" #:returns GValue)
   (hosts-probe [targets (lambda (v) (and (list? v) (andmap hash? v)))])
   (define results
     (for/list ([t (in-list targets)])
       (define id (hash-ref t 'id ""))
       (define ms
         (parameterize ([current-custodian (make-custodian)])
           (probe-host (hash-ref t 'host "?")
                       (hash-ref t 'port 22)
                       3000)))
       (hasheq 'id id 'ms ms)))
   (hasheq 'results results)]
  [(POST "api/logs/list" #:returns GValue)
   (logs-list)
   (hasheq 'logs (list-log-files))]
  [(POST "api/logs/read" #:returns GBytes)
   (logs-read [name string?])
   (read-log-file name)]
  [(POST "api/logs/delete" #:returns GValue)
   (logs-delete [name string?])
   (delete-log-file! name)
   (hasheq 'ok #t)]
  [(POST "api/update/check" #:returns GValue)
   (update-status)
   (define info (update-check))
   (hasheq 'current app-version
           'available (and info #t)
           'version (if info (hash-ref info 'version #f) #f)
           'url (if info (hash-ref info 'url #f) #f)
           'notes (if info (hash-ref info 'notes #f) #f))]

  ;; transport availability (UI gates connection-kind options on this)
  [(POST "api/doctor/transports" #:returns GValue)
   (doctor-transports)
   (hasheq 'ssh (and (find-executable-path "ssh") #t)
           'telnet (and (find-executable-path "telnet") #t)
           'mosh (and (find-executable-path "mosh") #t)
           'serial (if (eq? (system-type 'os) 'windows) "windows-leg" #t)
           'ssh-keygen (and (find-executable-path "ssh-keygen") #t))]

  ;; sftp
  [(POST "api/sftp/list" #:returns GValue)
   (sftp-list [host-id string?] [path string?])
   (hasheq 'path path 'entries (list-dir host-id path))]
  [(POST "api/sftp/mkdir" #:returns GValue)
   (sftp-mkdir [host-id string?] [path string?])
   (mkdir! host-id path)
   (hasheq 'ok #t)]
  [(POST "api/sftp/delete" #:returns GValue)
   (sftp-delete [host-id string?] [path string?])
   (remove! host-id path)
   (hasheq 'ok #t)]
  [(POST "api/sftp/rmdir" #:returns GValue)
   (sftp-rmdir [host-id string?] [path string?])
   (remove-dir! host-id path)
   (hasheq 'ok #t)]
  [(POST "api/sftp/rename" #:returns GValue)
   (sftp-rename [host-id string?] [from string?] [to string?])
   (rename! host-id from to)
   (hasheq 'ok #t)]
  [(POST "api/sftp/download-dir" #:returns GBytes)
   (sftp-download-dir [host-id string?] [path string?])
   (download-dir! host-id path)]
  [(POST "api/sftp/download" #:returns GBytes)
   (sftp-download [host-id string?] [path string?])
   (download! host-id path)]
  [(POST "api/sftp/upload" #:returns GValue)
   (sftp-upload [host-id string?] [path string?] [data GBytes])
   (define payload
     (if (string? data)
         (base64-decode data)
         data))
   (upload! host-id path payload)
   (hasheq 'ok #t)]
  [(POST "api/sftp/upload-dir" #:returns GValue)
   (sftp-upload-dir [host-id string?] [path string?] [files GValue])
   (define count
     (upload-dir!
      host-id path
      (for/list ([f (in-list files)])
        (hasheq 'path (hash-ref f 'path)
                'data (base64-decode (hash-ref f 'data))))))
   (hasheq 'count count)]

  ;; ssh keys
  [(POST "api/keys/list" #:returns GValue)
   (keys-list)
   (hasheq 'keys (list-keys))]
  [(POST "api/keys/meta" #:returns GValue)
   (keys-meta [name string?])
   (key-meta name)]
  [(POST "api/keys/generate" #:returns GValue)
   (keys-generate [name string?] [type string? "ed25519"]
                  [passphrase string? ""] [bits integer? 0])
   (generate-key! name type passphrase bits)]
  [(POST "api/keys/public" #:returns GValue)
   (keys-public [name string?])
   (hasheq 'name name 'public (public-key-of name))]
  [(POST "api/keys/delete" #:returns GValue)
   (keys-delete [name string?])
   (delete-key! name)]
  [(POST "api/keys/import" #:returns GValue)
   (keys-import [name string?] [content string?])
   (import-key! name content)]
  [(POST "api/keys/distribute" #:returns GValue)
   (keys-distribute [name string?] [host-id string?])
   (define h (or (get-host host-id)
                 (error 'keys/distribute "unknown host")))
   (define-values (ok? output)
     (distribute-pubkey! name (host-profile h)))
   (hasheq 'ok ok? 'output output 'host (hash-ref h 'label))]

  ;; known hosts
  [(POST "api/known/list" #:returns GValue)
   (known-list)
   (hasheq 'entries (list-known-hosts))]
  [(POST "api/known/remove" #:returns GValue)
   (known-remove [index integer?])
   (remove-known-host! index)]

  ;; snippets
  [(POST "api/snippets/list" #:returns GValue)
   (snippets-list)
   (hasheq 'snippets (list-snippets))]
  [(POST "api/snippets/create" #:returns GValue)
   (snippets-create [snippet hash?])
   (insert-snippet! snippet)]
  [(POST "api/snippets/delete" #:returns GValue)
   (snippets-delete [id string?])
   (delete-snippet! id)]

  ;; terminal sessions — params are top-level body keys (the bridge
  ;; flattens them); host sessions pass host-id, quick-connect passes
  ;; host/port/username, local tabs pass kind:"local".
  [(POST "api/terminal/open" #:returns GValue)
   (terminal-open [cols integer? 80] [rows integer? 24]
                  [host-id string? #f] [kind string? "ssh"]
                  [host string? "?"] [port integer? 22]
                  [username string? ""] [auth-type string? "agent"]
                  [identity-file string? ""] [label string? #f])
   (define body
     (hasheq 'cols cols 'rows rows 'host-id host-id 'kind kind
             'host host 'port port 'username username
             'auth-type auth-type 'identity-file identity-file
             'label label))
   (define spec (open-spec body))
   (define s
     (parameterize ([current-custodian session-custodian])
       (open-session! sessions spec #:cols cols #:rows rows)))
   ;; Auto-start forwarding rules bound to this host (opt-in flag).
   (when host-id
     (for ([r (in-list (list-rules))]
           #:when (and (hash-ref r 'auto-start #f)
                       (string=? (hash-ref r 'host-id "") host-id)))
       (with-handlers ([exn:fail? void])
         (parameterize ([current-custodian session-custodian])
           (start-tunnel! r)))))
   (hasheq 'id (session-id s)
           'kind (symbol->string (session-kind s))
           'label (session-label s))]
  [(POST "api/terminal/input")
   (terminal-input [id string?] [data string?])
   (unless (write-session! sessions id (string->bytes/utf-8 data))
     (error 'terminal/input "session not writable"))
   (hasheq 'ok #t)]
  ;; Broadcast input: same bytes to every listed session (Termius
  ;; broadcast-input parity). Partial failures report per-session.
  [(POST "api/terminal/broadcast")
   (terminal-broadcast [ids (lambda (v) (and (list? v) (andmap string? v)))] [data string?])
   (define results
     (for/list ([id (in-list ids)])
       (hasheq 'id id 'ok (write-session! sessions id (string->bytes/utf-8 data)))))
   (hasheq 'sent (count (lambda (r) (hash-ref r 'ok)) results)
           'results results)]
  [(POST "api/terminal/resize")
   (terminal-resize [id string?] [cols integer?] [rows integer?])
   (unless (resize-session! sessions id cols rows)
     (error 'terminal/resize "session not resizable"))
   (hasheq 'ok #t)]
  [(POST "api/terminal/close")
   (terminal-close [id string?])
   (close-session! sessions id)
   (hasheq 'ok #t)]
  [(POST "api/terminal/log/start" #:returns GValue)
   (terminal-log-start [id string?])
   (define s (or (get-session sessions id)
                 (error 'terminal/log "unknown session")))
   (hasheq 'path
           (path->string
            (parameterize ([current-custodian session-custodian])
              (start-logging! sessions id (session-label s)))))]
  [(POST "api/terminal/record/start" #:returns GValue)
   (terminal-record-start [id string?])
   (define s (or (get-session sessions id)
                 (error 'terminal/record "unknown session")))
   ;; Same custodian rule as sessions: the recording port must outlive
   ;; the request that opened it.
   (hasheq 'path
           (path->string
            (parameterize ([current-custodian session-custodian])
              (start-recording! sessions id (session-label s) #t))))]
  [(POST "api/terminal/log/stop" #:returns GValue)
   (terminal-log-stop [id string?])
   (stop-logging! sessions id)
   (hasheq 'ok #t)]
  [(POST "api/sessions/list" #:returns GValue)
   (sessions-list)
   (hasheq 'sessions (list-sessions sessions))]
  ;; Raw byte channel: OK, then the pty bytes until child exit. Returns
  ;; the streaming response directly (same shape the LLM streams use).
  [(POST "api/terminal/stream")
   (terminal-stream [id string?])
   (terminal-stream-streaming-response sessions id)]

  ;; ai
  [(POST "api/ai/settings" #:returns GValue)
   (ai-settings)
   (settings-view)]
  [(POST "api/ai/presets" #:returns GValue)
   (ai-presets)
   (hasheq 'presets (presets-view))]
  [(POST "api/ai/settings/save" #:returns GValue)
   (ai-settings-save [provider string?] [model string?]
                     [base-url string?] [api-key string?]
                     [redact-enabled boolean?])
   (save-settings-from-ui! provider model base-url api-key redact-enabled)]
  [(POST "api/ai/settings/test" #:returns GValue)
   (ai-settings-test)
   (test-settings!)]
  [(POST "api/ai/redact-preview" #:returns GValue)
   (ai-redact-preview [text string?])
   (redact-preview text)]
  [(POST "api/ai/generate" #:returns GValue)
   (ai-generate [intent string?] [host-context string? ""]
                [terminal string? ""])
   (generate-command intent host-context terminal)]
  [(POST "api/ai/explain" #:returns GValue)
   (ai-explain [output string?])
   (explain-output output)]
  [(POST "api/ai/summarize" #:returns GValue)
   (ai-summarize [output string?])
   (summarize-session output)]
  ;; Failure evidence: a bounded, fingerprinted diagnostic dump of one
  ;; session's recent output (family idiom — sized to stay out of LLM
  ;; context, with a sha256 so agents can cite and dedupe it). The
  ;; record shape lives in evidence.rkt, shared with the CLI and MCP.
  [(POST "api/terminal/evidence" #:returns GValue)
   (terminal-evidence [id string?])
   (define s (or (get-session sessions id)
                 (error 'terminal/evidence "unknown session")))
   (evidence-from-text
    id
    (session-label s)
    (symbol->string (session-kind s))
    (bytes->string/utf-8 (apply bytes-append (session-ring s)) #\?))])

;; ---- app -------------------------------------------------------------------

(define-runtime-path frontend-dist "../apps/desktop/dist")

(module+ main
  ;; Create the schema before the server accepts anything.
  (void (store-init!))

  ;; TERMPILOT_TRANSPORT=http switches to the explicit dev adapter; the
  ;; production shape is the native GLZ1 carrier (no loopback TCP).
  (define transport
    (or (let ([v (getenv "TERMPILOT_TRANSPORT")])
          (and (member v '("native" "http")) (string->symbol v)))
        'native))
  (run-app
   #:public-dir frontend-dist
   #:api api
   #:transport transport
   #:api-token (or (getenv "GLAZE_API_TOKEN") #t)
   #:title "TermPilot"
   #:width 1200
   #:height 800
   #:app-id "termpilot"
   #:window-state #t
   #:current-version app-version))
