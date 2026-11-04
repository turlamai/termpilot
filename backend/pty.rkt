#lang racket/base

;; Platform dispatch for pseudo terminals. Only the backend matching the
;; running OS is ever instantiated; the other module compiles everywhere
;; but its ffi-lib resolution is deferred until first use.

(require racket/runtime-path
         "pty/common.rkt")

(define-runtime-path unix-impl "pty/unix.rkt")
(define-runtime-path windows-impl "pty/windows.rkt")

(define impl-path
  (case (system-type 'os)
    [(windows) windows-impl]
    [else unix-impl]))

(define (pty-open* #:command command
                   #:args args
                   #:cols [cols 80]
                   #:rows [rows 24])
  ((dynamic-require impl-path 'pty-open)
   #:command command
   #:args args
   #:cols cols
   #:rows rows))

(provide (struct-out pty-handle)
         pty-open*)
