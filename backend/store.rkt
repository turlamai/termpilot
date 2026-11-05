#lang racket/base

;; Persistent store on SQLite (glaze's capability-scoped wrapper over
;; db-lib): hosts, groups, tags, snippets. The database lives in the app
;; data dir; every mutation updates updated_at. Hosts carry the profile
;; fields the ssh sidecar consumes (see ssh.rkt).

(require glaze/sql
         json
         racket/format
         racket/match
         racket/random
         racket/string
         "platform.rkt")

;; The database opens lazily on first use: module load must stay pure
;; (schema check and raco test load this module; CI has no writable
;; config dir and tests sandbox via TERMPILOT_DATA_DIR).
(define db-box (box #f))

(define (db-path)
  (build-path (ensure-app-data-dir!) "termpilot.db"))

(define (db)
  (or (unbox db-box)
      (let ([opened (open-sqlite-database (db-path))])
        (set-box! db-box opened)
        opened)))

(define (exec! stmt [params '()])
  (sql-execute! (db) stmt params))

(define (select stmt [params '()])
  (sql-select (db) stmt params))

;; Column migrations: v0.1 had a narrow hosts table; add columns as
;; needed. SQLite has no ADD COLUMN IF NOT EXISTS, so failures for
;; duplicate columns are swallowed. No users exist before 0.1, so no
;; data migrations beyond shape.
(define (try-add-column! table col decl)
  (with-handlers ([exn:fail? void])
    (exec! (format "ALTER TABLE ~a ADD COLUMN ~a ~a" table col decl))))

(define (init!)
  (define (ddl! stmt)
    (with-handlers ([exn:fail? void]) (exec! stmt)))
  (exec! "CREATE TABLE IF NOT EXISTS hosts (
            id TEXT PRIMARY KEY,
            label TEXT NOT NULL,
            host TEXT NOT NULL,
            port INTEGER NOT NULL DEFAULT 22,
            username TEXT NOT NULL DEFAULT '',
            auth_type TEXT NOT NULL DEFAULT 'agent',
            identity_file TEXT NOT NULL DEFAULT '',
            group_name TEXT NOT NULL DEFAULT '',
            tags TEXT NOT NULL DEFAULT '[]',
            notes TEXT NOT NULL DEFAULT '',
            strict_host_key TEXT NOT NULL DEFAULT 'accept-new',
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL)")
  (try-add-column! "hosts" "jump" "TEXT NOT NULL DEFAULT ''")
  (try-add-column! "hosts" "startup_snippet" "TEXT NOT NULL DEFAULT ''")
  (try-add-column! "hosts" "keep_alive" "INTEGER NOT NULL DEFAULT 0")
  (try-add-column! "hosts" "font_size" "INTEGER NOT NULL DEFAULT 0")
  (try-add-column! "hosts" "connection_kind" "TEXT NOT NULL DEFAULT 'ssh'")
  (ddl! "CREATE TABLE IF NOT EXISTS forwarding_rules (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            host_id TEXT NOT NULL DEFAULT '',
            bind_host TEXT NOT NULL DEFAULT '',
            local_port INTEGER NOT NULL,
            remote_host TEXT NOT NULL DEFAULT '',
            remote_port INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL)"))

;; ---- ids -------------------------------------------------------------------

(define (new-id!)
  (bytes->hex-string (crypto-random-bytes 12)))

(define (bytes->hex-string b)
  (apply string-append
         (for/list ([byte (in-bytes b)])
           (~r byte #:base 16 #:min-width 2 #:pad-string "0"))))

;; ---- hosts -----------------------------------------------------------------

(define host-keys
  '(id label host port username auth-type identity-file group-name tags
       notes strict-host-key sort-order created-at updated-at))

;; sql-select returns jsexpr rows; tags come back as a JSON string.
(define (row->host row)
  (hasheq 'id (hash-ref row 'id)
          'label (hash-ref row 'label)
          'host (hash-ref row 'host)
          'port (hash-ref row 'port)
          'username (hash-ref row 'username)
          'auth-type (hash-ref row 'auth_type)
          'identity-file (hash-ref row 'identity_file)
          'group-name (hash-ref row 'group_name)
          'tags (with-handlers ([exn:fail? (lambda (_) '())])
                  (string->jsexpr (hash-ref row 'tags)))
          'notes (hash-ref row 'notes)
          'strict-host-key (hash-ref row 'strict_host_key)
          'sort-order (hash-ref row 'sort_order)
          'jump (hash-ref row 'jump "")
          'startup-snippet (hash-ref row 'startup_snippet "")
          'keep-alive (hash-ref row 'keep_alive 0)
          'font-size (hash-ref row 'font_size 0)
          'connection-kind (hash-ref row 'connection_kind "ssh")
          'created-at (hash-ref row 'created_at)
          'updated-at (hash-ref row 'updated_at)))

(define (list-hosts)
  (for/list ([row (in-list (select "SELECT * FROM hosts
                                    ORDER BY sort_order, label"))])
    (row->host row)))

(define (get-host id)
  (match (select "SELECT * FROM hosts WHERE id = ?" (list id))
    [(list row) (row->host row)]
    [_ #f]))

(define (insert-host! h)
  (define now (current-seconds))
  (define id (or (hash-ref h 'id #f) (new-id!)))
  (exec! "INSERT INTO hosts (id, label, host, port, username, auth_type,
             identity_file, group_name, tags, notes, strict_host_key,
             sort_order, jump, startup_snippet, keep_alive, font_size,
             connection_kind, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
         (list id
               (hash-ref h 'label)
               (hash-ref h 'host)
               (hash-ref h 'port 22)
               (hash-ref h 'username "")
               (hash-ref h 'auth-type "agent")
               (hash-ref h 'identity-file "")
               (hash-ref h 'group-name "")
               (jsexpr->string (hash-ref h 'tags '()))
               (hash-ref h 'notes "")
               (hash-ref h 'strict-host-key "accept-new")
               (hash-ref h 'sort-order 0)
               (hash-ref h 'jump "")
               (hash-ref h 'startup-snippet "")
               (hash-ref h 'keep-alive 0)
               (hash-ref h 'font-size 0)
               (hash-ref h 'connection-kind "ssh")
               now now))
  (get-host id))

(define (update-host! id h)
  (unless (get-host id) (error 'update-host! "unknown host ~a" id))
  (exec! "UPDATE hosts SET label = ?, host = ?, port = ?, username = ?,
            auth_type = ?, identity_file = ?, group_name = ?, tags = ?,
            notes = ?, strict_host_key = ?, sort_order = ?,
            jump = ?, startup_snippet = ?, keep_alive = ?, font_size = ?,
            connection_kind = ?, updated_at = ?
          WHERE id = ?"
         (list (hash-ref h 'label)
               (hash-ref h 'host)
               (hash-ref h 'port 22)
               (hash-ref h 'username "")
               (hash-ref h 'auth-type "agent")
               (hash-ref h 'identity-file "")
               (hash-ref h 'group-name "")
               (jsexpr->string (hash-ref h 'tags '()))
               (hash-ref h 'notes "")
               (hash-ref h 'strict-host-key "accept-new")
               (hash-ref h 'sort-order 0)
               (hash-ref h 'jump "")
               (hash-ref h 'startup-snippet "")
               (hash-ref h 'keep-alive 0)
               (hash-ref h 'font-size 0)
               (hash-ref h 'connection-kind "ssh")
               (current-seconds)
               id))
  (get-host id))

(define (delete-host! id)
  (exec! "DELETE FROM hosts WHERE id = ?" (list id))
  #t)

;; ---- snippets ---------------------------------------------------------------

(define (row->snippet row)
  (hasheq 'id (hash-ref row 'id)
          'name (hash-ref row 'name)
          'command (hash-ref row 'command)
          'tags (with-handlers ([exn:fail? (lambda (_) '())])
                  (string->jsexpr (hash-ref row 'tags)))
          'created-at (hash-ref row 'created_at)))

(define (list-snippets)
  (for/list ([row (in-list (select "SELECT * FROM snippets
                                    ORDER BY created_at"))])
    (row->snippet row)))

(define (insert-snippet! s)
  (define id (new-id!))
  (exec! "INSERT INTO snippets (id, name, command, tags, created_at)
          VALUES (?, ?, ?, ?, ?)"
         (list id
               (hash-ref s 'name)
               (hash-ref s 'command)
               (jsexpr->string (hash-ref s 'tags '()))
               (current-seconds)))
  (define found
    (filter (lambda (x) (string=? (hash-ref x 'id) id)) (list-snippets)))
  (and (pair? found) (car found)))

(define (delete-snippet! id)
  (exec! "DELETE FROM snippets WHERE id = ?" (list id))
  #t)

(provide db-path
         (rename-out [init! store-init!])
         list-hosts
         get-host
         insert-host!
         update-host!
         delete-host!
         list-snippets
         insert-snippet!
         delete-snippet!)
