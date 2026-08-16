#lang racket/base

;; MCP stdio transport: Content-Length framing + one subprocess per server.

(require racket/port
         racket/string
         racket/match
         racket/treelist)

(provide frame-encode
         frame-read
         mcp-open
         mcp-rpc
         mcp-notify
         mcp-close
         mcp-alive?)

(struct conn (sp in out err-th mu) #:transparent)

(define (frame-encode json-str)
  (define body (string->bytes/utf-8 (if (string? json-str) json-str "")))
  (bytes-append
   (string->bytes/utf-8
    (format "Content-Length: ~a\r\n\r\n" (bytes-length body)))
   body))

(define (read-headers in)
  (define buf (open-output-bytes))
  (let loop ([state 0])
    (define b (read-byte in))
    (cond
      [(eof-object? b) (error 'mcp "eof while reading headers")]
      [else
       (write-byte b buf)
       (define next
         (cond
           [(and (= state 0) (= b 13)) 1]
           [(and (= state 1) (= b 10)) 2]
           [(and (= state 2) (= b 13)) 3]
           [(and (= state 3) (= b 10)) 'done]
           [(= b 13) 1]
           [else 0]))
       (if (eq? next 'done)
           (get-output-bytes buf)
           (loop next))])))

(define (header-length headers)
  (define s (string-downcase (bytes->string/utf-8 headers #\uFFFD)))
  (define m (regexp-match #px"content-length:\\s*([0-9]+)" s))
  (and m (string->number (cadr m))))

(define (frame-read-raw in)
  (define headers (read-headers in))
  (define n (header-length headers))
  (unless n (error 'mcp "missing Content-Length"))
  (define body (read-bytes n in))
  (when (or (eof-object? body) (< (bytes-length body) n))
    (error 'mcp "short MCP body"))
  (bytes->string/utf-8 body #\uFFFD))

(define (frame-read in timeout)
  (cond
    [(not timeout) (frame-read-raw in)]
    [else
     (define ch (make-channel))
     (define th
       (thread
        (lambda ()
          (with-handlers ([exn:fail? (lambda (e)
                                       (channel-put ch (list 'err e)))])
            (channel-put ch (list 'ok (frame-read-raw in)))))))
     (define r (sync/timeout timeout ch))
     (cond
       [(not r)
        (kill-thread th)
        (error 'mcp "timeout")]
       [(eq? (car r) 'ok) (cadr r)]
       [else (raise (cadr r))])]))

(define (->list xs)
  (cond
    [(treelist? xs) (treelist->list xs)]
    [(list? xs) xs]
    [else (list xs)]))

(define (as-bytes v)
  (cond
    [(bytes? v) v]
    [(string? v) (string->bytes/utf-8 v)]
    [else (string->bytes/utf-8 (format "~a" v))]))

(define (as-pair x)
  (cond
    [(and (pair? x) (not (list? x))) x]
    [(and (list? x) (>= (length x) 2)) (cons (car x) (cadr x))]
    [(and (treelist? x) (>= (treelist-length x) 2))
     (cons (treelist-ref x 0) (treelist-ref x 1))]
    [else #f]))

(define (mcp-open program args env-pairs)
  (define exe (find-executable-path program))
  (unless exe (error 'mcp (format "not found: ~a" program)))
  (define env (environment-variables-copy (current-environment-variables)))
  (for ([raw (in-list (->list env-pairs))])
    (define p (as-pair raw))
    (when p
      (environment-variables-set! env (as-bytes (car p)) (as-bytes (cdr p)))))
  (parameterize ([current-environment-variables env])
    (define-values (sp stdout stdin stderr)
      (apply subprocess #f #f #f exe (->list args)))
    (define err-th
      (thread
       (lambda ()
         (let loop ()
           (define b (read-bytes 4096 stderr))
           (unless (eof-object? b) (loop)))
         (close-input-port stderr))))
    (conn sp stdout stdin err-th (make-semaphore 1))))

(define (mcp-rpc c json-str timeout)
  (call-with-semaphore
   (conn-mu c)
   (lambda ()
     (write-bytes (frame-encode json-str) (conn-out c))
     (flush-output (conn-out c))
     (frame-read (conn-in c) timeout))))

(define (mcp-notify c json-str)
  (call-with-semaphore
   (conn-mu c)
   (lambda ()
     (write-bytes (frame-encode json-str) (conn-out c))
     (flush-output (conn-out c))
     #t)))

(define (mcp-close c)
  (with-handlers ([exn:fail? (lambda (_e) #f)])
    (close-output-port (conn-out c)))
  (with-handlers ([exn:fail? (lambda (_e) #f)])
    (close-input-port (conn-in c)))
  (define sp (conn-sp c))
  (when (eq? (subprocess-status sp) 'running)
    (subprocess-kill sp #t))
  (subprocess-wait sp)
  (define th (conn-err-th c))
  (when (and (thread? th) (thread-running? th))
    (kill-thread th))
  #t)

(define (mcp-alive? c)
  (eq? (subprocess-status (conn-sp c)) 'running))
