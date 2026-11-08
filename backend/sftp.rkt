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
         racket/path
         racket/port
         racket/string
         racket/system
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

(define (rename! host-id from to)
  (define-values (ok? out)
    (run-batch (profile-for host-id)
               (list (format "rename ~a ~a" (sh-quote from) (sh-quote to)))))
  (unless ok? (error 'sftp/rename "rename failed: ~a" (string-trim out)))
  #t)

;; Directory download: `get -r` lands the tree in a temp dir; we zip it
;; and hand the archive across the bridge (same 50 MiB cap — a source
;; tree compresses well, and the UI names it .zip).
(define max-archive-bytes (* 50 1024 1024))
(define max-transfer-bytes (* 10 1024 1024))

(define (download-dir! host-id remote-path)
  (define tmp (make-temporary-file "tpdir-~a" 'directory))
  (define-values (ok? out)
    (run-batch (profile-for host-id)
               (list (format "get -r ~a ~a"
                             (sh-quote remote-path)
                             (path->string tmp)))))
  (unless ok?
    (delete-directory/files tmp)
    (error 'sftp/get-dir "directory download failed: ~a" (string-trim out)))
  (define inner
    (car (directory-list tmp)))
  (define zip
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (define zip-path (path-replace-extension tmp ".zip"))
      (system* (or (find-executable-path "zip")
                   (error 'sftp/get-dir "zip not found for packaging"))
               "-rq"
               (path->string zip-path)
               ".")
      (if (file-exists? zip-path) zip-path #f)))
  (unless zip
    (delete-directory/files tmp)
    (error 'sftp/get-dir "archiving failed"))
  (define size (file-size zip))
  (when (> size max-archive-bytes)
    (delete-directory/files tmp)
    (delete-file zip)
    (error 'sftp/get-dir "directory exceeds the ~a MiB archive limit"
           (/ max-archive-bytes 1024 1024)))
  (define data (file->bytes zip))
  (delete-directory/files tmp)
  (delete-file zip)
  data)

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

;; ---- recursive directory upload ----------------------------------------------
;; Symmetric to download-dir! but honest about the tree: the UI walks a
;; dropped/picked directory and sends {relative-path, bytes} entries;
;; the backend stages them in a temp tree and transfers the whole tree
;; over ONE batch run (a single sftp connection — `-mkdir` per remote
;; directory with the leading dash so existing dirs don't abort, `put`
;; per file). Per-file ≤10 MiB inline limit, tree ≤50 MiB (parity with
;; the archive cap).

;; A relative path is accepted only when it stays inside the upload
;; root: no leading "/", no "." or ".." segments, no empty segments.
;; Returns the normalized path or #f.
(define (sanitize-rel-path p)
  (and (string? p)
       (not (string=? p ""))
       ;; string-prefix? takes (full-string prefix) — leading "/" rejected
       (not (string-prefix? p "/"))
       (let ([segs (string-split p "/")])
         (and (andmap (lambda (s)
                        (and (not (string=? s "")) (not (string=? s "."))
                             (not (string=? s ".."))))
                      segs)
              (string-join segs "/")))))

;; Every ancestor directory of "a/b/c.txt" — ("a" "a/b") — so mkdir
;; commands can be issued parents-first in one batch.
(define (ancestor-dirs p)
  (define segs (string-split p "/"))
  (if (< (length segs) 2)
      '()
      (for/list ([i (in-range 1 (length segs))])
        (string-join (take segs i) "/"))))

(define (rel->remote remote-dir rel)
  (if (string=? remote-dir ".") rel (format "~a/~a" remote-dir rel)))

(define (upload-dir! host-id remote-dir entries)
  (define profile (profile-for host-id))
  (define clean
    (for/list ([e (in-list entries)])
      (define p (sanitize-rel-path (hash-ref e 'path "")))
      (unless p
        (error 'sftp/put-dir "unsafe path in upload: ~a" (hash-ref e 'path "")))
      (define data (hash-ref e 'data))
      (when (> (bytes-length data) max-transfer-bytes)
        (error 'sftp/put-dir
               "file exceeds the ~a MiB inline limit: ~a"
               (/ max-transfer-bytes 1024 1024) p))
      (cons p data)))
  (define total (for/sum ([e (in-list clean)]) (bytes-length (cdr e))))
  (when (> total max-archive-bytes)
    (error 'sftp/put-dir "tree exceeds the ~a MiB upload limit"
           (/ max-archive-bytes 1024 1024)))
  (define tmp (make-temporary-file "tpdirup-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (for ([e (in-list clean)])
        (define local (build-path tmp (string->path (car e))))
        (make-directory* (path-only local))
        (with-output-to-file local (lambda () (write-bytes (cdr e))) #:exists 'replace))
      (define dirs
        (remove-duplicates
         (append* (for/list ([e (in-list clean)]) (ancestor-dirs (car e))))
         string=?))
      (define cmds
        (append
         (for/list ([d (in-list dirs)])
           (format "-mkdir ~a" (sh-quote (rel->remote remote-dir d))))
         (for/list ([e (in-list clean)])
           (format "put ~a ~a"
                   (sh-quote (path->string (build-path tmp (string->path (car e)))))
                   (sh-quote (rel->remote remote-dir (car e)))))))
      (define-values (ok? out) (run-batch profile cmds))
      (unless ok?
        (error 'sftp/put-dir
               "directory upload failed (some files may have transferred): ~a"
               (string-trim out)))
      (length clean))
    (lambda () (delete-directory/files tmp))))

(provide list-dir
         mkdir!
         rename!
         remove!
         remove-dir!
         download!
         download-dir!
         upload!
         sanitize-rel-path
         ancestor-dirs
         upload-dir!)
