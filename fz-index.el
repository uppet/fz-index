;;; fz-index.el --- Sublime-style fuzzy file open with a native index -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Joyer Huang

;; Author: Joyer Huang <collger@gmail.com>
;; Assisted-by: Kimi Code CLI
;; Maintainer: Joyer Huang <collger@gmail.com>
;; Version: 0.1.1
;; Package-Requires: ((emacs "28.1"))
;; Keywords: files, matching, convenience
;; URL: https://github.com/uppet/fz-index

;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of
;; the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Front-end for the fz-index dynamic module: fuzzy search and open
;; any file in a project, responsive at Chromium scale (400k+ files).
;;
;; Usage: M-x fz-index-open-file
;;   Type to narrow, C-n/C-p (or M-<down>/M-<up>) to move,
;;   RET to open, C-u RET to open in another window,
;;   M-RET to insert the path into the buffer you came from,
;;   C-o to jump between the minibuffer and the results buffer
;;   (in the results buffer, RET opens the file on the current
;;   line; isearch works there too), C-g to quit.

;; This file is part of an independent project; it is NOT a
;; contribution to GNU Emacs.

;;; Code:

(require 'seq)
(require 'subr-x)

;; Provided by the fz-index dynamic module (fz-index.so).
(declare-function fz-index-build "fz-index")
(declare-function fz-index-count "fz-index")
(declare-function fz-index-destroy "fz-index")
(declare-function fz-index-load "fz-index")
(declare-function fz-index-ready-p "fz-index")
(declare-function fz-index-save "fz-index")
(declare-function fz-query "fz-index")

(defgroup fz-index nil
  "Fast fuzzy file open backed by a native index."
  :group 'convenience)

(defconst fz-index-version "0.1.1"
  "Version of the fz-index package.
Prebuilt modules are published under the GitHub release tagged
\"v\" concatenated with this version.")

(defconst fz-index--directory
  (file-name-directory (or load-file-name buffer-file-name
                           default-directory))
  "Directory containing fz-index.el, the C sources and the module.")

(defcustom fz-index-module-auto-install t
  "When non-nil, a missing fz-index module is installed automatically.
A prebuilt binary matching this platform is downloaded from the
project's GitHub Releases (verified against its published SHA-256);
failing that, the bundled C source is compiled when a C compiler is
available.  When nil, a missing module just raises an error."
  :type 'boolean)

(defcustom fz-index-query-limit 100
  "Maximum number of candidates requested per query."
  :type 'integer)

(defcustom fz-index-results-buffer-name " *fz-index-results*"
  "Name of the buffer used to display query results."
  :type 'string)

(defcustom fz-index-preview-enabled t
  "Whether moving the selection previews the candidate file."
  :type 'boolean)

(defcustom fz-index-preview-max-size 1000000
  "Files larger than this many bytes are not previewed."
  :type 'integer)

(defcustom fz-index-frecency-boost 8
  "Score bonus per recorded open of a file."
  :type 'integer)

(defcustom fz-index-frecency-max-boost 40
  "Cap on the total frecency bonus for a file."
  :type 'integer)

(defcustom fz-index-history-file (locate-user-emacs-file "fz-index-history.el")
  "File where the open history is persisted."
  :type 'file)

(defcustom fz-index-base-directory nil
  "Base directory for `fz-index-open-file', set by `fz-index-open-set-base'.
Like Sublime's project folder: when non-nil, all fuzzy searches
start from this directory.  When nil, the current directory is
used as the base.  Cleared by `fz-index-reset'."
  :type '(choice (const :tag "Unset" nil) directory))

(defvar fz-index--history (make-hash-table :test 'equal)
  "Open history: absolute file name -> open count.")

(defvar fz-index--indexes (make-hash-table :test 'equal)
  "Cache of index handles, keyed by project root directory.")

(defvar fz-index--candidates nil
  "Candidates of the latest query, a list of (RELATIVE-PATH . SCORE).")

(defvar fz-index--last-input nil
  "Minibuffer input seen by the last `fz-index--update'.")

(defvar fz-index--selected 0
  "Index of the currently selected candidate.")

(defvar fz-index--root nil
  "Project root of the current `fz-index-open-file' session.")

(defvar fz-index--selection-overlay nil
  "Overlay highlighting the selected candidate.")

(defvar fz-index--action 'open
  "Action on the selected candidate: `open', `open-other-window'
or `insert-path'.")

(defvar fz-index--origin-window nil
  "Window that was selected when `fz-index-open-file' was invoked.")

(defvar fz-index--origin-buffer nil
  "Buffer that was shown in `fz-index--origin-window'.")

(defvar fz-index--preview-buffers nil
  "Buffers created transiently for previewing candidates.")

(defvar fz-index--preview-timer nil
  "Idle timer for the debounced preview, or nil.")

(defun fz-index--insert-path-action ()
  "Exit the minibuffer, requesting insertion of the path at point."
  (interactive)
  (setq fz-index--action 'insert-path)
  (exit-minibuffer))

(defun fz-index--exit-action ()
  "Exit the minibuffer, confirming the selected candidate.
With a prefix argument (C-u RET), open it in another window.
Recording the choice in `fz-index--action' here (inside the command,
where `current-prefix-arg' is still live) keeps it reliable after
`read-from-minibuffer' has returned."
  (interactive)
  (setq fz-index--action
        (if current-prefix-arg 'open-other-window 'open))
  (exit-minibuffer))

(defun fz-index--root ()
  "Return the base directory for `fz-index-open-file'.
This is `fz-index-base-directory' when set, otherwise the current directory."
  (file-name-as-directory
   (expand-file-name (or fz-index-base-directory default-directory))))

;;;###autoload
(defun fz-index-open-set-base (dir)
  "Set DIR as the base directory for `fz-index-open-file'.
Like Sublime's project folder: all subsequent fuzzy searches start
from DIR, regardless of the current buffer's directory.  The setting
is cleared by `fz-index-reset'; without it, the current directory is
used as the base."
  (interactive (list (read-directory-name "fz base directory: "
                                          nil nil t)))
  (setq fz-index-base-directory (expand-file-name dir))
  (message "fz base: %s" fz-index-base-directory))

(defcustom fz-index-cache-enabled t
  "When non-nil, indexes are persisted under `user-emacs-directory'.
A cached index loads instantly on the next session and is refreshed
by a background rescan (stale-while-revalidate), so the first
`fz-index-open-file' of a session does not wait for a full scan."
  :type 'boolean)

(defun fz-index--cache-file (root)
  "Return the on-disk cache file for ROOT's index."
  (expand-file-name (concat "fz-index/" (secure-hash 'sha1 root) ".cache")
                    user-emacs-directory))

(defun fz-index--load-cache (root)
  "Return a ready index handle from ROOT's cache file, or nil."
  (let ((file (fz-index--cache-file root)))
    (when (file-exists-p file)
      (let ((h (ignore-errors (fz-index-load file root))))
        (when h
          (message "fz-index: %s, %d files (cached; refreshing in background)"
                   root (fz-index-count h))
          h)))))

(defun fz-index--save-cache (root handle)
  "Persist HANDLE as ROOT's cache file."
  (when fz-index-cache-enabled
    (let ((file (fz-index--cache-file root)))
      (make-directory (file-name-directory file) t)
      (fz-index-save handle file))))

(defun fz-index--index-for (root)
  "Return the index handle for ROOT, building or refreshing as needed.
When a cache file exists, its index is returned immediately and a
background rescan replaces it once finished
(stale-while-revalidate).  Otherwise a background scan builds the
index; a pipe process filter updates any active `fz-index-open-file'
session when the index becomes ready.  Remote (TRAMP) directories
are not supported: the module indexes the local filesystem only."
  (when (file-remote-p root)
    (user-error "fz-index: cannot index remote directory %s (TRAMP is not supported)"
                root))
  (or (gethash root fz-index--indexes)
      (let* ((proc (make-pipe-process
                    :name (format "fz-index:%s" root)
                    :buffer nil
                    :noquery t
                    :filter #'fz-index--index-notify))
             (cached (and fz-index-cache-enabled
                          (fz-index--load-cache root))))
        (process-put proc 'fz-index-root root)
        (when cached
          (process-put proc 'fz-index-stale cached))
        (let ((handle (fz-index-build root proc)))
          (if cached
              (progn
                (process-put proc 'fz-index-fresh handle)
                (puthash root cached fz-index--indexes)
                cached)
            (message "fz-index: indexing %s in the background ..." root)
            (puthash root handle fz-index--indexes)
            handle)))))

(defun fz-index--index-notify (proc _string)
  "Process filter run when the background scan for PROC's root finishes.
Replaces a stale cached index with the fresh one and persists it.
Filters run on the main thread while `read-from-minibuffer' waits, so
the dynamic bindings of the `fz-index-open-file' session are still in scope."
  (let ((root (process-get proc 'fz-index-root))
        (stale (process-get proc 'fz-index-stale))
        (fresh (process-get proc 'fz-index-fresh)))
    (delete-process proc)
    (cond
     ;; Refresh of a cached index: swap in the fresh handle.
     (fresh
      (if (fz-index-ready-p fresh)
          (progn
            (puthash root fresh fz-index--indexes)
            (fz-index-destroy stale)
            (fz-index--save-cache root fresh)
            (message "fz-index: %s, %d files (refreshed)"
                     root (fz-index-count fresh)))
        ;; Rescan failed; keep serving the cached index.
        (fz-index-destroy fresh)))
     ;; Plain first build: the handle is already in the table.
     (t
      (when-let* ((handle (gethash root fz-index--indexes)))
        (when (fz-index-ready-p handle)
          (fz-index--save-cache root handle)
          (message "fz-index: %s, %d files" root (fz-index-count handle))))))
    ;; Refresh an active minibuffer session for this root.
    (when (and (boundp 'fz-index--root)
               (equal (symbol-value 'fz-index--root) root))
      (when-let* ((mbwin (active-minibuffer-window)))
        (with-current-buffer (window-buffer mbwin)
          (let ((fz-index--last-input nil))
            (fz-index--update)))))))

(defun fz-index-reset (&optional root)
  "Drop the cached index for ROOT (interactively: current base directory).
Also clears the base directory set by `fz-index-open-set-base'.
Rebuild happens on the next `fz-index-open-file'."
  (interactive)
  (let ((root (or root (fz-index--root))))
    (when-let* ((handle (gethash root fz-index--indexes)))
      (fz-index-destroy handle)
      (remhash root fz-index--indexes)
      (message "fz-index: dropped index for %s" root)))
  (setq fz-index-base-directory nil))

;;;###autoload
(defun fz-index-open-file ()
  "Fuzzy-find and open a file under the current project root."
  (interactive)
  (fz-index-ensure-module)
  (let* ((root (fz-index--root))
         (origin-buffer (current-buffer))
         (fz-index--root root)
         (fz-index--candidates nil)
         (fz-index--last-input nil)
         (fz-index--selected 0)
         (fz-index--selection-overlay nil)
         (fz-index--action 'open)
         (fz-index--origin-window (selected-window))
         (fz-index--origin-buffer (current-buffer))
         (fz-index--preview-buffers nil)
         (fz-index--preview-timer nil)
         (opened nil)
         (results-buf (get-buffer-create fz-index-results-buffer-name))
         (keymap (make-sparse-keymap)))
    (fz-index--index-for root)
    (set-keymap-parent keymap minibuffer-local-map)
    (define-key keymap (kbd "C-n") #'fz-index--next)
    (define-key keymap (kbd "C-p") #'fz-index--prev)
    (define-key keymap (kbd "M-<down>") #'fz-index--next)
    (define-key keymap (kbd "M-<up>") #'fz-index--prev)
    (define-key keymap (kbd "M-RET") #'fz-index--insert-path-action)
    (define-key keymap (kbd "RET") #'fz-index--exit-action)
    (define-key keymap (kbd "C-l") #'fz-index--toggle-preview)
    (define-key keymap (kbd "TAB") #'fz-index--complete)
    (define-key keymap (kbd "C-o") #'fz-index--focus-results)
    (with-current-buffer results-buf
      (let ((map (make-sparse-keymap)))
        (define-key map (kbd "<mouse-1>") #'fz-index--results-click)
        (define-key map (kbd "RET") #'fz-index--results-open)
        (define-key map (kbd "C-o") #'fz-index--focus-minibuffer)
        (use-local-map map))
      (read-only-mode 1))
    (unwind-protect
        (minibuffer-with-setup-hook
            (lambda ()
              (add-hook 'post-command-hook #'fz-index--update nil t)
              (fz-index--update))
          (fz-index--show-results-window results-buf)
          (when-let* ((choice (read-from-minibuffer
                               (format "fz [%s]: " root) nil keymap)))
            (if (not (and fz-index--candidates
                          (< fz-index--selected (length fz-index--candidates))))
                (message "fz: no candidate selected")
              (let* ((rel (car (nth fz-index--selected fz-index--candidates)))
                     (abs (expand-file-name rel root)))
                (pcase fz-index--action
                  ('insert-path
                   (with-current-buffer origin-buffer
                     (insert rel)))
                  ('open-other-window
                   (fz-index--record abs)
                   (find-file-other-window abs)
                   ;; Abs's buffer may be a preview buffer now in
                   ;; use; don't let the cleanup below kill it.
                   (setq fz-index--preview-buffers
                         (delq (get-file-buffer abs)
                               fz-index--preview-buffers)))
                  (_
                   (fz-index--record abs)
                   (setq opened t)
                   (find-file abs)
                   (setq fz-index--preview-buffers
                         (delq (get-file-buffer abs)
                               fz-index--preview-buffers))))))))
      ;; Restore the origin window unless the user opened a file in it.
      (unless opened
        (when (window-live-p fz-index--origin-window)
          (set-window-buffer fz-index--origin-window fz-index--origin-buffer)))
      (when (timerp fz-index--preview-timer)
        (cancel-timer fz-index--preview-timer))
      (dolist (buf fz-index--preview-buffers)
        (when (buffer-live-p buf)
          (kill-buffer buf)))
      (delete-window (get-buffer-window results-buf))
      (kill-buffer results-buf))))

(defun fz-index--next ()
  "Select the next candidate."
  (interactive)
  (when fz-index--candidates
    (setq fz-index--selected (min (1+ fz-index--selected)
                            (1- (length fz-index--candidates))))
    (fz-index--highlight-selection)))

(defun fz-index--prev ()
  "Select the previous candidate."
  (interactive)
  (when fz-index--candidates
    (setq fz-index--selected (max (1- fz-index--selected) 0))
    (fz-index--highlight-selection)))

(defun fz-index--update ()
  "Re-query with the current minibuffer input and refresh results.
Does nothing when the input has not changed since the last update,
so that navigation commands do not reset the selection.
With empty input, the most-opened files of this root are shown."
  (let ((input (minibuffer-contents)))
    (unless (equal input fz-index--last-input)
      (setq fz-index--last-input input
            fz-index--candidates
            (if (string-empty-p input)
                (fz-index--history-candidates fz-index--root)
              (fz-index--apply-frecency
               (fz-query (gethash fz-index--root fz-index--indexes)
                         input fz-index-query-limit)
               fz-index--root))
            fz-index--selected 0)
      (fz-index--render))))

(defun fz-index--history-candidates (root)
  "Return the open-history entries under ROOT, most opened first.
The result has the same (RELATIVE-PATH SCORE POSITIONS) shape as
`fz-query', with nil POSITIONS (nothing to highlight)."
  (let (out)
    (maphash (lambda (abs count)
               (when (and (string-prefix-p root abs)
                          (file-exists-p abs))
                 (push (list (substring abs (length root)) count nil)
                       out)))
             fz-index--history)
    (seq-take (sort out (lambda (a b) (> (cadr a) (cadr b))))
              fz-index-query-limit)))

(defun fz-index--complete ()
  "Fill the minibuffer with the selected candidate's path."
  (interactive)
  (when (and fz-index--candidates (< fz-index--selected (length fz-index--candidates)))
    (delete-minibuffer-contents)
    (insert (car (nth fz-index--selected fz-index--candidates)))))

(defun fz-index--results-click (event)
  "Select the clicked candidate and confirm it."
  (interactive "e")
  (let ((line (1- (line-number-at-pos (posn-point (event-start event))))))
    (when (and fz-index--candidates (< line (length fz-index--candidates)))
      (setq fz-index--selected line
            fz-index--action 'open)
      (fz-index--highlight-selection)
      (exit-minibuffer))))

(defun fz-index--results-open ()
  "Select the candidate on the current line and confirm it.
Like `fz-index--results-click', but for the keyboard: after moving to the
results buffer (C-o or C-x o), RET opens the file on the current line;
with a prefix argument (C-u RET) it opens in another window.
The actual open is done by the `fz-index-open-file' session after the
minibuffer exits.  Lines without a candidate do nothing."
  (interactive)
  (let ((line (1- (line-number-at-pos))))
    (when (and fz-index--candidates (< line (length fz-index--candidates)))
      (setq fz-index--selected line
            fz-index--action
            (if current-prefix-arg 'open-other-window 'open))
      (fz-index--highlight-selection)
      (exit-minibuffer))))

(defun fz-index--focus-results ()
  "Move input focus from the minibuffer to the results window."
  (interactive)
  (when-let* ((win (get-buffer-window fz-index-results-buffer-name)))
    (select-window win)))

(defun fz-index--focus-minibuffer ()
  "Move input focus from the results window back to the minibuffer."
  (interactive)
  (when-let* ((win (active-minibuffer-window)))
    (select-window win)))

(defface fz-index-match
  '((t :inherit completions-common-part))
  "Face used for the matched characters in the results buffer.")

(defun fz-index--render ()
  "Render `fz-index--candidates' into the results buffer."
  (let ((buf (get-buffer fz-index-results-buffer-name)))
    (when buf
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (cond
           ((not (fz-index--ready-p))
            (insert (propertize "  indexing ..." 'face 'shadow)))
           ((null fz-index--candidates)
            (insert (propertize "  no matches" 'face 'shadow)))
           (t
            (dolist (cand fz-index--candidates)
              (let ((line-start (point)))
                (insert "  " (car cand) "\n")
                ;; CANDIDATE positions are byte offsets into the
                ;; path; convert to buffer characters (the two leading
                ;; spaces are ASCII, so 2 extra bytes).
                (let ((line-start-bytes (position-bytes line-start)))
                  (dolist (p (caddr cand))
                    (let ((cp (byte-to-position
                               (+ line-start-bytes 2 p))))
                      (when cp
                        (put-text-property
                         cp (1+ cp) 'face 'fz-index-match))))))))))
        (fz-index--highlight-selection)))))

(defun fz-index--ready-p ()
  "Return non-nil if the index for the current session root is ready."
  (let ((handle (gethash fz-index--root fz-index--indexes)))
    (and handle (fz-index-ready-p handle))))

(defun fz-index--highlight-selection ()
  "Move the selection overlay to the selected candidate's line,
and scroll the results window so the selection stays visible."
  (let ((buf (get-buffer fz-index-results-buffer-name)))
    (when (and buf fz-index--candidates)
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (line (1+ fz-index--selected)))
          (if fz-index--selection-overlay
              (move-overlay fz-index--selection-overlay
                            (point-min) (point-min) buf)
            (setq fz-index--selection-overlay (make-overlay (point-min)
                                                      (point-min) buf))
            (overlay-put fz-index--selection-overlay 'face 'highlight))
          (save-excursion
            (goto-char (point-min))
            (forward-line (1- line))
            (move-overlay fz-index--selection-overlay
                          (line-beginning-position)
                          (1+ (line-end-position))))
          (let ((win (get-buffer-window buf))
                (pos (overlay-start fz-index--selection-overlay)))
            (when (and win pos)
              (set-window-point win pos)
              (unless (pos-visible-in-window-p pos win t)
                (with-selected-window win
                  (recenter)))))))))
  (fz-index--preview))

;;; Frecency

(defun fz-index--record (abs)
  "Record one open of file ABS in the history."
  (puthash abs (1+ (gethash abs fz-index--history 0)) fz-index--history))

(defun fz-index--apply-frecency (candidates root)
  "Re-sort CANDIDATES ((REL SCORE POSITIONS) ...) with the history bonus."
  (let ((boosted
         (mapcar (lambda (c)
                   (list (car c)
                         (+ (cadr c)
                            (min fz-index-frecency-max-boost
                                 (* fz-index-frecency-boost
                                    (gethash (expand-file-name (car c) root)
                                             fz-index--history 0))))
                         (caddr c)))
                 candidates)))
    (sort boosted (lambda (a b) (> (cadr a) (cadr b))))))

(defun fz-index--history-save ()
  "Persist the open history to `fz-index-history-file'."
  (let ((entries nil))
    (maphash (lambda (k v) (push (cons k v) entries)) fz-index--history)
    (setq entries (seq-take (sort entries (lambda (a b) (> (cdr a)
                                                           (cdr b))))
                            1000))
    (with-temp-file fz-index-history-file
      (prin1 entries (current-buffer)))))

(defun fz-index--history-load ()
  "Load the open history from `fz-index-history-file'."
  (when (file-exists-p fz-index-history-file)
    (with-temp-buffer
      (insert-file-contents fz-index-history-file)
      (goto-char (point-min))
      (let ((entries (ignore-errors (read (current-buffer)))))
        (when (listp entries)
          (clrhash fz-index--history)
          (dolist (e entries)
            (when (and (consp e) (stringp (car e)) (integerp (cdr e)))
              (puthash (car e) (cdr e) fz-index--history))))))))

(add-hook 'kill-emacs-hook #'fz-index--history-save)
(fz-index--history-load)

;;; Preview

(defcustom fz-index-preview-delay 0.15
  "Seconds of idle time before the selected candidate is previewed.
Rapid C-n/C-p navigation does not preview intermediate candidates;
only the file the selection settles on is loaded."
  :type 'number)

(defun fz-index--toggle-preview ()
  "Toggle live preview of the selected candidate."
  (interactive)
  (setq fz-index-preview-enabled (not fz-index-preview-enabled))
  (if fz-index-preview-enabled
      (fz-index--preview-now)
    (when (window-live-p fz-index--origin-window)
      (set-window-buffer fz-index--origin-window fz-index--origin-buffer))))

(defun fz-index--preview ()
  "Schedule a debounced preview of the selected candidate.
Previewing loads the file, which is too expensive to do on every
navigation step, so it runs only after `fz-index-preview-delay'
seconds of idle time.  The timer runs while `read-from-minibuffer'
waits, so the session's dynamic bindings are still in scope."
  (when fz-index-preview-enabled
    (when (timerp fz-index--preview-timer)
      (cancel-timer fz-index--preview-timer))
    (setq fz-index--preview-timer
          (run-with-idle-timer fz-index-preview-delay nil
                               #'fz-index--preview-now))))

(defun fz-index--preview-now ()
  "Show the selected candidate in the origin window, transiently.
At most one transient preview buffer is kept: the previous one is
killed first.  Buffers created just for preview are killed when the
session ends (except one the user actually opened)."
  (when (and fz-index-preview-enabled
             fz-index--candidates
             (< fz-index--selected (length fz-index--candidates))
             (window-live-p fz-index--origin-window))
    (let* ((rel (car (nth fz-index--selected fz-index--candidates)))
           (abs (expand-file-name rel fz-index--root)))
      (when (and (file-regular-p abs)
                 (< (file-attribute-size (file-attributes abs))
                    fz-index-preview-max-size))
        ;; Drop the previous transient preview buffer; a buffer the
        ;; user opened is removed from this list by `fz-index-open-file'.
        (dolist (b fz-index--preview-buffers)
          (when (buffer-live-p b)
            (kill-buffer b)))
        (setq fz-index--preview-buffers nil)
        (let ((buf (or (get-file-buffer abs)
                       ;; Not raw: a raw (literal) buffer would
                       ;; conflict with a later plain `find-file'.
                       (let ((b (ignore-errors
                                  (find-file-noselect abs))))
                         (when b
                           (push b fz-index--preview-buffers)
                           b)))))
          (when buf
            (set-window-buffer fz-index--origin-window buf)))))))

(defun fz-index--show-results-window (buf)
  "Display BUF in a side window at the bottom of the frame."
  (let ((win (display-buffer-in-side-window
              buf '((side . bottom) (window-height . 12)
                    (dedicated . t)))))
    (when win
      (set-window-parameter win 'no-delete-other-windows t))))

;;; Completing-read integration

(defun fz-index--style-try (_string _table _pred _point)
  "Never expand the input; the fz-index style only filters."
  nil)

(defun fz-index--style-all (string table pred _point)
  "Return TABLE's candidates for STRING without further filtering.
The fz-index table already fuzzy-matched, scored and sorted them."
  (let ((res (funcall table string pred 'all-completions)))
    ;; Like the basic style, terminate the list with a 0 cdr.
    (if (consp res)
        (nconc res 0)
      res)))

(add-to-list 'completion-styles-alist
             '(fz-index fz-index--style-try fz-index--style-all
               "Fuzzy matching done by the fz-index table itself."))

;;;###autoload
(defun fz-index-completion-table (root)
  "Return a completion table that fuzzy-searches files under ROOT.
Candidates are relative paths, already fuzzy-matched, scored and
sorted by the native index.  Use it with `completion-styles' bound
to (fz-index) so the completion styles do not filter the candidates
again.  While the index is still building, the table is empty."
  (fz-index-ensure-module)
  (lambda (string _pred action)
    (cond
     ((eq action 'metadata)
      '(metadata (category . fz-index)
                 (display-sort-function . identity)
                 (cycle-sort-function . identity)))
     ((eq action 'lambda)
      nil)
     ((or (eq action t) (eq action 'all-completions))
      (let ((handle (fz-index--index-for root)))
        (if (fz-index-ready-p handle)
            (mapcar #'car (fz-query handle string fz-index-query-limit))
          nil)))
     ((null action)
      ;; try-completion: the input is never expanded.
      string)
     (t nil))))

;;;###autoload
(defun fz-index-read-file (&optional prompt)
  "Fuzzy-find and open a file via `completing-read'.
Unlike `fz-index-open-file' with its own UI, this goes through the
standard completion machinery, so it works with whatever completion
framework you use (vertico, icomplete, fido, the default UI, ...).
The base directory is the same one `fz-index-open-file' would use."
  (interactive)
  (fz-index-ensure-module)
  (let* ((root (fz-index--root))
         (completion-styles '(fz-index))
         (rel (completing-read
               (or prompt (format "fz [%s]: " root))
               (fz-index-completion-table root))))
    (when (and rel (not (string-empty-p rel)))
      (find-file (expand-file-name rel root)))))

;;; Module loading

(defun fz-index--module-file ()
  "Return the module file name for this Emacs, next to fz-index.el."
  (and (boundp 'module-file-suffix)
       module-file-suffix
       (expand-file-name (concat "fz-index" module-file-suffix)
                         fz-index--directory)))

(defun fz-index--platform ()
  "Return the release-asset platform tag for this system, or nil.
The tags match the assets published on the project's GitHub
Releases page."
  (let ((arch (if (string-match-p "aarch64\\|arm64" system-configuration)
                  "aarch64" "x86_64")))
    (pcase system-type
      ('gnu/linux (format "%s-linux-gnu" arch))
      ('windows-nt "x86_64-windows")
      ('darwin (format "%s-macos" arch))
      (_ nil))))

(defun fz-index--fetch (url)
  "Return the body of URL as a unibyte string, or nil on failure."
  (require 'url)
  (condition-case nil
      (let ((buf (url-retrieve-synchronously url t t 60)))
        (when buf
          (with-current-buffer buf
            (set-buffer-multibyte nil)
            (goto-char (point-min))
            (if (not (looking-at-p "HTTP/[0-9.]+ 2[0-9][0-9]"))
                (progn (kill-buffer buf) nil)
              (re-search-forward "\r?\n\r?\n")
              (prog1 (buffer-substring (point) (point-max))
                (kill-buffer buf))))))
    (error (message "fz-index: fetching %s failed" url)
           nil)))

(defun fz-index--download-module (dest)
  "Download the prebuilt module for this platform to DEST.
The download is verified against the SHA-256 checksums published
with the release.  Returns non-nil on success."
  (when-let* ((platform (fz-index--platform))
              (base (format "https://github.com/uppet/fz-index/releases/download/v%s"
                            fz-index-version))
              (name (format "fz-index-%s%s" platform module-file-suffix))
              (bin (fz-index--fetch (concat base "/" name)))
              (sums (fz-index--fetch (concat base "/checksums.txt"))))
    (if (not (string-match (format "^\\([0-9a-f]\\{64\\}\\) +%s$"
                                   (regexp-quote name))
                           sums))
        (progn (message "fz-index: %s not found in checksums.txt" name)
               nil)
      (let ((want (match-string 1 sums))
            (got (secure-hash 'sha256 (encode-coding-string bin 'binary))))
        (if (not (equal want got))
            (progn (message "fz-index: checksum mismatch for %s" name)
                   nil)
          ;; Binary write: the default coding system would re-encode
          ;; the bytes and corrupt the module.
          (let ((coding-system-for-write 'binary))
            (write-region bin nil dest nil 'silent))
          ;; Verify what landed on disk, not just what we received.
          (let ((ondisk (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (insert-file-contents-literally dest)
                          (secure-hash 'sha256 (buffer-string)))))
            (if (not (equal want ondisk))
                (progn (delete-file dest)
                       (message "fz-index: on-disk checksum mismatch for %s"
                                name)
                       nil)
              (message "fz-index: downloaded %s" name)
              t)))))))

(defun fz-index--build-module (dest)
  "Compile the bundled fz-index.c into DEST.
Returns non-nil on success."
  (let ((src (expand-file-name "fz-index.c" fz-index--directory))
        (cc (or (executable-find "gcc") (executable-find "clang")
                (executable-find "cc"))))
    (when (and (file-exists-p src) cc)
      (message "fz-index: compiling module with %s ..." cc)
      (let ((args (append (if (eq system-type 'darwin)
                              '("-O2" "-fPIC" "-std=c99" "-dynamiclib")
                            '("-O2" "-fPIC" "-std=c99" "-shared"))
                          (list "-o" dest
                                (expand-file-name "fz-index.c"
                                                  fz-index--directory)
                                "-I" fz-index--directory "-lpthread")))
            (buf (get-buffer-create " *fz-index-build*")))
        (if (not (zerop (apply #'call-process cc nil buf nil args)))
            (progn (message "fz-index: build failed, see buffer %s"
                            (buffer-name buf))
                   nil)
          (message "fz-index: module compiled")
          t)))))

;;;###autoload
(defun fz-index-ensure-module ()
  "Load the fz-index dynamic module, installing it when missing.
When the module file is absent and `fz-index-module-auto-install'
is non-nil, a prebuilt binary matching this platform is downloaded
from the project's GitHub Releases (verified against its published
SHA-256 checksum); failing that, the bundled C source is compiled
when a C compiler is available.  Called automatically by
`fz-index-open-file'; run it interactively to install the module ahead
of time."
  (interactive)
  (cond
   ((fboundp 'fz-index-build)
    t)
   ((not (fz-index--module-file))
    (user-error "This Emacs was built without dynamic module support"))
   (t
    (let ((file (fz-index--module-file)))
      (cond
       ((file-exists-p file)
        (module-load file))
       ((not fz-index-module-auto-install)
        (user-error "fz-index module not found at %s" file))
       ((or (fz-index--download-module file)
            (fz-index--build-module file))
        (module-load file))
       (t
        (user-error "fz-index: no prebuilt module for this platform \
and no usable C compiler; see https://github.com/uppet/fz-index")))))))

(provide 'fz-index)
;;; fz-index.el ends here
