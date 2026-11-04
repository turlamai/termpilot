#lang racket/base

;; The uniform pseudo-terminal contract both platform backends implement.
;; A pty-handle wraps exactly one child process attached to one pty:

;;   reader  — input port delivering the child's terminal output
;;   writer  — (-> bytes? void?) pushing keystrokes into the pty
;;   resizer — (-> exact-positive-integer? exact-positive-integer? void?)
;;   closer  — (-> void?) killing the child and releasing the pty
;;   pid     — child process id, for diagnostics
;;   poller  — (-> (or/c 'running exact-nonnegative-integer?)) exit probe

(struct pty-handle (reader writer resizer closer pid poller)
  #:transparent)

(provide (struct-out pty-handle))
