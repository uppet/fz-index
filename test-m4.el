;;; Test frecency re-sort and history persistence.  -*- lexical-binding: t; -*-
(module-load (expand-file-name "./fz-index.so"))
(load (expand-file-name "./fz-index.elc") nil t)

(let ((fz-index--history (make-hash-table :test 'equal)))
  (fz-index--record "/proj/src/old-favorite.c")
  (fz-index--record "/proj/src/old-favorite.c")
  (fz-index--record "/proj/src/old-favorite.c")
  (let* ((cands '(("src/emacs.c" 87 nil) ("src/old-favorite.c" 60 nil)
                  ("src/macros.c" 70 nil)))
         (res (fz-index--apply-frecency cands "/proj/")))
    ;; old-favorite: 60 + min(40, 8*3)=24 -> 84, still below emacs.c(87)
    ;; macros.c stays 70
    (princ (format "order after frecency: %s\n"
                   (mapcar #'car res)))
    ;; one more record pushes it to the top
    (fz-index--record "/proj/src/old-favorite.c")
    (fz-index--record "/proj/src/old-favorite.c")
    (fz-index--record "/proj/src/old-favorite.c")
    (fz-index--record "/proj/src/old-favorite.c")
    (fz-index--record "/proj/src/old-favorite.c")
    ;; count=8 -> bonus capped at 40 -> 100, tops the list
    (let ((res2 (fz-index--apply-frecency cands "/proj/")))
      (princ (format "after more opens: %s\n" (mapcar #'car res2))))))

;; persistence round-trip
(let ((fz-index-history-file (make-temp-file "fz-index-history-test")))
  (let ((fz-index--history (make-hash-table :test 'equal)))
    (puthash "/a/b.c" 3 fz-index--history)
    (puthash "/a/d.c" 1 fz-index--history)
    (fz-index--history-save))
  (let ((fz-index--history (make-hash-table :test 'equal)))
    ;; load into the dynamic binding: call with our table
    (let ((loaded (make-hash-table :test 'equal)))
      (with-temp-buffer
        (insert-file-contents fz-index-history-file)
        (goto-char (point-min))
        (dolist (e (read (current-buffer)))
          (puthash (car e) (cdr e) loaded)))
      (princ (format "persist round-trip: /a/b.c=%s /a/d.c=%s\n"
                     (gethash "/a/b.c" loaded) (gethash "/a/d.c" loaded)))))
  (delete-file fz-index-history-file))
(princ "M4 elisp tests done\n")
