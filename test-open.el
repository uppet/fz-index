;;; Regression test: RET on a previewed candidate must keep the file open. -*- lexical-binding: t; -*-
(module-load (expand-file-name (concat "fz-index" module-file-suffix)))
(load (expand-file-name "./fz-index.elc") nil t)

;; End-to-end: empty input shows history candidates; preview loads the
;; selected file into a transient buffer; RET must open the file and the
;; session cleanup must NOT kill that buffer (previously it did, so the
;; file "did not open").  Batch `read-from-minibuffer' skips the setup
;; hook and reads stdin, so mock it to run the hook and return "" (= RET).
;; Preview is debounced via an idle timer, which never fires in batch;
;; mock it to run immediately so the preview path stays covered.
(require 'cl-lib)
(let* ((root (file-name-as-directory (expand-file-name default-directory)))
       (abs (expand-file-name "fz-index.el" root))
       (fz-index--history (make-hash-table :test 'equal))
       (fz-index-preview-enabled t)
       (user-emacs-directory "/tmp/fz-open-uem/")
       (captured nil))
  (make-directory user-emacs-directory t)
  (puthash abs 3 fz-index--history)
  (cl-letf (((symbol-function 'minibuffer-contents) (lambda () ""))
            ((symbol-function 'run-with-idle-timer)
             (lambda (_secs _repeat fn &rest args)
               (apply fn args)
               nil))
            ((symbol-function 'read-from-minibuffer)
             (lambda (&rest args)
               (setq captured args)
               (run-hooks 'minibuffer-setup-hook)
               "")))
    (fz-index-open-file))
  ;; Queries go into their own minibuffer history (M-p / M-n).
  (unless (eq (nth 4 captured) 'fz-index--query-history)
    (error "BUG: read-from-minibuffer hist arg => %S" captured))
  (let ((buf (get-file-buffer abs)))
    (unless (and buf (buffer-live-p buf))
      (error "BUG: RET did not open %s (buffer killed by cleanup)" abs))
    (princ (format "RET opened %s in live buffer %S\n" abs buf))
    (kill-buffer buf)))

;; Unit level: the preview->open->cleanup sequence keeps the opened buffer.
(let* ((abs (expand-file-name "fz-index.c" default-directory))
       (fz-index--preview-buffers nil)
       (pbuf (find-file-noselect abs)))
  (push pbuf fz-index--preview-buffers)
  (find-file abs)                       ; reuses pbuf
  (setq fz-index--preview-buffers
        (delq (get-file-buffer abs) fz-index--preview-buffers))
  (dolist (b fz-index--preview-buffers)
    (when (buffer-live-p b) (kill-buffer b)))
  (unless (buffer-live-p pbuf)
    (error "BUG: opened buffer was killed during cleanup"))
  (kill-buffer pbuf)
  (princ "preview->open->cleanup keeps the buffer\n"))

(princ "open tests done\n")

;; fz-index--results-open: RET in the results buffer selects the current
;; line's candidate and exits the minibuffer; out-of-range lines
;; ("indexing ..."/"no matches"/trailing empty) do nothing.
(let ((fz-index--candidates '(("a.c" 10 nil) ("b.c" 9 nil)))
      (fz-index--selected 0))
  (cl-letf (((symbol-function 'fz-index--highlight-selection) (lambda () nil)))
    (with-temp-buffer
      (insert "  a.c\n  b.c\n")
      (goto-char (point-min))
      (forward-line 1)
      (catch 'exit (fz-index--results-open))
      (unless (= fz-index--selected 1)
        (error "BUG: results-open did not select line 2, got %s"
               fz-index--selected))
      (goto-char (point-max))           ; line 3, out of range
      (setq fz-index--selected 0)
      (catch 'exit (fz-index--results-open))
      (unless (= fz-index--selected 0)
        (error "BUG: results-open moved selection on out-of-range line"))))
  (princ "results-open tests passed\n"))

(delete-directory "/tmp/fz-open-uem" t)
