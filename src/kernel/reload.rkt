#lang racket/base

;; Hot-reload shim: dynamic-rerequire tracks file modification times and
;; reloads changed modules (including transitive requires); the Rhombus-aware
;; dynamic require fetches exports like `init` after (re)loading.

(require racket/rerequire
         rhombus/dynamic-require)

(provide rerequire_path
         get_export)

(define (->path p)
  (path->complete-path (if (path? p) p (string->path p))))

;; Returns a list of paths that were (re)loaded; empty if nothing changed.
(define (rerequire_path p)
  (map path->string (dynamic-rerequire (->path p) #:verbosity 'none)))

(define (get_export p name)
  (rhombus-dynamic-require (list 'file (string->immutable-string
                                        (path->string (->path p))))
                           (string->symbol name)))
