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
(define infinite -1) ; INFINITE, as the _int32 call wants it
;; STARTUPINFOEXW on x64: STARTUPINFOW is 104 bytes there (cb@0,
;; lpReserved@8 … dwFlags@60, wShowWindow@64, cbReserved2@66, pad,
;; lpReserved2@72, hStdInput@80, hStdOutput@88, hStdError@96 → size
;; 104), so lpAttributeList sits at offset 104 and the ex struct is
;; 112 bytes. Writing the list pointer at 96 (an x86 layout) left
;; CreateProcessW reading garbage → GetLastError 87.
(define startupinfoex-size 112)
(define attrib-list-offset 104)
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
              terminateProcess waitForObject readFile writeFile
              getExitCode getLastError cancelIoEx peekNamedPipe
              setHandleInfo))

;; NULL-able UTF-16 string: #f / "" → NULL pointer (the FFI make-ctype
;; convention — returning #f from the to-c function means NULL).
(define _wstring/nullable
  (make-ctype _string/utf-16
              (lambda (v) (and v (if (string=? v "") #f v)))
              values))
(define (init!)
  (or bindings
      (let ([k32 (ffi-lib "kernel32")])
        (define simple
          (lambda (name type) (get-ffi-obj name k32 type)))
        ;; HANDLEs travel as pointer-width integers end to end — one
        ;; representation, no cpointer/int mixing.
        (define pipe-type
          (_fun _pointer _pointer _pointer _int32 -> _bool))
        (define coord-type (_fun _sint32 _intptr _intptr _int32
                                 _pointer -> _int32))
        (define resize-type (_fun _intptr _sint32 -> _int32))
        (define attr-type
          (_fun _pointer _int32 _int32 _pointer -> _bool))
        (define update-type
          (_fun _pointer _int32 _intptr _intptr _sizet _pointer _pointer
                -> _bool))
        (define process-type
          (_fun _pointer               ; lpApplicationName (null)
                _string/utf-16         ; lpCommandLine
                _pointer _pointer _bool _int32 _pointer
                _wstring/nullable      ; lpCurrentDirectory (cwd)
                _pointer _pointer
                -> _bool))
        (set! bindings
              (bindings-table
               (simple "CreatePipe" pipe-type)
               (simple "CloseHandle" (_fun _intptr -> _bool))
               (simple "CreatePseudoConsole" coord-type)
               (simple "ResizePseudoConsole" resize-type)
               (simple "ClosePseudoConsole" (_fun _intptr -> _void))
               (simple "InitializeProcThreadAttributeList" attr-type)
               (simple "UpdateProcThreadAttribute" update-type)
               (simple "CreateProcessW" process-type)
               (simple "TerminateProcess" (_fun _intptr _int32 -> _bool))
               (blocking-get k32 "WaitForSingleObject"
                             (list _intptr _int32) _int32)
               (blocking-get k32 "ReadFile"
                             (list _intptr _pointer _int32 _pointer _pointer)
                             _bool)
               (blocking-get k32 "WriteFile"
                             (list _intptr _pointer _int32 _pointer _pointer)
                             _bool)
               (simple "GetExitCodeProcess" (_fun _intptr _pointer -> _bool))
               (simple "GetLastError" (_fun -> _int32))
               (simple "CancelIoEx" (_fun _intptr _pointer -> _bool))
               (simple "PeekNamedPipe"
                       (_fun _intptr _pointer _int32 _pointer _pointer
                             _pointer -> _bool))
               (simple "SetHandleInformation"
                       (_fun _intptr _int32 _int32 -> _bool)))))))

;; Read GetLastError immediately after the failing call. (Racket-level
;; allocations between the call and the read can reset the thread's
;; last-error value, so this is best-effort diagnostics.)
(define (saved-last-error B)
  ((bindings-table-getLastError B)))

;; --- raw memory helpers ---------------------------------------------------

(define (alloc n) (malloc n 'raw))
(define (alloc-handle) (malloc handle-size 'raw))

(define (make-dword) (alloc handle-size))
(define (read-dword blob) (ptr-ref blob _int32 0))

;; Create one anonymous pipe; returns the two HANDLE values. Every
;; consumer below (CreatePseudoConsole, ReadFile/WriteFile, CloseHandle)
;; takes handles by value — handing them the address of the handle
;; variable was the 0x80070006 (ERROR_INVALID_HANDLE) failure.
;; Inheritance is enabled afterwards with SetHandleInformation: the
;; ConPTY machinery (conhost) adopts the ends during CreateProcessW —
;; without the inherit flag the child falls back to the parent console
;; and the pty pipes stay empty.
(define handle-flag-inherit #x00000001)
(define (create-pipe)
  (define r (alloc-handle))
  (define w (alloc-handle))
  (unless ((bindings-table-createPipe bindings) r w #f 0)
    (error 'pty-open "CreatePipe failed (GetLastError ~a)"
           (saved-last-error bindings)))
  (values (ptr-ref r _int64 0) (ptr-ref w _int64 0)))

(define (mark-inheritable! h)
  (unless ((bindings-table-setHandleInfo bindings)
           h handle-flag-inherit handle-flag-inherit)
    (error 'pty-open "SetHandleInformation failed")))

;; Peek-poll reader. A blocking ReadFile on an empty anonymous pipe
;; never returns, and Racket's GC then deadlocks stop-the-world on the
;; parked thread — the whole place freezes. PeekNamedPipe bounds every
;; call; once data is confirmed, ReadFile returns immediately. FALSE
;; from the peek means the pipe broke: EOF.
(define (pty-read-bytes handle)
  (define B bindings)
  (define avail (make-dword))
  (let poll ()
    (cond
      [(not ((bindings-table-peekNamedPipe B) handle #f 0 #f avail #f))
       #f]
      [(> (read-dword avail) 0)
       (define buf (alloc 65536))
       (define got (make-dword))
       (ptr-set! got _int32 0 0)
       (define ok ((bindings-table-readFile B) handle buf 65536 got #f))
       (define n (read-dword got))
       (if (and ok (> n 0))
           (make-bytes n (lambda (i) (ptr-ref buf _byte i)))
           #f)]
      [else (sleep 0.05) (poll)])))

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
   (lambda () (void)))) ; teardown rides the pty-handle closer

;; --- the backend ----------------------------------------------------------

(define (pty-open #:command command
                  #:args args
                  #:cwd [cwd ""] ; lpCurrentDirectory for the sidecar
                  #:cols [cols 80]
                  #:rows [rows 24])
  (init!)
  (define B bindings)
  ;; 1. Pipes: we write hInWrite (the pty reads child input from
  ;;    hInRead); we read hOutRead (the pty writes output to hOutWrite).
  (define-values (hInRead hInWrite) (create-pipe))
  (define-values (hOutRead hOutWrite) (create-pipe))
  (for ([h (in-list (list hInRead hInWrite hOutRead hOutWrite))])
    (mark-inheritable! h))
  ;; 2. The pseudo console itself.
  (define hPC-blob (alloc-handle))
  (define rc ((bindings-table-createPseudoConsole B)
              (coord cols rows) hInRead hOutWrite 0 hPC-blob))
  (unless (zero? rc)
    (error 'pty-open "CreatePseudoConsole failed: ~a" rc))
  (define hPC (ptr-ref hPC-blob _int64 0))
  ;; 3. Attribute list carrying the pseudo console into CreateProcess.
  (define attr-size-blob (alloc (ctype-sizeof _sizet)))
  (ptr-set! attr-size-blob _sizet 0 0)
  ((bindings-table-initAttrList B) #f 1 0 attr-size-blob) ; size query
  (define attr-size (ptr-ref attr-size-blob _sizet 0))
  (define attr-list (alloc attr-size))
  (memset attr-list 0 attr-size)
  (unless ((bindings-table-initAttrList B) attr-list 1 0 attr-size-blob)
    (error 'pty-open "InitializeProcThreadAttributeList failed"))
  (unless ((bindings-table-updateAttr B) attr-list 0
                                          attr-pseudoconsole
                                          hPC handle-size #f #f)
    (error 'pty-open "UpdateProcThreadAttribute failed"))
  ;; STARTUPINFOEXW blob: zeroed (CreateProcessW reads lpDesktop/lpTitle
  ;; from it — garbage there is undefined behavior), cb = its own size,
  ;; lpAttributeList at offset 104 on x64.
  (define si (alloc startupinfoex-size))
  (memset si 0 startupinfoex-size)
  (ptr-set! si _int32 0 startupinfoex-size)
  (ptr-set! si _pointer attrib-list-offset attr-list)
  ;; 4. The sidecar. SearchPath finds ssh.exe on PATH and the well-known
  ;;    System32\OpenSSH location; bInheritHandles must stay FALSE.
  (define cmdline
    (string-join (cons (if (path? command) (path->string command) command)
                       args)
                 " "))
  (define pi-blob (alloc process-info-size))
  (memset pi-blob 0 process-info-size)
  ;; CreateProcessW may write into the command line buffer: hand it a
  ;; fresh mutable copy, NUL-terminated by the FFI converter itself.
  (define cmdline-buf (list->string (string->list cmdline)))
  (define ok? ((bindings-table-createProcess B)
               #f cmdline-buf #f #f #f
               extended-startupinfo-complete
               #f cwd si pi-blob))
  (unless ok?
    (error 'pty-open "CreateProcessW failed (GetLastError ~a)"
           (saved-last-error B)))
  ;; 5. Only the pseudo console keeps the pty-side pipe ends now.
  ((bindings-table-closeHandle B) hInRead)
  ((bindings-table-closeHandle B) hOutWrite)
  (define hProcess (ptr-ref pi-blob _int64 0))
  (define hThread (ptr-ref pi-blob _int64 1))
  (define pid (ptr-ref pi-blob _int32 16))
  (pty-handle (handle->reader hOutRead)
              (lambda (bs) (pty-write-bytes hInWrite bs))
              (lambda (c r)
                (define rc2 ((bindings-table-resizePseudoConsole B)
                             hPC (coord c r)))
                (unless (zero? rc2)
                  (error 'terminal/resize "ResizePseudoConsole failed")))
              (lambda ()
                ;; Order matters: the session pump is parked in a
                ;; blocking ReadFile on hOutRead; cancelling pending IO
                ;; on it FIRST makes that call return, THEN it is safe
                ;; to close. CloseHandle with a read in flight is
                ;; undefined and wedges the reader for good.
                ((bindings-table-cancelIoEx B) hOutRead #f)
                ((bindings-table-terminateProcess B) hProcess 0)
                ((bindings-table-closePseudoConsole B) hPC)
                ((bindings-table-waitForObject B) hProcess infinite)
                ((bindings-table-closeHandle B) hProcess)
                ((bindings-table-closeHandle B) hThread)
                ((bindings-table-closeHandle B) hInWrite)
                ((bindings-table-closeHandle B) hOutRead))
              pid
              ;; Exit-code readback: STILL_ACTIVE (259) means running;
              ;; any other value is the child's real exit code.
              (lambda ()
                (define code-blob (alloc 4))
                (ptr-set! code-blob _uint32 0 #xFFFFFFFF)
                (if ((bindings-table-getExitCode B) hProcess code-blob)
                    (let ([code (ptr-ref code-blob _uint32 0)])
                      (if (= code 259) 'running code))
                    'running))))

(provide pty-open)
