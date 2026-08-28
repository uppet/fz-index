;;; Match positions and result-line highlighting.  -*- lexical-binding: t; -*-
(module-load (expand-file-name "./fz-index.so"))
(load (expand-file-name "./fz-index.elc") nil t)
(require 'cl-lib)

(make-directory "/tmp/fz-hl/src" t)
(make-directory "/tmp/fz-hl/中文目录" t)
(write-region "" nil "/tmp/fz-hl/src/emacs.c" nil 'silent)
(write-region "" nil "/tmp/fz-hl/中文目录/笔记.c" nil 'silent)

(let ((h (fz-index-build "/tmp/fz-hl/")))
  (while (not (fz-index-ready-p h))
    (sleep-for 0.005))
  ;; Positions identify the matched bytes of the query.
  (let* ((hit (car (fz-query h "emacs.c" 1)))
         (pos (caddr hit)))
    (unless (equal (car hit) "src/emacs.c")
      (error "BUG: top1 => %S" hit))
    (unless (equal (length pos) (length "emacs.c"))
      (error "BUG: %d positions for 7-char query" (length pos)))
    (unless (equal (mapcar (lambda (p) (aref (car hit) p)) pos)
                   (string-to-list "emacs.c"))
      (error "BUG: positions point at wrong bytes: %S" pos)))
  ;; Multi-word: positions of all words are present.
  (let* ((hit (car (fz-query h "src emacs" 1)))
         (pos (caddr hit)))
    (unless (equal (length pos) (length "srcemacs"))
      (error "BUG: multiword positions => %S" pos)))
  (fz-index-destroy h)
  (princ "position tests passed\n"))

;; Rendering: matched characters get the fz-index-match face, at the
;; right buffer positions even for multibyte paths (byte offsets from
;; the module must become character positions).
(cl-letf (((symbol-function 'fz-index--ready-p) (lambda () t))
          ((symbol-function 'fz-index--highlight-selection) (lambda () nil)))
  (let ((fz-index--candidates
         ;; "中文目录/" is 13 bytes (4 chars x 3 + "/"), so 记 is at
         ;; byte 16 and "." at byte 19 -- as the module would report.
         '(("中文目录/笔记.c" 90 (16 19))
           ("src/emacs.c" 87 (4 5 6 7 8 9 10)))))
    (get-buffer-create fz-index-results-buffer-name)
    (fz-index--render)
    (with-current-buffer fz-index-results-buffer-name
      (goto-char (point-min))
      ;; Line 1: 中文目录/笔记.c, matched bytes 5,6 = "记" ".", which are
      ;; characters 3,4 of the path (中文目录 = 4 chars but 13 bytes).
      (let ((p1 (save-excursion
                  (goto-char (point-min))
                  (search-forward "记" nil t)
                  (1- (point))))
            (p2 (save-excursion
                  (goto-char (point-min))
                  (search-forward ".c" nil t)
                  (- (point) 2))))
        (unless (eq (get-text-property p1 'face) 'fz-index-match)
          (error "BUG: no match face on multibyte char at %d" p1))
        (unless (eq (get-text-property p2 'face) 'fz-index-match)
          (error "BUG: no match face after multibyte prefix at %d" p2)))
      ;; Line 2: src/emacs.c bytes 4..10 = "emacs.c".
      (forward-line 1)
      (dotimes (k 7)
        (let ((cp (+ (line-beginning-position) 2 4 k)))
          (unless (eq (get-text-property cp 'face) 'fz-index-match)
            (error "BUG: missing match face at column %d" cp)))))
    (kill-buffer fz-index-results-buffer-name))
  (princ "highlight tests passed\n"))

(delete-file "/tmp/fz-hl/src/emacs.c")
(delete-file "/tmp/fz-hl/中文目录/笔记.c")
(delete-directory "/tmp/fz-hl/src")
(delete-directory "/tmp/fz-hl/中文目录")
(delete-directory "/tmp/fz-hl")
(princ "highlight tests done\n")
