;;; Completion table integration tests.  -*- lexical-binding: t; -*-
(module-load (expand-file-name (concat "fz-index" module-file-suffix)))
(load (expand-file-name "./fz-index.elc") nil t)
(require 'cl-lib)

;; One expanded root per fixture: on Windows expand-file-name maps
;; "/tmp" onto the current drive's \tmp, so a raw "/tmp/..." string
;; would not match the keys the code under test derives from the
;; root (history records, index table entries, prefix checks).
(defconst fz-ct-root
  (file-name-as-directory (expand-file-name "/tmp/fz-ct/")))
(defconst fz-os-root
  (file-name-as-directory (expand-file-name "/tmp/fz-os/")))

(make-directory (concat fz-ct-root "src") t)
(write-region "" nil (concat fz-ct-root "src/emacs.c") nil 'silent)
(write-region "" nil (concat fz-ct-root "src/main.c") nil 'silent)

(clrhash fz-index--indexes)
(let ((user-emacs-directory "/tmp/fz-ct-uem/")
      (table (fz-index-completion-table fz-ct-root))
      (deadline (+ (float-time) 30)))
  (make-directory user-emacs-directory t)
  ;; Querying the table starts the background build; wait for it.
  (funcall table "x" nil 'all-completions)
  (while (and (not (let ((h (gethash fz-ct-root fz-index--indexes)))
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
      (table (fz-index-completion-table fz-ct-root))
      (deadline (+ (float-time) 30)))
  (make-directory user-emacs-directory t)
  (funcall table "x" nil 'all-completions)
  (while (and (not (let ((h (gethash fz-ct-root fz-index--indexes)))
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
      (table (fz-index-completion-table fz-ct-root))
      (deadline (+ (float-time) 30)))
  (make-directory user-emacs-directory t)
  (funcall table "x" nil 'all-completions)
  (while (and (not (let ((h (gethash fz-ct-root fz-index--indexes)))
                     (and h (fz-index-ready-p h))))
              (< (float-time) deadline))
    (accept-process-output nil 0.05))
  ;; Empty input, empty history: no candidates.
  (when (funcall table "" nil 'all-completions)
    (error "BUG: empty input with empty history => %S"
           (funcall table "" nil 'all-completions)))
  ;; Record an open; empty input now lists it.
  (fz-index--record (concat fz-ct-root "src/main.c"))
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
    (let ((default-directory fz-ct-root))
      (fz-index-read-file "x: ")))
  (unless (fz-index--history-entry (concat fz-ct-root "src/emacs.c"))
    (error "BUG: fz-index-read-file did not record the open"))
  (princ "history/frecency tests passed\n"))

;; Oversampling: a favorite whose raw score ranks beyond the display
;; limit must still surface when its frecency boost is large, and the
;; candidate list must trim back to `fz-index-query-limit'.  121
;; files all match "f"; the boosted one has the longest path, so its
;; raw score is the worst of the lot.
(let ((user-emacs-directory "/tmp/fz-os-uem/")
      (table (fz-index-completion-table fz-os-root))
      (deadline (+ (float-time) 30)))
  (make-directory (concat fz-os-root "src") t)
  (make-directory user-emacs-directory t)
  (dotimes (i 120)
    (write-region "" nil
                  (format (concat fz-os-root "src/f%03d.c") i) nil 'silent))
  (write-region "" nil (concat fz-os-root "src/m-favorite.c") nil 'silent)
  (funcall table "x" nil 'all-completions)
  (while (and (not (let ((h (gethash fz-os-root fz-index--indexes)))
                     (and h (fz-index-ready-p h))))
              (< (float-time) deadline))
    (accept-process-output nil 0.05))
  (let ((fz-index-frecency-boost 10000)
        (fz-index-frecency-max-boost 10000))
    (dotimes (_ 5)
      (fz-index--record (concat fz-os-root "src/m-favorite.c")))
    (let ((res (funcall table "f" nil 'all-completions)))
      (unless (= (length res) fz-index-query-limit)
        (error "BUG: oversample trim => %d candidates" (length res)))
      (unless (equal (car res) "src/m-favorite.c")
        (error "BUG: boosted favorite not surfaced, first => %S"
               (car res)))))
  (let ((h (gethash fz-os-root fz-index--indexes)))
    (when h (fz-index-destroy h)))
  (clrhash fz-index--indexes)
  (delete-directory (concat fz-os-root "src") t)
  (delete-directory fz-os-root)
  (delete-directory "/tmp/fz-os-uem" t)
  (princ "oversample tests passed\n"))

(let ((h (gethash fz-ct-root fz-index--indexes)))
  (when h (fz-index-destroy h)))
(clrhash fz-index--indexes)
(delete-file (concat fz-ct-root "src/emacs.c"))
(delete-file (concat fz-ct-root "src/main.c"))
(delete-directory (concat fz-ct-root "src"))
(delete-directory fz-ct-root)
(delete-directory "/tmp/fz-ct-uem" t)
(delete-directory "/tmp/fz-ct-uem2" t)
(delete-directory "/tmp/fz-ct-uem3" t)
(princ "completion-table tests done\n")
