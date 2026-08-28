;;; Fuzz the module with pathological file names and queries. -*- lexical-binding: t; -*-
(module-load (expand-file-name "./fz-index.so"))

(defconst fz-fuzz-dir "/tmp/fz-fuzz")

;; --- Fixture: pathological names.
(delete-directory fz-fuzz-dir t)
(make-directory (concat fz-fuzz-dir "/sub") t)
(dolist (name
         (list "normal.c"
               (concat (make-string 200 ?a) ".c")   ; very long name
               "with space.c"
               "with'quote.c"
               "with\"dquote.c"
               "with\\backslash.c"
               "with*star.c"
               "with[bracket].c"
               "line\nbreak.c"                      ; newline in name
               "tab\tname.c"
               "中文文件.c"
               "emoji-\U0001F600.c"
               ".hidden.c"
               (string-make-unibyte "raw-\xff\xfe-bytes.c")))
  (write-region "" nil (concat fz-fuzz-dir "/" name) nil 'silent))
(write-region "" nil (concat fz-fuzz-dir "/sub/deep.c") nil 'silent)
;; Deep nesting.
(let ((d fz-fuzz-dir))
  (dotimes (i 30)
    (setq d (concat d "/d"))
    (make-directory d))
  (write-region "" nil (concat d "/leaf.c") nil 'silent))

;; --- Pathological queries: must never crash, whatever they return.
(defconst fz-fuzz-queries
  (list ""
        "a"
        "中"
        "\U0001F600"
        (make-string 2000 ?x)             ; beyond FZ_MAX_PATTERN
        (make-string 300 ?a)              ; longer than any name
        "a b c d e f g"
        "   "
        " \t "
        ".*[]()"
        "with space"
        "line break"                      ; words matching a newline name
        "normal.c"
        "sub deep"
        (concat "bad" (string 0) "nul")   ; embedded NUL
        "\xff\xfe"
        (make-string 40 ?/)))

(let ((h (fz-index-build (concat fz-fuzz-dir "/"))))
  (let ((deadline (+ (float-time) 30)))
    (while (and (not (fz-index-ready-p h)) (< (float-time) deadline))
      (sleep-for 0.01)))
  (princ (format "fuzz index count: %d\n" (fz-index-count h)))
  (dolist (q fz-fuzz-queries)
    (dolist (_ '(1 2 3))
      (let ((res (fz-query h q 100)))
        (unless (listp res)
          (error "BUG: query %S returned non-list %S" q res))
        (dolist (hit res)
          (unless (and (consp hit) (stringp (car hit))
                       (integerp (cadr hit)) (listp (caddr hit)))
            (error "BUG: malformed hit %S for query %S" hit q))))))
  ;; Repeatedly alternate widen/narrow to stress the narrowing cache.
  (dolist (pat '("a" "ab" "a" "abc" "ab" "abcd" "a" "a b" "a" ""))
    (fz-query h pat 50))
  (fz-index-destroy h)
  (princ "fuzz tests passed\n"))

(delete-directory fz-fuzz-dir t)
(princ "fuzz tests done\n")
