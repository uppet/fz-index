;;; Regression test for fz-index M3.  -*- lexical-binding: t; -*-
(module-load (expand-file-name (concat "fz-index" module-file-suffix)))

(let ((ix (fz-index-build "/tmp/fz-index-bench")))
  (let ((t0 (float-time)) (deadline (+ (float-time) 10)))
    (while (and (not (fz-index-ready-p ix)) (< (float-time) deadline))
      (sleep-for 0.05))
    (princ (format "async build: %.2fs count=%d\n"
                   (- (float-time) t0) (fz-index-count ix))))
  (dolist (pat (list "m" "mod1" "file42" "nonexistentzzz"))
    (let ((res (benchmark-run 20 (fz-query ix pat 100))))
      (princ (format "cold  %-14s %6.1fms\n" pat (* 1000 (car res))))))
  (fz-query ix "mod1" 100)
  (let ((res (benchmark-run 20 (fz-query ix "mod14" 100))))
    (princ (format "narrow mod1->14  %6.1fms\n" (* 1000 (car res)))))
  (fz-index-destroy ix))

(let ((ix (fz-index-build "/home/joyer/bld")))
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (fz-index-ready-p ix)) (< (float-time) deadline))
      (sleep-for 0.05)))
  (princ (format "top1 emacs.c in /home/joyer/bld: %s\n"
                 (caar (fz-query ix "emacs.c" 1))))
  (fz-index-destroy ix))
