#lang racket/base

;; Serial transport (macOS + Linux): open the device file, configure the
;; line once via termios (baud/parity/stop/data bits + raw mode + CLOCAL),
;; then read and write plain file ports — the same scheduler-integrated
;; ports the script bridge relies on. A one-shot tcsetattr does not block,
;; so no FFI scheduling problems arise here.
;;
;; Device + line parameters come from the connection profile (device path
;; in `host`, baud in `port`?? — no: baud rides `baud`, data bits/parity/
;; stop bits/flow ride dedicated fields; see serial-profile below).
;;
;; Windows: COM-port access needs the Win32 comm API and is validated on
;; the Windows leg (same policy as ConPTY); serial-open raises a clear
;; error elsewhere.

(require ffi/unsafe
         ffi/unsafe/define
         racket/file
         racket/format
         racket/string
         "common.rkt")

(define libc (ffi-lib "libc" '("6" "")))
(define-ffi-definer define-libc libc)

;; struct termios differs: macOS uses 4×unsigned-long flags (cflag at
;; offset 8), glibc packs 4×u32 (cflag at offset 4). Blob layout:
(define termios-size 128)
(define cflag-offset
  (case (system-type 'os)
    [(macosx) 8]
    [else 4]))
(define ispeed-offset
  (case (system-type 'os)
    [(macosx) 56]  ; after 4×8 flags + c_cc[20]
    [else 52]))    ; 4×4 flags + c_line + c_cc[32]

(define-libc c-open (_fun _string _int -> _int) #:c-id open)
(define-libc c-close (_fun _int -> _int) #:c-id close)
(define-libc c-tcgetattr (_fun _int _pointer -> _int) #:c-id tcgetattr)
(define-libc c-cfmakeraw (_fun _pointer -> _void) #:c-id cfmakeraw)
(define-libc c-tcsetattr (_fun _int _int _pointer -> _int) #:c-id tcsetattr)
(define-libc c-cfsetispeed (_fun _pointer _uint -> _int) #:c-id cfsetispeed)
(define-libc c-cfsetospeed (_fun _pointer _uint -> _int) #:c-id cfsetospeed)

(define tcsanow 0)
(define o-rdwr 2)

;; Input/output speed constants. macOS uses literal baud values; Linux
;; uses the classic codes. Values outside the table are refused with the
;; supported list — guessing a code writes garbage to the line.
(define (speed-code baud)
  (case (system-type 'os)
    [(macosx)
     (if (member baud '(1200 2400 4800 9600 19200 38400 57600 115200 230400))
         baud
         (error 'serial "unsupported baud on macOS (use 1200/2400/4800/9600/19200/38400/57600/115200/230400): ~a" baud))]
    [else
     (case baud
       [(1200) 9] [(2400) 11] [(4800) 12] [(9600) 13]
       [(19200) 14] [(38400) 15] [(57600) 16] [(115200) 17] [(230400) 18]
       [else (error 'serial "unsupported baud on Linux (1200/2400/4800/9600/19200/38400/57600/115200/230400): ~a" baud)])]))

;; c_cflag bits: platform tables (data bits 8/7, stop 2, parity).
(define (cflag-bits databits parity stopbits)
  (define-values (cs7 cs8 cstopb parenb parodd clocal cread)
    (case (system-type 'os)
      [(macosx) (values #x200 #x300 #x400 #x1000 #x2000 #x8000 #x800)]
      [else (values #o20 #o30 #o100 #o400 #o1000 #o4000 #o200)]))
  (define size (case databits [(7) cs7] [(8) cs8]
                 [else (error 'serial "data bits must be 7 or 8: ~a" databits)]))
  (+ size
     (if (= stopbits 2) cstopb 0)
     (if (not (string=? parity "none")) parenb 0)
     (if (string=? parity "odd") parodd 0)
     clocal
     cread))

;; Open + configure; returns a pty-handle (no real pty: the ports are the
;; device file, resize is a no-op, poller reports running — serial has no
;; child process to exit; EOF arrives when the device disappears).
(define (serial-open #:device device
                     #:baud [baud 115200]
                     #:databits [databits 8]
                     #:parity [parity "none"]
                     #:stopbits [stopbits 1])
  (define fd (c-open device o-rdwr))
  (when (< fd 0) (error 'serial "cannot open device ~a (errno ~a)" device fd))
  (define termios (malloc termios-size 'raw))
  (define g (c-tcgetattr fd termios))
  (when (< g 0)
    (error 'serial "~a is not a configurable tty/serial device" device))
  (c-cfmakeraw termios)
  ;; Patch c_cflag in place: keep everything else the platform set.
  (ptr-set! termios _uint cflag-offset
            (cflag-bits databits parity stopbits))
  (define speed (speed-code baud))
  (c-cfsetispeed termios speed)
  (c-cfsetospeed termios speed)
  (define r (c-tcsetattr fd tcsanow termios))
  (when (< r 0)
    (error 'serial "tcsetattr failed on ~a (errno ~a)" device r))
  (define in (open-input-file device))
  (define out (open-output-file device #:exists 'append))
  ;; Keep the original fd open for the lifetime (close only via closer).
  (pty-handle in
              (lambda (bs) (write-bytes bs out) (flush-output out))
              (lambda (_c _r) (void)) ; no winsize on a wire
              (lambda ()
                (close-input-port in)
                (close-output-port out)
                (c-close fd))
              0
              (lambda () 'running)))

(provide serial-open)
