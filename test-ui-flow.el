;;; Integration: scripted query -> navigate -> RET opens the right file. -*- lexical-binding: t; -*-
(module-load (expand-file-name "./fz-index.so"))
(load (expand-file-name "./fz-index.elc") nil t)
(require 'cl-lib)

;; Keep the on-disk index cache out of the real user directory.
(setq user-emacs-directory "/tmp/fz-flow-uem/")
(make-directory user-emacs-directory t)

;; Batch read-from-minibuffer reads stdin and never runs the setup
;; hook, so mock it: run the setup hook (initial update), then replay
;; "type QUERY, move down MOVES times" and return the input, as RET
;; would.  find-file is mocked to record what the session opens.
(defun fz-index-test--run-session (root query moves)
  (let ((opened nil)
        (input "")
        (default-directory root)
        (fz-index--history (make-hash-table :test 'equal))
        (fz-index-preview-enabled nil))
    (cl-letf (((symbol-function 'find-file)
               (lambda (f) (setq opened (cons 'find-file f))))
              ((symbol-function 'minibuffer-contents) (lambda () input))
              ((symbol-function 'read-from-minibuffer)
               (lambda (&rest _)
                 (run-hooks 'minibuffer-setup-hook)
                 (setq input query)
                 (fz-index--update)          ; what post-command-hook would do
                 (dotimes (_ moves) (fz-index--next))
                 input)))
      (fz-index-open-file))
    opened))

;; Small fixture tree; the index is pre-built so queries are answered.
(make-directory "/tmp/fz-index-flow/sub" t)
(write-region "" nil "/tmp/fz-index-flow/backup.c" nil 'silent)
(write-region "" nil "/tmp/fz-index-flow/sub/backup-extra.c" nil 'silent)
(write-region "" nil "/tmp/fz-index-flow/other.c" nil 'silent)
(let ((h (fz-index-build "/tmp/fz-index-flow/")))
  (while (not (fz-index-ready-p h))
    (sleep-for 0.005))
  (puthash "/tmp/fz-index-flow/" h fz-index--indexes))

;; RET opens the first candidate; C-n RET opens the second; both must
;; be the two backup* fixtures and must differ (i.e. C-n took effect).
(let* ((first (fz-index-test--run-session "/tmp/fz-index-flow/" "backu" 0))
       (second (fz-index-test--run-session "/tmp/fz-index-flow/" "backu" 1)))
  (princ (format "RET: %S\nC-n RET: %S\n" first second))
  (unless (and (equal (car first) 'find-file)
               (string-prefix-p "/tmp/fz-index-flow/" (cdr first))
               (string-match-p "backup" (cdr first)))
    (error "BUG: RET opened %S, expected a backup* fixture" first))
  (unless (and (equal (car second) 'find-file)
               (string-match-p "backup" (cdr second))
               (not (equal first second)))
    (error "BUG: C-n RET opened %S, expected the other backup* fixture"
           second)))

(when-let* ((h (gethash "/tmp/fz-index-flow/" fz-index--indexes)))
  (fz-index-destroy h)
  (remhash "/tmp/fz-index-flow/" fz-index--indexes))
(delete-file "/tmp/fz-index-flow/backup.c")
(delete-file "/tmp/fz-index-flow/sub/backup-extra.c")
(delete-file "/tmp/fz-index-flow/other.c")
(delete-directory "/tmp/fz-index-flow/sub")
(delete-directory "/tmp/fz-index-flow")
(princ "ui flow tests done\n")
(delete-directory "/tmp/fz-flow-uem" t)
