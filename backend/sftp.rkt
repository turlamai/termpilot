#lang racket/base

;; SFTP transport: batch-mode `sftp` sidecar drives list/download/upload/
;; mkdir/rm operations. Each op spawns one batch run (`sftp -b -` reads
;; commands on stdin) — stateless, deterministic, parse-friendly, and
;; exactly what the transport seam sanctions while an in-process stack
;; is pending. Paths are quoted; output parsing is strict (exit code
;; decides success, so a listing that "looks fine" but failed exits
;; non-zero).

(require racket/contract
         racket/file
         racket/format
         racket/list
         racket/port
         racket/string
         "platform.rkt"
         "store.rkt")

;; ---- helpers -----------------------------------------------------------------

(define (sftp-binary)
  (or (find-executable-path "sftp")
      (error 'sftp "sftp not found (install OpenSSH client tools)")))

(define (sh-quote str)
  (string-append "'" (string-replace str "'" "'\\''") "'"))

;; Run one sftp batch against a host profile; returns (values ok? output).
(define (run-batch profile commands)
  (define sftp (sftp-binary))
  (define host (hash-ref profile 'host))
  (define port (hash-ref profile 'port 22))
  (define user (hash-ref profile 'username ""))
  (define destination
    (if (string=? user "") host (format "~a@~a" user host)))
  (define argv
    (append
     (list "-o" (format "StrictHostKeyChecking=~a"
                        (hash-ref profile 'strict-host-key "accept-new")))
     (list "-o" "BatchMode=yes")
     (list "-o" "ConnectTimeout=12")
     (if (not (= port 22)) (list "-P" (number->string port)) '())
     (if (not (string=? (hash-ref profile 'identity-file "")))
         (list "-i" (hash-ref profile 'identity-file))
         '())
     (if (not (string=? (hash-ref profile 'jump "")))
         (list "-o" (format "ProxyJump=~a" (hash-ref profile 'jump "")))
         '())
     (list "-b" "-" destination)))
  (define-values (proc stdout stdin stderr)
    (apply subprocess #f #f #f sftp argv))
  (display (string-join (map (lambda (c) (string-append c "\n")) commands) "")
           stdin)
  (close-output-port stdin)
  (define out (port->string stdout))
  (define err (port->string stderr))
  (subprocess-wait proc)
  (define st (subprocess-status proc))
  (values (and st (eq? st 'done)) (string-append out err)))

;; ---- profile resolution --------------------------------------------------------

(define (profile-for host-id)
  (define h (or (get-host host-id) (error 'sftp "unknown host ~a" host-id)))
  (hasheq 'host (hash-ref h 'host)
          'port (hash-ref h 'port 22)
          'username (hash-ref h 'username "")
          'identity-file (hash-ref h 'identity-file "")
          'strict-host-key (hash-ref h 'strict-host-key "accept-new")
          'jump (hash-ref h 'jump "")))

;; ---- operations ------------------------------------------------------------------

;; ls -l1 parsing: permissions links owner group size date... name.
;; Directories get a trailing "/" in the name via -F.
(define (parse-ls output)
  (for/list ([line (in-list (string-split output "\n"))]
             #:unless (string=? (string-trim line) "")
             #:unless (string-prefix? (string-trim line) "sftp>")
             #:unless (string-prefix? (string-trim line) "remote")
             #:unless (string-prefix? (string-trim line) "Changing"))
    (define parts (string-split (string-trim line)))
    (when (>= (length parts) 9)
      (define name (string-join (drop parts 8) " "))
      (hasheq 'name name
              'dir (string-suffix? name "/")
              'size (string->number (list-ref parts 4))
              'perms (list-ref parts 0)))))

(define (list-dir host-id path)
  (define-values (ok? out)
    (run-batch (profile-for host-id)
               (list (format "ls -l1F ~a" (sh-quote path)))))
  (unless ok? (error 'sftp/ls "listing failed: ~a" (string-trim out)))
  (filter values (parse-ls out)))

(define (mkdir! host-id path)
  (define-values (ok? out)
    (run-batch (profile-for host-id) (list (format "mkdir ~a" (sh-quote path)))))
  (unless ok? (error 'sftp/mkdir "mkdir failed: ~a" (string-trim out)))
  #t)

(define (remove! host-id path)
  (define-values (ok? out)
    (run-batch (profile-for host-id) (list (format "rm ~a" (sh-quote path)))))
  (unless ok? (error 'sftp/rm "rm failed: ~a" (string-trim out)))
  #t)

(define (remove-dir! host-id path)
  (define-values (ok? out)
    (run-batch (profile-for host-id) (list (format "rmdir ~a" (sh-quote path)))))
  (unless ok? (error 'sftp/rmdir "rmdir failed: ~a" (string-trim out)))
  #t)

;; get/put stream to the app data dir and hand the bytes across the
;; bridge (bounded — the UI warns past 10 MiB).
(define max-transfer-bytes (* 10 1024 1024))

(define (download! host-id remote-path)
  (define tmp (make-temporary-file "tpdl-~a"))
  (define-values (ok? out)
    (run-batch (profile-for host-id)
               (list (format "get ~a ~a" (sh-quote remote-path) (path->string tmp)))))
  (unless ok?
    (when (file-exists? tmp) (delete-file tmp))
    (error 'sftp/get "download failed: ~a" (string-trim out)))
  (define size (file-size tmp))
  (when (> size max-transfer-bytes)
    (delete-file tmp)
    (error 'sftp/get "file exceeds the ~a MiB inline limit"
           (/ max-transfer-bytes 1024 1024)))
  (define data (file->bytes tmp))
  (delete-file tmp)
  data)

(define (upload! host-id remote-path data)
  (when (> (bytes-length data) max-transfer-bytes)
    (error 'sftp/put "exceeds the ~a MiB inline limit"
           (/ max-transfer-bytes 1024 1024)))
  (define tmp (make-temporary-file "tpup-~a"))
  (with-output-to-file tmp (lambda () (write-bytes data)) #:exists 'replace)
  (define-values (ok? out)
    (run-batch (profile-for host-id)
               (list (format "put ~a ~a" (path->string tmp) (sh-quote remote-path)))))
  (delete-file tmp)
  (unless ok? (error 'sftp/put "upload failed: ~a" (string-trim out)))
  #t)

(provide list-dir
         mkdir!
         remove!
         remove-dir!
         download!
         upload!)
