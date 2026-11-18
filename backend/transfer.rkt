#lang racket/base

;; Device file transfer jobs: SCP, X/Y/ZMODEM (serial targets), TFTP
;; (curl), ADB push/pull. Every job is one real sidecar process built
;; from an argv array — never a concatenated shell string — spawned under
;; the app custodian (the route parameterizes), so transfers outlive the
;; request that started them. The registry answers typed status routes;
;; cancel kills the process and never reports completion; retry re-runs
;; the same config under a new id.
;;
;; SFTP stays on its synchronous routes (the browser drives it directly);
;; everything queued here is the async transfer surface.
;;
;; X/Y/ZMODEM wiring: lrzsz tools speak on stdin/stdout, so the child's
;; stdio IS the serial line — the device opens for the job's duration
;; with the profile's line params, a pipe bridges child stdout to the
;; device writer, and the child reads the device input port directly.
;; A serial session holding the same device would steal bytes — the
;; route layer refuses that combination.
;;
;; Progress bars are a prototype affordance: these tools don't expose
;; byte progress, so the honest states are running / done / failed /
;; cancelled with stderr detail — no fabricated percentages, no fake
;; receipts.

(require racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/port
         racket/random
         racket/string
         "platform.rkt"
         "pty/common.rkt"
         "pty/serial.rkt"
         "store.rkt")

(struct job (id             ; opaque id
             mode           ; scp|tftp|adb|xmodem|ymodem|zmodem
             direction      ; upload|download
             host-id
             target-name    ; display label of the target connection
             remote-path
             name           ; file name (uploads: local name)
             proc           ; live subprocess, #f when sealed
             status         ; running|done|failed|cancelled
             exit           ; exit code when finished
             detail         ; stderr tail (failure evidence)
             started        ; seconds
             tmp-dir        ; staging / received-file directory
             download-file  ; path for finished downloads awaiting fetch
             config)        ; full launch config (retry)
  #:transparent
  #:mutable)

(struct registry (lock jobs))
(define jobs-reg (registry (make-semaphore 1) (make-hash)))
(define (lock!) (semaphore-wait (registry-lock jobs-reg)))
(define (unlock!) (semaphore-post (registry-lock jobs-reg)))

(define (new-id!)
  (bytes->hex-string (crypto-random-bytes 12)))

(define (bytes->hex-string b)
  (apply string-append
         (for/list ([byte (in-bytes b)])
           (~r byte #:base 16 #:min-width 2 #:pad-string "0"))))

(define (transfer-dir)
  (define dir (build-path (ensure-app-data-dir!) "transfers"))
  (unless (directory-exists? dir) (make-directory* dir))
  dir)

;; Bounded history: sealed jobs beyond this count drop (oldest first)
;; along with their staging directories.
(define job-history 40)

(define (cleanup-dir! j)
  (define d (job-tmp-dir j))
  (when (and (path? d) (directory-exists? d))
    (with-handlers ([exn:fail? void])
      (for ([f (in-list (directory-list d))])
        (with-handlers ([exn:fail? void])
          (delete-file (build-path d f))))
      (delete-directory d))))

;; ---- argv builders ----------------------------------------------------------

(define (scp-argv profile direction local-tmp remote-path)
  (define host (hash-ref profile 'host))
  (define port (hash-ref profile 'port 22))
  (define user (hash-ref profile 'username ""))
  (define identity (hash-ref profile 'identity-file ""))
  (define jump (hash-ref profile 'jump ""))
  (define destination
    (format "~a:~a"
            (if (string=? user "") host (format "~a@~a" user host))
            remote-path))
  (define argv
    (append
     (list "-o" "BatchMode=yes") ; unattended: no password prompt path
     (list "-o" (format "StrictHostKeyChecking=~a"
                        (hash-ref profile 'strict-host-key "accept-new")))
     (list "-o" "ConnectTimeout=12")
     (if (not (= port 22)) (list "-P" (number->string port)) '())
     (if (not (string=? identity "")) (list "-i" identity) '())
     (if (not (string=? jump "")) (list "-o" (format "ProxyJump=~a" jump)) '())
     (case direction
       [(upload) (list local-tmp destination)]
       [else (list destination local-tmp)])))
  (values "scp" argv))

(define (adb-argv direction local-tmp remote-path serial)
  (case direction
    [(upload)
     (values "adb" (list "-s" serial "push" local-tmp remote-path))]
    [else
     (values "adb" (list "-s" serial "pull" remote-path local-tmp))]))

(define (tftp-argv direction local-tmp remote-path host)
  (define url (format "tftp://~a/~a" host remote-path))
  (case direction
    [(upload) (values "curl" (list "-sS" "-T" local-tmp url))]
    [else (values "curl" (list "-sS" "-o" local-tmp url))]))

;; lrzsz senders take the staged file; XMODEM/YMODEM receivers get an
;; explicit target name (rx), ZMODEM receivers take the transmitted name
;; and land in the staging dir.
(define (zmodem-argv mode direction local-tmp name)
  (case direction
    [(upload)
     (case mode
       [(xmodem) (values "sx" (list local-tmp))]
       [(ymodem) (values "sb" (list local-tmp))]
       [else (values "sz" (list local-tmp))])]
    [else
     (case mode
       [(xmodem) (values "rx" (list local-tmp))]
       [(ymodem) (values "rb" '())]
       [else (values "rz" '())])]))

;; ---- helpers -----------------------------------------------------------------

(define (tail-stderr port)
  (with-handlers ([exn:fail? (lambda (_) "")])
    (define s (string-trim (port->string port)))
    (if (string=? s "")
        ""
        (let ([lines (string-split s "\n")])
          (string-join (take-right lines (min 6 (length lines))) "\n")))))

;; Control characters (not representable in remote paths / tool args).
(define (has-control-char? s)
  (for/or ([c (in-string s)]) (char<=? c #\u001F)))

;; The staged file name must survive as a local path segment.
(define (safe-name name)
  (define base (or (and (string? name) (not (string=? name "")) name)
                   "transfer.bin"))
  (if (or (regexp-match? #px"[/\\\\]" base)
          (has-control-char? base))
      "transfer.bin"
      base))

;; ---- launch -------------------------------------------------------------------

;; config: mode / direction / host-id / remote-path / name (+ raw bytes
;; for uploads via `data`). Serial line params come from the stored
;; profile. Returns the started job record hash.
(define (start-transfer! config [data #f])
  (define mode (string->symbol (hash-ref config 'mode)))
  (define direction (string->symbol (hash-ref config 'direction)))
  (define host-id (hash-ref config 'host-id ""))
  (define remote-path (hash-ref config 'remote-path "/"))
  (define h (get-host host-id))
  (unless h (error 'transfer/start "unknown target host"))
  (define target-name (hash-ref h 'label))
  (define fname (safe-name (hash-ref config 'name "")))
  (when (and (eq? direction 'upload) (not (bytes? data)))
    (error 'transfer/start "upload needs file bytes"))
  (when (and data (> (bytes-length data) (* 512 1024 1024)))
    (error 'transfer/start "payload exceeds the 512 MiB staging limit"))
  (define tmp-dir (make-temporary-file "tpjob-~a" 'directory (transfer-dir)))
  (define local-tmp (path->string (build-path tmp-dir fname)))
  (when (eq? direction 'upload)
    (display-to-file data local-tmp #:exists 'truncate))
  (define-values (cmd args serial-job?)
    (case mode
      [(scp) (let-values ([(c a) (scp-argv h direction local-tmp remote-path)])
               (values c a #f))]
      [(adb) (let-values ([(c a) (adb-argv direction local-tmp remote-path
                                           (hash-ref h 'host))])
               (values c a #f))]
      [(tftp) (let-values ([(c a) (tftp-argv direction local-tmp remote-path
                                             (hash-ref h 'host))])
                (values c a #f))]
      [(xmodem ymodem zmodem)
       (let-values ([(c a) (zmodem-argv mode direction local-tmp fname)])
         (values c a #t))]
      [else
       (delete-directory tmp-dir)
       (error 'transfer/start "unsupported mode ~a" mode)]))
  ;; Resolve to an absolute path before spawn: subprocess does not
  ;; reliably search PATH for bare command names (macOS exec fails with
  ;; ENOENT even when find-executable-path resolves the binary), so the
  ;; doctor's presence check alone is not enough.
  (define cmd-path (find-executable-path cmd))
  (unless cmd-path
    (delete-directory tmp-dir)
    (error 'transfer/start "~a not found on PATH (see doctor/transports)" cmd))
  (define cmd-absolute (path->string cmd-path))

  (define jid (new-id!))
  (define j
    (job jid mode direction host-id target-name remote-path fname
         #f "running" #f "" (current-seconds) tmp-dir
         (and (eq? direction 'download) local-tmp)
         config))
  (define-values (proc stdout stdin stderr)
    (cond
      [serial-job?
       ;; Child stdio = the serial line. stdin is the device input port
       ;; (fd redirect); stdout rides a pipe a pump thread forwards to
       ;; the device writer; stderr keeps a readable pipe for the
       ;; failure detail.
       (define sh ((dynamic-require "pty/serial.rkt" 'serial-open)
                   #:device (hash-ref h 'host)
                   #:baud (hash-ref h 'port 115200)
                   #:databits (hash-ref h 'data-bits 8)
                   #:parity (hash-ref h 'parity "none")
                   #:stopbits (hash-ref h 'stopbits 1)
                   #:flow (hash-ref h 'flow-control "none")))
       (define dev-in (pty-handle-reader sh))
       (define dev-write (pty-handle-writer sh))
       (define-values (child-out-r child-out-w) (make-pipe))
       (define-values (err-r err-w) (make-pipe))
       (define-values (proc _sout _sin _serr)
         (apply subprocess child-out-w dev-in err-w
                #:set-pwd tmp-dir
                cmd-absolute args))
       (close-output-port child-out-w) ; parent end: child owns its side
       (close-output-port err-w)
       (define buf (make-bytes 16384))
       ;; Pump: child stdout → device, until the child is gone; then the
       ;; device handle releases (the watcher below seals the job).
       (thread
        (lambda ()
          (let loop ()
            (define n
              (with-handlers ([exn:fail? (lambda (_) eof)])
                (read-bytes-avail! buf child-out-r)))
            (cond
              [(eof-object? n)
               (close-input-port child-out-r)
               (with-handlers ([exn:fail? void])
                 ((pty-handle-closer sh)))]
              [(and (number? n) (> n 0))
               (with-handlers ([exn:fail? void])
                 (dev-write (subbytes buf 0 n)))
               (loop)]
              [else (loop)]))))
       (values proc #f #f err-r)]
      [else
       (apply subprocess #f #f #f cmd-absolute args)]))
  (set-job-proc! j proc)
  ;; Watcher: seal the job when the process exits.
  (thread
   (lambda ()
     (subprocess-wait proc)
     (define code
       (let ([st (subprocess-status proc)])
         (if (eq? st 'done) 0 st)))
     (define detail (tail-stderr stderr))
     (lock!)
     (define live (hash-ref (registry-jobs jobs-reg) jid #f))
     (when live
       (set-job-proc! live #f)
       (set-job-exit! live code)
       (set-job-detail! live detail)
       (cond
         [(string=? (job-status live) "cancelled")
          (void)] ; stays cancelled — a kill never reports completion
         [(zero? code)
          (set-job-status! live "done")
          (when (and (member mode '(xmodem ymodem zmodem))
                     (eq? direction 'download))
            ;; rb/rz name received files themselves: take the file the
            ;; tool left in the staging dir (XMODEM rx wrote local-tmp).
            (define got
              (for/first ([f (in-list (directory-list (job-tmp-dir live)))]
                          #:when (not (string-prefix? (path->string f) "."))
                          #:when (file-exists? (build-path (job-tmp-dir live) f)))
                (build-path (job-tmp-dir live) f)))
            (set-job-download-file! live got))]
         [else
          (set-job-status! live "failed")]))
     (unlock!)))
  (lock!)
  (hash-set! (registry-jobs jobs-reg) jid j)
  (prune-jobs!)
  (unlock!)
  (job-view j))

;; Bounded job history.
(define (prune-jobs!)
  (define entries (hash->list (registry-jobs jobs-reg)))
  (when (> (length entries) job-history)
    (define sealed
      (filter (lambda (e) (not (job-proc (cdr e)))) entries))
    (for ([e (in-list (take sealed (- (length entries) job-history)))])
      (hash-remove! (registry-jobs jobs-reg) (car e))
      (cleanup-dir! (cdr e)))))

;; ---- status / result / cancel / retry -----------------------------------------

(define (job-view j)
  (hasheq 'id (job-id j)
          'mode (symbol->string (job-mode j))
          'direction (symbol->string (job-direction j))
          'target (job-target-name j)
          'path (job-remote-path j)
          'name (job-name j)
          'status (job-status j)
          'exit (job-exit j)
          'detail (job-detail j)
          'started (job-started j)))

(define (transfer-status)
  (lock!)
  (define views
    (for/list ([j (in-list (hash-values (registry-jobs jobs-reg)))])
      (job-view j)))
  (unlock!)
  (reverse views))

(define (get-job id)
  (hash-ref (registry-jobs jobs-reg) id #f))

;; Finished download payload; fetching marks the job consumed and drops
;; its staging dir. Uploads never carry a result.
(define (transfer-result id)
  (lock!)
  (define j (get-job id))
  (cond
    [(and j (job-download-file j) (string=? (job-status j) "done"))
     (define f (job-download-file j))
     (unlock!)
     (unless (and f (file-exists? f))
       (error 'transfer/result "downloaded file is gone"))
     (define data (file->bytes f))
     (set-job-download-file! j #f)
     data]
    [j
     (unlock!)
     (error 'transfer/result "job ~a has no result yet" id)]
    [else
     (unlock!)
     (error 'transfer/result "unknown job ~a" id)]))

(define (transfer-cancel! id)
  (lock!)
  (define j (get-job id))
  (cond
    [(and j (job-proc j))
     (define proc (job-proc j))
     (set-job-status! j "cancelled")
     (set-job-proc! j #f)
     (unlock!)
     (with-handlers ([exn:fail? void])
       (subprocess-kill proc #t))
     (hasheq 'id id 'cancelled #t)]
    [j
     (unlock!)
     (hasheq 'id id 'cancelled (string=? (job-status j) "cancelled"))]
    [else
     (unlock!)
     (error 'transfer/cancel "unknown job ~a" id)]))

;; Retry: same config, new id, fresh staging. Upload retries need the
;; bytes again — the route passes them through like a first start.
(define (transfer-retry! id [data #f])
  (lock!)
  (define j (get-job id))
  (unlock!)
  (unless j (error 'transfer/retry "unknown job ~a" id))
  (start-transfer! (job-config j) data))

(provide start-transfer!
         transfer-status
         transfer-result
         transfer-cancel!
         transfer-retry!)
