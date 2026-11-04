#lang racket/base

;; Unix pseudo-terminal backend (macOS + Linux) via the script(1) forkpty
;; bridge — zero FFI, fully scheduler-integrated.
;;
;; Why not posix_openpt + raw fds: a raw pty master fd has no
;; Racket-integrated port; wrapping it (custom port + blocking FFI read)
;; freezes the entire place — one blocked call stops every thread. The
;; bridge sidesteps the problem completely: script(1) allocates the pty
;; with forkpty(3) (child = session leader, controlling tty, proper
;; SIGWINCH delivery), relays bytes over plain pipes, and subprocess(1)
;; gives us real integrated ports for both directions.
;;
;; The child runs as the pty's foreground process group, so a resize is
;; `stty -f <slave> rows R cols C` — the kernel updates the line
;; discipline's winsize and delivers SIGWINCH straight to ssh.
;;
;; script(1) arg shapes:
;;   macOS (BSD):   script -q -t 0 /dev/null CMD ARG...
;;   Linux (util):  script -q -F /dev/null CMD ARG...
;; Both keep the child's argv intact (no shell re-parsing) on these
;; modern versions; util-linux's -c form is avoided for exactly that
;; reason.

(require racket/format
         racket/port
         racket/string
         racket/system
         "common.rkt")

(struct script-proc (proc stdin stdout) #:transparent)

(define (script-argv command args)
  (case (system-type 'os)
    [(macosx)
     (list* "/usr/bin/script" "-q" "-t" "0" "/dev/null"
            command args)]
    [else
     (list* "/usr/bin/script" "-q" "-F" "/dev/null"
            command args)]))

;; Spawn `command args` inside a fresh pty owned by script(1); returns a
;; pty-handle whose ports are Racket-integrated pipes.
(define (pty-open #:command command
                  #:args args
                  #:cols [cols 80] ; accepted for contract parity; the
                  #:rows [rows 24]) ; real size arrives via terminal/resize
  (define command-str
    (if (string? command) command (path->string command)))
  (define resolved
    (or (and (complete-path? command-str) command-str)
        (let ([found (find-executable-path command-str)])
          (and found (path->string found)))
        (error 'pty-open "executable not found: ~a" command)))
  (define argv (script-argv resolved args))
  (define-values (proc stdout stdin stderr)
    (apply subprocess #f #f #f (car argv) (cdr argv)))
  ;; The initial size: stty on the slave as soon as we can find it.
  ;; script(1) creates the pty at its own inherited size; the frontend
  ;; sends its real size immediately after open, so an initial
  ;; best-effort resize lands within the first moment.
  (define handle
    (pty-handle stdout
                (lambda (bs)
                  (write-bytes bs stdin)
                  (flush-output stdin))
                (lambda (c r) (resize-via-stty! proc c r))
                (lambda ()
                  (subprocess-kill proc #t)
                  (close-output-port stdin)
                  (close-input-port stdout))
                (subprocess-pid proc)
                (lambda ()
                  (define st (subprocess-status proc))
                  (cond
                    [(not st) 'running]
                    [(eq? st 'done) 0]
                    [else st]))))
  ;; No eager initial resize: the frontend sends terminal/resize with
  ;; its real size right after open.
  handle)

;; The pty slave path is whatever tty the script child sits on.
(define (child-tty-path proc)
  (define pid (subprocess-pid proc))
  (define out
    (with-output-to-string
      (lambda ()
        (with-handlers ([exn:fail? void])
          (system* "ps" "-o" "tty=" "-p" (~a pid))))))
  (define tty (string-trim out))
  (and (not (string=? tty ""))
       (not (string=? tty "??"))
       (string-append "/dev/" tty)))

(define (resize-via-stty! proc cols rows)
  (define tty (child-tty-path proc))
  (when tty
    ;; macOS stty takes -f; util-linux stty takes -F.
    (define flag
      (case (system-type 'os)
        [(macosx) "-f"]
        [else "-F"]))
    (system* "stty" flag tty
                     "rows" (~a rows) "cols" (~a cols))))

(provide pty-open)
