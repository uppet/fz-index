;;; Verify the UI fix pieces.  -*- lexical-binding: t; -*-
(module-load (expand-file-name "./fz-index.so"))
(load (expand-file-name "./fz-index.elc") nil t)
(require 'cl-lib)

;; fz-index--complete fills the minibuffer with the selected candidate.
(let* ((fz-index--candidates '(("src/emacs.c" . 87) ("src/macros.c" . 70)))
       (fz-index--selected 1))
  (with-temp-buffer
    (insert "mac")
    (fz-index--complete)
    (princ (format "complete => %S (expect src/macros.c)\n" (buffer-string)))))

;; fz-index--history-candidates returns most-opened files under root.
(let ((fz-index--history (make-hash-table :test 'equal))
      (fz-index-query-limit 10))
  (puthash "/tmp/fz-index-test-proj/src/a.c" 5 fz-index--history)
  (puthash "/tmp/fz-index-test-proj/src/b.c" 9 fz-index--history)
  (puthash "/other/c.c" 99 fz-index--history)     ; outside root
  (puthash "/tmp/fz-index-test-proj/gone.c" 50 fz-index--history)   ; does not exist
  (make-directory "/tmp/fz-index-test-proj/src" t)
  (write-region "" nil "/tmp/fz-index-test-proj/src/a.c" nil 'silent)
  (write-region "" nil "/tmp/fz-index-test-proj/src/b.c" nil 'silent)
  (princ (format "history cands => %S (expect b.c first, no c.c/gone.c)\n"
                 (fz-index--history-candidates "/tmp/fz-index-test-proj/")))
  (delete-file "/tmp/fz-index-test-proj/src/a.c") (delete-file "/tmp/fz-index-test-proj/src/b.c")
  (delete-directory "/tmp/fz-index-test-proj/src") (delete-directory "/tmp/fz-index-test-proj"))

;; fz-index--update on empty input uses history instead of querying.
(let* ((fz-index--root "/tmp/fz-index-test-proj/")
       (fz-index--last-input nil)
       (fz-index--candidates nil)
       (fz-index--selected 0)
       (fz-index--selection-overlay nil)
       (fz-index--history (make-hash-table :test 'equal)))
  (puthash "/tmp/fz-index-test-proj/src/x.c" 2 fz-index--history)
  (make-directory "/tmp/fz-index-test-proj/src" t)
  (write-region "" nil "/tmp/fz-index-test-proj/src/x.c" nil 'silent)
  (cl-letf (((symbol-function 'minibuffer-contents) (lambda () ""))
            ((symbol-function 'fz-index--render) (lambda () nil)))
    (fz-index--update)
    (princ (format "empty-input update => %S\n" fz-index--candidates)))
  (delete-file "/tmp/fz-index-test-proj/src/x.c")
  (delete-directory "/tmp/fz-index-test-proj/src") (delete-directory "/tmp/fz-index-test-proj"))
(princ "UI fix tests done\n")
