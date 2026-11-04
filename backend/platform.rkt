#lang racket/base

;; Data directory resolution, following the family layout:
;;   macOS    ~/Library/Application Support/termpilot
;;   Windows  %APPDATA%/termpilot
;;   Linux    ~/.config/termpilot
;; TERMPILOT_DATA_DIR overrides everything (tests and CI sandboxes).

(require racket/file
         racket/path
         racket/string)

(provide app-data-dir
         ensure-app-data-dir!)

(define (base-dir)
  (case (system-type)
    [(macosx)
     (build-path (find-system-path 'home-dir)
                 "Library" "Application Support")]
    [(windows)
     (find-system-path 'pref-dir)]
    [else
     (find-system-path 'config-dir)]))

(define (env-override)
  (define env (getenv "TERMPILOT_DATA_DIR"))
  (and env (not (string=? env "")) (simple-form-path env)))

(define (app-data-dir)
  (or (env-override)
      (build-path (base-dir) "termpilot")))

(define (ensure-app-data-dir!)
  (define dir (app-data-dir))
  (unless (directory-exists? dir)
    (make-directory* dir))
  dir)
