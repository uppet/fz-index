;;; Module install / load-failure handling tests.  -*- lexical-binding: t; -*-
(module-load (expand-file-name "./fz-index.so"))
(load (expand-file-name "./fz-index.elc") nil t)

;; A file that fails module-load: deleted when auto-install is on
;; (self-heal), left alone when off (it may be the user's own build).
(let ((dir (make-temp-file "fz-mod-" t)))
  (unwind-protect
      (let ((bad (expand-file-name "bad.so" dir)))
        (write-region "not a module" nil bad nil 'silent)
        (let ((fz-index-module-auto-install t))
          (when (fz-index--load-module-file bad)
            (error "BUG: garbage file loaded as a module"))
          (when (file-exists-p bad)
            (error "BUG: unloadable module not deleted (auto-install on)")))
        (write-region "not a module" nil bad nil 'silent)
        (let ((fz-index-module-auto-install nil))
          (when (fz-index--load-module-file bad)
            (error "BUG: garbage file loaded as a module"))
          (unless (file-exists-p bad)
            (error "BUG: module deleted with auto-install off"))))
    (delete-directory dir t)))
(princ "load-failure tests passed\n")

;; Platform tags: only x86_64 Windows has a prebuilt asset; other
;; Windows builds go straight to the compiler.
(dolist (case '(("x86_64-w64-mingw32" . "x86_64-windows")
                ("i686-w64-mingw32" . nil)
                ("aarch64-w64-mingw32" . nil)))
  (let ((system-type 'windows-nt)
        (system-configuration (car case)))
    (unless (equal (fz-index--platform) (cdr case))
      (error "BUG: platform for %s => %S" (car case) (fz-index--platform)))))
(princ "platform tests passed\n")
(princ "module-install tests done\n")
