;;; Index persistence: save/load round-trip and stale-while-revalidate. -*- lexical-binding: t; -*-
(module-load (expand-file-name (concat "fz-index" module-file-suffix)))
(load (expand-file-name "./fz-index.elc") nil t)

(make-directory "/tmp/fz-persist/sub" t)
(write-region "" nil "/tmp/fz-persist/alpha.c" nil 'silent)
(write-region "" nil "/tmp/fz-persist/sub/beta.c" nil 'silent)

;; --- C level: save then load yields an identical, ready index.
(let ((h (fz-index-build "/tmp/fz-persist/")))
  (while (not (fz-index-ready-p h))
    (sleep-for 0.005))
  (unless (fz-index-save h "/tmp/fz-persist.cache")
    (error "BUG: fz-index-save failed"))
  (let ((h2 (fz-index-load "/tmp/fz-persist.cache" "/tmp/fz-persist/")))
    (unless h2
      (error "BUG: fz-index-load returned nil"))
    (unless (and (fz-index-ready-p h2)
                 (= (fz-index-count h2) (fz-index-count h)))
      (error "BUG: loaded index count %s, expected %s"
             (fz-index-count h2) (fz-index-count h)))
    (unless (equal (fz-query h2 "beta" 5) (fz-query h "beta" 5))
      (error "BUG: query results differ after round-trip"))
    (fz-index-destroy h2))
  (fz-index-destroy h)
  (princ "save/load round-trip OK\n"))

;; --- C level: a corrupt cache file loads as nil, no crash.
(write-region "garbage-not-a-cache" nil "/tmp/fz-corrupt.cache" nil 'silent)
(when (fz-index-load "/tmp/fz-corrupt.cache" "/tmp/")
  (error "BUG: corrupt cache did not load as nil"))
(princ "corrupt cache rejected OK\n")

;; --- Elisp level: first build persists; next "session" serves the
;; cache instantly and swaps in the rescan (stale-while-revalidate).
(let ((user-emacs-directory "/tmp/fz-uem/")
      (fz-index-cache-enabled t)
      (deadline (+ (float-time) 30)))
  (make-directory user-emacs-directory t)
  (clrhash fz-index--indexes)
  ;; First build: no cache yet.
  (let ((h (fz-index--index-for "/tmp/fz-persist/")))
    (while (not (fz-index-ready-p h))
      (accept-process-output nil 0.05)))
  ;; Let the pipe filter run (it saves the cache).
  (while (and (not (file-exists-p "/tmp/fz-uem/fz-index/"))
              (< (float-time) deadline))
    (accept-process-output nil 0.05))
  (unless (file-exists-p (fz-index--cache-file "/tmp/fz-persist/"))
    (error "BUG: cache file was not written after first build"))
  (princ "first build persisted OK\n")

  ;; New "session": drop the in-memory table, add a file on disk.
  (clrhash fz-index--indexes)
  (write-region "" nil "/tmp/fz-persist/sub/gamma.c" nil 'silent)
  (let ((h (fz-index--index-for "/tmp/fz-persist/")))
    ;; The cached handle is served immediately, with the OLD count...
    (unless (fz-index-ready-p h)
      (error "BUG: cached handle was not ready immediately"))
    (unless (= (fz-index-count h) 2)
      (error "BUG: cached count %s, expected stale 2" (fz-index-count h)))
    ;; ...and the background rescan swaps in a fresh one.
    (let ((d2 (+ (float-time) 30)))
      (while (and (eq (gethash "/tmp/fz-persist/" fz-index--indexes) h)
                  (< (float-time) d2))
        (accept-process-output nil 0.05)))
    (let ((h2 (gethash "/tmp/fz-persist/" fz-index--indexes)))
      (when (eq h2 h)
        (error "BUG: stale handle was not swapped after rescan"))
      (unless (= (fz-index-count h2) 3)
        (error "BUG: refreshed count %s, expected 3" (fz-index-count h2)))
      (unless (assoc "sub/gamma.c" (fz-query h2 "gamma" 5))
        (error "BUG: new file not found after refresh")))
    (princ "stale-while-revalidate OK\n"))
  (dolist (h (let (acc) (maphash (lambda (_ v) (push v acc))
                                 fz-index--indexes) acc))
    (fz-index-destroy h))
  (clrhash fz-index--indexes))

(delete-file "/tmp/fz-persist/alpha.c")
(delete-file "/tmp/fz-persist/sub/beta.c")
(delete-file "/tmp/fz-persist/sub/gamma.c")
(delete-directory "/tmp/fz-persist/sub")
(delete-directory "/tmp/fz-persist")
(delete-file "/tmp/fz-persist.cache")
(delete-file "/tmp/fz-corrupt.cache")
(delete-directory "/tmp/fz-uem" t)
(princ "persist tests done\n")
