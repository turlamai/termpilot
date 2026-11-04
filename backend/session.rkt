#lang racket/base

;; Terminal session manager: one pty + one sidecar child per session,
;; with a bounded scrollback ring for re-attach and a broadcast pump that
;; feeds every streaming subscriber. Session state lives in this process
;; only — nothing about a live session persists.

(require racket/format
         racket/match
         racket/random
         racket/set
         "pty.rkt")

;; Scrollback retained for re-attach (bytes).
(define ring-cap (* 512 1024))

(struct session
  (id              ; opaque session id
   kind            ; 'ssh | 'local
   label           ; display label (host or command)
   pty             ; pty-handle
   command         ; full argv list for diagnostics
   started-at      ; seconds
   ;; mutable below — accessed under the manager semaphore
   ring            ; oldest-first list of byte strings
   ring-size
   subscribers     ; set of output ports (one per stream consumer)
   closed?         ; sealed after child exit
   exit-status)
  #:transparent
  #:mutable)

(struct manager (lock sessions)) ; sessions: mutable hash id -> session

(define (make-manager)
  (manager (make-semaphore 1) (make-hash)))

(define (new-id!)
  (bytes->hex-string (crypto-random-bytes 12)))

(define (bytes->hex-string b)
  (apply string-append
         (for/list ([byte (in-bytes b)])
           (~r byte #:base 16 #:min-width 2 #:pad-string "0"))))

(define (lock! mgr) (semaphore-wait (manager-lock mgr)))
(define (unlock! mgr) (semaphore-post (manager-lock mgr)))

;; ---- ring & subscribers (all under mgr lock) -----------------------------

(define (ring-append! s bs)
  (define lst (append (session-ring s) (list bs)))
  (define total (+ (bytes-length bs) (session-ring-size s)))
  (let loop ([lst lst] [size total])
    (cond
      [(and (> size ring-cap) (pair? (cdr lst)))
       (loop (cdr lst) (- size (bytes-length (car lst))))]
      [else
       (set-session-ring! s lst)
       (set-session-ring-size! s size)])))

(define (ring-bytes s)
  (apply bytes-append (session-ring s)))

(define (drop-subscriber! s port)
  (set-session-subscribers! s (set-remove (session-subscribers s) port)))

(define (broadcast! s bs)
  (for ([port (in-set (session-subscribers s))])
    (with-handlers ([exn:fail? (lambda (_) (drop-subscriber! s port))])
      (write-bytes bs port)
      (flush-output port))))

;; ---- session lifecycle ---------------------------------------------------

;; spec: (hash 'kind "ssh"|"local" 'label string? 'command path-string?
;;             'args (listof string?))
(define (open-session! mgr spec #:cols [cols 80] #:rows [rows 24])
  (define kind
    (match (hash-ref spec 'kind)
      ["ssh" 'ssh]
      [_ 'local]))
  (define handle
    (pty-open* #:command (hash-ref spec 'command)
               #:args (hash-ref spec 'args)
               #:cols cols
               #:rows rows))
  (define s
    (session (new-id!) kind
             (hash-ref spec 'label)
             handle
             (list* (hash-ref spec 'command) (hash-ref spec 'args))
             (current-seconds)
             '() 0 (set) #f #f))
  ;; The pump thread reads child output until EOF (child exit or close),
  ;; appends to the scrollback ring and fans out to every subscriber.
  ;; read-bytes-avail! (not read-bytes): it returns as soon as ANY byte
  ;; arrives — read-bytes would block until the full buffer fills, which
  ;; never happens for a shell prompt's few bytes.
  (define pump-buf (make-bytes 65536))
  (thread
   (lambda ()
     (let loop ()
       (define n
         (with-handlers ([exn:fail? (lambda (_) eof)])
           (read-bytes-avail! pump-buf (pty-handle-reader (session-pty s)))))
       (define bs
         (cond [(eof-object? n) eof]
               [(and (number? n) (> n 0)) (subbytes pump-buf 0 n)]
               [else eof]))
       (cond
         [(eof-object? bs)
          (lock! mgr)
          (set-session-closed?! s #t)
          (set-session-exit-status! s
                                    (pty-poll (session-pty s)))
          (for ([port (in-set (session-subscribers s))])
            (with-handlers ([exn:fail? void])
              (close-output-port port)))
          (set-session-subscribers! s (set))
          (unlock! mgr)]
         [else
          (lock! mgr)
          (ring-append! s bs)
          (broadcast! s bs)
          (unlock! mgr)
          (loop)]))))
  (lock! mgr)
  (hash-set! (manager-sessions mgr) (session-id s) s)
  (unlock! mgr)
  s)

(define (pty-poll pty)
  ((pty-handle-poller pty)))

(define (get-session mgr id)
  (hash-ref (manager-sessions mgr) id #f))

(define (write-session! mgr id bs)
  (define s (get-session mgr id))
  (and s (not (session-closed? s))
       (begin ((pty-handle-writer (session-pty s)) bs) #t)))

(define (resize-session! mgr id cols rows)
  (define s (get-session mgr id))
  (and s (not (session-closed? s))
       (begin ((pty-handle-resizer (session-pty s)) cols rows) #t)))

;; Close: kill the child; the pump thread drains EOF and seals state.
(define (close-session! mgr id)
  (define s (get-session mgr id))
  (when s
    (unless (session-closed? s)
      ((pty-handle-closer (session-pty s))))
    (lock! mgr)
    (hash-remove! (manager-sessions mgr) id)
    (unlock! mgr))
  (and s #t))

;; Attach: returns the session plus replay bytes; `port` joins the live
;; subscriber set so the streaming writer can drain it.
(define (attach-session! mgr id port)
  (define s (get-session mgr id))
  (cond
    [s
     (lock! mgr)
     (define replay (ring-bytes s))
     (unless (session-closed? s)
       (set-session-subscribers!
        s (set-add (session-subscribers s) port)))
     (unlock! mgr)
     (values s replay)]
    [else (values #f #"")]))

(define (list-sessions mgr)
  (for/list ([s (in-hash-values (manager-sessions mgr))])
    (hasheq 'id (session-id s)
            'kind (symbol->string (session-kind s))
            'label (session-label s)
            'startedAt (session-started-at s)
            'closed (session-closed? s)
            'ring-bytes (session-ring-size s))))

(provide (struct-out session)
         (struct-out manager)
         make-manager
         open-session!
         get-session
         write-session!
         resize-session!
         close-session!
         attach-session!
         list-sessions)
