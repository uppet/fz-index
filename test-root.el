;;; fz-index-root-function: precedence, fallback, normalization.  -*- lexical-binding: t; -*-
;;; Pure Elisp; no module needed.
(load (expand-file-name "./fz-index.elc") nil t)
;; Keep the kill-emacs history save out of the real home directory.
(setq fz-index-history-file
      (expand-file-name "fz-root-hist.el" temporary-file-directory))

;; Default: current directory.
(let ((fz-index-base-directory nil)
      (fz-index-root-function nil)
      (default-directory "/tmp/fz-root-cwd/"))
  (unless (equal (fz-index--root)
                 (file-name-as-directory
                  (expand-file-name "/tmp/fz-root-cwd")))
    (error "BUG: default-directory fallback => %S" (fz-index--root))))

;; Manual base directory wins over the current directory.
(let ((fz-index-base-directory "/tmp/fz-root-base")
      (fz-index-root-function nil)
      (default-directory "/tmp/"))
  (unless (equal (fz-index--root)
                 (file-name-as-directory
                  (expand-file-name "/tmp/fz-root-base")))
    (error "BUG: base-directory precedence => %S" (fz-index--root))))

;; A root function returning nil falls back to the manual base.
(let ((fz-index-base-directory "/tmp/fz-root-base")
      (fz-index-root-function (lambda () nil))
      (default-directory "/tmp/"))
  (unless (equal (fz-index--root)
                 (file-name-as-directory
                  (expand-file-name "/tmp/fz-root-base")))
    (error "BUG: nil root-function must fall back => %S"
           (fz-index--root))))

;; A root function wins over the manual base and is normalized to a
;; directory string.
(let ((fz-index-base-directory "/tmp/fz-root-base")
      (fz-index-root-function (lambda () "/tmp/fz-root-func"))
      (default-directory "/tmp/"))
  (unless (equal (fz-index--root)
                 (file-name-as-directory
                  (expand-file-name "/tmp/fz-root-func")))
    (error "BUG: root-function precedence => %S" (fz-index--root))))

(princ "root tests passed\n")
