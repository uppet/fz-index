;;; Module install / load-failure handling tests.  -*- lexical-binding: t; -*-
(require 'cl-lib)
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

;; fz-index--download-module returns a keyword naming the failure
;; reason (t on success, nil only when the platform has no asset).
(let ((dir (make-temp-file "fz-mod-" t)))
  (unwind-protect
      (let ((dest (expand-file-name
                   (concat "fz-index" module-file-suffix) dir))
            (fz-index-version "0.0.0")
            (system-type 'gnu/linux)
            (system-configuration "x86_64-linux-gnu")
            (name (concat "fz-index-x86_64-linux-gnu" module-file-suffix)))
        ;; Platform without a prebuilt asset: nil, never a keyword.
        (let ((system-configuration "riscv64-linux-gnu"))
          (unless (null (fz-index--download-module dest))
            (error "BUG: no-asset platform must return nil")))
        ;; Fetch failure (binary or checksums): :network.
        (cl-letf (((symbol-function 'fz-index--fetch)
                   (lambda (&rest _) nil)))
          (unless (eq (fz-index--download-module dest) :network)
            (error "BUG: fetch failure must return :network")))
        ;; Asset not listed in checksums.txt: :no-checksum.
        (cl-letf (((symbol-function 'fz-index--fetch)
                   (lambda (url &optional _label)
                     (if (string-match-p "checksums.txt" url)
                         "0123456789abcdef  other-file.so"
                       "ELF"))))
          (unless (eq (fz-index--download-module dest) :no-checksum)
            (error "BUG: missing checksum entry must return :no-checksum")))
        ;; Received bytes do not match the published checksum:
        ;; :checksum-mismatch.
        (cl-letf (((symbol-function 'fz-index--fetch)
                   (lambda (url &optional _label)
                     (if (string-match-p "checksums.txt" url)
                         (format "%s  %s" (make-string 64 ?0) name)
                       "ELF"))))
          (unless (eq (fz-index--download-module dest) :checksum-mismatch)
            (error "BUG: checksum mismatch must return :checksum-mismatch")))
        ;; Success: t, and the file on disk matches the checksum.
        (let ((sha (secure-hash 'sha256 "ELF")))
          (cl-letf (((symbol-function 'fz-index--fetch)
                     (lambda (url &optional _label)
                       (if (string-match-p "checksums.txt" url)
                           (format "%s  %s" sha name)
                         "ELF"))))
            (unless (eq (fz-index--download-module dest) t)
              (error "BUG: valid download must return t"))
            (with-temp-buffer
              (insert-file-contents-literally dest)
              (unless (equal (secure-hash 'sha256 (current-buffer)) sha)
                (error "BUG: downloaded file does not match checksum"))))))
    (delete-directory dir t)))
(princ "download-reason tests passed\n")
(princ "module-install tests done\n")
