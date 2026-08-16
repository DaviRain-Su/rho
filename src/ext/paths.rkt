#lang racket/base

;; Resolve the shipped-plugin directory next to this file, whether rho is
;; run from a git checkout or a raco-linked install.

(require racket/runtime-path)

(provide bundled-extensions-dir)

(define-runtime-path bundled-dir "bundled")

(define (bundled-extensions-dir)
  (path->string (simplify-path bundled-dir)))
