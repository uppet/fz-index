;;; Multi-word (space-separated AND) query tests.  -*- lexical-binding: t; -*-
(module-load (expand-file-name "./fz-index.so"))
(require 'cl-lib)

(make-directory "/tmp/fz-mw/src" t)
(make-directory "/tmp/fz-mw/doc" t)
(make-directory "/tmp/fz-mw/tests" t)
(dolist (f '("src/emacs.c" "src/main.c" "doc/emacs-intro.txt"
             "tests/emacs-tests.el" "src/canvas.c"))
  (write-region "" nil (concat "/tmp/fz-mw/" f) nil 'silent))

(let ((h (fz-index-build "/tmp/fz-mw/")))
  (while (not (fz-index-ready-p h))
    (sleep-for 0.005))
  (cl-flet ((top1 (q) (caar (fz-query h q 5)))
            (hits (q) (mapcar #'car (fz-query h q 20))))
    ;; Both words must match; best alignment wins.
    (unless (equal (top1 "emacs c") "src/emacs.c")
      (error "BUG: top1 of \"emacs c\" => %S" (top1 "emacs c")))
    ;; Word order does not matter.
    (unless (equal (top1 "c emacs") "src/emacs.c")
      (error "BUG: top1 of \"c emacs\" => %S" (top1 "c emacs")))
    ;; Directory word + name word.
    (unless (equal (top1 "tests emacs") "tests/emacs-tests.el")
      (error "BUG: top1 of \"tests emacs\" => %S" (top1 "tests emacs")))
    ;; Extra whitespace is ignored.
    (unless (equal (top1 "  emacs   c ") "src/emacs.c")
      (error "BUG: top1 with extra spaces => %S" (top1 "  emacs   c ")))
    ;; A word that matches nothing rejects the whole query.
    (when (hits "emacs zzz")
      (error "BUG: \"emacs zzz\" should have no hits => %S"
             (hits "emacs zzz")))
    ;; AND narrows the single-word result set: "c" alone also matches
    ;; canvas.c and main.c, "emacs c" must not contain them.
    (let ((hs (hits "emacs c")))
      (when (or (member "src/canvas.c" hs) (member "src/main.c" hs))
        (error "BUG: \"emacs c\" leaked non-emacs hits => %S" hs)))
    ;; Incremental narrowing still works across word additions:
    ;; query "emacs" first, then "emacs c" must reuse it correctly.
    (hits "emacs")
    (unless (equal (top1 "emacs c") "src/emacs.c")
      (error "BUG: narrowing \"emacs\" -> \"emacs c\" => %S"
             (top1 "emacs c")))
    (princ "multiword tests passed\n"))
  (fz-index-destroy h))

(dolist (f '("src/emacs.c" "src/main.c" "doc/emacs-intro.txt"
             "tests/emacs-tests.el" "src/canvas.c"))
  (delete-file (concat "/tmp/fz-mw/" f)))
(delete-directory "/tmp/fz-mw/src")
(delete-directory "/tmp/fz-mw/doc")
(delete-directory "/tmp/fz-mw/tests")
(delete-directory "/tmp/fz-mw")
