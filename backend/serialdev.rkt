#lang racket/base

;; Serial device enumeration. Read-only directory probes — no device is
;; opened, so listing never perturbs modem-control state.
;;
;; macOS: cu.* callout devices are the ones terminals use (tty.* entries
;; wait for carrier on open); the short-node name rides the label.
;; Linux: ttyUSB*/ttyACM* first, then hardware aliases under
;; /dev/serial/by-id (descriptive, stable), then legacy ttyS*.
;; Windows: the COM map lives in HKLM\HARDWARE\DEVICEMAP\SERIALCOMM,
;; read via reg.exe (always present); a failed query yields an empty
;; list — never a fake port.

;; Windows: COM ports live in the registry under
;; HKLM\HARDWARE\DEVICEMAP\SERIALCOMM (value name = kernel device
;; object, value data = COMn). reg.exe is always present on Windows;
;; a failed query yields an empty list — never a fake port.

(require racket/list
         racket/match
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         "platform.rkt")

(provide list-serial-ports
         parse-serialcomm-output)

(define (entry->port path [label #f])
  (hasheq 'path path
          'label (or label path)))

;; Parse `reg query HKLM\HARDWARE\DEVICEMAP\SERIALCOMM` output; pure so
;; every platform's unit tests cover it. Lines look like:
;;     \Device\UsbSer000    REG_SZ    COM3
;; The value name's last segment (UsbSer000) is the driver-side hint
;; that makes the label useful in the device picker.
(define (parse-serialcomm-output text)
  (for*/list ([ln (in-list (string-split text "\n"))]
              [tokens (in-value (string-split (string-trim ln)))]
              #:when (and (= (length tokens) 3)
                          (string=? (second tokens) "REG_SZ")
                          (string-prefix? (third tokens) "COM")))
    (define device (first tokens))
    (define com (third tokens))
    (define hint (last (string-split device "\\")))
    (entry->port com (format "~a · ~a" hint com))))

(define (by-alias dir prefix)
  ;; /dev/serial/by-id entries are symlinks to ../ttyUSBn etc.; the
  ;; symlink names carry vendor/product strings — the useful label.
  (define d dir)
  (if (directory-exists? d)
      (for/list ([p (in-list (directory-list d #:link? #t))])
        (define full (build-path d p))
        (define target
          (with-handlers ([exn:fail? (lambda (_) #f)])
            (resolve-path full)))
        (entry->port (path->string full)
                     (format "~a → ~a" (path->string p)
                             (if target (path->string target) "?"))))
      '()))

(define (list-serial-ports)
  (case (system-type 'os)
    [(macosx)
     (define dev (string->path "/dev"))
     (unless (directory-exists? dev) '())
     ;; cu.* only: opening tty.* on macOS blocks on carrier wait.
     (sort
      (for/list ([p (in-list (directory-list dev))]
                 #:when (string-prefix? (path->string p) "cu."))
        (define name (path->string p))
        (entry->port (string-append "/dev/" name)
                     (string-append "Apple · " name)))
      string<?
      #:key (lambda (e) (hash-ref e 'path)))]
    [(windows)
     (define reg (find-executable-path "reg.exe"))
     (cond
       [(not reg) '()]
       [else
        (define-values (proc out in err)
          (subprocess #f #f #f reg
                      "query" "HKLM\\HARDWARE\\DEVICEMAP\\SERIALCOMM"))
        (define text (port->string out))
        (subprocess-wait proc)
        (if (zero? (subprocess-status proc))
            (parse-serialcomm-output text)
            '())])]
    [else
     ;; Linux
     (define dev (string->path "/dev"))
     (define aliases (by-alias (string->path "/dev/serial/by-id") "usb"))
     (define kernel
       (if (directory-exists? dev)
           (for/list ([p (in-list (directory-list dev))]
                      #:when (regexp-match? #px"^(ttyUSB|ttyACM|ttyO|ttyS)[0-9]+$"
                                            (path->string p)))
             (define name (path->string p))
             (entry->port (string-append "/dev/" name)
                          (string-append "Linux · " name)))
           '()))
     ;; Aliases first (they identify boards); dedupe by resolved path.
     (append aliases kernel)]))
