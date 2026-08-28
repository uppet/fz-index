;;; Age-based background refresh of live indexes.  -*- lexical-binding: t; -*-
(module-load (expand-file-name "./fz-index.so"))
(load (expand-file-name "./fz-index.elc") nil t)

(make-directory "/tmp/fz-age/sub" t)
(write-region "" nil "/tmp/fz-age/a.c" nil 'silent)
(write-region "" nil "/tmp/fz-age/sub/b.c" nil 'silent)

(let ((user-emacs-directory "/tmp/fz-age-uem/")
      (fz-index-max-age 0.2)          ; expire almost immediately
      (deadline (+ (float-time) 30)))
  ;; Start clean: a leftover cache would make the first index-for a
  ;; cache load, whose background refresh swaps the handle early.
  (delete-directory "/tmp/fz-age-uem" t)
  (make-directory user-emacs-directory t)
  (clrhash fz-index--indexes)
  (clrhash fz-index--index-times)
  (clrhash fz-index--refreshing)

  ;; First build.
  (fz-index--index-for "/tmp/fz-age/")
  (let ((deadline2 (+ (float-time) 30)))
    (while (zerop (gethash "/tmp/fz-age/" fz-index--index-times 0))
      (when (> (float-time) deadline2)
        (error "timeout waiting for first build"))
      (accept-process-output nil 0.05)))
  (let ((h1 (gethash "/tmp/fz-age/" fz-index--indexes)))
    ;; Young index: no refresh triggered.
    (unless (eq (fz-index--index-for "/tmp/fz-age/") h1)
      (error "BUG: young index not returned as-is"))
    (when (gethash "/tmp/fz-age/" fz-index--refreshing)
      (error "BUG: refresh triggered for a young index"))

    ;; Age it past the threshold: next call refreshes in background
    ;; but keeps serving the old handle.
    (sleep-for 0.3)
    (unless (eq (fz-index--index-for "/tmp/fz-age/") h1)
      (error "BUG: aged index not served while refreshing"))
    (unless (gethash "/tmp/fz-age/" fz-index--refreshing)
      (error "BUG: refresh not triggered for an aged index"))
    ;; A second call must not start a duplicate rescan.
    (let ((proc (gethash "/tmp/fz-age/" fz-index--refreshing)))
      (fz-index--index-for "/tmp/fz-age/")
      (unless (eq proc (gethash "/tmp/fz-age/" fz-index--refreshing))
        (error "BUG: duplicate refresh started")))
    ;; Wait for the rescan: handle is swapped, time is updated.
    (while (and (eq (gethash "/tmp/fz-age/" fz-index--indexes) h1)
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (let ((h2 (gethash "/tmp/fz-age/" fz-index--indexes)))
      (when (eq h2 h1)
        (error "BUG: aged handle was not swapped after rescan"))
      (unless (= (fz-index-count h2) 2)
        (error "BUG: refreshed count %s, expected 2" (fz-index-count h2))))
    (princ "age-refresh tests passed\n"))

  ;; fz-index-reset cleans up refresh state too.
  (sleep-for 0.3)
  (fz-index--index-for "/tmp/fz-age/")
  (fz-index-reset "/tmp/fz-age/")
  (when (or (gethash "/tmp/fz-age/" fz-index--indexes)
            (gethash "/tmp/fz-age/" fz-index--refreshing)
            (gethash "/tmp/fz-age/" fz-index--index-times))
    (error "BUG: reset left refresh state behind"))
  (princ "reset-cleanup tests passed\n"))

(delete-file "/tmp/fz-age/a.c")
(delete-file "/tmp/fz-age/sub/b.c")
(delete-directory "/tmp/fz-age/sub")
(delete-directory "/tmp/fz-age")
(delete-directory "/tmp/fz-age-uem" t)
(princ "refresh tests done\n")
