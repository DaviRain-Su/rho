#lang racket/base

;; Tiny mutex for module-level mutable state shared with background threads.

(provide make-lock
         with-lock)

(define (make-lock)
  (make-semaphore 1))

(define (with-lock lock thunk)
  (call-with-semaphore lock thunk))
