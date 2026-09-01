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
  index in C memory (outside the Lisp heap), scans directories with a
  worker pool fed by a shared queue (fd-style parallel traversal;
  `.gitignore` state shared between workers as a refcounted chain of
  `fz_ign_node`), scores queries with a Smith-Waterman-style DP under
  the Sublime scoring model (with a memchr prefilter), persists
  indexes (`fz-index-save`/`fz-index-load`).  Exports: `fz-index-build`,
  `fz-index-count`, `fz-index-ready-p`, `fz-index-destroy`,
  `fz-index-save`, `fz-index-load`, `fz-query` (note: NO "index" in
  this one).  `fz-query` returns (RELATIVE-PATH SCORE POSITIONS).
- `fz-index.el` — the entire UI plus `fz-index-read-file` and
  `fz-index-completion-table` for completing-read integration.  Every
  public symbol uses the `fz-index-` prefix (MELPA/package-lint
  requirement); internal symbols use `fz-index--`.
- `emacs-module.h` — vendored module header; the build needs nothing
  else from Emacs.
- `Makefile` — `make` (Linux .so / macOS .dylib), `make fz-index.dll`
  (Windows via mingw-w64 cross or MSYS2 native).
- `fz-index-tests.el` — ERT unit tests for the module API (run with
  `ert-run-tests-batch-and-exit`).  `test-*.el` — batch
  integration/performance scripts (NOT ert); each exits non-zero on
  failure.  `melpa-recipe` — recipe to submit to melpa/melpa.
- `.github/workflows/build.yml` — ERT + integration tests on
  ubuntu/macOS/Windows × Emacs 28.2/29.4/30.2, checkdoc and
  package-lint, an ASan+UBSan job with `clang --analyze`, and
  prebuilt modules for 5 platform tags published with
  `checksums.txt` to the GitHub release on `v*` tags.

## Build and test

```sh
make                 # produces fz-index.so (or .dylib on macOS)
emacs -Q --batch --eval '(byte-compile-file "fz-index.el")'
emacs -Q --batch -L . -l fz-index-tests.el -f ert-run-tests-batch-and-exit
for t in test-m3.el test-m4.el test-open.el test-ui-fix.el test-ui-flow.el \
         test-multiword.el test-persist.el test-refresh.el test-symlink.el \
         test-root.el test-highlight.el test-completion-table.el \
         test-module-install.el test-fuzz.el; do
  emacs -Q --batch -L . -l "$t" || exit 1
done
```

Any emacs ≥ 28.1 with module support works.  During development the
maintainer uses a locally built Emacs at `../build-31.1/src/emacs`.

## Pushing and CI

The CI matrix (`.github/workflows/build.yml`) runs the tests on
Linux/macOS/Windows × Emacs 28.2/29.4/30.2, plus an ASan job with
`clang --analyze`.  A green local run on Linux proves little for
the other platforms: the matrix has caught real bugs in symlink
semantics, in `/tmp` path expansion (`/tmp/...` becomes
`d:\tmp\...` on Windows, so raw `/tmp/...` strings used as hash
keys stop matching), and in file-name encoding — none of which
show up locally.  Therefore:

- Land non-trivial changes through a PR.  The bare `pull_request:`
  trigger runs the full matrix on every PR; pushes to the branch
  re-run it.  Merge only once it is green:

  ```sh
  git push origin <branch>
  gh pr create --head <branch> --fill
  gh pr checks --watch          # iterate on the branch until green
  gh pr merge <branch>          # or fast-forward main yourself
  git push origin --delete <branch>
  ```

- Direct pushes to `main` are for CI-trivial changes (docs,
  comments) and for one thing only otherwise: repairing a red
  main.  A red main has priority over feature work — fix it first,
  push the fix directly, confirm the run goes green.

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
- The module API only accepts valid UTF-8 for Lisp strings: paths
  with raw-byte (non-UTF-8) file names are skipped at scan/load
  time.  Never pass unvalidated bytes to `make_string`.
- `default-directory` may keep a literal `~` abbreviation; C code
  (`opendir`) does not expand it.  Always `expand-file-name` on the
  Lisp side before calling into the module.
- `fz-query` positions are BYTE offsets (the module works on UTF-8
  bytes); convert with `byte-to-position` before putting text
  properties, or multibyte paths highlight the wrong characters.
- Tests that drive `fz-index-open-file` must bind
  `user-emacs-directory` to a temp dir, otherwise the on-disk index
  cache leaks into the real `~/.emacs.d/fz-index/`.
- The directory scan is multi-threaded (pool of ≤8 workers, shared
  LIFO queue in `fz_scan_ctx`).  All queue handoffs happen under
  `sc->mu`; `fz_index_add` is serialized under `ix->add_mu`;
  `.gitignore` levels are refcounted `fz_ign_node`s — acquire when
  enqueueing a child job, release when the job is done.
  Symlinked directories are never descended into (`fz_lstat`
  classification in `fz_scan_dir`): a loop, or a link out of the
  tree, would keep the scan growing forever.  Symlinked regular
  files ARE indexed.  On Windows `fz_lstat` is plain `stat` (mingw),
  so directory links and junctions may still be followed there.
  When touching this code, re-run the ASan stress harness, which
  covers a symlink loop and mid-flight cancels and also gates the
  asan CI job: `gcc -fsanitize=address,undefined -std=c99
  fz-asan-stress.c -o fz-asan-stress -lpthread &&
  ASAN_OPTIONS=detect_leaks=0 ./fz-asan-stress`.
- Interactive Emacs ignores SIGPIPE but BATCH Emacs does not: a
  worker thread writing to a pipe whose Lisp process was deleted
  mid-scan kills batch Emacs with SIGPIPE.  The build worker blocks
  SIGPIPE itself (`pthread_sigmask`); never remove that, and be
  suspicious of any background-thread I/O in tests.
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
- Run the full test loop above.  Besides it, CI gates on
  byte-compilation, `check-parens`, checkdoc, package-lint and
  `clang --analyze` (see `.github/workflows/build.yml`).
- C changes: remember the module runs on worker threads and is
  loaded into the user's Emacs — a crash kills the editor.  Prefer
  boring, obviously-correct code.
