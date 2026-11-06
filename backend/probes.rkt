#lang racket/base

;; Host latency probing: measure TCP handshake time to host:port — no
;; auth, no data, honest "can I reach it and how fast". Probes run in
;; parallel with a per-host timeout; each probe lives in its own
;; custodian so a hung connect is reaped.

(require racket/contract
         racket/format
         racket/string
         racket/tcp)

(provide probe-host)

;; Milliseconds to complete a TCP connect, or #f (unreachable/timeout).
(define (probe-host host port [timeout-ms 3000])
  (unless (string? host) (error 'probe "host must be a string"))
  (define result-box (box #f))
  (define done (make-semaphore))
  (define cust (make-custodian))
  (parameterize ([current-custodian cust])
    (thread
     (lambda ()
       (define start (current-inexact-milliseconds))
       (with-handlers ([exn:fail? (lambda (_) (semaphore-post done))])
         (define-values (in out)
           (tcp-connect host port))
         (close-input-port in)
         (close-output-port out)
         (set-box! result-box
                   (inexact->exact
                    (floor (- (current-inexact-milliseconds) start))))
         (semaphore-post done)))))
  (sync/timeout (/ timeout-ms 1000) done)
  (custodian-shutdown-all cust)
  (unbox result-box))
