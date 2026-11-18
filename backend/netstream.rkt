#lang racket/base

;; Raw TCP network stream (plain TCP targets, OpenOCD telnet/RTT console
;; ports): the engine's own tcp-connect feeds the same pty-handle
;; contract the session manager consumes — reader, writer, closer,
;; poller. No child process, no cols/rows.
;;
;; Lifecycle needs no watcher: a peer close surfaces as EOF on the
;; reader (the session pump seals the session exactly like a child
;; exit), and a local close makes the next read raise, which the pump
;; already maps to the same EOF path.
;;
;; Telnet keeps its sidecar binary when installed (IAC negotiation for
;; free); this module is the no-binary fallback and the transport for
;; console ports.

(require racket/tcp
         "pty/common.rkt")

(provide tcp-open-stream)

(define (tcp-open-stream #:host host #:port port)
  (define-values (in out)
    (with-handlers
        ([exn:fail? (lambda (e)
                      (error 'tcp "cannot connect ~a:~a: ~a"
                             host port
                             (if (exn? e) (exn-message e) e)))])
      (tcp-connect host port)))
  (define alive (box #t))
  (pty-handle in
              (lambda (bs) (write-bytes bs out) (flush-output out))
              (lambda (_c _r) (void)) ; no winsize on a wire
              (lambda ()
                (set-box! alive #f)
                (close-input-port in)
                (close-output-port out))
              0
              (lambda () (if (unbox alive) 'running 0))))
