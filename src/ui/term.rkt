#lang racket/base

;; Thin wrapper around raart's lux chaos so the Rhombus TUI can drive the
;; terminal without implementing lux's generic interfaces.
;;
;; We use the chaos only for raw-mode setup and key input; drawing goes
;; through our own cached buffer so that we control the screen size. The
;; size comes from `stty size` (reliable even when the terminal ignores the
;; CSI 18t query that raart sends) and is refreshed on demand.
;;
;; Events (term-wait-event) are treelists so Rhombus patterns match them:
;;   ['key "a"] / ['key "C-C"] / ['key "<up>"] ...
;;   ['resize rows cols]
;;   'timeout | 'eof
;;
;; Drawing (term-draw!) takes rows of spans; a span is
;;   [fg-sym-or-#f bg-sym-or-#f style-sym-or-#f text-string]
;; plus an optional cursor position.

(require racket/match
         racket/treelist
         racket/system
         racket/string
         racket/port
         lux/chaos
         raart/lux-chaos
         raart/draw
         raart/buffer
         (submod raart/buffer internal))

(provide term-start!
         term-stop!
         term-wait-event
         term-poll-size!
         term-rows
         term-cols
         term-draw!)

(define C #f)
(define BUF #f)
(define ROWS 24)
(define COLS 80)

;; Rhombus lists are treelists; accept both.
(define (->list v)
  (cond [(treelist? v) (treelist->list v)]
        [(list? v) v]
        [else (error '->list "not a list: ~e" v)]))

(define (stty-size)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (define s
      (with-output-to-string
        (lambda () (system "stty size < /dev/tty 2>/dev/null"))))
    (match (string-split (string-trim s))
      [(list r c)
       (define rn (string->number r))
       (define cn (string->number c))
       (and rn cn (> rn 0) (> cn 0) (list rn cn))]
      [_ #f])))

(define (apply-size! r c)
  (unless (and (= r ROWS) (= c COLS))
    (set! ROWS r)
    (set! COLS c)
    (when BUF (buffer-resize! BUF ROWS COLS))))

;; Re-reads the tty size; returns #t when it changed.
(define (term-poll-size!)
  (match (stty-size)
    [(list r c)
     (define changed? (not (and (= r ROWS) (= c COLS))))
     (apply-size! r c)
     changed?]
    [_ #f]))

(define (term-start!)
  (set! C (make-raart))
  (chaos-start! C)
  (match (stty-size)
    [(list r c) (set! ROWS r) (set! COLS c)]
    [_ (void)])
  (set! BUF (make-cached-buffer ROWS COLS)))

(define (term-stop!)
  (when C
    (chaos-stop! C)
    (set! C #f)
    (set! BUF #f)))

(define (term-rows) ROWS)
(define (term-cols) COLS)

(define (term-wait-event timeout)
  (define e (sync/timeout (if (eq? timeout #f) #f timeout) (chaos-event C)))
  (cond
    [(not e) 'timeout]
    [(screen-size-report? e)
     (apply-size! (screen-size-report-rows e)
                  (screen-size-report-columns e))
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
  (draw BUF final))
