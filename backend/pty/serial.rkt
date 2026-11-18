#lang racket/base

;; Serial transport (macOS + Linux): open the device file, configure the
;; line once via termios (baud/parity/stop/data bits + raw mode + CLOCAL),
;; then read and write plain file ports — the same scheduler-integrated
;; ports the script bridge relies on. A one-shot tcsetattr does not block,
;; so no FFI scheduling problems arise here.
;;
;; Device + line parameters come from the connection profile (device path
;; in `host`, baud rides `port`; data bits/parity/stop bits/flow control
;; ride dedicated store fields).
;;
;; Signal control (DTR/RTS/BREAK) rides ioctl(2) on the original fd,
;; which this module keeps in an eq?-based registry keyed by the returned
;; pty-handle. The session manager never sees the fd.
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
(define iflag-offset 0)
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
(define-libc c-tcsendbreak (_fun _int _int -> _int) #:c-id tcsendbreak)
(define-libc c-ioctl (_fun _int _uint64 _pointer -> _int) #:c-id ioctl)

(define tcsanow 0)
(define o-rdwr 2)
;; O_NONBLOCK: the open call itself must not hang on modem-control lines.
;; macOS 0x4, Linux 0x800. The flag lives on the control fd only (ioctl /
;; tcsetattr, never read/write), so it never needs clearing.
(define o-nonblock
  (case (system-type 'os)
    [(macosx) 4]
    [else 2048]))

;; errno codes for open-failure classification (same on both platforms).
(define e-enoent 2)
(define e-eacces 13)
(define e-ebusy 16)

;; ---- modem-bits & flow-control constants (platform tables) -----------------

(define-values (tiocmget tiocmbis tiocmbic tiocmset crtscts ixon ixoff)
  (case (system-type 'os)
    ;; Verified against the macOS SDK: TIOCMGET = _IOR('t',106,int)
    ;; (0x4004746a), TIOCMBIC/BIS/SET likewise; CRTSCTS = CCTS_OFLOW |
    ;; CRTS_IFLOW = 0x30000; IXON 0x200, IXOFF 0x400.
    [(macosx) (values #x4004746a #x8004746b #x8004746c #x8004746d
                      #x30000 #x200 #x400)]
    ;; Linux: TIOCMGET 0x5415, TIOCMBIC 0x541A, TIOCMBIS 0x5419,
    ;; TIOCMSET 0x5418; CRTSCTS = bit 31; IXON 0x400, IXOFF 0x1000.
    [else (values #x5415 #x541a #x5419 #x5418
                  #x80000000 #x400 #x1000)]))
;; TIOCM_DTR / TIOCM_RTS share the same values everywhere.
(define tiocm-dtr 2)
(define tiocm-rts 4)

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

;; c_cflag bits: platform tables (data bits 5–8, stop 2, parity).
(define (cflag-bits databits parity stopbits)
  (define-values (cs5 cs6 cs7 cs8 cstopb parenb parodd clocal cread)
    (case (system-type 'os)
      [(macosx) (values #x000 #x100 #x200 #x300 #x400 #x1000 #x2000 #x8000 #x800)]
      [else (values #o00 #o10 #o20 #o30 #o100 #o400 #o1000 #o4000 #o200)]))
  (define size (case databits
                 [(5) cs5] [(6) cs6] [(7) cs7] [(8) cs8]
                 [else (error 'serial "data bits must be 5–8: ~a" databits)]))
  (+ size
     (if (= stopbits 2) cstopb 0)
     (if (not (string=? parity "none")) parenb 0)
     (if (string=? parity "odd") parodd 0)
     clocal
     cread))

;; c_iflag patches for software flow control; c_cflag patch for hardware
;; (RTS/CTS). cfmakeraw already cleared IXON/IXOFF — set what the profile
;; asks for, nothing more.
(define (flow-bits flow)
  (case flow
    [("rtscts") (values crtscts 0)]
    [("xonxoff") (values 0 (+ ixon ixoff))]
    [else (values 0 0)]))

;; Classify an open failure into the states the UI surfaces (the design
;; contract's device states: occupied / permission / unplugged).
(define (open-fault errno)
  (cond
    [(= errno e-ebusy) "device-busy"]
    [(= errno e-eacces) "no-access"]
    [(memv errno (list e-enoent)) "not-present"]
    [else "open-failed"]))

;; ---- signal-control registry ----------------------------------------------
;; eq?-based: handle -> (hasheq 'fd int). Registered at open, dropped at
;; close. Only these actions exist; a plain session can never reach them.

(define signal-registry (make-weak-hasheq))

(define (modem-bits fd)
  (define buf (malloc _int 'raw))
  (ptr-set! buf _int 0 0)
  (define r (c-ioctl fd tiocmget buf))
  (when (< r 0) (error 'serial "TIOCMGET failed (errno ~a)" r))
  (ptr-ref buf _int 0))

(define (set-modem-bit! fd bit on?)
  (define op (if on? tiocmbis tiocmbic))
  (define buf (malloc _int 'raw))
  (ptr-set! buf _int 0 bit)
  (define r (c-ioctl fd op buf))
  (when (< r 0) (error 'serial "modem-bit ioctl failed (errno ~a)" r)))

;; action: 'break | 'dtr | 'rts — dtr/rts TOGGLE: the current modem
;; line is read via TIOCMGET first, then flipped, so the UI needs no
;; shadow state. Returns the resulting level symbol.
;; RTS is refused while hardware flow control owns the line — flipping it
;; by hand would stall or corrupt the transfer the driver is pacing.
(define (serial-control! handle action)
  (define entry (hash-ref signal-registry handle #f))
  (unless entry (error 'serial "not a serial session handle"))
  (define fd (hash-ref entry 'fd))
  (define flow (hash-ref entry 'flow "none"))
  (case action
    [(break)
     (define r (c-tcsendbreak fd 0))
     (when (< r 0) (error 'serial "tcsendbreak failed (errno ~a)" r))
     'break-pulse]
    [(dtr)
     (define on? (zero? (bitwise-and (modem-bits fd) tiocm-dtr)))
     (set-modem-bit! fd tiocm-dtr on?)
     (if on? 'dtr-high 'dtr-low)]
    [(rts)
     (when (string=? flow "rtscts")
       (error 'serial "RTS is owned by hardware flow control"))
     (define on? (zero? (bitwise-and (modem-bits fd) tiocm-rts)))
     (set-modem-bit! fd tiocm-rts on?)
     (if on? 'rts-high 'rts-low)]
    [else (error 'serial "unknown signal action: ~a" action)]))

;; ---- open ------------------------------------------------------------------

;; Open + configure; returns a pty-handle (no real pty: the ports are the
;; device file, resize is a no-op, poller reports running — serial has no
;; child process to exit; EOF arrives when the device disappears).
(define (serial-open #:device device
                     #:baud [baud 115200]
                     #:databits [databits 8]
                     #:parity [parity "none"]
                     #:stopbits [stopbits 1]
                     #:flow [flow "none"])
  (define fd (c-open device (+ o-rdwr o-nonblock)))
  (when (< fd 0)
    (error 'serial "~a: ~a (errno ~a)"
           device
           (open-fault (- fd))
           (- fd)))
  (define termios (malloc termios-size 'raw))
  (define g (c-tcgetattr fd termios))
  (when (< g 0)
    (c-close fd)
    (error 'serial "~a is not a configurable tty/serial device" device))
  (c-cfmakeraw termios)
  ;; Patch c_cflag/c_iflag in place: keep everything else the platform
  ;; set. The control fd keeps O_NONBLOCK (it never does I/O); the ports
  ;; below get their own blocking descriptors.
  (define-values (cflow iflow) (flow-bits flow))
  (ptr-set! termios _uint cflag-offset
            (+ (cflag-bits databits parity stopbits) cflow))
  (ptr-set! termios _uint iflag-offset
            (+ (ptr-ref termios _uint iflag-offset) iflow))
  (define speed (speed-code baud))
  (c-cfsetispeed termios speed)
  (c-cfsetospeed termios speed)
  (define r (c-tcsetattr fd tcsanow termios))
  (when (< r 0)
    (c-close fd)
    (error 'serial "tcsetattr failed on ~a (errno ~a)" device r))
  (define in (open-input-file device))
  (define out (open-output-file device #:exists 'append))
  (define h
    (pty-handle in
                (lambda (bs) (write-bytes bs out) (flush-output out))
                (lambda (_c _r) (void)) ; no winsize on a wire
                (lambda ()
                  (hash-remove! signal-registry h)
                  (close-input-port in)
                  (close-output-port out)
                  (c-close fd))
                0
                (lambda () 'running)))
  (hash-set! signal-registry h (hasheq 'fd fd 'flow flow))
  h)

(provide serial-open
         serial-control!)
