#lang racket/base

;; Failure evidence: a bounded, fingerprinted diagnostic dump of one
;; session's recent output (family idiom — sized to stay out of LLM
;; context, with a sha1 so agents can cite and dedupe the evidence).
;; One implementation shared by the app route (backend/main.rkt), the
;; CLI and the MCP server: text may come from a live session ring or
;; an on-disk session log, the record shape is identical either way.

(require file/sha1
         json
         racket/port
         racket/string)

(provide evidence-bound
         evidence-from-text
         evidence-from-log-bytes)

;; Keep the most recent `evidence-bound` characters of the output.
(define evidence-bound 16000)

(define (bounded-tail text)
  (if (> (string-length text) evidence-bound)
      (substring text (- (string-length text) evidence-bound))
      text))

(define (evidence-record id label kind tail)
  (hasheq 'session id
          'label label
          'kind kind
          'captured-at (current-seconds)
          'sha1 (sha1 (open-input-bytes (string->bytes/utf-8 tail)))
          'bytes (string-length tail)
          'output tail))

;; Evidence from raw output text; the app passes its session ring.
(define (evidence-from-text id label kind text)
  (evidence-record id label kind (bounded-tail text)))

;; Evidence from a session-log file's bytes. Plain .log files are raw
;; session output; .cast files are asciinema v2 recordings — their
;; output events are concatenated so the evidence is the terminal
;; text, not the recording's JSON scaffolding. Input events are
;; deliberately excluded (evidence is what the session showed, not
;; what was typed).
(define (evidence-from-log-bytes id label raw)
  (define text (bytes->string/utf-8 raw #\?))
  (define kind (if (string-suffix? label ".cast") "recording" "log"))
  (evidence-record id label kind
                   (bounded-tail
                    (if (string-suffix? label ".cast")
                        (cast-events-text text)
                        text))))

;; asciinema v2: one JSON value per line — a header object, then
;; ["<time>", "o", "<text>"] event arrays. Unparsable lines are
;; skipped; only string output events ("o") contribute.
(define (cast-events-text text)
  (for/fold ([acc ""]) ([line (in-list (string-split text "\n"))])
    (define ev
      (with-handlers ([exn:fail? (lambda (_) #f)])
        (string->jsexpr line)))
    (if (and (list? ev) (= (length ev) 3)
             (equal? (list-ref ev 1) "o")
             (string? (list-ref ev 2)))
        (string-append acc (list-ref ev 2))
        acc)))
