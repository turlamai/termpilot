#lang racket/base

;; Windows pseudo-terminal backend via ConPTY (kernel32), the same API the
;; Windows Terminal host uses. The child (OpenSSH ssh.exe, shipped with
;; Windows 10+) is created with EXTENDED_STARTUPINFO_COMPLETE and the
;; PROC_THREAD_ATTRIBUTE_PSEUDO_CONSOLE attribute; the parent feeds the
;; pseudo console through two anonymous pipes and never shares its own
;; stdio with the child.
;;
;; Everything resolves lazily on the first pty-open: the module
;; instantiates on any platform (so raco test compiles it everywhere),
;; but ffi-lib lookup for kernel32 only happens when a terminal actually
;; opens — which, by construction, only happens on Windows.
;;
;; Struct-by-value notes: COORD is a 4-byte struct of two SHORTs, which
;; passes through the Win64 ABI exactly like a 32-bit integer, so the
;; console APIs take a packed coordinate (cols | (rows << 16)).
;; STARTUPINFOEXW and PROCESS_INFORMATION are written/read through raw
;; byte blobs at fixed offsets instead of full struct declarations.
;;
;; First runtime validation belongs to the Windows leg; this module only
;; guarantees compile-everywhere.

(require ffi/unsafe
         racket/string
         "common.rkt")

;; PROC_THREAD_ATTRIBUTE_PSEUDO_CONSOLE, EXTENDED_STARTUPINFO_COMPLETE.
(define attr-pseudoconsole #x00020016)
(define extended-startupinfo-complete #x00080000)
(define infinite #xFFFFFFFF)
;; STARTUPINFOEXW on x64: STARTUPINFOW (96 bytes) + lpAttributeList (8).
(define startupinfoex-size 104)
(define attrib-list-offset 96)
(define process-info-size 32)
(define handle-size (ctype-sizeof _pointer))

;; SIZE_T / DWORD_PTR-sized integers travel as pointer-width integers.
(define _sizet _intptr)

;; Blocking calls (ReadFile on the output pipe, WaitForSingleObject on
;; teardown) must not pin the place's OS thread: declare them with a
;; _cprocedure #:blocking? type so other Racket threads keep running.
(define (blocking-get lib name arg-types result-type)
  (get-ffi-obj name lib
               (_cprocedure arg-types result-type #:blocking? #t)))

(struct conpty (hPC hInWrite hOutRead hProcess hThread)
  #:transparent)

;; The resolved kernel32 bindings, populated once by init!.
(define bindings #f)

(struct bindings-table
  (createPipe closeHandle createPseudoConsole resizePseudoConsole
              closePseudoConsole initAttrList updateAttr createProcess
              terminateProcess waitForObject readFile writeFile))
(define (init!)
  (or bindings
      (let ([k32 (ffi-lib "kernel32")])
        (define simple
          (lambda (name type) (get-ffi-obj name k32 type)))
        (define pipe-type
          (_fun _pointer _pointer _pointer _int32 -> _bool))
        (define coord-type (_fun _sint32 _pointer _pointer _int32
                                 _pointer -> _int32))
        (define resize-type (_fun _pointer _sint32 -> _int32))
        (define attr-type
          (_fun _pointer _int32 _int32 _pointer -> _bool))
        (define update-type
          (_fun _pointer _int32 _intptr _pointer _sizet _pointer _pointer
                -> _bool))
        (define process-type
          (_fun _pointer               ; lpApplicationName (null)
                _string/utf-16         ; lpCommandLine
                _pointer _pointer _bool _int32 _pointer _pointer
                _pointer _pointer
                -> _bool))
        (set! bindings
              (bindings-table
               (simple "CreatePipe" pipe-type)
               (simple "CloseHandle" (_fun _pointer -> _bool))
               (simple "CreatePseudoConsole" coord-type)
               (simple "ResizePseudoConsole" resize-type)
               (simple "ClosePseudoConsole" (_fun _pointer -> _void))
               (simple "InitializeProcThreadAttributeList" attr-type)
               (simple "UpdateProcThreadAttribute" update-type)
               (simple "CreateProcessW" process-type)
               (simple "TerminateProcess" (_fun _pointer _int32 -> _bool))
               (blocking-get k32 "WaitForSingleObject"
                             (list _pointer _int32) _int32)
               (blocking-get k32 "ReadFile"
                             (list _pointer _pointer _int32 _pointer _pointer)
                             _bool)
               (blocking-get k32 "WriteFile"
                             (list _pointer _pointer _int32 _pointer _pointer)
                             _bool))))))

;; --- raw memory helpers ---------------------------------------------------

(define (alloc n) (malloc n 'raw))
(define (alloc-handle) (malloc handle-size 'raw))
(define (blob-handle blob) (ptr-ref blob _pointer 0))

(define (make-dword) (alloc handle-size))
(define (read-dword blob) (ptr-ref blob _int32 0))

;; Create one anonymous pipe; returns two handle blobs.
(define (create-pipe)
  (define r (alloc-handle))
  (define w (alloc-handle))
  (unless ((bindings-table-createPipe bindings) r w #f 0)
    (error 'pty-open "CreatePipe failed"))
  (values r w))

;; Blocking ReadFile into a fresh buffer; #f at pipe close.
(define (pty-read-bytes handle)
  (define buf (alloc 65536))
  (define got (make-dword))
  (ptr-set! got _int32 0 0)
  (define ok ((bindings-table-readFile bindings) handle buf 65536 got #f))
  (define n (read-dword got))
  (if (and ok (> n 0))
      (make-bytes n (lambda (i) (ptr-ref buf _byte i)))
      #f))

(define (pty-write-bytes handle bs)
  (define n (bytes-length bs))
  (define blob (alloc n))
  (for ([b (in-bytes bs)] [i (in-naturals)]) (ptr-set! blob _byte i b))
  (define got (make-dword))
  (unless ((bindings-table-writeFile bindings) handle blob n got #f)
    (error 'terminal/write "WriteFile failed"))
  (void))

(define (coord cols rows)
  (bitwise-ior cols (arithmetic-shift rows 16)))

;; Blocking handle reads wrapped as an input port for the session pump.
(define (handle->reader handle)
  (make-input-port
   'conpty
   (lambda (sink)
     (define bs (pty-read-bytes handle))
     (cond
       [(not bs) eof]
       [else
        (bytes-copy! sink 0 bs 0 (bytes-length bs))
        (bytes-length bs)]))
   #f
   (lambda ()
     ((bindings-table-closeHandle bindings) handle)
     (void))))

;; --- the backend ----------------------------------------------------------

(define (pty-open #:command command
                  #:args args
                  #:cols [cols 80]
                  #:rows [rows 24])
  (init!)
  (define B bindings)
  ;; 1. Pipes: we write hInWrite (the pty reads child input from
  ;;    hInRead); we read hOutRead (the pty writes output to hOutWrite).
  (define-values (hInRead hInWrite) (create-pipe))
  (define-values (hOutRead hOutWrite) (create-pipe))
  ;; 2. The pseudo console itself.
  (define hPC-blob (alloc-handle))
  (define rc ((bindings-table-createPseudoConsole B)
              (coord cols rows) hInRead hOutWrite 0 hPC-blob))
  (unless (zero? rc)
    (error 'pty-open "CreatePseudoConsole failed: ~a" rc))
  ;; 3. Attribute list carrying the pseudo console into CreateProcess.
  (define attr-size-blob (alloc (ctype-sizeof _sizet)))
  (ptr-set! attr-size-blob _sizet 0 0)
  ((bindings-table-initAttrList B) #f 1 0 attr-size-blob) ; size query
  (define attr-size (ptr-ref attr-size-blob _sizet 0))
  (define attr-list (alloc attr-size))
  (unless ((bindings-table-initAttrList B) attr-list 1 0 attr-size-blob)
    (error 'pty-open "InitializeProcThreadAttributeList failed"))
  (define hPC (blob-handle hPC-blob))
  (unless ((bindings-table-updateAttr B) attr-list 0
                                          attr-pseudoconsole
                                          hPC handle-size #f #f)
    (error 'pty-open "UpdateProcThreadAttribute failed"))
  ;; STARTUPINFOEXW blob: cb = its own size, lpAttributeList at offset 96.
  (define si (alloc startupinfoex-size))
  (ptr-set! si _int32 0 startupinfoex-size)
  (ptr-set! si _pointer attrib-list-offset attr-list)
  ;; 4. The sidecar. SearchPath finds ssh.exe on PATH and the well-known
  ;;    System32\OpenSSH location; bInheritHandles must stay FALSE.
  (define cmdline
    (string-join (cons (if (path? command) (path->string command) command)
                       args)
                 " "))
  (define pi-blob (alloc process-info-size))
  ;; CreateProcessW may write into the command line buffer: hand it a
  ;; fresh mutable copy, NUL-terminated by the FFI converter itself.
  (define cmdline-buf (list->string (string->list cmdline)))
  (define ok? ((bindings-table-createProcess B)
               #f cmdline-buf #f #f #f
               extended-startupinfo-complete
               #f #f si pi-blob))
  (unless ok? (error 'pty-open "CreateProcessW failed"))
  ;; 5. Only the pseudo console keeps the pty-side pipe ends now.
  ((bindings-table-closeHandle B) hInRead)
  ((bindings-table-closeHandle B) hOutWrite)
  (define hProcess (ptr-ref pi-blob _pointer 0))
  (define hThread (ptr-ref pi-blob _pointer 1))
  (define pid (ptr-ref pi-blob _int32 16))
  (pty-handle (handle->reader hOutRead)
              (lambda (bs) (pty-write-bytes hInWrite bs))
              (lambda (c r)
                (define rc2 ((bindings-table-resizePseudoConsole B)
                             hPC (coord c r)))
                (unless (zero? rc2)
                  (error 'terminal/resize "ResizePseudoConsole failed")))
              (lambda ()
                ((bindings-table-terminateProcess B) hProcess 0)
                ((bindings-table-closePseudoConsole B) hPC)
                ((bindings-table-waitForObject B) hProcess infinite)
                ((bindings-table-closeHandle B) hProcess)
                ((bindings-table-closeHandle B) hThread)
                ((bindings-table-closeHandle B) hInWrite)
                ((bindings-table-closeHandle B) hOutRead))
              pid
              ;; Exit-code readback (GetExitCodeProcess) is Windows-leg
              ;; polish; EOF already seals the session either way.
              (lambda () 'running)))

(provide pty-open)
