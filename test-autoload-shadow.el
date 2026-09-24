;;; Autoload shadowing regression: module vs library basename.  -*- lexical-binding: t; -*-
;;
;; load-suffixes puts the module suffix first (".so" before ".elc"
;; before ".el"), so up to 0.3.1 a module named "fz-index.so" sitting
;; next to "fz-index.el" shadowed the library: every autoload entry
;; point died with "Autoloading file ... failed to define function",
;; and (require 'fz-index) silently loaded only the C layer.  The
;; module is now named fz-index-core, and an ;;;###autoload cookie in
;; fz-index.el deletes a stale fz-index<suffix> left behind by an old
;; install when the package autoloads load (in-place upgrades keep the
;; old download).  Runs as its own batch process because it exercises
;; autoloads, which the other tests' eager loads would mask.
(require 'autoload)

(unless (and (boundp 'module-file-suffix) module-file-suffix)
  (error "This test needs an Emacs with dynamic module support"))

(let* ((dir (make-temp-file "fz-shadow-" t))
       (stale (expand-file-name (concat "fz-index" module-file-suffix) dir))
       (gen (expand-file-name "fz-index-autoloads.el" dir)))
  (unwind-protect
      (progn
        ;; A fake installed package: the library plus a stale module
        ;; binary from an old install.  Garbage bytes suffice — while
        ;; the shadowing existed, Fload tried to module-load this file
        ;; instead of fz-index.el.
        (copy-file (expand-file-name "fz-index.el")
                   (expand-file-name "fz-index.el" dir))
        (write-region "not a module" nil stale nil 'silent)
        (let ((generated-autoload-file gen))
          (update-directory-autoloads dir))
        ;; Package activation, in the order package.el generates it:
        ;; load-path first, then the autoloads file.
        (add-to-list 'load-path dir)
        (load gen nil t)
        (when (file-exists-p stale)
          (error "BUG: stale fz-index%s not deleted at activation"
                 module-file-suffix))
        (unless (autoloadp (symbol-function 'fz-index-open-file))
          (error "BUG: fz-index-open-file not autoloaded"))
        ;; Triggering the autoload must load fz-index.el; before the
        ;; fix this died trying to load the module file instead.
        (autoload-do-load (symbol-function 'fz-index-open-file)
                          'fz-index-open-file)
        (when (autoloadp (symbol-function 'fz-index-open-file))
          (error "BUG: autoload did not load fz-index.el")))
    (delete-directory dir t)))
(princ "autoload-shadow tests passed\n")
