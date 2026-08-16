#lang info

(define collection "rho")
(define deps '("base"
               "rhombus"
               "rhombus-json"
               "rhombus-http"
               "raart"))
(define pkg-desc "rho: a Pi-style hot-reloadable coding agent written in Rhombus")
(define version "0.2.0")
(define pkg-authors '(davirain))
(define license 'MIT)
;; Catalog source (pkgs.racket-lang.org):
;;   github://github.com/DaviRain-Su/rho/v0.2.0
;;   https://github.com/DaviRain-Su/rho.git
(define compile-omit-paths '("tests" "docs" "examples" "ttfx"))
