#lang racket/base

;; One-shot subprocess runner with an honest timeout, shared by the
;; CLI and the MCP server (family idiom: exit codes that never lie —
;; a timed-out run reports a timeout, never a borrowed exit code).
;;
;; Deadline enforcement is SIGKILL: a soft kill is unreliable here
;; (bash defers SIGTERM while a foreground child runs, so the child
;; finishes first). Output is pumped incrementally because orphaned
;; grandchildren can hold the pipes open past the child's death —
;; readers get a 2 s grace after the child exits, then whatever
;; arrived is returned.

(require racket/file
         racket/port)

(provide run-command-with-timeout)

;; Incremental pump: survives a thread kill with partial output in
;; the box (read-bytes-avail! + sync — read-bytes would wait for a
;; full buffer, see the family stream lesson).
(define (pump-into! box port)
  (thread
   (lambda ()
     (define acc (open-output-bytes))
     (let loop ()
       (define buf (make-bytes 4096))
       (define n (read-bytes-avail! buf port))
       (cond
         [(eof-object? n)
          (set-box! box (bytes->string/utf-8 (get-output-bytes acc) #\?))]
         [(not n) (sync port) (loop)]
         [else (write-bytes buf acc 0 n) (loop)])))))

;; (run-command-with-timeout argv timeout-secs)
;; -> (values exit-code stdout stderr timed-out?)
;; timeout-secs #f or 0 waits forever.
(define (run-command-with-timeout argv timeout-secs)
  (define timed-out? #f)
  ;; subprocess resolves a bare name against the cwd only — never
  ;; PATH. ssh-argv returns "ssh", so resolve it here once for both
  ;; agent surfaces (a pre-existing latent bug before runproc existed).
  (define cmd
    (or (find-executable-path (car argv)) (car argv)))
  (define-values (proc stdout stdin stderr)
    (apply subprocess #f #f #f cmd (cdr argv)))
  (close-output-port stdin)
  (define watchdog
    (and timeout-secs
         (> timeout-secs 0)
         (thread
          (lambda ()
            (sleep timeout-secs)
            ;; 'running while alive (status is a symbol mid-run, an
            ;; integer once done — never #f)
            (when (eq? (subprocess-status proc) 'running)
              (set! timed-out? #t)
              (subprocess-kill proc #t))))))
  (define out-box (box ""))
  (define err-box (box ""))
  (define out-th (pump-into! out-box stdout))
  (define err-th (pump-into! err-box stderr))
  (subprocess-wait proc)
  (when watchdog (kill-thread watchdog))
  (define got-out? (sync/timeout 2 (thread-dead-evt out-th)))
  (define got-err? (sync/timeout 2 (thread-dead-evt err-th)))
  (unless got-out? (kill-thread out-th))
  (unless got-err? (kill-thread err-th))
  (values (or (subprocess-status proc) 255)
          (unbox out-box)
          (unbox err-box)
          timed-out?))
