;;; Symlink handling in the scanner.  -*- lexical-binding: t; -*-
;;; Directory links are not followed (a loop must not keep the scan
;;; growing); symlinked files are indexed.
(module-load (expand-file-name "./fz-index.so"))

(defun fz--symlink-fixture-clean ()
  "Delete the fixture from a possible earlier run.
`delete-file' removes each symlink itself, never its target."
  (dolist (f '("/tmp/fz-link/loop" "/tmp/fz-link/link.c"
               "/tmp/fz-link/dirlink" "/tmp/fz-link/a.c"
               "/tmp/fz-link/sub/b.c"))
    (ignore-errors (delete-file f)))
  (ignore-errors (delete-directory "/tmp/fz-link/sub"))
  (ignore-errors (delete-directory "/tmp/fz-link")))

;; Leftover links would make make-symbolic-link fail with "file
;; exists" below, so start from a clean fixture.
(fz--symlink-fixture-clean)
(make-directory "/tmp/fz-link/sub" t)
(write-region "" nil "/tmp/fz-link/a.c" nil 'silent)
(write-region "" nil "/tmp/fz-link/sub/b.c" nil 'silent)
(make-symbolic-link "." "/tmp/fz-link/loop")
(make-symbolic-link "a.c" "/tmp/fz-link/link.c")
(make-symbolic-link "sub" "/tmp/fz-link/dirlink")

(let ((h (fz-index-build "/tmp/fz-link/"))
      (deadline (+ (float-time) 30)))
  (while (and (not (fz-index-ready-p h)) (< (float-time) deadline))
    (accept-process-output nil 0.05))
  (unless (fz-index-ready-p h)
    (error "BUG: scan with a symlink loop never finished"))
  (unless (= (fz-index-count h) 3)
    (error "BUG: count %s, expected 3 (a.c, link.c, sub/b.c)"
           (fz-index-count h)))
  (unless (member "link.c" (mapcar #'car (fz-query h "link" 10)))
    (error "BUG: symlinked file link.c not indexed"))
  (when (mapcar #'car (fz-query h "dirlink" 10))
    (error "BUG: symlinked directory dirlink was descended into"))
  (fz-index-destroy h)
  (princ "symlink tests passed\n"))

(fz--symlink-fixture-clean)
(princ "symlink tests done\n")
