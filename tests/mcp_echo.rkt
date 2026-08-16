#lang racket/base

;; Tiny MCP stdio server for tests: one `echo` tool.

(require json
         racket/port
         racket/match
         racket/string)

(define (read-headers)
  (define buf (open-output-bytes))
  (let loop ([state 0])
    (define b (read-byte))
    (cond
      [(eof-object? b) #f]
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

(define (read-frame)
  (define headers (read-headers))
  (cond
    [(not headers) #f]
    [else
     (define s (string-downcase (bytes->string/utf-8 headers #\uFFFD)))
     (define m (regexp-match #px"content-length:\\s*([0-9]+)" s))
     (define n (and m (string->number (cadr m))))
     (and n
          (let ([body (read-bytes n)])
            (and (bytes? body)
                 (string->jsexpr (bytes->string/utf-8 body #\uFFFD)))))]))

(define (write-frame jsexpr)
  (define body (string->bytes/utf-8 (jsexpr->string jsexpr)))
  (display (format "Content-Length: ~a\r\n\r\n" (bytes-length body)))
  (write-bytes body)
  (flush-output))

(define (reply id result)
  (write-frame (hash 'jsonrpc "2.0" 'id id 'result result)))

(define echo-tool
  (hash 'name "echo"
        'description "echo text"
        'inputSchema (hash 'type "object"
                           'properties (hash 'text (hash 'type "string"))
                           'required (list "text"))))

(let loop ()
  (define msg (read-frame))
  (when msg
    (define method (hash-ref msg 'method #f))
    (define id (hash-ref msg 'id #f))
    (define params (hash-ref msg 'params (hash)))
    (cond
      [(equal? method "initialize")
       (reply id (hash 'protocolVersion "2024-11-05"
                       'capabilities (hash 'tools (hash))
                       'serverInfo (hash 'name "echo" 'version "0")))]
      [(equal? method "notifications/initialized") (void)]
      [(equal? method "tools/list")
       (reply id (hash 'tools (list echo-tool)))]
      [(equal? method "tools/call")
       (define name (hash-ref params 'name ""))
       (define args (hash-ref params 'arguments (hash)))
       (define text (hash-ref args 'text (jsexpr->string args)))
       (reply id (hash 'content (list (hash 'type "text" 'text text))))]
      [id
       (write-frame (hash 'jsonrpc "2.0"
                          'id id
                          'error (hash 'code -32601 'message "unknown method")))]
      [else (void)])
    (loop)))
