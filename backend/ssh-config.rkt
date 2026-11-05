#lang racket/base

;; OpenSSH client-config import: parses ~/.ssh/config into host
;; profiles. Only concrete Host entries are imported (patterns with
;; * or ? are skipped — they are option groups, not real hosts).
;; HostName/User/Port/IdentityFile/ProxyJump map onto the profile the
;; ssh sidecar consumes. Import (dedup by label) lives in main.rkt —
;; this module only parses.

(require racket/contract
         racket/file
         racket/list
         racket/string)

(struct entry (label fields) #:transparent)

;; Logical lines: comments and blanks dropped.
(define (config-lines path)
  (for/list ([line (in-list (file->lines path))])
    (string-trim line))
  )

;; Split "Key Value…" honoring an optional leading equals sign.
(define (split-kv line)
  (define parts
    (string-split (string-trim (string-replace line "=" " ")) #:trim? #t))
  (if (>= (length parts) 2)
      (cons (string-downcase (first parts)) (string-join (rest parts) " "))
      #f))

(define (wildcard? pattern)
  (or (string-contains? pattern "*")
      (string-contains? pattern "?")))

;; Parse into a list of profiles (hasheq label/host/port/username/
;; identity-file/jump). First-match-wins semantics of ssh_config are
;; approximated by keeping the FIRST occurrence of each key per entry.
(define (parse-ssh-config path)
  (define open-entries '()) ; list of entry?, options apply to all
  (define done '())         ; accumulated concrete entries
  (define (finish-open!)
    (set! done (append done open-entries))
    (set! open-entries '()))
  (for ([line (in-list (config-lines path))]
        #:unless (string=? line ""))
    (define kv (split-kv line))
    (when kv
      (define key (car kv))
      (define value (cdr kv))
      (cond
        [(string=? key "host")
         (finish-open!)
         (for ([pat (in-list (string-split value))]
               #:unless (or (wildcard? pat)
                            (string-prefix? pat "!")))
           (set! open-entries
                 (cons (entry pat (hasheq)) open-entries)))]
        [(and (member key '("hostname" "user" "port" "identityfile"
                                 "proxyjump"))
              (pair? open-entries))
         (set! open-entries
               (for/list ([e (in-list open-entries)])
                 (define f (entry-fields e))
                 (define k (string->symbol key))
                 (entry (entry-label e)
                        (if (hash-has-key? f k) f (hash-set f k value)))))])))
  (finish-open!)
  (for/list ([e (in-list done)])
    (define f (entry-fields e))
    (hasheq 'label (entry-label e)
            'host (hash-ref f 'hostname (entry-label e))
            'port (string->number (hash-ref f 'port "22"))
            'username (hash-ref f 'user "")
            'identity-file (hash-ref f 'identityfile "")
            'jump (hash-ref f 'proxyjump ""))))

(provide parse-ssh-config)
