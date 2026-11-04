#lang racket/base

;; E2E PTY smoke: open a pty around a real child, assert output flows,
;; input reaches the child, resize does not throw, close seals the
;; session, and the scrollback replays on attach. Runs only where a pty
;; can exist; the ConPTY path validates on the Windows leg.

(require rackunit
         racket/port
         racket/string
         "../pty.rkt"
         "../session.rkt")

;; Drain the reader into `acc-box` until `needle` shows up or budget
;; expires. Returns the accumulated text.
(define (read-until reader needle acc-box [budget-ms 6000])
  (let loop ([deadline (+ (current-inexact-milliseconds) budget-ms)])
    (define text (bytes->string/utf-8 (unbox acc-box) #\?))
    (cond
      [(string-contains? text needle) text]
      [(> (current-inexact-milliseconds) deadline) text]
      [else
       (define buf (make-bytes 4096))
       (define n (read-bytes-avail! buf reader))
       (cond
         [(eof-object? n) (loop deadline)]
         [(and (number? n) (> n 0))
          (set-box! acc-box
                    (bytes-append (unbox acc-box) (subbytes buf 0 n)))
          (loop deadline)]
         [else
          (sleep 0.05)
          (loop deadline)])])))

(when (not (eq? (system-type 'os) 'windows))

  ;; ---- 1. raw pty: cat echoes what we write ----
  (define h (pty-open* #:command "cat" #:args '() #:cols 100 #:rows 30))
  (check-equal? ((pty-handle-poller h)) 'running)
  ((pty-handle-writer h) #"hello pty\n")
  (define acc (box #""))
  (define text (read-until (pty-handle-reader h) "hello" acc))
  (check-true (string-contains? text "hello") "echo must round-trip")

  ;; ---- 2. resize does not throw ----
  (check-not-exn (lambda () ((pty-handle-resizer h) 120 40)))

  ;; ---- 3. close kills the child ----
  ((pty-handle-closer h))
  (check-not-exn (lambda () ((pty-handle-closer h))) "close is idempotent-ish")

  ;; ---- 4. session manager: scripted child, exit status, replay ----
  (define mgr (make-manager))
  (define s
    (open-session! mgr
                   (hasheq 'kind "local"
                           'label "probe"
                           'command "sh"
                           'args '("-c"
                                   "echo marker-out; sleep 0.3; exit 7"))
                   #:cols 80 #:rows 24))
  (check-true (string? (session-id s)))
  ;; output lands in the ring
  (let loop ([tries 0])
    (when (and (< tries 60) (not (session-closed? s)))
      (sleep 0.1)
      (loop (add1 tries))))
  (check-true (session-closed? s) "child exit must seal the session")
  (check-equal? (session-exit-status s) 7)

  ;; ---- 5. write + resize through the session ----
  (define s2
    (open-session! mgr
                   (hasheq 'kind "local"
                           'label "probe2"
                           'command "cat"
                           'args '())))
  ;; hash key typo guard: spec uses 'command
  (unless (equal? (session-label s2) "probe2")
    (error 'smoke "label mismatch"))
  (check-true (write-session! mgr (session-id s2) #"x\n"))
  (check-true (resize-session! mgr (session-id s2) 100 30))
  ;; The auto-exited s1 lingers by design (an exited tab stays until the
  ;; user closes it); close both explicitly.
  (check-true (close-session! mgr (session-id s)))
  (check-true (close-session! mgr (session-id s2)))
  (check-equal? (length (list-sessions mgr)) 0
                "closed sessions are removed from the manager")

  ;; ---- 6. attach replay: new session, drain output, attach ----
  (define s3
    (open-session! mgr
                   (hasheq 'kind "local"
                           'label "probe3"
                           'command "sh"
                           'args '("-c" "echo replay-marker; sleep 5"))))
  (let loop ([tries 0])
    (when (and (< tries 60)
               (not (string-contains?
                     (bytes->string/utf-8 (apply bytes-append
                                                 (session-ring s3))
                                          #\?)
                     "replay-marker")))
      (sleep 0.1)
      (loop (add1 tries))))
  (define-values (_s3 replay) (attach-session! mgr (session-id s3) (open-output-nowhere)))
  (check-true (string-contains? (bytes->string/utf-8 replay #\?)
                                "replay-marker")
              "replay must contain scrollback")
  (close-session! mgr (session-id s3))
  (check-equal? (length (list-sessions mgr)) 0))

(displayln "pty-smoke ok")
