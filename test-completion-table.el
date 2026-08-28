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
                            (cycle-sort-function . identity)
                            (eager-display . t)
                            (eager-update . t)))
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

;; Compatibility across completion styles (all-completions, fuzzy
;; query "emc"): basic-family styles do not re-filter; flex shares
;; the subsequence semantics, so candidates survive (ordering then
;; follows flex's own cost model); the fz-index style preserves our
;; scoring.  (orderless with its default regexp matching WOULD drop
;; them -- hence fz-index-read-file binds (fz-index).)
(clrhash fz-index--indexes)
(let ((user-emacs-directory "/tmp/fz-ct-uem2/")
      (table (fz-index-completion-table "/tmp/fz-ct/"))
      (deadline (+ (float-time) 30)))
  (make-directory user-emacs-directory t)
  (funcall table "x" nil 'all-completions)
  (while (and (not (let ((h (gethash "/tmp/fz-ct/" fz-index--indexes)))
                     (and h (fz-index-ready-p h))))
              (< (float-time) deadline))
    (accept-process-output nil 0.05))
  (dolist (style '(basic partial-completion emacs22 flex fz-index))
    (let ((completion-styles (list style)))
      (unless (equal (all-completions "emc" table) '("src/emacs.c"))
        (error "BUG: style %s lost fuzzy candidates => %S"
               style (all-completions "emc" table)))))
  (princ "style compatibility tests passed\n"))

;; History and frecency: empty input lists the open history and
;; recorded opens boost query results -- the same candidates
;; `fz-index--update' shows in the main UI.  Point the history file
;; at a temp path so the kill-emacs save hook does not touch the
;; real one.
(setq fz-index-history-file "/tmp/fz-ct-uem3/history.el")
(clrhash fz-index--indexes)
(clrhash fz-index--history)
(let ((user-emacs-directory "/tmp/fz-ct-uem3/")
      (table (fz-index-completion-table "/tmp/fz-ct/"))
      (deadline (+ (float-time) 30)))
  (make-directory user-emacs-directory t)
  (funcall table "x" nil 'all-completions)
  (while (and (not (let ((h (gethash "/tmp/fz-ct/" fz-index--indexes)))
                     (and h (fz-index-ready-p h))))
              (< (float-time) deadline))
    (accept-process-output nil 0.05))
  ;; Empty input, empty history: no candidates.
  (when (funcall table "" nil 'all-completions)
    (error "BUG: empty input with empty history => %S"
           (funcall table "" nil 'all-completions)))
  ;; Record an open; empty input now lists it.
  (fz-index--record "/tmp/fz-ct/src/main.c")
  (unless (equal (funcall table "" nil 'all-completions) '("src/main.c"))
    (error "BUG: empty input with history => %S"
           (funcall table "" nil 'all-completions)))
  ;; Both files match "m"; with a large boost the recorded one wins.
  (unless (= (length (funcall table "m" nil 'all-completions)) 2)
    (error "BUG: query m => %S" (funcall table "m" nil 'all-completions)))
  (let ((fz-index-frecency-max-boost 10000))
    (unless (equal (car (funcall table "m" nil 'all-completions))
                   "src/main.c")
      (error "BUG: frecency boost did not reorder => %S"
             (funcall table "m" nil 'all-completions))))
  ;; fz-index-read-file records the chosen file in the history.
  (cl-letf (((symbol-function 'completing-read)
             (lambda (&rest _) "src/emacs.c"))
            ((symbol-function 'find-file) (lambda (&rest _) nil)))
    (let ((default-directory "/tmp/fz-ct/"))
      (fz-index-read-file "x: ")))
  (unless (fz-index--history-entry "/tmp/fz-ct/src/emacs.c")
    (error "BUG: fz-index-read-file did not record the open"))
  (princ "history/frecency tests passed\n"))

(let ((h (gethash "/tmp/fz-ct/" fz-index--indexes)))
  (when h (fz-index-destroy h)))
(clrhash fz-index--indexes)
(delete-file "/tmp/fz-ct/src/emacs.c")
(delete-file "/tmp/fz-ct/src/main.c")
(delete-directory "/tmp/fz-ct/src")
(delete-directory "/tmp/fz-ct")
(delete-directory "/tmp/fz-ct-uem" t)
(delete-directory "/tmp/fz-ct-uem2" t)
(delete-directory "/tmp/fz-ct-uem3" t)
(princ "completion-table tests done\n")
