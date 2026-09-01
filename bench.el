;;; bench.el --- Reproducible build/query benchmark for fz-index. -*- lexical-binding: t; -*-
;;;
;;; Usage:
;;;   emacs -Q --batch -L . -l bench.el [ROOT]
;;;
;;; Builds the index for ROOT, times the build, then times
;;; representative single-word, multi-word, no-match and incremental
;;; narrowing queries.  It prints the machine and Emacs identity so
;;; numbers from different runs can be compared, and reports the file
;;; count and a path-length sample so the tree shape is documented.
;;;
;;; For a Chromium-scale tree, generate one first:
;;;   gcc -O2 -std=c99 bench-gen-tree.c -o bench-gen-tree
;;;   ./bench-gen-tree /tmp/bench-tree 400000
;;;   emacs -Q --batch -L . -l bench.el /tmp/bench-tree
;;;
;;; Each query below is repeated 20 times and averaged; the narrowing
;;; sequence exercises the incremental-narrowing path (each keystroke
;;; rescoring only the previous match set).

(require 'subr-x)

(module-load (expand-file-name (concat "fz-index" module-file-suffix)))

(defconst bench-root
  (or (car command-line-args-left)
      (error "usage: emacs -Q --batch -L . -l bench.el [ROOT]")))

(defun bench--time-query (handle pattern limit reps)
  "Run `fz-query' on HANDLE with PATTERN/LIMIT, REPS times, return ms/query."
  (let ((t0 (float-time)))
    (dotimes (_ reps)
      (fz-query handle pattern limit))
    (* 1000 (/ (- (float-time) t0) (float reps)))))

(defun bench--avg-rel-len (handle limit)
  "Average relative path length of the first LIMIT entries, or nil."
  (let ((hits (fz-query handle "" limit)))
    (when hits
      (/ (float (apply #'+ (mapcar #'length (mapcar #'car hits))))
         (length hits)))))

(princ (format "bench: emacs %s (%s %s)\n"
               emacs-version system-type system-configuration))
(princ (format "bench: root %s\n" bench-root))

(let* ((t0 (float-time))
       (h (fz-index-build bench-root))
       (deadline (+ (float-time) 60)))
  (while (and (not (fz-index-ready-p h)) (< (float-time) deadline))
    (sleep-for 0.01))
  (unless (fz-index-ready-p h)
    (error "bench: index build did not finish within 60s"))
  (let ((build (- (float-time) t0))
        (count (fz-index-count h)))
    (princ (format "bench: index build %.3f s, %d files\n" build count))
    (when-let ((avg (bench--avg-rel-len h 100)))
      (princ (format "bench: sample avg rel path %.1f bytes\n" avg)))
    (dolist (q '("emacs.c" "util hash" "render frame" "zzz-nonexistent"))
      (princ (format "bench: query %-16s %7.2f ms/query\n"
                     q (bench--time-query h q 100 20))))
    (let ((t1 (float-time)))
      (dolist (pat '("e" "em" "ema" "emac" "emacs"))
        (fz-query h pat 100))
      (princ (format "bench: narrowing e->emacs %7.2f ms/step\n"
                     (* 1000 (/ (- (float-time) t1) 5.0)))))
    (fz-index-destroy h)))

(princ "bench: done\n")
