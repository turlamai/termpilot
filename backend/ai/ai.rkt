#lang racket/base

;; AI orchestration: settings custody (BYOK, 0600, backend-held, never
;; enters the webview), command generation and output explanation over
;; Switchboard (the family's shared LLM access layer). Every preset is
;; registered as a Switchboard provider at load, so one call surface
;; covers GLM/DeepSeek/Qwen/Kimi/Doubao/SiliconFlow/OpenAI/Anthropic/
;; Ollama alike. Every send path redacts first (see ai/redact.rkt).
;; AI proposes; the user runs anything.

(require json
         racket/contract
         racket/file
         racket/string
         switchboard
         "../platform.rkt"
         "providers.rkt"
         "redact.rkt")

;; Masked sentinel: the UI receives this after a save instead of the key.
(define saved-sentinel "__SAVED__")

;; ---- Switchboard provider registration -----------------------------------

;; Built-in switchboard providers (openai, anthropic, deepseek, ollama,
;; ...) are shadowed by our presets so base-urls stay in one table.
(for ([p (in-list provider-presets)])
  (add-provider!
   (provider (string->symbol (preset-id p))
             (if (string=? (preset-base-url p) "")
                 "https://api.openai.com/v1"
                 (preset-base-url p))
             (if (preset-env-key p) (list (preset-env-key p)) '())
             (not (string=? (preset-kind p) "ollama"))
             (if (string=? (preset-kind p) "anthropic")
                 'anthropic
                 'openai))))

;; ---- settings file (0600, backend-held) -----------------------------------

;; Computed lazily: module load stays pure; the file is only touched
;; when settings are read or saved.
(define (settings-path)
  (build-path (ensure-app-data-dir!) "ai-settings.json"))

(define default-settings
  (hasheq 'provider default-preset-id
          'model ""
          'base-url ""
          'api-key ""
          'redact-enabled #t))

(define (load-settings)
  (if (file-exists? (settings-path))
      (with-handlers ([exn:fail? (lambda (_) default-settings)])
        (for/fold ([acc default-settings])
                  ([(k v) (in-hash (string->jsexpr
                                    (file->string (settings-path))))])
          (hash-set acc k v)))
      default-settings))

(define (save-settings! h)
  (define dir (ensure-app-data-dir!))
  (define tmp (build-path dir ".ai-settings.json.tmp"))
  (with-output-to-file tmp
    (lambda () (write-string (jsexpr->string h)))
    #:exists 'replace)
  (when (file-exists? (settings-path))
    (delete-file (settings-path)))
  (rename-file-or-directory tmp (settings-path))
  ;; 0600: the key file is backend-held; nothing else may read it.
  (file-or-directory-permissions (settings-path) #o600)
  (void))

;; Public view: the key is replaced by the sentinel so it never crosses
;; the bridge; an empty key shows as empty (nothing saved yet).
(define (settings-view)
  (define s (load-settings))
  (hasheq 'provider (hash-ref s 'provider)
          'model (hash-ref s 'model)
          'base-url (hash-ref s 'base-url)
          'api-key (if (string=? (hash-ref s 'api-key "") "")
                       ""
                       saved-sentinel)
          'redact-enabled (hash-ref s 'redact-enabled)))

(define (save-settings-from-ui! provider model base-url api-key redact-enabled)
  (define current (load-settings))
  ;; A sentinel round-trip keeps the stored key unchanged.
  (define key
    (cond
      [(string=? api-key saved-sentinel) (hash-ref current 'api-key)]
      [(string=? api-key "") ""]
      [else api-key]))
  (save-settings!
   (hasheq 'provider provider
           'model model
           'base-url base-url
           'api-key key
           'redact-enabled redact-enabled))
  (settings-view))

;; ---- LLM calls ------------------------------------------------------------

(struct llm-call (model key settings) #:transparent)

(define (resolve-llm-call)
  (define s (load-settings))
  (define p (or (find-preset (hash-ref s 'provider default-preset-id))
                (find-preset default-preset-id)))
  (define model-name
    (let ([m (hash-ref s 'model "")])
      (if (string=? m "") (preset-model p) m)))
  (define stored-key (hash-ref s 'api-key ""))
  (define key
    (cond
      [(not (string=? stored-key "")) stored-key]
      [(preset-env-key p) => (lambda (e) (or (getenv e) ""))]
      [else ""]))
  (llm-call (format "~a/~a" (preset-id p) model-name) key s))

;; Redact unless the user explicitly disabled it (their choice, visible
;; in settings; previews always show what actually goes out).
(define (maybe-redact text settings)
  (if (hash-ref settings 'redact-enabled #t)
      (redacted-text (redact text))
      text))

(define system-prompt-command
  "You are the command assistant inside TermPilot, an SSH client. Given a
user intent plus optional context (host/os, recent terminal output),
return ONE shell command line ready to run on the remote host. Reply with
exactly one line: the command. No markdown fences, no explanation.")

(define system-prompt-explain
  "You are the output assistant inside TermPilot, an SSH client. Explain
the given terminal output: what happened, why it failed if it did, and
one concrete next command when relevant. Answer in the language of the
terminal output, in at most 120 words, plain text.")

;; POST api/ai/generate {intent, host-context?, terminal?} -> {command}
(define (generate-command intent host-context terminal)
  (define call (resolve-llm-call))
  (define s (llm-call-settings call))
  (define context
    (string-join
     (filter (lambda (x) (not (string=? x "")))
             (list
              (and host-context (string? host-context)
                   (not (string=? host-context ""))
                   (format "host: ~a" host-context))
              (and terminal (string? terminal)
                   (not (string=? terminal ""))
                   (format "recent output:\n~a"
                           (maybe-redact terminal s)))))
     "\n"))
  (define prompt
    (if (string=? context "")
        intent
        (format "~a\n\ncontext:\n~a" intent context)))
  (define reply
    (ask (llm-call-model call) prompt
         #:system system-prompt-command
         #:max-tokens 200
         #:api-key (llm-call-key call)))
  (hasheq 'command (string-trim reply)))

;; POST api/ai/explain {output} -> {text}
(define (explain-output output)
  (define call (resolve-llm-call))
  (define reply
    (ask (llm-call-model call)
         (maybe-redact output (llm-call-settings call))
         #:system system-prompt-explain
         #:max-tokens 400
         #:api-key (llm-call-key call)))
  (hasheq 'text (string-trim reply)))

;; POST api/ai/settings/test -> {ok, message}
;; One tiny round trip; a wrong key fails loudly here, not mid-session.
(define (test-settings!)
  (with-handlers
      ([exn:fail? (lambda (e) (hasheq 'ok #f
                                      'message (exn-message e)))])
    (define call (resolve-llm-call))
    (when (string=? (llm-call-key call) "")
      (error 'ai/test "no API key configured"))
    (define reply
      (ask (llm-call-model call) "Reply with the single word: ok"
           #:max-tokens 4
           #:api-key (llm-call-key call)))
    (hasheq 'ok #t 'message reply)))

;; GET api/ai/presets — the settings dropdown's data source; the
;; backend preset table is the single source of truth.
(define (presets-view)
  (for/list ([p (in-list provider-presets)])
    (hasheq 'id (preset-id p)
            'label (preset-label p)
            'model (preset-model p)
            'base-url (preset-base-url p)
            'kind (preset-kind p))))

(provide settings-view
         save-settings-from-ui!
         generate-command
         explain-output
         test-settings!
         redact-preview
         presets-view
         (struct-out preset)
         find-preset
         provider-presets)
