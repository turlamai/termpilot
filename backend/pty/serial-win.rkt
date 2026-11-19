#lang racket/base

;; Serial transport, Windows side: the Win32 comm API over kernel32 —
;; the same surface every native Windows terminal uses.
;;
;;   open      CreateFileW("\\.\COMn", GENERIC_READ|WRITE, share 0,
;;              OPEN_EXISTING) — share 0 is what makes a second open
;;              fail with ERROR_SHARING_VIOLATION (the busy state).
;;   line      GetCommState → patch DCB (baud/size/parity/stop/flow)
;;              → SetCommState; SetCommTimeouts paces the reader.
;;   io        one full-duplex handle: blocking ReadFile/WriteFile
;;              (declared #:blocking? so the place never pins).
;;   signals   SetCommBreak/ClearCommBreak (BREAK), EscapeCommFunction
;;              (DTR/RTS — levels shadowed locally: GetCommModemStatus
;;              only reports inputs like CTS/DSR, never our outputs).
;;
;; Same contract as serial-unix.rkt: serial-open returns a pty-handle
;; whose reader/writer are the device stream; resize is a no-op and the
;; poller reports 'running (no child process; EOF when the line dies).
;;
;; Bindings resolve lazily on first serial-open (the module instantiates
;; on any platform so raco test compiles it everywhere); GetLastError is
;; classified into the same fault keywords the UI guidance consumes.

(require ffi/unsafe
         racket/format
         racket/string
         "common.rkt")

;; ---- constants ---------------------------------------------------------------

(define generic-read #x80000000)
(define generic-write #x40000000)
(define open-existing 3)
(define invalid-handle -1)
;; COMMTIMEOUTS: block until ≥1 byte or ~1 s, so the pump thread sleeps
;; instead of spinning; writes block until delivered.
(define read-interval-timeout #xFFFFFFFF)
(define read-total-multiplier #xFFFFFFFF)
(define read-total-constant 1000)

;; EscapeCommFunction orders.
(define set-rts 3)
(define clr-rts 4)
(define set-dtr 5)
(define clr-dtr 6)

;; DCB layout on x64 (offsets in bytes):
;;   0 DCBlength(u32)  4 BaudRate(u32)  8 flags bitfield(u32)
;;  12 wReserved(u16)  14 XonLim(u16)  16 XoffLim(u16)
;;  18 ByteSize(u8)   19 Parity(u8)    20 StopBits(u8)
;;  21 XonChar 22 XoffChar 23 ErrorChar 24 EofChar 25 EvtChar 26 wReserved1
(define dcb-size 32)
(define dcb-length 28)
;; flags bitfield (WinBase.h order): fBinary:1 fParity:1 fOutxCtsFlow:1
;; fOutxDsrFlow:1 fDtrControl:2 fDsrSensitivity:1 fTXContinueOnXoff:1
;; fOutX:1 fInX:1 fErrorChar:1 fNull:1 fRtsControl:2 fAbortOnError:1 ...
(define f-outxctsflow #x0004) ; bit 2
(define f-outx        #x0100) ; bit 8
(define f-inx         #x0200) ; bit 9
(define f-dtr-2bits   #x0030) ; bits 4–5
(define f-rts-2bits   #x3000) ; bits 12–13
(define dtr-control-enable 1)
(define rts-control-enable 1)
(define rts-control-handshake 2)

(define commtimeouts-size 20) ; 5 × DWORD

;; ---- lazily resolved bindings -------------------------------------------------

(define bindings #f)

(struct win-bindings
  (createFileW closeHandle getCommState setCommState setCommTimeouts
               escapeCommFunction setCommBreak clearCommBreak cancelIoEx
               readFile writeFile getLastError))

(define (blocking-get lib name arg-types result-type)
  (get-ffi-obj name lib
               (_cprocedure arg-types result-type #:blocking? #t)))

(define (init!)
  (or bindings
      (let* ([k32 (ffi-lib "kernel32")]
             [simple (lambda (name type) (get-ffi-obj name k32 type))])
        ;; NB: set! returns void — return the table itself so callers
        ;; can bind (define B (init!)).
        (set! bindings
              (win-bindings
               (simple "CreateFileW"
                       (_fun _string/utf-16          ; lpFileName
                             _uint32 _uint32          ; access, share
                             _pointer                 ; security attrs
                             _int32                   ; creation disposition
                             _uint32                  ; flags & attributes
                             _pointer                 ; template file
                             -> _intptr))             ; INVALID_HANDLE_VALUE = -1
               (simple "CloseHandle" (_fun _intptr -> _bool))
               (simple "GetCommState" (_fun _intptr _pointer -> _bool))
               (simple "SetCommState" (_fun _intptr _pointer -> _bool))
               (simple "SetCommTimeouts" (_fun _intptr _pointer -> _bool))
               (simple "EscapeCommFunction" (_fun _intptr _int32 -> _bool))
               (simple "SetCommBreak" (_fun _intptr -> _bool))
               (simple "ClearCommBreak" (_fun _intptr -> _bool))
               (simple "CancelIoEx" (_fun _intptr _pointer -> _bool))
               (blocking-get k32 "ReadFile"
                             (list _intptr _pointer _int32 _pointer _pointer)
                             _bool)
               (blocking-get k32 "WriteFile"
                             (list _intptr _pointer _int32 _pointer _pointer)
                             _bool)
               (simple "GetLastError" (_fun -> _int32))))
        bindings)))

;; ---- pure helpers (unit-tested on every platform) -----------------------------

;; "COM3" needs the \\.\ device namespace for ports ≥ COM10 and harmless
;; for the rest; explicit paths pass through untouched.
(define (com-device-path device)
  (cond
    [(or (string-prefix? device "\\\\.\\")
         (string-prefix? device "//./")
         (string-contains? device "\\")
         (string-contains? device "/"))
     device]
    [else (string-append "\\\\.\\" device)]))

;; GetLastError → the contract's fault keywords (same strings the Unix
;; side's errno classifier emits; the UI maps them to recovery hints).
(define (win-open-fault err)
  (cond
    [(memv err (list 2 3)) "not-present"]     ; FILE_NOT_FOUND / PATH_NOT_FOUND
    [(= err 5) "no-access"]                   ; ACCESS_DENIED
    [(= err 32) "device-busy"]                ; SHARING_VIOLATION
    [else "open-failed"]))

(define (parity-code parity)
  (case parity
    [("none") 0] [("even") 2] [("odd") 1] [("mark") 3] [("space") 4]
    [else (error 'serial "unknown parity: ~a" parity)]))

(define (stopbits-code stopbits)
  (cond
    [(= stopbits 2) 2]
    [(= stopbits 1.5) 1]  ; ONE5STOPBITS — expressible here, unlike termios
    [else 0]))            ; ONESTOPBIT

;; ---- signal-control registry ---------------------------------------------------
;; handle -> (hasheq 'h intptr 'flow string 'dtr bool 'rts bool). DTR/RTS
;; levels are shadowed: the Win32 status API only reads input lines.

(define signal-registry (make-weak-hasheq))

(define (serial-control! handle action)
  (define entry (hash-ref signal-registry handle #f))
  (unless entry (error 'serial "not a serial session handle"))
  (define B (init!))
  (define h (hash-ref entry 'h))
  (define flow (hash-ref entry 'flow "none"))
  (case action
    [(break)
     (unless ((win-bindings-setCommBreak B) h)
       (error 'serial "SetCommBreak failed (~a)" ((win-bindings-getLastError B))))
     ;; POSIX tcsendbreak holds 0.25–0.5 s; 150 ms is the conventional
     ;; bootloader window.
     (sleep 0.15)
     (unless ((win-bindings-clearCommBreak B) h)
       (error 'serial "ClearCommBreak failed (~a)" ((win-bindings-getLastError B))))
     'break-pulse]
    [(dtr)
     (define on? (not (hash-ref entry 'dtr)))
     (unless ((win-bindings-escapeCommFunction B)
              h (if on? set-dtr clr-dtr))
       (error 'serial "EscapeCommFunction(DTR) failed"))
     (hash-set! entry 'dtr on?)
     (if on? 'dtr-high 'dtr-low)]
    [(rts)
     (when (string=? flow "rtscts")
       (error 'serial "RTS is owned by hardware flow control"))
     (define on? (not (hash-ref entry 'rts)))
     (unless ((win-bindings-escapeCommFunction B)
              h (if on? set-rts clr-rts))
       (error 'serial "EscapeCommFunction(RTS) failed"))
     (hash-set! entry 'rts on?)
     (if on? 'rts-high 'rts-low)]
    [else (error 'serial "unknown signal action: ~a" action)]))

;; ---- open ------------------------------------------------------------------

(define (serial-open #:device device
                     #:baud [baud 115200]
                     #:databits [databits 8]
                     #:parity [parity "none"]
                     #:stopbits [stopbits 1]
                     #:flow [flow "none"])
  (define B (init!))
  (define h ((win-bindings-createFileW B)
             (com-device-path device)
             (bitwise-ior generic-read generic-write)
             0 #f open-existing 0 #f))
  (when (= h invalid-handle)
    (define err ((win-bindings-getLastError B)))
    (error 'serial "~a: ~a (GetLastError ~a)"
           device (win-open-fault err) err))
  ;; Line configuration: start from the driver's DCB, patch what the
  ;; profile owns, keep the rest (XonLim etc.).
  (define dcb (malloc dcb-size 'raw))
  (memset dcb 0 dcb-size)
  (ptr-set! dcb _uint32 0 dcb-length)
  (unless ((win-bindings-getCommState B) h dcb)
    ((win-bindings-closeHandle B) h)
    (error 'serial "~a is not a configurable serial device (GetCommState failed)" device))
  (define flags (ptr-ref dcb _uint32 2))
  (define flags*
    (bitwise-ior
     (bitwise-and flags (bitwise-not (bitwise-ior f-outxctsflow f-outx f-inx
                                                  f-dtr-2bits f-rts-2bits)))
     (arithmetic-shift dtr-control-enable 4)
     (case flow
       [("rtscts") (bitwise-ior f-outxctsflow
                                (arithmetic-shift rts-control-handshake 12))]
       [("xonxoff") (bitwise-ior f-outx f-inx
                                 (arithmetic-shift rts-control-enable 12))]
       [else (arithmetic-shift rts-control-enable 12)])))
  (ptr-set! dcb _uint32 1 baud)
  (ptr-set! dcb _uint32 2 flags*)
  (ptr-set! dcb _byte 18 databits)
  (ptr-set! dcb _byte 19 (parity-code parity))
  (ptr-set! dcb _byte 20 (stopbits-code stopbits))
  (unless ((win-bindings-setCommState B) h dcb)
    (define err ((win-bindings-getLastError B)))
    ((win-bindings-closeHandle B) h)
    (error 'serial "SetCommState failed on ~a (~a)" device err))
  (define timeouts (malloc commtimeouts-size 'raw))
  (ptr-set! timeouts _uint32 0 read-interval-timeout)
  (ptr-set! timeouts _uint32 1 read-total-multiplier)
  (ptr-set! timeouts _uint32 2 read-total-constant)
  (ptr-set! timeouts _uint32 3 0)
  (ptr-set! timeouts _uint32 4 0)
  (unless ((win-bindings-setCommTimeouts B) h timeouts)
    ((win-bindings-closeHandle B) h)
    (error 'serial "SetCommTimeouts failed on ~a" device))

  ;; Reader: blocking ReadFile in a retry loop. Timeouts surface as
  ;; FALSE + ERROR_TIMEOUT / ERROR_OPERATION_ABORTED → keep waiting. The
  ;; closer flips the flag and cancels pending IO first, so a blocked
  ;; read returns instead of touching a closed handle.
  (define closed? (box #f))
  (define (read-once)
    (define buf (malloc 65536 'raw))
    (define got (malloc 4 'raw))
    (ptr-set! got _int32 0 0)
    (define ok ((win-bindings-readFile B) h buf 65536 got #f))
    (define n (ptr-ref got _int32 0))
    (cond
      [(unbox closed?) #f]
      [(and ok (> n 0))
       (make-bytes n (lambda (i) (ptr-ref buf _byte i)))]
      [else
       (define err ((win-bindings-getLastError B)))
       (if (memv err (list 1460 995)) ; timeout / cancelled-but-open
           (read-once)
           #f)]))
  (define reader
    (make-input-port
     'serial-win
     (lambda (sink)
       (define bs (read-once))
       (cond
         [(not bs) eof]
         [else (bytes-copy! sink 0 bs 0 (bytes-length bs)) (bytes-length bs)]))
     #f
     (lambda () (void)))) ; teardown rides the pty-handle closer

  (define (writer bs)
    (define n (bytes-length bs))
    (define buf (malloc n 'raw))
    (for ([b (in-bytes bs)] [i (in-naturals)]) (ptr-set! buf _byte i b))
    (define got (malloc 4 'raw))
    (unless ((win-bindings-writeFile B) h buf n got #f)
      (error 'terminal/write "WriteFile on serial failed")))

  (define entry (hasheq 'h h 'flow flow 'dtr #t 'rts #t))
  ;; Self-referential like the Unix side: the closer closes over the
  ;; variable `handle`, bound by the time it ever runs.
  (define handle
    (pty-handle reader
                writer
                (lambda (_c _r) (void))  ; no winsize on a wire
                (lambda ()
                  (set-box! closed? #t)
                  ((win-bindings-cancelIoEx B) h #f)
                  ((win-bindings-closeHandle B) h)
                  (hash-remove! signal-registry handle))
                0
                (lambda () 'running)))
  (hash-set! signal-registry handle entry)
  handle)

(provide serial-open
         serial-control!
         com-device-path
         win-open-fault)
