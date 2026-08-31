/* Standalone ASan stress for the directory scanner, outside Emacs.

   Builds a fixture that includes a symlink loop, a symlinked file
   and a symlinked directory, then

     1. scans it synchronously to completion and checks the entry
        count, proving that the loop terminates (code that follows
        directory links hangs here);
     2. repeatedly starts a build worker over the tree and destroys
        the index mid-flight, the way `fz-index-destroy' does from
        Lisp.

   Build and run (see AGENTS.md "When changing things"):

     gcc -fsanitize=address -std=c99 fz-asan-stress.c \
         -o fz-asan-stress -lpthread
     ASAN_OPTIONS=detect_leaks=0 ./fz-asan-stress

   fz-index.c is #included so its static functions are reachable;
   the module glue is compiled but never called.  On Windows creating
   symlinks usually needs a privilege; the harness then skips the
   links and the count check adapts.  On POSIX a link that cannot be
   created is fatal: a silently link-less fixture would make the
   loop-termination check vacuously pass.  */

#include "fz-index.c"
#include <errno.h>
#include <stdio.h>
#include <time.h>
#ifdef _WIN32
#include <direct.h>
#endif

static void
write_file (const char *path)
{
  FILE *f = fopen (path, "wb");
  if (!f)
    {
      fprintf (stderr, "cannot create %s\n", path);
      exit (1);
    }
  fclose (f);
}

static void
make_dir (const char *path)
{
#ifdef _WIN32
  if (_mkdir (path) != 0 && errno != EEXIST)
#else
  if (mkdir (path, 0777) != 0 && errno != EEXIST)
#endif
    {
      fprintf (stderr, "cannot create %s\n", path);
      exit (1);
    }
}

static int
make_link (const char *target, const char *path)
{
  /* A leftover link from an earlier run would fail with EEXIST;
     the fixture is ours, so clear the name first.  */
  remove (path);
#ifdef _WIN32
  return CreateSymbolicLinkA (path, target, 0) != 0 ? 0 : -1;
#else
  return symlink (target, path);
#endif
}

static void
ms_sleep (long ms)
{
#ifdef _WIN32
  Sleep ((DWORD) ms);
#else
  struct timespec ts;
  ts.tv_sec = ms / 1000;
  ts.tv_nsec = (ms % 1000) * 1000000L;
  nanosleep (&ts, NULL);
#endif
}

static fz_index *
build_sync (const char *root)
{
  fz_index *ix = malloc (sizeof *ix);
  if (!ix)
    exit (1);
  fz_index_init (ix);
  ix->root = strdup (root);
  if (fz_run_scan (ix) != 0)
    {
      fprintf (stderr, "scan failed\n");
      exit (1);
    }
  return ix;
}

int
main (void)
{
  const char *root = "fz-asan-fix";
  char path[512];
  int i, j;
  int have_loop, have_link_file, have_dirlink;

  /* The real tree must exist before the links: symlink(2) creates
     no parent directories, so links made first fail with ENOENT on
     a clean tree (as in CI) and the checks below silently test
     nothing.  */
  make_dir (root);
  snprintf (path, sizeof path, "%s/sub", root);
  make_dir (path);
  write_file ("fz-asan-fix/a.c");
  write_file ("fz-asan-fix/sub/b.c");

  have_loop = make_link (".", "fz-asan-fix/loop") == 0;
  have_link_file = make_link ("a.c", "fz-asan-fix/link.c") == 0;
  have_dirlink = make_link ("sub", "fz-asan-fix/dirlink") == 0;
#ifndef _WIN32
  /* POSIX needs no privilege for symlink(2): a failure here means
     the fixture is broken.  Windows keeps the lenient path — see
     the header comment.  */
  if (!have_loop || !have_link_file || !have_dirlink)
    {
      fprintf (stderr, "cannot create symlink fixture: loop=%d "
               "link.c=%d dirlink=%d\n",
               have_loop, have_link_file, have_dirlink);
      return 1;
    }
#endif

  /* A big tree so the cancel stress below can destroy mid-scan.  */
  snprintf (path, sizeof path, "%s/big", root);
  make_dir (path);
  for (i = 0; i < 300; i++)
    {
      snprintf (path, sizeof path, "%s/big/d%03d", root, i);
      make_dir (path);
      for (j = 0; j < 100; j++)
        {
          snprintf (path, sizeof path, "%s/big/d%03d/f%03d.c",
                    root, i, j);
          write_file (path);
        }
    }

  printf ("links created: loop=%d link.c=%d dirlink=%d\n",
          have_loop, have_link_file, have_dirlink);

  /* 1. Termination: against code that follows directory links this
        never finishes.  30000 big-tree files + a.c + sub/b.c, plus
        link.c when it could be created; loop and dirlink are never
        descended into.  */
  {
    fz_index *ix = build_sync (root);
    size_t want = 30002 + (have_link_file ? 1 : 0);
    printf ("sync scan: count=%zu\n", ix->count);
    if (ix->count != want)
      {
        fprintf (stderr, "count %zu, expected %zu\n", ix->count, want);
        return 1;
      }
    fz_index_free (ix);
  }

  /* 2. Cancel stress: destroy a building index at varied depths.  */
  for (i = 0; i < 30; i++)
    {
      fz_index *ix = malloc (sizeof *ix);
      if (!ix)
        return 1;
      fz_index_init (ix);
      ix->root = strdup (root);
      if (pthread_create (&ix->worker, NULL, fz_build_worker, ix) == 0)
        {
          ix->worker_started = true;
          ms_sleep (2 + (i % 5));
        }
      else
        fz_run_scan (ix);
      fz_index_free (ix);
    }
  printf ("cancel stress: 30 iterations OK\n");
  return 0;
}
