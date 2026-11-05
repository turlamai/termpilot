#lang racket/base

;; Serial smoke (macOS/Linux, no hardware): a pty slave stands in for a
;; serial device. open + termios configuration + the write path are
;; exercised for real; the read direction through a pty slave has
;; kernel-queue semantics a second slave-open cannot see (the pty's
;; consumer already drains input), so the read leg validates on real
;; hardware / the Windows leg. This keeps CI deterministic while still
;; proving the FFI configuration path works end to end.

(require racket/format
         racket/list
         racket/port
         racket/string
         rackunit
         racket/system
         "../pty.rkt"
         "../pty/serial.rkt")

(define (child-tty holder)
  (define child
    (string-trim
     (with-output-to-string
       (lambda ()
         (system* (find-executable-path "pgrep")
                  "-P" (~a (pty-handle-pid holder)))))))
  (string-append "/dev/"
                 (string-trim
                  (with-output-to-string
                    (lambda ()
                      (system* (find-executable-path "ps")
                               "-o" "tty=" "-p"
                               (first (string-split child))))))))

(unless (eq? (system-type 'os) 'windows)
  (define a (pty-open* #:command "sh" #:args '("-c" "cat; sleep 8")))
  (define dev (child-tty a))
  (check-true (string-contains? dev "/dev/ttys") "child tty found")

  ;; Open + full termios configuration must succeed on a real tty.
  (define ser (serial-open #:device dev #:baud 115200))
  (check-true (input-port? (pty-handle-reader ser)) "serial reader port")

  ;; Write through the serial handle surfaces on the peer's master.
  ((pty-handle-writer ser) #"PONG\n")
  (define buf (make-bytes 4096))
  (define n (read-bytes-avail! buf (pty-handle-reader a)))
  (check-true (and (number? n) (> n 0)) "serial write reaches the peer")

  ((pty-handle-closer ser))
  ((pty-handle-closer a)))

(displayln "serial-smoke ok")
