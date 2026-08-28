;;; Completion table integration tests.  -*- lexical-binding: t; -*-
(module-load (expand-file-name "./fz-index.so"))
(load (expand-file-name "./fz-index.elc") nil t)
(require 'cl-lib)

(make-directory "/tmp/fz-ct/src" t)
(write-region "" nil "/tmp/fz-ct/src/emacs.c" nil 'silent)
(write-region "" nil "/tmp/fz-ct/src/main.c" nil 'silent)

(clrhash fz-index--indexes)
(let ((user-emacs-directory "/tmp/fz-ct-uem/")
      (table (fz-index-completion-table "/tmp/fz-ct/"))
      (deadline (+ (float-time) 30)))
  (make-directory user-emacs-directory t)
  ;; Querying the table starts the background build; wait for it.
  (funcall table "x" nil 'all-completions)
  (while (and (not (let ((h (gethash "/tmp/fz-ct/" fz-index--indexes)))
                     (and h (fz-index-ready-p h))))
              (< (float-time) deadline))
    (accept-process-output nil 0.05))

  ;; Table protocol: metadata, all-completions, try-completion.
  (unless (equal (funcall table "" nil 'metadata)
                 '(metadata (category . fz-index)
                            (display-sort-function . identity)
                            (cycle-sort-function . identity)))
    (error "BUG: metadata => %S" (funcall table "" nil 'metadata)))
  (let ((all (funcall table "emacs" nil 'all-completions)))
    (unless (equal all '("src/emacs.c"))
      (error "BUG: all-completions emacs => %S" all)))
  (unless (equal (funcall table "ema" nil nil) "ema")
    (error "BUG: try-completion should return input unchanged"))

  ;; With the fz-index style, all-completions returns the fuzzy
  ;; candidates unfiltered.  The basic style works too: matching is
  ;; table-driven, so default completion UIs need no configuration.
  (let ((completion-styles '(fz-index)))
    (unless (equal (all-completions "emacs.c" table)
                   '("src/emacs.c"))
      (error "BUG: fz-index style all-completions => %S"
             (all-completions "emacs.c" table))))
  (let ((completion-styles '(basic)))
    (unless (equal (all-completions "emacs.c" table)
                   '("src/emacs.c"))
      (error "BUG: basic style all-completions => %S"
             (all-completions "emacs.c" table))))
  (princ "completion-table tests passed\n"))

(let ((h (gethash "/tmp/fz-ct/" fz-index--indexes)))
  (when h (fz-index-destroy h)))
(clrhash fz-index--indexes)
(delete-file "/tmp/fz-ct/src/emacs.c")
(delete-file "/tmp/fz-ct/src/main.c")
(delete-directory "/tmp/fz-ct/src")
(delete-directory "/tmp/fz-ct")
(delete-directory "/tmp/fz-ct-uem" t)
(princ "completion-table tests done\n")
