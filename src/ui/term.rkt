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
;;
;; We draw whole rows ourselves (goto + SGR + text + clear-to-eol) instead of
;; using raart's per-cell buffer: the cell model assumes every character is
;; one column wide, which breaks double-width CJK glyphs (later cell writes
;; land inside a wide glyph and visually erase characters). Writing a row
;; left-to-right lets the terminal handle glyph widths natively; a row-level
;; diff keeps redraws cheap.

(require racket/match
         racket/treelist
         racket/system
         racket/string
         racket/port
         net/base64
         lux/chaos
         raart/lux-chaos
         (only-in ansi/lcd-terminal
                  any-mouse-event? mouse-event? mouse-event-type
                  mouse-event-button mouse-event-row mouse-event-column))

(provide term-start!
         term-stop!
         term-wait-event
         term-poll-size!
         term-rows
         term-cols
         term-draw!
         term-copy!
         term-suspend!
         term-resume!)

(define C #f)
(define OP #f)                        ; terminal output port
(define ROWS 24)
(define COLS 80)
;; last-drawn representation per screen row: #f (unknown), 'blank, or a
;; list of (fg bg style text) lists — used to skip unchanged rows
(define LAST (make-vector 512 #f))

(define (reset-last!)
  (vector-fill! LAST #f))

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
    (reset-last!)
    (when OP
      (write-string "\e[2J" OP)
      (flush-output OP))))

;; Re-reads the tty size; returns #t when it changed.
(define (term-poll-size!)
  (match (stty-size)
    [(list r c)
     (define changed? (not (and (= r ROWS) (= c COLS))))
     (apply-size! r c)
     changed?]
    [_ #f]))

(define (term-start!)
  ;; mouse? enables SGR mouse reporting so wheel scrolling works in the
  ;; alternate screen (hold Shift for native terminal text selection)
  (set! C (make-raart #:mouse? #t))
  (chaos-start! C)
  (set! OP (current-output-port))
  (match (stty-size)
    [(list r c) (set! ROWS r) (set! COLS c)]
    [_ (void)])
  (reset-last!)
  ;; disable autowrap: writing the bottom-right cell must not scroll the
  ;; screen (rows are clipped at the right edge instead)
  (write-string "\e[?7l\e[2J" OP)
  (flush-output OP))

(define (term-stop!)
  (when C
    (when OP
      (write-string "\e[?7h" OP)
      (flush-output OP))
    (chaos-stop! C)
    (set! C #f)
    (set! OP #f)))

(define (term-rows) ROWS)
(define (term-cols) COLS)

;; OSC 52: ask the terminal to place text on the system clipboard.
;; Returns #t when the escape was written (terminal support varies).
(define (term-copy! s)
  (cond
    [OP
     (define b64 (bytes->string/utf-8
                  (base64-encode (string->bytes/utf-8 s) #"")))
     (write-string (format "\e]52;c;~a\a" b64) OP)
     (flush-output OP)
     #t]
    [else #f]))

;; Temporarily leave raw mode / the alternate screen (external editor).
(define (term-suspend!)
  (term-stop!))

(define (term-resume!)
  (term-start!))

;; wake: optional semaphore; posting it wakes the wait immediately ('wake).
;; Lets background threads (streaming, notify pump) trigger a repaint without
;; waiting out the timeout.
(define (term-wait-event timeout wake)
  (define e (sync/timeout (if (eq? timeout #f) #f timeout)
                          (chaos-event C)
                          (if (semaphore? wake) wake never-evt)))
  (cond
    [(not e) 'timeout]
    [(semaphore? e) 'wake]
    [(screen-size-report? e)
     (apply-size! (screen-size-report-rows e)
                  (screen-size-report-columns e))
     (treelist 'resize ROWS COLS)]
    [(and (mouse-event? e) (eq? (mouse-event-type e) 'scroll))
     ;; wheel up = button 4 (scroll toward older lines), down = button 5
     (treelist 'wheel (if (= (mouse-event-button e) 4) 3 -3))]
    [(and (mouse-event? e)
          (memq (mouse-event-type e) '(press motion drag release release-all)))
     ;; in-app text selection: 1-based coordinates. NB: the ansi package
     ;; passes (x y) to (mouse-event type button row column _), so the
     ;; "row" field actually holds the column and vice versa.
     (treelist 'mouse
               (case (mouse-event-type e)
                 [(release-all) "release"]
                 [(motion) "drag"]
                 [else (symbol->string (mouse-event-type e))])
               (mouse-event-button e)
               (mouse-event-column e)    ; real row
               (mouse-event-row e))]     ; real column
    [(any-mouse-event? e) 'skip]     ; motion without buttons, focus: ignored
    [(string? e) (treelist 'key (string->immutable-string e))]
    [(eof-object? e) 'eof]
    [else (treelist 'key (string->immutable-string (format "~a" e)))]))

(define (->sym v)
  (cond [(symbol? v) v]
        [(string? v) (string->symbol v)]
        [else #f]))

(define (color-code c)
  (case (->sym c)
    [(black) 30] [(red) 31] [(green) 32] [(yellow) 33]
    [(blue) 34] [(magenta) 35] [(cyan) 36] [(white) 37]
    [(brblack) 90] [(brred) 91] [(brgreen) 92] [(bryellow) 93]
    [(brblue) 94] [(brmagenta) 95] [(brcyan) 96] [(brwhite) 97]
    [else #f]))

(define (style-code s)
  (case (->sym s)
    [(bold) 1] [(dim) 2] [(italic) 3] [(underline) 4] [(invert) 7]
    [else #f]))

(define (span-sgr f b s)
  (define codes
    (append (let ([sc (and s (style-code s))]) (if sc (list sc) '()))
            (let ([fc (and f (color-code f))]) (if fc (list fc) '()))
            (let ([bc (and b (color-code b))]) (if bc (list (+ bc 10)) '()))))
  (if (null? codes)
      "\e[0m"
      (string-append "\e[0;" (string-join (map number->string codes) ";") "m")))

(define (write-row! i spans)
  (write-string (format "\e[~a;1H" (add1 i)) OP)
  (for ([sp (in-list spans)])
    (match sp
      [(list f b s txt)
       (write-string (span-sgr f b s) OP)
       (write-string txt OP)]))
  (write-string "\e[0m\e[K" OP))

;; rows-of-spans : (listof (listof span))
;; cursor : #f or (list row col), 0-based screen coordinates
(define (term-draw! rows-of-spans cursor)
  (define rows (map (lambda (row) (map ->list (->list row)))
                    (->list rows-of-spans)))
  (write-string "\e[?25l" OP)
  (for ([i (in-naturals)] [row (in-list rows)])
    (when (and (< i ROWS) (not (equal? row (vector-ref LAST i))))
      (vector-set! LAST i row)
      (write-row! i row)))
  ;; clear any rows below the provided content
  (for ([i (in-range (length rows) ROWS)])
    (unless (eq? (vector-ref LAST i) 'blank)
      (vector-set! LAST i 'blank)
      (write-string (format "\e[~a;1H\e[0m\e[K" (add1 i)) OP)))
  (when cursor
    (let ([c (->list cursor)])
      (write-string (format "\e[~a;~aH" (add1 (car c)) (add1 (cadr c))) OP))
    (write-string "\e[?25h" OP))
  (flush-output OP))
