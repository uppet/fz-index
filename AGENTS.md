# AGENTS.md — guidance for agentic contributors

## What this project is

fz-index is a **standalone Emacs package**, NOT a contribution to GNU
Emacs.  It may live inside a checkout of the Emacs source tree during
development, but it has its own repository (github.com/uppet/fz-index)
and its own history.  The parent Emacs checkout's AGENTS.md (which
prohibits LLM-generated contributions) applies to Emacs upstream only,
not to this directory.

LLM/AI assistance policy for THIS repository: agents may draft code,
but the maintainer reviews every line before committing.  Write code
that is easy to review: small diffs, no speculative generality, match
the surrounding style.

## Layout

- `fz-index.c` — the Emacs dynamic module.  Holds the whole file
  index in C memory (outside the Lisp heap), scores queries
  (Sublime-style), honors .gitignore.  Exports: `fz-index-build`,
  `fz-index-count`, `fz-index-ready-p`, `fz-index-destroy`,
  `fz-query` (note: NO "index" in this one).
- `fz-index.el` — the entire UI.  Minibuffer + bottom results side
  window, frecency, preview, module auto-install.  Every public
  symbol uses the `fz-index-` prefix (MELPA/package-lint
  requirement); internal symbols use `fz-index--`.
- `emacs-module.h` — vendored module header; the build needs nothing
  else from Emacs.
- `Makefile` — `make` (Linux .so / macOS .dylib), `make fz-index.dll`
  (Windows via mingw-w64 cross or MSYS2 native).
- `test-*.el` — batch test scripts (NOT ert); each exits non-zero on
  failure.  `melpa-recipe` — recipe to submit to melpa/melpa.
- `.github/workflows/build.yml` — tests on Emacs 28.2/29.4/30.2,
  builds prebuilt modules for 5 platform tags, publishes them +
  `checksums.txt` to the GitHub release on `v*` tags.

## Build and test

```sh
make                 # produces fz-index.so (or .dylib on macOS)
emacs -Q --batch --eval '(byte-compile-file "fz-index.el")'
for t in test-m3.el test-m4.el test-open.el test-ui-fix.el test-ui-flow.el; do
  emacs -Q --batch -L . -l "$t" || exit 1
done
```

Any emacs ≥ 28.1 with module support works.  During development the
maintainer uses a locally built Emacs at `../build-31.1/src/emacs`.

## Hard-won implementation facts (don't relearn these)

- Batch `read-from-minibuffer` reads **stdin**, ignores
  `unread-command-events`, and never runs `minibuffer-setup-hook`.
  UI tests therefore mock `read-from-minibuffer` and
  `minibuffer-contents` with `cl-letf` and run the hook manually —
  see `test-open.el` and `test-ui-flow.el`.
- Session state (`fz-index--candidates`, `fz-index--selected`, ...)
  is held in `defvar`ed dynamic variables rebound by `fz-open-file`;
  commands invoked from the results buffer (RET, mouse-1) rely on
  that dynamic scope still being active inside the recursive edit.
  Do not convert them to lexical capture.
- Preview buffers are transient and killed at session end — EXCEPT
  when the user opens the previewed file, which reuses that buffer;
  `fz-open-file` removes it from `fz-index--preview-buffers` before
  cleanup.  Do not regress this (test-open.el covers it).
- `url-retrieve-synchronously` SIGNALS on connection failure; any
  network fetch must be wrapped in `condition-case` or the auto
  install fallback never runs.
- Writing downloaded binaries needs `coding-system-for-write` bound
  to `binary` around `write-region`; the default coding system
  re-encodes bytes and produces a module that CRASHES dlopen.
  `fz-index--download-module` also re-hashes the file on disk after
  writing — keep both checks.
- Module file suffix comes from `module-file-suffix` at runtime
  (.so / .dylib / .dll); never hard-code it.
- The results buffer is read-only and line-indexed: candidate N is
  on line N+1.  If you change rendering (headers, grouping), update
  `fz-index--results-click`/`fz-index--results-open` accordingly.

## Release process

1. Bump BOTH `;; Version:` and `fz-index-version` in `fz-index.el`
   (CI rejects tags that don't match the header).
2. Commit, tag `vX.Y.Z`, push the tag.
3. CI builds `fz-index-<platform><suffix>` for
   x86_64-linux-gnu, aarch64-linux-gnu, x86_64-macos, aarch64-macos,
   x86_64-windows, generates `checksums.txt`, and attaches all of
   them to the GitHub release.
4. `fz-index-ensure-module` downloads
   `releases/download/v<fz-index-version>/fz-index-<platform><suffix>`
   and verifies it against `checksums.txt`, so the Version bump and
   the tag MUST stay in sync.

## When changing things

- Keep `README.org` in sync with key bindings and user options.
- Run the full test loop above; it is the only CI gate besides
  byte-compilation and `check-parens`.
- C changes: remember the module runs on worker threads and is
  loaded into the user's Emacs — a crash kills the editor.  Prefer
  boring, obviously-correct code.
