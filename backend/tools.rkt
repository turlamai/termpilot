#lang racket/base

;; External debug tools (GDB / OpenOCD / ADB): argv builders + preview.
;; The UI confirms the exact parameter array before launch; nothing is
;; ever concatenated into a shell string. Launching reuses the session
;; manager — a tool is a pty sidecar session, so streaming, input,
;; logging, evidence and close/stop all come for free.
;;
;; Scope guard (design contract): no graphical breakpoints, no register
;; UI, no flashing. OpenOCD's telnet console and RTT port are plain TCP
;; sessions the session manager opens with kind "tcp".

(require racket/contract
         racket/format
         racket/path
         racket/string)

;; ---- argv builders ---------------------------------------------------------
;; Every builder returns (values executable args); empty required fields
;; raise, so the preview route can surface a per-field message.

(define (gdb-argv exe elf target)
  (values (or (and (string? exe) (not (string=? (string-trim exe) "")) exe)
              (error 'tools "gdb executable is required"))
          (list (or elf (error 'tools "ELF path is required"))
                "-ex"
                (format "target remote ~a" target))))

(define (openocd-argv exe adapter board)
  (values (or (and (string? exe) (not (string=? (string-trim exe) "")) exe)
              (error 'tools "openocd executable is required"))
          (list "-f" (or adapter (error 'tools "adapter config is required"))
                "-f" (or board (error 'tools "target config is required")))))

(define (adb-tool-argv exe serial)
  (values (or (and (string? exe) (not (string=? (string-trim exe) "")) exe)
              (error 'tools "adb executable is required"))
          (list "-s" (or (and (string? serial) (not (string=? (string-trim serial) ""))
                         serial)
                     (error 'tools "device serial is required"))
                "shell")))

;; config: hash with 'tool ("gdb"|"openocd"|"adb") plus the per-tool
;; fields. Returns the launch record: executable + args array.
(define (tool-launch config)
  (define tool (string-downcase (hash-ref config 'tool "")))
  (case tool
    [("gdb")
     (define-values (exe args)
       (gdb-argv (hash-ref config 'executable "arm-none-eabi-gdb")
                 (hash-ref config 'elf "")
                 (hash-ref config 'target "")))
     (hasheq 'tool "gdb" 'executable exe 'args args)]
    [("openocd")
     (define-values (exe args)
       (openocd-argv (hash-ref config 'executable "openocd")
                     (hash-ref config 'adapter "")
                     (hash-ref config 'board "")))
     (hasheq 'tool "openocd" 'executable exe 'args args)]
    [("adb")
     (define-values (exe args)
       (adb-tool-argv (hash-ref config 'executable "adb")
                      (hash-ref config 'serial "")))
     (hasheq 'tool "adb" 'executable exe 'args args)]
    [else (error 'tools "unknown tool: ~a" tool)]))

(provide tool-launch)
