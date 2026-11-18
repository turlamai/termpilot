#lang racket/base

;; Serial device enumeration. Read-only directory probes — no device is
;; opened, so listing never perturbs modem-control state.
;;
;; macOS: cu.* callout devices are the ones terminals use (tty.* entries
;; wait for carrier on open); the short-node name rides the label.
;; Linux: ttyUSB*/ttyACM* first, then hardware aliases under
;; /dev/serial/by-id (descriptive, stable), then legacy ttyS*.
;; Windows: COM enumeration needs the Win32 registry and is validated on
;; the Windows leg (same policy as ConPTY) — an empty list plus a note,
;; never a fake port.

(require racket/list
         racket/match
         racket/runtime-path
         racket/string
         "platform.rkt")

(provide list-serial-ports)

(define (entry->port path [label #f])
  (hasheq 'path path
          'label (or label path)))

(define (by-alias dir prefix)
  ;; /dev/serial/by-id entries are symlinks to ../ttyUSBn etc.; the
  ;; symlink names carry vendor/product strings — the useful label.
  (define d dir)
  (if (directory-exists? d)
      (for/list ([p (in-list (directory-list d #:link? #t))])
        (define full (build-path d p))
        (define target
          (with-handlers ([exn:fail? (lambda (_) #f)])
            (resolve-path full)))
        (entry->port (path->string full)
                     (format "~a → ~a" (path->string p)
                             (if target (path->string target) "?"))))
      '()))

(define (list-serial-ports)
  (case (system-type 'os)
    [(macosx)
     (define dev (string->path "/dev"))
     (unless (directory-exists? dev) '())
     ;; cu.* only: opening tty.* on macOS blocks on carrier wait.
     (sort
      (for/list ([p (in-list (directory-list dev))]
                 #:when (string-prefix? (path->string p) "cu."))
        (define name (path->string p))
        (entry->port (string-append "/dev/" name)
                     (string-append "Apple · " name)))
      string<?
      #:key (lambda (e) (hash-ref e 'path)))]
    [(windows)
     ;; Validated on the Windows leg; the UI surfaces the note.
     (list (hasheq 'path ""
                   'label "windows-leg"))]
    [else
     ;; Linux
     (define dev (string->path "/dev"))
     (define aliases (by-alias (string->path "/dev/serial/by-id") "usb"))
     (define kernel
       (if (directory-exists? dev)
           (for/list ([p (in-list (directory-list dev))]
                      #:when (regexp-match? #px"^(ttyUSB|ttyACM|ttyO|ttyS)[0-9]+$"
                                            (path->string p)))
             (define name (path->string p))
             (entry->port (string-append "/dev/" name)
                          (string-append "Linux · " name)))
           '()))
     ;; Aliases first (they identify boards); dedupe by resolved path.
     (append aliases kernel)]))
