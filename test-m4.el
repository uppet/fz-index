;;; Test frecency re-sort (log2 + half-life decay) and persistence. -*- lexical-binding: t; -*-
(module-load (expand-file-name (concat "fz-index-core" module-file-suffix)))
(load (expand-file-name "./fz-index.elc") nil t)

(let ((fz-index--history (make-hash-table :test 'equal)))
  (dotimes (_ 3)
    (fz-index--record (expand-file-name "/proj/src/old-favorite.c")))
  (let* ((cands '(("src/emacs.c" 87 nil) ("src/old-favorite.c" 60 nil)
                  ("src/macros.c" 70 nil)))
         (res (fz-index--apply-frecency cands "/proj/")))
    ;; old-favorite: 60 + 8*log2(4)=16 -> 76, still below emacs.c(87).
    (unless (equal (mapcar #'car res)
                   '("src/emacs.c" "src/old-favorite.c" "src/macros.c"))
      (error "BUG: order after frecency: %s" (mapcar #'car res)))
    (princ (format "order after frecency: %s\n" (mapcar #'car res)))
    ;; 31 opens total: 8*log2(32)=40, capped at 40 -> 100, tops the list.
    (dotimes (_ 28)
      (fz-index--record (expand-file-name "/proj/src/old-favorite.c")))
    (let ((res2 (fz-index--apply-frecency cands "/proj/")))
      (unless (equal (car (car res2)) "src/old-favorite.c")
        (error "BUG: frecency did not top the list: %s" (mapcar #'car res2)))
      (princ (format "after 31 opens: %s\n" (mapcar #'car res2))))))

;; Decay: an entry opened 30 days ago scores far below a fresh one.
(let ((fz-index--history (make-hash-table :test 'equal))
      (fz-index-frecency-half-life 7))
  (puthash "/proj/fresh.c" (cons 8 (float-time)) fz-index--history)
  (puthash "/proj/stale.c"
           (cons 8 (- (float-time) (* 30 86400))) fz-index--history)
  (let ((fresh (fz-index--frecency-score "/proj/fresh.c"))
        (stale (fz-index--frecency-score "/proj/stale.c")))
    (unless (and (> stale 0) (< stale (/ fresh 4)))
      (error "BUG: decay wrong: fresh=%s stale=%s" fresh stale))
    (princ (format "decay: fresh=%.2f stale=%.2f\n" fresh stale)))
  ;; Legacy integer entries read as (count . 0) and do not decay.
  (puthash "/proj/legacy.c" 5 fz-index--history)
  (unless (= (fz-index--frecency-score "/proj/legacy.c")
             (log 6 2))
    (error "BUG: legacy entry score %s"
           (fz-index--frecency-score "/proj/legacy.c")))
  (princ "legacy integer entries OK\n"))

;; Persistence round-trip: new (count . ts) format, plus legacy
;; integer migration on load.
(let ((fz-index-history-file (make-temp-file "fz-index-history-test")))
  (let ((fz-index--history (make-hash-table :test 'equal)))
    (fz-index--record "/a/b.c")
    (fz-index--record "/a/b.c")
    (fz-index--record "/a/b.c")
    (fz-index--record "/a/d.c")
    (fz-index--history-save))
  (let ((fz-index--history (make-hash-table :test 'equal)))
    (fz-index--history-load)
    (let ((b (fz-index--history-entry "/a/b.c"))
          (d (fz-index--history-entry "/a/d.c")))
      (unless (and (= (car b) 3) (= (car d) 1) (> (cdr b) 0))
        (error "BUG: persist round-trip: b=%S d=%S" b d))
      (princ (format "persist round-trip: /a/b.c=(%d . ts) /a/d.c=(%d . ts)\n"
                     (car b) (car d)))))
  ;; Legacy file format: integers migrate to undecayed entries.
  (with-temp-file fz-index-history-file
    (prin1 '(("/x/y.c" . 4)) (current-buffer)))
  (let ((fz-index--history (make-hash-table :test 'equal)))
    (fz-index--history-load)
    (let ((y (fz-index--history-entry "/x/y.c")))
      (unless (and (= (car y) 4) (> (cdr y) 0))
        (error "BUG: legacy migration: %S" y))
      (princ "legacy file migration OK\n")))
  (delete-file fz-index-history-file))

;; fz-index--ensure-history: when the load fails (here the history
;; file is a directory, which insert-file-contents cannot read), the
;; error propagates, the loaded flag stays unset and the save hook
;; unarmed, so the next search retries; with a readable file the
;; retry loads it and arms the hook.  The history table, the loaded
;; flag and kill-emacs-hook are let-bound, so the global state stays
;; untouched; unwind-protect removes the temp path (a directory,
;; later a file) even when an assertion fails.
(let ((fz-index-history-file (make-temp-file "fz-hist-dir" t))
      (fz-index--history (make-hash-table :test 'equal))
      (fz-index--history-loaded nil)
      (kill-emacs-hook nil))
  (unwind-protect
      (progn
        (unless (condition-case nil
                    (progn (fz-index--ensure-history) nil)
                  (file-error t))
          (error "BUG: unreadable history file did not signal file-error"))
        (when fz-index--history-loaded
          (error "BUG: loaded flag set despite the failed load"))
        (when (member #'fz-index--history-save kill-emacs-hook)
          (error "BUG: save hook armed despite the failed load"))
        (delete-directory fz-index-history-file)
        (with-temp-file fz-index-history-file
          (prin1 (list (cons "/retry/a.c" (cons 4 (float-time))))
                 (current-buffer)))
        (fz-index--ensure-history)
        (unless fz-index--history-loaded
          (error "BUG: retry after a failed load did not set the flag"))
        (unless (member #'fz-index--history-save kill-emacs-hook)
          (error "BUG: retry after a failed load did not arm the save hook"))
        (let ((e (fz-index--history-entry "/retry/a.c")))
          (unless (and e (= (car e) 4))
            (error "BUG: retry did not load the history: %S" e)))
        (princ "ensure-history retry tests passed\n"))
    (if (file-directory-p fz-index-history-file)
        (delete-directory fz-index-history-file)
      (when (file-exists-p fz-index-history-file)
        (delete-file fz-index-history-file)))))
(princ "M4 elisp tests done\n")
