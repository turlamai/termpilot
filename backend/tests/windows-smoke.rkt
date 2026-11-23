#lang racket/base

;; Windows-leg runtime smoke: COM enumeration, serial fault
;; classification (negative — no physical COM in a VM), ConPTY io +
;; exit code, and the local-shell cwd passthrough. Other platforms
;; print skip and exit 0 (compile-everywhere, run-on-windows).

(unless (eq? (system-type 'os) 'windows)
  (displayln "skip: windows-only smoke")
  (exit 0))

(require rackunit
         racket/port
         racket/string
         "../serialdev.rkt"
         "../pty.rkt"
         "../pty/serial.rkt")

;; rackunit has no bytes-contains checker; compare as latin-1 strings.
(define (bytes-contains? hay needle)
  (string-contains? (bytes->string/latin-1 hay)
                    (bytes->string/latin-1 needle)))

(define (say what)
  (display what)
  (newline)
  (flush-output))
(define pass
  (let ([n 0])
    (lambda (what)
      (set! n (add1 n))
      (printf "ok ~a · ~a" n what)
      (newline)
      (flush-output))))

;; 1. Enumeration: reg.exe is always present; a VM with no COM ports
;;    lists zero entries — but never errors and never fakes one.
(define ports (list-serial-ports))
(check-pred list? ports)
(for ([p (in-list ports)])
  (check-true (string? (hash-ref p 'path))))
(printf "serial enumeration: ~a port(s)\n" (length ports))
(pass "enumeration returns a list without fake ports")

;; 2. Fault classification: opening a port that is not there must fail
;;    with the not-present keyword (the UI maps it to recovery hints).
(check-exn
 (lambda (e)
   (define msg (exn-message e))
   (and (string-contains? msg "not-present")
        (string-contains? msg "COM99")))
 (lambda () (serial-open #:device "COM99" #:baud 115200)))
(pass "absent COM fails as not-present with the device name")

;; 3. ConPTY io + exit code: cmd echoes, exits 0, the poller reports
;; the real code instead of the old constant 'running.
;; drain collects whatever arrives within the window — a live conhost
;; delivers no EOF until the closer tears the pty down, so waiting for
;; one would time out even though the bytes arrived.
(define (drain h [secs 6])
  (define r (pty-handle-reader h))
  (define out (open-output-bytes))
  (define t (thread (lambda () (copy-port r out) (close-output-port out))))
  (sync/timeout secs t)
  (get-output-bytes out))

(say "step3: opening conpty (echo)")
(define h1
  (pty-open* #:command "cmd.exe"
             #:args '("/c" "echo conpty-ok")
             #:cwd ""
             #:cols 80
             #:rows 24))
(say "step3: pty opened; draining")
(define out1 (drain h1))
(say (format "step3: drained ~a bytes: ~s" (bytes-length out1) out1))
(check-true (bytes-contains? out1 #"conpty-ok") "echo output arrived")
(sleep 0.3)
(define code1 ((pty-handle-poller h1)))
(check-equal? code1 0 "echo exits 0")
((pty-handle-closer h1))
(pass "ConPTY round trip + real exit code")

;; 4. cwd passthrough: `cd` prints the directory CreateProcessW started
;;    the child in — proof for lpCurrentDirectory.
(say "step4: opening conpty (cd)")
(define h2
  (pty-open* #:command "cmd.exe"
             #:args '("/c" "cd")
             #:cwd "C:\\Windows"
             #:cols 80
             #:rows 24))
(say "step4: pty opened; draining")
(define out2 (drain h2))
(say (format "step4: drained: ~s" out2))
(check-true (bytes-contains? out2 #"C:\\Windows")
            "child started in C:\\Windows")
((pty-handle-closer h2))
(pass "cwd rides CreateProcessW lpCurrentDirectory")

(displayln "windows smoke: all green")
