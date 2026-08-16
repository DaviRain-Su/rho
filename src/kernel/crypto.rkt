#lang racket/base

;; PKCE + small HTTP helpers used by OAuth login.

(require net/base64
         file/sha1
         racket/random
         racket/port
         racket/string
         racket/match
         racket/tcp
         racket/list)

(provide pkce-verifier
         pkce-challenge
         base64url-encode
         url-encode
         open-browser
         browser-argv
         oauth-wait-code
         jwt-payload
         run-argv)

(define (base64url-encode bs)
  (define s (bytes->string/utf-8 (base64-encode bs #"")))
  (string-replace
   (string-replace
    (string-replace s "+" "-")
    "/" "_")
   "=" ""))

(define (pkce-verifier)
  (base64url-encode (crypto-random-bytes 32)))

(define (pkce-challenge verifier)
  (base64url-encode (sha256-bytes (string->bytes/utf-8 verifier))))

;; argv subprocess: no shell, so caller-supplied paths/URLs cannot inject.
;; Returns (values exit-code combined-output).
(define (run-argv program args)
  (define exe (find-executable-path program))
  (cond
    [(not exe) (values 127 (string-append program " not found"))]
    [else
     (define-values (sp out in err)
       (apply subprocess #f #f #f exe args))
     (close-output-port in)
     (define text
       (bytes->string/utf-8
        (bytes-append (port->bytes out) (port->bytes err))
        #\uFFFD))
     (close-input-port out)
     (close-input-port err)
     (subprocess-wait sp)
     (define status (subprocess-status sp))
     (values (if (exact-integer? status) status 1) text)]))

;; Decode a JWT payload (middle segment) without verifying the signature.
;; Used only to read ChatGPT account_id / plan claims from tokens we just
;; received over TLS from auth.openai.com.
(define (jwt-payload token)
  (define parts (string-split (if (string? token) token "") "."))
  (cond
    [(< (length parts) 2) #f]
    [else
     (define seg (list-ref parts 1))
     (define m (modulo (string-length seg) 4))
     (define padded
       (cond [(= m 2) (string-append seg "==")]
             [(= m 3) (string-append seg "=")]
             [else seg]))
     (define b64
       (string-replace (string-replace padded "-" "+") "_" "/"))
     (with-handlers ([exn:fail? (lambda (_e) #f)])
       (bytes->string/utf-8
        (base64-decode (string->bytes/utf-8 b64))))]))

(define (url-encode s)
  (define out (open-output-string))
  (for ([b (in-bytes (string->bytes/utf-8 s))])
    (if (or (<= 48 b 57) (<= 65 b 90) (<= 97 b 122)
            (memv b '(45 46 95 126)))
        (write-byte b out)
        (fprintf out "%~a~a"
                 (string-upcase (number->string (quotient b 16) 16))
                 (string-upcase (number->string (modulo b 16) 16)))))
  (string->immutable-string (get-output-string out)))

(define (windows-browser-argv url)
  (define cmd-exe (or (find-executable-path "cmd.exe")
                      (find-executable-path "cmd")))
  ;; `start` treats the first quoted argument as a window title.
  (and cmd-exe (list cmd-exe "/c" "start" "" url)))

(define (browser-argv url)
  (cond
    [(eq? (system-type) 'windows) (windows-browser-argv url)]
    [(find-executable-path "open") (list (find-executable-path "open") url)]
    [(find-executable-path "xdg-open") (list (find-executable-path "xdg-open") url)]
    [else #f]))

(define (open-browser url)
  (define cmd (browser-argv url))
  (cond
    [cmd
     (define-values (sp out in err)
       (apply subprocess #f #f #f cmd))
     (close-output-port in)
     (close-input-port out)
     (close-input-port err)
     (subprocess-wait sp)
     #t]
    [else #f]))

(define (parse-query qs)
  (define acc (make-hash))
  (for ([pair (in-list (string-split qs "&"))])
    (define kv (string-split pair "="))
    (when (pair? kv)
      (hash-set! acc (car kv) (if (null? (cdr kv)) "" (cadr kv)))))
  acc)

(define (url-decode-query s)
  (define out (open-output-string))
  (define bs (string->bytes/utf-8 s))
  (let loop ([i 0])
    (cond
      [(>= i (bytes-length bs)) (void)]
      [(= (bytes-ref bs i) 43) ; +
       (write-byte 32 out)
       (loop (add1 i))]
      [(and (= (bytes-ref bs i) 37) ; %
            (< (+ i 2) (bytes-length bs)))
       (define hi (string->number (string (integer->char (bytes-ref bs (+ i 1)))) 16))
       (define lo (string->number (string (integer->char (bytes-ref bs (+ i 2)))) 16))
       (if (and hi lo)
           (begin (write-byte (+ (* hi 16) lo) out) (loop (+ i 3)))
           (begin (write-byte (bytes-ref bs i) out) (loop (add1 i))))]
      [else
       (write-byte (bytes-ref bs i) out)
       (loop (add1 i))]))
  (get-output-string out))

(define (accept-oauth-loop listener result)
  (let loop ()
    (with-handlers ([exn:fail? (lambda (_e) (void))])
      (define-values (in out) (tcp-accept listener))
      (define line (read-line in 'any))
      (define path
        (match (string-split (if (string? line) line "") " ")
          [(list _ p _ ...) p]
          [_ ""]))
      (define qpos (regexp-match #rx"\\?(.*)$" path))
      (when qpos
        (define q (parse-query (cadr qpos)))
        (define code (hash-ref q "code" #f))
        (when (and code (non-empty-string? code))
          (set-box! result
                    (list (url-decode-query code)
                          (url-decode-query (hash-ref q "state" ""))))))
      (display "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n" out)
      (display (if (unbox result)
                   "<html><body><p>rho login complete. You can close this tab.</p></body></html>"
                   "<html><body><p>rho is still waiting for the auth code.</p></body></html>")
               out)
      (close-output-port out)
      (close-input-port in)
      (unless (unbox result)
        (loop)))))

;; Block until a browser hits loopback:port with ?code=, or timeout.
;; Listens on 127.0.0.1 and ::1 only (not all interfaces) so a LAN peer
;; cannot steal the auth code; macOS `localhost` still works via ::1.
;; Returns (list code state) or #f.
(define (oauth-wait-code port timeout-sec)
  (define listeners
    (filter
     values
     (for/list ([host '("127.0.0.1" "::1")])
       (with-handlers ([exn:fail? (lambda (_e) #f)])
         (tcp-listen port 8 #t host)))))
  (when (null? listeners)
    (error 'oauth-wait-code "could not bind loopback on port ~a" port))
  (define result (box #f))
  (define threads
    (for/list ([listener (in-list listeners)])
      (thread (lambda () (accept-oauth-loop listener result)))))
  (define deadline (+ (current-inexact-milliseconds) (* 1000.0 timeout-sec)))
  (let wait ()
    (cond
      [(unbox result) (void)]
      [(> (current-inexact-milliseconds) deadline) (void)]
      [else (sleep 0.2) (wait)]))
  (for ([th (in-list threads)])
    (with-handlers ([exn:fail? void])
      (kill-thread th)))
  (for ([listener (in-list listeners)])
    (with-handlers ([exn:fail? void])
      (tcp-close listener)))
  (unbox result))
