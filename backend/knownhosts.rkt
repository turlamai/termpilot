#lang racket/base

;; Known-hosts manager: inventory and removal for ~/.ssh/known_hosts.
;; Entries are hashed (|1|) or plain; both are listed — hashed hosts are
;; shown by their key type and fingerprint shape, with the hash intact.
;; Removal matches whole first-field patterns (plain) or the entire
;; hashed line (by index), so a delete never corrupts the file.

(require racket/contract
         racket/file
         racket/list
         racket/string)

(provide list-known-hosts
         remove-known-host!)

(define (known-hosts-path)
  (build-path (find-system-path 'home-dir) ".ssh" "known_hosts"))

(define (read-lines)
  (define p (known-hosts-path))
  (if (file-exists? p)
      (file->lines p)
      '()))

(define (write-lines! lines)
  (define p (known-hosts-path))
  (define tmp (path-replace-extension p (lambda (_) ".tmp")))
  (with-output-to-file tmp
    (lambda () (for ([l (in-list lines)]) (displayln l)))
    #:exists 'replace)
  (when (file-exists? p) (delete-file p))
  (rename-file-or-directory tmp p))

;; One line: host-pattern keytype keybase64 [comment]
(define (line->entry idx line)
  (define parts (string-split line))
  (if (< (length parts) 3)
      (hasheq 'index idx 'raw line 'host "?" 'keytype "?")
      (hasheq 'index idx
              'raw line
              'host (first parts)
              'keytype (second parts)
              'comment (string-join (drop parts 3) " "))))

(define (list-known-hosts)
  (for/list ([line (in-list (read-lines))]
             [idx (in-naturals)]
             #:unless (string=? (string-trim line) ""))
    (line->entry idx line)))

;; Remove by index (as listed); rewrite without that entry.
(define (remove-known-host! index)
  (define entries (list-known-hosts))
  (define target
    (findf (lambda (e) (= (hash-ref e 'index) index)) entries))
  (unless target (error 'known-hosts "no entry at index ~a" index))
  (define remaining
    (for/list ([e (in-list entries)]
               #:unless (= (hash-ref e 'index) index))
      (hash-ref e 'raw)))
  (write-lines! remaining)
  (hasheq 'removed index 'remaining (length remaining)))
