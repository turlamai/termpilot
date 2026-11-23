#lang racket/base

;; Platform dispatch for the serial transport, mirroring pty.rkt: only
;; the backend matching the running OS is ever instantiated. The other
;; module compiles everywhere, but its ffi-lib resolution is deferred
;; until first use — the Unix side's libc bindings and the Windows
;; side's kernel32 comm bindings never load on the wrong platform.

(require racket/runtime-path)

(define-runtime-path unix-impl "serial-unix.rkt")
(define-runtime-path windows-impl "serial-win.rkt")

(define impl-path
  (case (system-type 'os)
    [(windows) windows-impl]
    [else unix-impl]))

(define (serial-open #:device device
                     #:baud [baud 115200]
                     #:databits [databits 8]
                     #:parity [parity "none"]
                     #:stopbits [stopbits 1]
                     #:flow [flow "none"])
  ((dynamic-require impl-path 'serial-open)
   #:device device
   #:baud baud
   #:databits databits
   #:parity parity
   #:stopbits stopbits
   #:flow flow))

(define (serial-control! handle action)
  ((dynamic-require impl-path 'serial-control!) handle action))

(provide serial-open
         serial-control!)
