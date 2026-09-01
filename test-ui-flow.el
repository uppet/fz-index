;;; Integration: scripted query -> navigate -> RET opens the right file. -*- lexical-binding: t; -*-
(module-load (expand-file-name (concat "fz-index" module-file-suffix)))
(load (expand-file-name "./fz-index.elc") nil t)
(require 'cl-lib)

;; Keep the on-disk index cache and history out of the real user
;; directory.  All fixture paths go through one expanded root: on
;; Windows expand-file-name maps "/tmp" to the current drive's \tmp,
;; so the raw string would not match the key fz-index--root uses.
(setq user-emacs-directory "/tmp/fz-flow-uem/")
(setq fz-index-history-file
      (expand-file-name "fz-flow-hist.el" user-emacs-directory))
(make-directory user-emacs-directory t)
(defconst fz-flow-root
  (file-name-as-directory (expand-file-name "/tmp/fz-index-flow/")))

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
(make-directory (concat fz-flow-root "sub") t)
(write-region "" nil (concat fz-flow-root "backup.c") nil 'silent)
(write-region "" nil (concat fz-flow-root "sub/backup-extra.c") nil 'silent)
(write-region "" nil (concat fz-flow-root "other.c") nil 'silent)
(let ((h (fz-index-build fz-flow-root))
      (deadline (+ (float-time) 30)))
  (while (and (not (fz-index-ready-p h)) (< (float-time) deadline))
    (sleep-for 0.005))
  (unless (fz-index-ready-p h)
    (error "BUG: flow index never became ready"))
  (puthash fz-flow-root h fz-index--indexes))

;; RET opens the first candidate; C-n RET opens the second; both must
;; be the two backup* fixtures and must differ (i.e. C-n took effect).
(let* ((first (fz-index-test--run-session fz-flow-root "backu" 0))
       (second (fz-index-test--run-session fz-flow-root "backu" 1)))
  (princ (format "RET: %S\nC-n RET: %S\n" first second))
  (unless (and (equal (car first) 'find-file)
               (string-prefix-p fz-flow-root (cdr first))
               (string-match-p "backup" (cdr first)))
    (error "BUG: RET opened %S, expected a backup* fixture" first))
  (unless (and (equal (car second) 'find-file)
               (string-match-p "backup" (cdr second))
               (not (equal first second)))
    (error "BUG: C-n RET opened %S, expected the other backup* fixture"
           second)))

(when-let* ((h (gethash fz-flow-root fz-index--indexes)))
  (fz-index-destroy h)
  (remhash fz-flow-root fz-index--indexes))
(delete-file (concat fz-flow-root "backup.c"))
(delete-file (concat fz-flow-root "sub/backup-extra.c"))
(delete-file (concat fz-flow-root "other.c"))
(delete-directory (concat fz-flow-root "sub"))
(delete-directory fz-flow-root)
(princ "ui flow tests done\n")
(delete-directory "/tmp/fz-flow-uem" t)
