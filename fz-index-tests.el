;;; fz-index-tests.el --- ERT unit tests for the fz-index module -*- lexical-binding: t; -*-

;; Fine-grained ERT entry point for the module API.  The test-*.el
;; scripts remain as integration/performance tests; run both in CI.

(require 'ert)

(module-load (expand-file-name "./fz-index.so"
                             (file-name-directory
                              (or load-file-name buffer-file-name))))

(defvar fz-index-test-dir nil)

(defun fz-index-test--with-fixture (files thunk)
  "Create a temp tree with FILES (relative names), run THUNK with its root."
  (let ((dir (make-temp-file "fz-index-test-" t)))
    (unwind-protect
        (progn
          (dolist (f files)
            (let ((abs (expand-file-name f dir)))
              (make-directory (file-name-directory abs) t)
              (write-region "" nil abs nil 'silent)))
          (funcall thunk (file-name-as-directory dir)))
      (delete-directory dir t))))

(defun fz-index-test--ready-index (root)
  "Build an index for ROOT and wait until it is ready."
  (let ((h (fz-index-build root))
        (deadline (+ (float-time) 30)))
    (while (and (not (fz-index-ready-p h)) (< (float-time) deadline))
      (sleep-for 0.01))
    (should (fz-index-ready-p h))
    h))

(ert-deftest fz-index-test-build-and-count ()
  (fz-index-test--with-fixture
   '("a.c" "sub/b.c" "sub/deep/c.c")
   (lambda (root)
     (let ((h (fz-index-test--ready-index root)))
       (should (= (fz-index-count h) 3))
       (fz-index-destroy h)))))

(ert-deftest fz-index-test-query-shape-and-order ()
  (fz-index-test--with-fixture
   '("src/emacs.c" "src/main.c" "lib/emacs.cfg")
   (lambda (root)
     (let ((h (fz-index-test--ready-index root)))
       (let ((hits (fz-query h "emacs.c" 10)))
         (should (= (length hits) 2))
         (dolist (hit hits)
           (should (and (consp hit) (stringp (car hit))
                        (integerp (cadr hit)) (listp (caddr hit)))))
         (should (equal (caar hits) "src/emacs.c"))
         ;; Descending score order.
         (should (>= (cadr (nth 0 hits)) (cadr (nth 1 hits)))))
       (fz-index-destroy h)))))

(ert-deftest fz-index-test-multiword ()
  (fz-index-test--with-fixture
   '("src/emacs.c" "src/canvas.c" "doc/emacs.txt")
   (lambda (root)
     (let ((h (fz-index-test--ready-index root)))
       (should (equal (caar (fz-query h "emacs c" 5)) "src/emacs.c"))
       (should (equal (caar (fz-query h "c emacs" 5)) "src/emacs.c"))
       (should-not (fz-query h "emacs zzz" 5))
       (fz-index-destroy h)))))

(ert-deftest fz-index-test-positions ()
  (fz-index-test--with-fixture
   '("src/emacs.c")
   (lambda (root)
     (let ((h (fz-index-test--ready-index root)))
       (let* ((hit (car (fz-query h "emacs.c" 1)))
              (pos (caddr hit)))
         (should (= (length pos) (length "emacs.c")))
         (should (equal (mapcar (lambda (p) (aref (car hit) p)) pos)
                        (string-to-list "emacs.c"))))
       (fz-index-destroy h)))))

(ert-deftest fz-index-test-smart-case ()
  (fz-index-test--with-fixture
   '("src/Emacs.c" "src/emacs.c")
   (lambda (root)
     (let ((h (fz-index-test--ready-index root)))
       ;; Lowercase query matches both cases; uppercase restricts.
       (should (= (length (fz-query h "emacs" 10)) 2))
       (should (equal (mapcar #'car (fz-query h "Emacs" 10))
                      '("src/Emacs.c")))
       (fz-index-destroy h)))))

(ert-deftest fz-index-test-save-load ()
  (fz-index-test--with-fixture
   '("a.c" "sub/b.c")
   (lambda (root)
     (let ((h (fz-index-test--ready-index root))
           (cache (expand-file-name "fz-test.cache"
                                    temporary-file-directory)))
       (unwind-protect
           (progn
             (should (fz-index-save h cache))
             (let ((h2 (fz-index-load cache root)))
               (should h2)
               (should (fz-index-ready-p h2))
               (should (= (fz-index-count h2) (fz-index-count h)))
               (should (equal (fz-query h2 "b.c" 5) (fz-query h "b.c" 5)))
               (fz-index-destroy h2)))
         (when (file-exists-p cache)
           (delete-file cache)))
       (fz-index-destroy h)))))

(ert-deftest fz-index-test-narrowing ()
  (fz-index-test--with-fixture
   '("src/emacs.c" "src/emacsen.c" "src/other.c")
   (lambda (root)
     (let ((h (fz-index-test--ready-index root)))
       (fz-query h "em" 10)
       (let ((hits (fz-query h "emacs" 10)))
         (should (= (length hits) 2))
         (should (equal (caar hits) "src/emacs.c")))
       (fz-index-destroy h)))))

(provide 'fz-index-tests)
;;; fz-index-tests.el ends here
