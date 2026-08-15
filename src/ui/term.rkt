#lang racket/base

;; Thin wrapper around raart's lux chaos so the Rhombus TUI can drive the
;; terminal without implementing lux's generic interfaces.
;;
;; Events (term-wait-event) are simple lists:
;;   (list 'key "a") / (list 'key "C-c") / (list 'key "<up>") ...
;;   (list 'resize rows cols)
;;   'timeout | 'eof
;;
;; Drawing (term-draw!) takes rows of spans; a span is
;;   (list fg-sym-or-#f bg-sym-or-#f style-sym-or-#f text-string)
;; plus an optional cursor position.

(require racket/match
         racket/treelist
         lux/chaos
         raart/lux-chaos
         raart/draw)

;; Rhombus lists are treelists; accept both.
(define (->list v)
  (cond [(treelist? v) (treelist->list v)]
        [(list? v) v]
        [else (error '->list "not a list: ~e" v)]))

(provide term-start!
         term-stop!
         term-wait-event
         term-rows
         term-cols
         term-draw!)

(define C #f)
(define ROWS 24)
(define COLS 80)

(define (term-start!)
  (set! C (make-raart))
  (chaos-start! C))

(define (term-stop!)
  (when C
    (chaos-stop! C)
    (set! C #f)))

(define (term-rows) ROWS)
(define (term-cols) COLS)

;; Events are returned as treelists so Rhombus list patterns match them.
(define (term-wait-event timeout)
  (define e (sync/timeout (if (eq? timeout #f) #f timeout) (chaos-event C)))
  (cond
    [(not e) 'timeout]
    [(screen-size-report? e)
     (set! ROWS (screen-size-report-rows e))
     (set! COLS (screen-size-report-columns e))
     (treelist 'resize ROWS COLS)]
    [(string? e) (treelist 'key (string->immutable-string e))]
    [(eof-object? e) 'eof]
    [else (treelist 'key (string->immutable-string (format "~a" e)))]))

(define (span->art sp)
  (match (->list sp)
    [(list f b s txt)
     (define base (text txt))
     (define w1 (if s (style (if (string? s) (string->symbol s) s) base) base))
     (define w2 (if f (fg (if (string? f) (string->symbol f) f) w1) w1))
     (if b (bg (if (string? b) (string->symbol b) b) w2) w2)]))

(define (row->art spans)
  (define l (->list spans))
  (if (null? l)
      (blank 0 1)
      (happend* #:valign 'top (map span->art l))))

;; rows-of-spans : (listof (listof span))
;; cursor : #f or (list row col), 0-based screen coordinates
(define (term-draw! rows-of-spans cursor)
  (define body (vappend* #:halign 'left (map row->art (->list rows-of-spans))))
  (define matted (matte COLS ROWS #:halign 'left #:valign 'top body))
  (define final
    (if cursor
        (let ([c (->list cursor)])
          (place-cursor-after matted (car c) (cadr c)))
        matted))
  (chaos-output! C final))
