/* fz-index.c -- Fast fuzzy file-path index for Emacs, as a dynamic module.

   Keeps the candidate list in native memory (outside the Emacs Lisp
   heap) and answers fuzzy queries with top-K results, so that
   interactive fuzzy file search stays responsive at Chromium scale
   (400k+ files).

   Scoring model follows the one reverse-engineered from Sublime Text
   (fts_fuzzy_match): bonuses for consecutive matches, word-separator
   boundaries and camelCase boundaries; penalties for unmatched and
   leading-unmatched characters.

   Exported Lisp functions:
     (fz-index-build ROOT)            -> handle (user-ptr)
     (fz-index-count HANDLE)          -> integer
     (fz-query HANDLE PATTERN LIMIT)  -> list of (RELATIVE-PATH . SCORE)
     (fz-index-destroy HANDLE)        -> nil

   This file is part of an independent project; it is NOT a contribution
   to GNU Emacs.  It only uses the public module ABI in emacs-module.h.
*/

#define _GNU_SOURCE             /* for qsort_r */

#include <assert.h>
#include <ctype.h>
#include <dirent.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef _WIN32
#include <windows.h>
#endif

#include "emacs-module.h"

/* mingw's dirent rarely reports link entries and its lstat is an
   alias of stat, so the symlink classification below degrades to the
   old following behavior on Windows; POSIX gets a real lstat.  */
#ifdef _WIN32
# define fz_lstat stat
# ifndef S_ISLNK
/* mingw's sys/stat.h has no S_ISLNK: links are not distinguishable
   there, so nothing ever classifies as one.  */
#  define S_ISLNK(m) 0
# endif
#else
# define fz_lstat lstat
#endif

int plugin_is_GPL_compatible;


/* Index storage                                                       */
/* ------------------------------------------------------------------ */

/* All paths live in two arenas: PATHS holds the original bytes
   (NUL-separated, relative to the index root), LOWER holds the
   ASCII-lowercased copies.  Entries are addressed by 32-bit offsets so
   the arenas can be realloc'd freely while scanning.  */

typedef struct
{
  char *paths;         /* arena of original paths, NUL-separated */
  size_t paths_len;
  size_t paths_cap;
  char *lower;         /* arena of lowercased paths, NUL-separated */
  size_t lower_len;    /* always == paths_len */
  uint32_t *offs;      /* offs[i] = offset of entry i in both arenas */
  uint32_t *lens;      /* lens[i] = byte length of entry i (sans NUL) */
  size_t count;
  size_t cap;
  char *root;          /* absolute root directory (for debugging) */

  /* Incremental narrowing cache: when a query's pattern extends the
     previous one (prefix), only the previous match set is rescored.
     Touched only from the Lisp thread, so no locking is needed.  */
  char *last_pat;        /* pattern of the previous query */
  bool last_case_insens;
  uint32_t *last_hits;   /* indices of entries that matched last_pat */
  size_t last_nhits;
  size_t last_hits_cap;

  /* Asynchronous build: the scan runs on WORKER, which only touches
     this struct and, at the end, writes one byte to PIPE_FD (a channel
     opened with the module function open_channel, the one module API
     call allowed from arbitrary threads).  STATE transitions from
     FZ_BUILDING to FZ_READY or FZ_FAILED.  */
  pthread_t worker;
  bool worker_started;
  atomic_int state;
  atomic_int cancel;
  int pipe_fd;           /* -1 when there is no channel */

  /* Serializes fz_index_add between the parallel scan workers.  */
  pthread_mutex_t add_mu;
  bool no_gitignore;
} fz_index;

enum { FZ_BUILDING, FZ_READY, FZ_FAILED };

static void
fz_index_init (fz_index *ix)
{
  memset (ix, 0, sizeof *ix);
  ix->pipe_fd = -1;
  atomic_init (&ix->state, FZ_BUILDING);
  atomic_init (&ix->cancel, 0);
  pthread_mutex_init (&ix->add_mu, NULL);
}

static void
fz_index_free (fz_index *ix)
{
  if (ix->worker_started)
    {
      atomic_store (&ix->cancel, 1);
      pthread_join (ix->worker, NULL);
    }
  if (ix->pipe_fd >= 0)
    close (ix->pipe_fd);
  pthread_mutex_destroy (&ix->add_mu);
  free (ix->paths);
  free (ix->lower);
  free (ix->offs);
  free (ix->lens);
  free (ix->root);
  free (ix->last_pat);
  free (ix->last_hits);
  free (ix);
}

/* Growable arena append: append LEN bytes of DATA plus a NUL to both
   arenas (LOWERCASED version to the lower arena).  */
static int
fz_index_add (fz_index *ix, const char *data, size_t len)
{
  if (ix->count == ix->cap)
    {
      size_t newcap = ix->cap ? ix->cap * 2 : 1 << 16;
      uint32_t *n = realloc (ix->offs, newcap * sizeof *n);
      if (!n)
        return -1;
      ix->offs = n;
      uint32_t *nl = realloc (ix->lens, newcap * sizeof *nl);
      if (!nl)
        return -1;
      ix->lens = nl;
      ix->cap = newcap;
    }
  if (ix->paths_len + len + 1 > ix->paths_cap)
    {
      size_t newcap = ix->paths_cap ? ix->paths_cap : 1 << 22;
      while (ix->paths_len + len + 1 > newcap)
        newcap *= 2;
      char *np = realloc (ix->paths, newcap);
      if (!np)
        return -1;
      ix->paths = np;
      char *nl = realloc (ix->lower, newcap);
      if (!nl)
        return -1;
      ix->lower = nl;
      ix->paths_cap = newcap;
    }
  uint32_t off = (uint32_t) ix->paths_len;
  memcpy (ix->paths + off, data, len);
  ix->paths[off + len] = '\0';
  for (size_t i = 0; i < len; i++)
    {
      unsigned char c = (unsigned char) data[i];
      ix->lower[off + i] = (char) tolower (c);
    }
  ix->lower[off + len] = '\0';
  ix->paths_len += len + 1;
  ix->lower_len = ix->paths_len;
  ix->lens[ix->count] = (uint32_t) len;
  ix->offs[ix->count++] = off;
  return 0;
}

/* Shrink the arenas and index arrays to their exact used sizes.
   During a scan or cache load the arrays grow by doubling, so a
   completed index can hold up to ~2x the bytes it needs; call this
   once the index is complete (it is immutable afterwards) to drop
   the slack.  A failed realloc keeps the larger allocation, which is
   still correct.  */
static void
fz_index_shrink (fz_index *ix)
{
  if (ix->count == 0)
    {
      free (ix->offs);
      free (ix->lens);
      ix->offs = NULL;
      ix->lens = NULL;
      ix->cap = 0;
    }
  else if (ix->count < ix->cap)
    {
      uint32_t *no = realloc (ix->offs, ix->count * sizeof *ix->offs);
      uint32_t *nl = realloc (ix->lens, ix->count * sizeof *ix->lens);
      if (no)
        ix->offs = no;
      if (nl)
        ix->lens = nl;
      ix->cap = ix->count;
    }
  if (ix->paths_len == 0)
    {
      free (ix->paths);
      free (ix->lower);
      ix->paths = NULL;
      ix->lower = NULL;
      ix->paths_cap = 0;
    }
  else if (ix->paths_len < ix->paths_cap)
    {
      char *np = realloc (ix->paths, ix->paths_len);
      char *nl = realloc (ix->lower, ix->lower_len);
      if (np)
        ix->paths = np;
      if (nl)
        ix->lower = nl;
      ix->paths_cap = ix->paths_len;
    }
}

/* Minimal UTF-8 validation: the module API can only hand valid UTF-8
   to Lisp strings, so paths containing invalid bytes cannot be
   represented and are skipped instead.  */
static bool
fz_utf8_valid (const char *s, size_t len)
{
  for (size_t i = 0; i < len;)
    {
      unsigned char c = (unsigned char) s[i];
      if (c < 0x80)
        {
          i++;
          continue;
        }
      size_t n;                 /* continuation bytes expected */
      if ((c & 0xE0) == 0xC0)
        n = 1;
      else if ((c & 0xF0) == 0xE0)
        n = 2;
      else if ((c & 0xF8) == 0xF0)
        n = 3;
      else
        return false;
      if (n == 1 && c < 0xC2)   /* overlong */
        return false;
      if (n == 3 && c > 0xF4)   /* beyond U+10FFFF */
        return false;
      if (i + n >= len)
        return false;
      if (n == 2 && c == 0xED
          && ((unsigned char) s[i + 1] & 0xE0) == 0xA0)
        return false;           /* UTF-16 surrogate */
      for (size_t k = 1; k <= n; k++)
        if (((unsigned char) s[i + k] & 0xC0) != 0x80)
          return false;
      i += n + 1;
    }
  return true;
}


/* ------------------------------------------------------------------ */
/* gitignore handling (worker thread only)                             */
/* ------------------------------------------------------------------ */

/* A subset of gitignore semantics: comments, '!' negation, trailing
   '/' for directory-only rules, '/'-anchored patterns, and the glob
   operators '*', '?', '[...]' and '**'.  Backslash escapes are not
   supported.  Deeper .gitignore files override shallower ones; within
   one file, the last matching line wins.  Ignored directories are
   pruned without descending, so their contents are ignored too.  */

typedef struct
{
  char *pat;
  bool negate;
  bool dir_only;
  bool anchored;                /* pattern contains '/' */
} fz_rule;

typedef struct fz_rule_level
{
  fz_rule *rules;
  size_t n, cap;
  size_t dir_len;               /* length of the level's rel path */
} fz_rule_level;

static void
fz_rules_free (fz_rule_level *lvl)
{
  for (size_t i = 0; i < lvl->n; i++)
    free (lvl->rules[i].pat);
  free (lvl->rules);
  memset (lvl, 0, sizeof *lvl);
}

/* Recursive glob matcher: '*' and '?' do not cross '/', '[...]' is a
   character class, and '**' crosses directory boundaries but only at
   component boundaries.  */
static bool
glob_match (const char *pat, const char *str)
{
  while (*pat)
    {
      if (pat[0] == '*' && pat[1] == '*')
        {
          const char *rest = pat + 2;
          if (*rest == '/')
            rest++;
          for (const char *s = str;; s++)
            {
              if ((s == str || s[-1] == '/') && glob_match (rest, s))
                return true;
              if (!*s)
                return false;
            }
        }
      else if (*pat == '*')
        {
          const char *rest = pat + 1;
          for (const char *s = str;; s++)
            {
              if (glob_match (rest, s))
                return true;
              if (*s == '/' || !*s)
                return false;
            }
        }
      else if (*pat == '?')
        {
          if (!*str || *str == '/')
            return false;
          pat++;
          str++;
        }
      else if (*pat == '[')
        {
          if (!*str)
            return false;
          const char *p = pat + 1;
          bool negate = *p == '!' || *p == '^';
          if (negate)
            p++;
          bool hit = false;
          char prev = 0;
          for (; *p && *p != ']'; p++)
            {
              if (*p == '-' && prev && p[1] && p[1] != ']')
                {
                  if (*str >= prev && *str <= p[1])
                    hit = true;
                  p++;
                }
              else
                {
                  if (*str == *p)
                    hit = true;
                  prev = *p;
                }
            }
          if (hit == negate)
            return false;
          pat = *p == ']' ? p + 1 : p;
          str++;
        }
      else
        {
          if (*pat != *str)
            return false;
          pat++;
          str++;
        }
    }
  return *str == '\0';
}

static void
fz_rules_add (fz_rule_level *lvl, char *line)
{
  size_t len = strlen (line);
  while (len && (line[len - 1] == ' ' || line[len - 1] == '\t'
                 || line[len - 1] == '\r'))
    line[--len] = '\0';
  if (!len || line[0] == '#')
    return;

  char *p = line;
  bool negate = false, dir_only = false;
  if (*p == '!')
    {
      negate = true;
      p++;
      len--;
    }
  if (len && p[len - 1] == '/')
    {
      dir_only = true;
      p[--len] = '\0';
    }
  if (!len)
    return;
  bool anchored;
  if (*p == '/')
    {
      p++;
      len--;
      anchored = true;
    }
  else
    anchored = strchr (p, '/') != NULL;
  if (!len)
    return;

  if (lvl->n == lvl->cap)
    {
      size_t newcap = lvl->cap ? lvl->cap * 2 : 8;
      fz_rule *n = realloc (lvl->rules, newcap * sizeof *n);
      if (!n)
        return;
      lvl->rules = n;
      lvl->cap = newcap;
    }
  fz_rule *rule = &lvl->rules[lvl->n];
  rule->pat = strdup (p);
  if (!rule->pat)
    return;
  rule->negate = negate;
  rule->dir_only = dir_only;
  rule->anchored = anchored;
  lvl->n++;
}

static void
fz_rules_load (fz_rule_level *lvl, const char *path)
{
  FILE *f = fopen (path, "r");
  if (!f)
    return;
  /* fgets with a fixed buffer instead of getline, for portability
     (mingw toolchains do not all provide getline).  .gitignore lines
     are short in practice.  */
  char buf[4096];
  while (fgets (buf, sizeof buf, f))
    {
      size_t n = strlen (buf);
      if (n && buf[n - 1] == '\n')
        buf[n - 1] = '\0';
      fz_rules_add (lvl, buf);
    }
  fclose (f);
}

/* ------------------------------------------------------------------ */
/* Parallel directory scan                                             */
/* ------------------------------------------------------------------ */

/* The scan follows the fd model: a pool of worker threads is fed by a
   shared queue of pending directories; each worker scans the direct
   entries of one directory at a time and enqueues the subdirectories
   it finds.  The gitignore rule stack, formerly an array owned by the
   single recursive scan, becomes a chain of immutable refcounted
   nodes, so that workers share their ancestors' rules without
   copying.  */

typedef struct fz_ign_node
{
  struct fz_ign_node *parent;
  fz_rule_level lvl;
  atomic_uint refs;
} fz_ign_node;

static void
fz_ign_acquire (fz_ign_node *n)
{
  if (n)
    atomic_fetch_add (&n->refs, 1);
}

static void
fz_ign_release (fz_ign_node *n)
{
  while (n && atomic_fetch_sub (&n->refs, 1) == 1)
    {
      fz_ign_node *parent = n->parent;
      fz_rules_free (&n->lvl);
      free (n);
      n = parent;
    }
}

/* Push a rule level for the directory whose relative path is DIR_LEN
   bytes long, chained below PARENT.  The caller owns the new node's
   reference.  */
static fz_ign_node *
fz_ign_push (fz_ign_node *parent, size_t dir_len)
{
  fz_ign_node *n = malloc (sizeof *n);
  if (!n)
    return NULL;
  n->parent = parent;
  memset (&n->lvl, 0, sizeof n->lvl);
  n->lvl.dir_len = dir_len;
  atomic_init (&n->refs, 1);
  if (parent)
    fz_ign_acquire (parent);
  return n;
}

/* Decide whether REL (path relative to the index root) is ignored, by
   walking the rule chain from the deepest level upwards.  IS_DIR
   tells whether REL names a directory.  */
static bool
fz_ignored (const fz_ign_node *n, const char *rel, bool is_dir)
{
  for (; n; n = n->parent)
    {
      const fz_rule_level *lvl = &n->lvl;
      const char *sub = rel + lvl->dir_len + (lvl->dir_len ? 1 : 0);
      const char *base = strrchr (sub, '/');
      base = base ? base + 1 : sub;
      for (size_t r = lvl->n; r-- > 0;)
        {
          const fz_rule *rule = &lvl->rules[r];
          if (rule->dir_only && !is_dir)
            continue;
          if (glob_match (rule->pat, rule->anchored ? sub : base))
            return !rule->negate;
        }
    }
  return false;
}

/* A directory waiting to be scanned, plus the rule chain inherited
   from its ancestors (an owned reference).  */
typedef struct
{
  char *full;                   /* absolute path */
  char *rel;                    /* path relative to the index root */
  fz_ign_node *ign;
} fz_scan_job;

static void
fz_scan_job_free (fz_scan_job *j)
{
  free (j->full);
  free (j->rel);
  fz_ign_release (j->ign);
}

/* Growable job vector: the shared work queue (LIFO), and each
   worker's local list of newly found subdirectories.  */
typedef struct
{
  fz_scan_job *v;
  size_t n, cap;
} fz_scan_jobs;

static int
fz_jobs_push (fz_scan_jobs *js, const fz_scan_job *j)
{
  if (js->n == js->cap)
    {
      size_t newcap = js->cap ? js->cap * 2 : 64;
      fz_scan_job *nv = realloc (js->v, newcap * sizeof *nv);
      if (!nv)
        return -1;
      js->v = nv;
      js->cap = newcap;
    }
  js->v[js->n++] = *j;
  return 0;
}

typedef struct
{
  fz_index *ix;
  pthread_mutex_t mu;           /* guards the queue and fields below */
  pthread_cond_t cv;            /* jobs arrived, or work ran out */
  fz_scan_jobs queue;
  size_t active;                /* jobs taken out, not yet finished */
  bool stopping;                /* cancel or fatal error: wind down */
  int rc;                       /* first error: 0, -1, or -2 */
} fz_scan_ctx;

/* Scan the direct entries of JOB's directory: regular files go into
   the index (under the add mutex), subdirectories are appended to
   CHILDREN.  Entries under any .git directory are always skipped;
   entries matched by the gitignore rule chain are skipped as well
   (directories are pruned without descending).  Symlinked
   directories are not descended into (a loop, or a link out of the
   tree, would otherwise keep the scan growing forever); symlinked
   files are indexed.  Returns 0, -1 on
   fatal error (allocation failure or an unreadable root), or -2 if
   the scan was cancelled.  */
static int
fz_scan_dir (fz_scan_ctx *sc, fz_scan_job *job, fz_scan_jobs *children)
{
  fz_index *ix = sc->ix;
  DIR *d = opendir (job->full);
  if (!d)
    /* An unreadable subdirectory is skipped silently, but an
       unreadable root is a build failure.  */
    return job->rel[0] == '\0' ? -1 : 0;

  /* Load this directory's gitignore rules into a new chain node.  At
     the root, .git/info/exclude is honored as well.  */
  fz_ign_node *node = fz_ign_push (job->ign, strlen (job->rel));
  if (!node)
    {
      closedir (d);
      return -1;
    }
  if (!ix->no_gitignore)
    {
      size_t dirlen = strlen (job->full);
      char *gi = malloc (dirlen + sizeof "/.gitignore");
      if (gi)
        {
          sprintf (gi, "%s/.gitignore", job->full);
          fz_rules_load (&node->lvl, gi);
          free (gi);
        }
      if (job->rel[0] == '\0')
        {
          char *ex = malloc (dirlen + sizeof "/.git/info/exclude");
          if (ex)
            {
              sprintf (ex, "%s/.git/info/exclude", job->full);
              fz_rules_load (&node->lvl, ex);
              free (ex);
            }
        }
    }

  int rc = 0;
  struct dirent *de;
  while ((de = readdir (d)) != NULL)
    {
      if (atomic_load (&ix->cancel))
        {
          rc = -2;
          break;
        }
      const char *name = de->d_name;
      if (name[0] == '.'
          && (name[1] == '\0'
              || (name[1] == '.' && name[2] == '\0')))
        continue;
      if (strcmp (name, ".git") == 0)
        continue;

      size_t dirlen = strlen (job->full);
      size_t rellen = strlen (job->rel);
      size_t namelen = strlen (name);
      char *full = malloc (dirlen + 1 + namelen + 1);
      char *newrel = malloc (rellen + (rellen ? 1 : 0) + namelen + 1);
      if (!full || !newrel)
        {
          free (full);
          free (newrel);
          rc = -1;
          break;
        }
      memcpy (full, job->full, dirlen);
      full[dirlen] = '/';
      memcpy (full + dirlen + 1, name, namelen + 1);
      if (rellen)
        {
          memcpy (newrel, job->rel, rellen);
          newrel[rellen] = '/';
          memcpy (newrel + rellen + 1, name, namelen + 1);
        }
      else
        memcpy (newrel, name, namelen + 1);

      /* The entry type comes from dirent when the filesystem provides
         it, saving one stat(2) per entry; DT_UNKNOWN entries and
         symlinks are classified with lstat plus, for links, one
         stat.  A symlinked directory never becomes a scan job: only
         its target type is inspected, and a broken link is skipped
         like any unreadable entry.  */
      bool is_dir, is_reg;
#ifdef _DIRENT_HAVE_D_TYPE
      if (de->d_type == DT_DIR)
        {
          is_dir = true;
          is_reg = false;
        }
      else if (de->d_type == DT_REG)
        {
          is_dir = false;
          is_reg = true;
        }
      else
#endif
        {
          struct stat st;
          if (fz_lstat (full, &st) != 0)
            {
              free (full);
              free (newrel);
              continue;
            }
          if (S_ISLNK (st.st_mode))
            {
              is_dir = false;
              is_reg = stat (full, &st) == 0
                && S_ISREG (st.st_mode) != 0;
            }
          else
            {
              is_dir = S_ISDIR (st.st_mode) != 0;
              is_reg = S_ISREG (st.st_mode) != 0;
            }
        }

      if (fz_ignored (node, newrel, is_dir) || (!is_dir && !is_reg))
        {
          free (full);
          free (newrel);
        }
      else if (is_dir)
        {
          fz_ign_acquire (node);
          fz_scan_job child = { full, newrel, node };
          if (fz_jobs_push (children, &child) != 0)
            {
              fz_scan_job_free (&child);
              rc = -1;
            }
        }
      else if (fz_utf8_valid (newrel, strlen (newrel)))
        {
          pthread_mutex_lock (&ix->add_mu);
          int arc = fz_index_add (ix, newrel, strlen (newrel));
          pthread_mutex_unlock (&ix->add_mu);
          free (full);
          free (newrel);
          if (arc != 0)
            rc = -1;
        }
      else
        {
          /* Names that are not valid UTF-8 cannot be passed to Lisp
             strings through the module API; skip them.  */
          free (full);
          free (newrel);
        }
    }
  fz_ign_release (node);
  closedir (d);
  return rc;
}

static void *
fz_scan_worker (void *arg)
{
  fz_scan_ctx *sc = arg;
  fz_scan_jobs children = { 0 };
  for (;;)
    {
      pthread_mutex_lock (&sc->mu);
      while (!sc->stopping && sc->queue.n == 0 && sc->active > 0)
        pthread_cond_wait (&sc->cv, &sc->mu);
      if (sc->stopping || sc->queue.n == 0)
        {
          pthread_mutex_unlock (&sc->mu);
          break;
        }
      fz_scan_job job = sc->queue.v[--sc->queue.n];
      sc->active++;
      pthread_mutex_unlock (&sc->mu);

      children.n = 0;
      int rc = fz_scan_dir (sc, &job, &children);

      pthread_mutex_lock (&sc->mu);
      if (rc != 0)
        {
          if (sc->rc == 0)
            sc->rc = rc;
          sc->stopping = true;
        }
      for (size_t i = 0; i < children.n; i++)
        if (sc->stopping || fz_jobs_push (&sc->queue, &children.v[i]) != 0)
          {
            /* Winding down, or the queue allocation failed (fatal):
               free this and the remaining children.  */
            for (size_t k = i; k < children.n; k++)
              fz_scan_job_free (&children.v[k]);
            if (!sc->stopping)
              {
                sc->rc = -1;
                sc->stopping = true;
              }
            break;
          }
      sc->active--;
      /* Wake both idle workers (new jobs, or none left) and anyone
         waiting for the queue to drain.  */
      pthread_cond_broadcast (&sc->cv);
      pthread_mutex_unlock (&sc->mu);
      fz_scan_job_free (&job);
    }
  free (children.v);
  return NULL;
}

/* Number of online processors, portably.  */
static size_t
fz_nproc (void)
{
#ifdef _WIN32
  SYSTEM_INFO si;
  GetSystemInfo (&si);
  return si.dwNumberOfProcessors;
#else
  long n = sysconf (_SC_NPROCESSORS_ONLN);
  return n > 0 ? (size_t) n : 1;
#endif
}

/* Scan the index root with a pool of worker threads fed by the shared
   directory queue, and join them all.  Directory scanning stops
   scaling well past ~8 workers (the queue lock and the filesystem
   become the bottleneck), so the pool is capped there.  Returns 0,
   -1, or -2; see fz_scan_dir.  */
static int
fz_run_scan (fz_index *ix)
{
  fz_scan_ctx sc;
  memset (&sc, 0, sizeof sc);
  sc.ix = ix;
  pthread_mutex_init (&sc.mu, NULL);
  pthread_cond_init (&sc.cv, NULL);

  fz_scan_job root = { strdup (ix->root), strdup (""), NULL };
  if (!root.full || !root.rel || fz_jobs_push (&sc.queue, &root) != 0)
    {
      fz_scan_job_free (&root);
      pthread_cond_destroy (&sc.cv);
      pthread_mutex_destroy (&sc.mu);
      return -1;
    }

  size_t nth = fz_nproc ();
  if (nth > 8)
    nth = 8;
  pthread_t th[8];
  size_t started;
  for (started = 0; started < nth; started++)
    if (pthread_create (&th[started], NULL, fz_scan_worker, &sc) != 0)
      break;
  if (started == 0)
    /* Thread creation failed: scan on the calling thread instead.  */
    fz_scan_worker (&sc);
  else
    for (size_t i = 0; i < started; i++)
      pthread_join (th[i], NULL);

  /* Jobs still queued (only when winding down early) are freed here;
     finished jobs were freed by their workers.  */
  for (size_t i = 0; i < sc.queue.n; i++)
    fz_scan_job_free (&sc.queue.v[i]);
  free (sc.queue.v);
  pthread_cond_destroy (&sc.cv);
  pthread_mutex_destroy (&sc.mu);
  if (sc.rc == 0)
    fz_index_shrink (ix);
  return sc.rc;
}

/* ------------------------------------------------------------------ */
/* Fuzzy scoring                                                       */
/* ------------------------------------------------------------------ */

#define SCORE_UNMATCHED        (-1)
#define SCORE_CONSECUTIVE      (+5)
#define SCORE_SEPARATOR        (+10)
#define SCORE_CAMEL            (+10)
#define SCORE_BASENAME         (+8)
#define SCORE_LEADING          (-3)
#define SCORE_LEADING_MAX      3
#define NO_MATCH               INT_MIN
static bool
is_separator (char c)
{
  return c == '/' || c == '_' || c == '-' || c == '.' || c == ' ';
}

#define FZ_MAX_PATTERN 1024
/* A query is split into at most this many space-separated words; any
   remainder is lumped (spaces included) into the final word.  */
#define FZ_MAX_WORDS 32

/* memrchr with a portable fallback.  */
static const char *
fz_memrchr (const char *s, int c, size_t n)
{
#ifdef __GLIBC__
  return memrchr (s, c, n);
#else
  const char *p = s + n;
  while (p > s)
    if (*--p == (char) c)
      return p;
  return NULL;
#endif
}

/* Greedy rightmost subsequence match: fill POS with the match positions
   of PAT in HAY, anchoring the pattern as far right as possible.  This
   aligns the pattern with the file name at the end of the path, which
   is usually what the user means.  Return 0 on match, -1 otherwise.  */
static int
fz_match_backward (const char *pat, size_t plen, const char *hay,
                   size_t len, size_t *pos)
{
  size_t off = len;
  for (size_t k = plen; k-- > 0;)
    {
      const char *p = fz_memrchr (hay, pat[k], off);
      if (!p)
        return -1;
      pos[k] = (size_t) (p - hay);
      if (pos[k] < k)
        return -1;              /* remaining pattern cannot fit before */
      off = pos[k];
    }
  return 0;
}

/* Per-position match bonus: separator, camelCase and basename
   bonuses for a match landing at offset I of STR.  */
static int
fz_pos_bonus (const char *str, size_t i, size_t basename)
{
  int b = 0;
  if (i >= basename)
    b += SCORE_BASENAME;
  if (i > 0 && is_separator (str[i - 1]))
    b += SCORE_SEPARATOR;
  if (i > 0 && islower ((unsigned char) str[i - 1])
      && isupper ((unsigned char) str[i]))
    b += SCORE_CAMEL;
  return b;
}

#define FZ_NEG (INT_MIN / 2)

/* Optimal-alignment fuzzy score via a Smith-Waterman-style DP,
   equivalent to exhaustively scoring every subsequence alignment of
   PAT in STR under the Sublime scoring model (which is what Sublime
   itself does), instead of scoring only the leftmost/rightmost
   greedy alignments.  D[j] is the best bonus of an alignment where
   PAT[j] matches the current STR[I]; M[j] the best bonus aligning
   PAT[0..J] within STR[0..I].  Both arrays roll over DP rows, so no
   allocation happens per candidate.  Returns NO_MATCH when PAT is
   not a subsequence of the path.  */
static int
fz_score_dp (const char *pat, size_t plen, const char *str,
             const char *lower, size_t len, bool case_insens)
{
  if (plen == 0)
    return -(int) len;
  if (plen > len || plen > FZ_MAX_PATTERN)
    return NO_MATCH;

  const char *hay = case_insens ? lower : str;
  /* Cheap memchr prefilter: reject non-subsequences at SIMD speed.  */
  {
    size_t off = 0;
    for (size_t k = 0; k < plen; k++)
      {
        const char *p = memchr (hay + off, pat[k], len - off);
        if (!p)
          return NO_MATCH;
        off = (size_t) (p - hay) + 1;
      }
  }

  const char *slash = fz_memrchr (str, '/', len);
  size_t basename = slash ? (size_t) (slash - str) + 1 : 0;

  int D[FZ_MAX_PATTERN], M[FZ_MAX_PATTERN];
  for (size_t j = 0; j < plen; j++)
    D[j] = M[j] = FZ_NEG;
  for (size_t i = 0; i < len; i++)
    {
      char c = hay[i];
      int posb = fz_pos_bonus (str, i, basename);
      /* Descending J, so D[J-1]/M[J-1] still belong to row I-1.  */
      size_t jmax = i < plen - 1 ? i : plen - 1;
      for (size_t j = jmax + 1; j-- > 0;)
        {
          if (c != pat[j])
            {
              D[j] = FZ_NEG;
              continue;
            }
          int cand;
          if (j == 0)
            cand = SCORE_LEADING * (int) (i < (size_t) SCORE_LEADING_MAX
                                          ? i : (size_t) SCORE_LEADING_MAX);
          else
            cand = M[j - 1];
          cand += posb;
          if (j > 0 && D[j - 1] != FZ_NEG)
            {
              int consec = D[j - 1] + SCORE_CONSECUTIVE + posb;
              if (consec > cand)
                cand = consec;
            }
          D[j] = cand;
          if (cand > M[j])
            M[j] = cand;
        }
    }
  if (M[plen - 1] == FZ_NEG)
    return NO_MATCH;
  return M[plen - 1] - (int) (len - plen);
}

/* Full-matrix DP variant that also reports the matched byte
   positions in OUT_POS (PLEN entries), for highlighting the top
   candidates.  Falls back to the rolled DP plus the rightmost greedy
   alignment when the matrix would exceed FZ_POS_MAX_CELLS.  */
#define FZ_POS_MAX_CELLS (1u << 20)

static int
fz_score_dp_pos (const char *pat, size_t plen, const char *str,
                 const char *lower, size_t len, bool case_insens,
                 size_t *out_pos)
{
  const char *hay = case_insens ? lower : str;
  if (plen == 0 || plen > len || plen > FZ_MAX_PATTERN
      || (size_t) len * plen > FZ_POS_MAX_CELLS)
    {
      int s = fz_score_dp (pat, plen, str, lower, len, case_insens);
      if (s != NO_MATCH && plen > 0)
        fz_match_backward (pat, plen, hay, len, out_pos);
      return s;
    }

  const char *slash = fz_memrchr (str, '/', len);
  size_t basename = slash ? (size_t) (slash - str) + 1 : 0;

  int *Dm = malloc ((size_t) len * plen * sizeof *Dm);
  int *Mm = malloc ((size_t) len * plen * sizeof *Mm);
  if (!Dm || !Mm)
    {
      free (Dm);
      free (Mm);
      int s = fz_score_dp (pat, plen, str, lower, len, case_insens);
      if (s != NO_MATCH)
        fz_match_backward (pat, plen, hay, len, out_pos);
      return s;
    }
  for (size_t i = 0; i < len; i++)
    {
      char c = hay[i];
      int posb = fz_pos_bonus (str, i, basename);
      size_t jmax = i < plen - 1 ? i : plen - 1;
      for (size_t j = jmax + 1; j-- > 0;)
        {
          int Mprev_j = i > 0 ? Mm[(i - 1) * plen + j] : FZ_NEG;
          int Mprev_jm1
              = (i > 0 && j > 0) ? Mm[(i - 1) * plen + j - 1] : FZ_NEG;
          int Dprev_jm1
              = (i > 0 && j > 0) ? Dm[(i - 1) * plen + j - 1] : FZ_NEG;
          if (c != pat[j])
            {
              Dm[i * plen + j] = FZ_NEG;
              Mm[i * plen + j] = Mprev_j;
              continue;
            }
          int cand;
          if (j == 0)
            cand = SCORE_LEADING * (int) (i < (size_t) SCORE_LEADING_MAX
                                          ? i : (size_t) SCORE_LEADING_MAX);
          else
            cand = Mprev_jm1;
          cand += posb;
          if (j > 0 && Dprev_jm1 != FZ_NEG)
            {
              int consec = Dprev_jm1 + SCORE_CONSECUTIVE + posb;
              if (consec > cand)
                cand = consec;
            }
          Dm[i * plen + j] = cand;
          Mm[i * plen + j] = cand > Mprev_j ? cand : Mprev_j;
        }
      for (size_t j = jmax + 1; j < plen; j++)
        {
          Dm[i * plen + j] = FZ_NEG;
          Mm[i * plen + j] = i > 0 ? Mm[(i - 1) * plen + j] : FZ_NEG;
        }
    }
  int best = Mm[(len - 1) * plen + plen - 1];
  /* Trace the optimal alignment back: positions where M == D are the
     ones the pattern actually consumes.  */
  size_t i = len - 1;
  for (size_t j = plen; j-- > 0;)
    {
      while (Mm[i * plen + j] != Dm[i * plen + j])
        {
          if (i == 0)
            goto traced;    /* cannot happen after the prefilter */
          i--;
        }
      out_pos[j] = i;
      if (j == 0)
        break;
      if (i == 0)
        goto traced;
      i--;
    }
traced:
  free (Dm);
  free (Mm);
  return best == FZ_NEG ? NO_MATCH : best - (int) (len - plen);
}

/* Score STR against every one of the NWORDS query words: all of them
   must match, and the total score is the sum of the per-word scores.
   This implements Sublime/fzf-style multi-word queries ("foo bar"
   matches paths matching both "foo" and "bar").  */
static int
fz_score_multi (const char **words, const size_t *wlens, size_t nwords,
                const char *str, const char *lower, size_t len,
                bool case_insens)
{
  if (nwords == 0)
    return -(int) len;
  int total = 0;
  for (size_t w = 0; w < nwords; w++)
    {
      int s = fz_score_dp (words[w], wlens[w], str, lower, len,
                           case_insens);
      if (s == NO_MATCH)
        return NO_MATCH;
      total += s;
    }
  return total;
}

/* ------------------------------------------------------------------ */
/* Top-K heap (min-heap by score; ties prefer shorter paths)           */
/* ------------------------------------------------------------------ */

typedef struct
{
  int score;
  uint32_t idx;
} fz_hit;

static bool
hit_better (fz_hit a, fz_hit b, const fz_index *ix)
{
  if (a.score != b.score)
    return a.score > b.score;
  return ix->lens[a.idx] < ix->lens[b.idx];
}

/* HEAP is a min-heap of the best N hits: element 0 is the *worst* of
   the kept hits, so a new hit replaces it when better.  */
static void
heap_sift_down (fz_hit *heap, size_t n, size_t i, const fz_index *ix)
{
  for (;;)
    {
      size_t smallest = i;
      size_t l = 2 * i + 1, r = 2 * i + 2;
      if (l < n && hit_better (heap[smallest], heap[l], ix))
        smallest = l;
      if (r < n && hit_better (heap[smallest], heap[r], ix))
        smallest = r;
      if (smallest == i)
        return;
      fz_hit tmp = heap[i];
      heap[i] = heap[smallest];
      heap[smallest] = tmp;
      i = smallest;
    }
}

#if defined(__GLIBC__) || defined(__GNU_LIBRARY__)
static int
hit_cmp_desc (const void *pa, const void *pb, void *ctx)
{
  const fz_index *ix = ctx;
  const fz_hit *a = pa, *b = pb;
  if (a->score != b->score)
    return b->score - a->score;
  uint32_t la = ix->lens[a->idx];
  uint32_t lb = ix->lens[b->idx];
  return la < lb ? -1 : la > lb ? 1 : 0;
}
#endif

/* Offer hit H to the top-LIMIT min-heap HEAP holding NHITS entries:
   insert it while the heap is not full, otherwise replace the worst
   kept hit when H is better.  */
static void
heap_offer (fz_hit *heap, size_t *nhits, size_t limit, fz_hit h,
            const fz_index *ix)
{
  if (*nhits < limit)
    {
      size_t c = (*nhits)++;
      heap[c] = h;
      while (c > 0)
        {
          size_t p = (c - 1) / 2;
          if (!hit_better (heap[c], heap[p], ix))
            break;
          fz_hit tmp = heap[p];
          heap[p] = heap[c];
          heap[c] = tmp;
          c = p;
        }
    }
  else if (hit_better (h, heap[0], ix))
    {
      heap[0] = h;
      heap_sift_down (heap, *nhits, 0, ix);
    }
}

/* ------------------------------------------------------------------ */
/* Parallel query                                                      */
/* ------------------------------------------------------------------ */

#define FZ_MAX_THREADS 16

typedef struct
{
  const fz_index *ix;
  const char **words;           /* query words (NUL-terminated) */
  const size_t *wlens;
  size_t nwords;
  bool case_insens;
  const uint32_t *pool;         /* candidate entry indices, or NULL
                                   meaning "the whole index" */
  size_t begin, end;            /* slice of pool (or index) to score */
  size_t limit;
  fz_hit *heap;                 /* this thread's top-LIMIT heap */
  size_t nhits;
  uint32_t *hits;               /* all matching entry indices */
  size_t hits_len;
  size_t hits_cap;
} fz_query_slice;

static void *
fz_query_worker (void *arg)
{
  fz_query_slice *s = arg;
  const fz_index *ix = s->ix;
  for (size_t i = s->begin; i < s->end; i++)
    {
      uint32_t ei = s->pool ? s->pool[i] : (uint32_t) i;
      uint32_t off = ix->offs[ei];
      int score = fz_score_multi (s->words, s->wlens, s->nwords,
                                  ix->paths + off, ix->lower + off,
                                  ix->lens[ei], s->case_insens);
      if (score == NO_MATCH)
        continue;
      heap_offer (s->heap, &s->nhits, s->limit,
                  (fz_hit) { score, ei }, ix);
      if (s->hits_len == s->hits_cap)
        {
          size_t newcap = s->hits_cap ? s->hits_cap * 2 : 256;
          uint32_t *n = realloc (s->hits, newcap * sizeof *n);
          if (!n)
            continue;           /* drop the hit record, keep the heap */
          s->hits = n;
          s->hits_cap = newcap;
        }
      s->hits[s->hits_len++] = ei;
    }
  return NULL;
}

/* ------------------------------------------------------------------ */
/* Module glue                                                         */
/* ------------------------------------------------------------------ */

static void
fz_index_finalizer (void *ptr)
{
  /* `fz-index-destroy' NULLs the user pointer after freeing, so the
     finalizer can legitimately be called with NULL.  */
  if (ptr)
    fz_index_free (ptr);
}

static fz_index *
get_index (emacs_env *env, emacs_value arg)
{
  fz_index *ix = env->get_user_ptr (env, arg);
  if (!ix)
    {
      env->non_local_exit_signal (
          env, env->intern (env, "wrong-type-argument"),
          env->make_integer (env, 0));
      return NULL;
    }
  return ix;
}

static emacs_value
wrap_index (emacs_env *env, fz_index *ix)
{
  return env->make_user_ptr (env, fz_index_finalizer, ix);
}

/* Background scan entry point: never touches the Emacs API; finishing
   is announced through the pipe channel, which is the one module
   facility usable from arbitrary threads.  */
static void *
fz_build_worker (void *arg)
{
#ifndef _WIN32
  /* The pipe may already be closed on our side (e.g. the Lisp process
     was deleted mid-scan).  Interactive Emacs ignores SIGPIPE, but
     batch Emacs does not, and a module must not kill its host:
     block it here and let write(2) fail with EPIPE instead.  */
  sigset_t set;
  sigemptyset (&set);
  sigaddset (&set, SIGPIPE);
  pthread_sigmask (SIG_BLOCK, &set, NULL);
#endif
  fz_index *ix = arg;
  int rc = fz_run_scan (ix);
  atomic_store (&ix->state, rc == 0 ? FZ_READY : FZ_FAILED);
  if (ix->pipe_fd >= 0)
    {
      ssize_t ignored = write (ix->pipe_fd, "k", 1);
      (void) ignored;
      close (ix->pipe_fd);
      ix->pipe_fd = -1;
    }
  return NULL;
}

/* (fz-index-build ROOT &optional NOTIFY-PROCESS NO-GITIGNORE) */
static emacs_value
Ffz_index_build (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                 void *data)
{
  (void) data;
  ptrdiff_t len = 0;
  if (!env->copy_string_contents (env, args[0], NULL, &len))
    return env->make_integer (env, -1);
  char *root = malloc (len);
  if (!root)
    return env->make_integer (env, -1);
  env->copy_string_contents (env, args[0], root, &len);
  /* Strip a trailing slash, if any.  */
  if (len > 2 && root[len - 2] == '/')
    root[len - 2] = '\0';

  fz_index *ix = malloc (sizeof *ix);
  if (!ix)
    {
      free (root);
      return env->make_integer (env, -1);
    }
  fz_index_init (ix);
  ix->root = root;
  if (nargs > 2 && env->is_not_nil (env, args[2]))
    ix->no_gitignore = true;

  /* When given a pipe process (from `make-pipe-process'), open a
     channel to it: the worker thread announces completion by writing
     to the pipe, and the process filter on the Lisp side picks it
     up.  */
  if (nargs > 1 && env->is_not_nil (env, args[1]))
    {
      ix->pipe_fd = env->open_channel (env, args[1]);
      if (ix->pipe_fd < 0)
        {
          fz_index_free (ix);
          env->non_local_exit_signal (env, env->intern (env, "error"),
                                      env->make_integer (env, 0));
          return env->make_integer (env, -1);
        }
    }

  if (pthread_create (&ix->worker, NULL, fz_build_worker, ix) == 0)
    {
      ix->worker_started = true;
    }
  else
    {
      /* Thread creation failed: scan synchronously instead.  */
      if (fz_run_scan (ix) != 0)
        {
          fz_index_free (ix);
          env->non_local_exit_signal (env, env->intern (env, "error"),
                                      env->make_integer (env, 0));
          return env->make_integer (env, -1);
        }
      atomic_store (&ix->state, FZ_READY);
      if (ix->pipe_fd >= 0)
        {
          ssize_t ignored = write (ix->pipe_fd, "k", 1);
          (void) ignored;
          close (ix->pipe_fd);
          ix->pipe_fd = -1;
        }
    }
  return wrap_index (env, ix);
}

/* (fz-index-count HANDLE) */
static emacs_value
Ffz_index_count (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                 void *data)
{
  (void) nargs;
  (void) data;
  fz_index *ix = get_index (env, args[0]);
  if (!ix)
    return env->make_integer (env, -1);
  if (atomic_load (&ix->state) != FZ_READY)
    return env->make_integer (env, -1);
  return env->make_integer (env, (intmax_t) ix->count);
}

/* (fz-index-ready-p HANDLE) */
static emacs_value
Ffz_index_ready_p (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                   void *data)
{
  (void) nargs;
  (void) data;
  fz_index *ix = get_index (env, args[0]);
  if (!ix)
    return env->intern (env, "nil");
  return env->intern (env,
                      atomic_load (&ix->state) == FZ_READY ? "t" : "nil");
}

/* (fz-query HANDLE PATTERN LIMIT) */
static emacs_value
Ffz_query (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  (void) nargs;
  (void) data;
  fz_index *ix = get_index (env, args[0]);
  if (!ix)
    return env->intern (env, "nil");
  if (atomic_load (&ix->state) != FZ_READY)
    return env->intern (env, "nil");

  ptrdiff_t plen = 0;
  if (!env->copy_string_contents (env, args[1], NULL, &plen))
    return env->intern (env, "nil");
  char *pattern = malloc (plen);
  if (!pattern)
    return env->intern (env, "nil");
  env->copy_string_contents (env, args[1], pattern, &plen);

  intmax_t limit = env->extract_integer (env, args[2]);
  if (limit < 1)
    limit = 1;
  if ((uintmax_t) limit > ix->count)
    limit = (intmax_t) ix->count;

  /* Smart case: an all-lowercase pattern matches case-insensitively.  */
  bool case_insens = true;
  for (ptrdiff_t i = 0; i < plen - 1; i++)
    if (isupper ((unsigned char) pattern[i]))
      {
        case_insens = false;
        break;
      }
  char *pat_lower = pattern;
  if (case_insens)
    {
      pat_lower = malloc (plen);
      if (!pat_lower)
        {
          free (pattern);
          return env->intern (env, "nil");
        }
      for (ptrdiff_t i = 0; i < plen - 1; i++)
        pat_lower[i] = (char) tolower ((unsigned char) pattern[i]);
      pat_lower[plen - 1] = '\0';
    }

  /* Incremental narrowing: if the pattern extends the previous query's
     pattern, only rescore the previous match set.  */
  const uint32_t *pool = NULL;
  size_t pool_count = ix->count;
  if (ix->last_pat && ix->last_case_insens == case_insens)
    {
      size_t lp = strlen (ix->last_pat);
      if ((size_t) (plen - 1) >= lp
          && memcmp (pat_lower, ix->last_pat, lp) == 0)
        {
          pool = ix->last_hits;
          pool_count = ix->last_nhits;
        }
    }

  /* Score in parallel slices when the candidate set is large.  The
     worker threads only read the index and pattern; they never touch
     the Emacs API, which is permitted.  */
  size_t nthreads = 1;
  if (pool_count >= 20000)
    {
      size_t ncpu = fz_nproc ();
      if (ncpu > 1)
        nthreads = ncpu > FZ_MAX_THREADS ? FZ_MAX_THREADS : ncpu;
    }

  /* Split the pattern into space-separated words: "foo bar" matches
     paths matching both words, like Sublime and fzf.  WORDS_BUF holds
     NUL-terminated copies; PAT_LOWER keeps the original spacing for
     the narrowing-cache comparison.  */
  char *words_buf = malloc (plen);
  if (!words_buf)
    {
      free (pattern);
      if (pat_lower != pattern)
        free (pat_lower);
      return env->intern (env, "nil");
    }
  memcpy (words_buf, pat_lower, plen);
  const char *words[FZ_MAX_WORDS];
  size_t wlens[FZ_MAX_WORDS];
  size_t nwords = 0;
  {
    char *p = words_buf;
    char *wend = words_buf + (plen - 1);   /* PLEN includes the NUL */
    while (p < wend && nwords < FZ_MAX_WORDS - 1)
      {
        while (p < wend && *p == ' ')
          p++;
        if (p >= wend)
          break;
        char *start = p;
        while (p < wend && *p != ' ')
          p++;
        words[nwords] = start;
        wlens[nwords] = (size_t) (p - start);
        nwords++;
        if (p < wend)
          *p++ = '\0';
      }
    while (p < wend && *p == ' ')
      p++;
    if (p < wend)
      {
        /* Too many words: lump the rest (spaces included) into the
           final word.  */
        words[nwords] = p;
        wlens[nwords] = (size_t) (wend - p);
        nwords++;
      }
  }

  fz_query_slice slices[FZ_MAX_THREADS];
  pthread_t threads[FZ_MAX_THREADS];
  size_t per = (pool_count + nthreads - 1) / nthreads;
  for (size_t t = 0; t < nthreads; t++)
    {
      slices[t].ix = ix;
      slices[t].words = words;
      slices[t].wlens = wlens;
      slices[t].nwords = nwords;
      slices[t].case_insens = case_insens;
      slices[t].pool = pool;
      slices[t].begin = t * per;
      slices[t].end = slices[t].begin + per;
      if (slices[t].end > pool_count)
        slices[t].end = pool_count;
      slices[t].limit = (size_t) limit;
      slices[t].heap = malloc ((size_t) limit * sizeof *slices[t].heap);
      slices[t].nhits = 0;
      slices[t].hits = NULL;
      slices[t].hits_len = 0;
      slices[t].hits_cap = 0;
      if (!slices[t].heap)
        {
          for (size_t u = 0; u < t; u++)
            free (slices[u].heap);
          free (words_buf);
          free (pattern);
          if (pat_lower != pattern)
            free (pat_lower);
          return env->intern (env, "nil");
        }
    }
  for (size_t t = 1; t < nthreads; t++)
    if (pthread_create (&threads[t], NULL, fz_query_worker, &slices[t]))
      {
        /* Fall back to doing this slice on the current thread.  */
        fz_query_worker (&slices[t]);
        threads[t] = 0;
      }
  fz_query_worker (&slices[0]);
  for (size_t t = 1; t < nthreads; t++)
    if (threads[t])
      pthread_join (threads[t], NULL);

  /* Refresh the narrowing cache with this query's full match set.  */
  size_t total_hits = 0;
  for (size_t t = 0; t < nthreads; t++)
    total_hits += slices[t].hits_len;
  if (total_hits > ix->last_hits_cap)
    {
      uint32_t *n = realloc (ix->last_hits,
                             total_hits * sizeof *ix->last_hits);
      if (n)
        {
          ix->last_hits = n;
          ix->last_hits_cap = total_hits;
        }
    }
  if (total_hits <= ix->last_hits_cap)
    {
      size_t at = 0;
      for (size_t t = 0; t < nthreads; t++)
        {
          memcpy (ix->last_hits + at, slices[t].hits,
                  slices[t].hits_len * sizeof *ix->last_hits);
          at += slices[t].hits_len;
        }
      ix->last_nhits = total_hits;
      free (ix->last_pat);
      ix->last_pat = malloc (plen);
      if (ix->last_pat)
        memcpy (ix->last_pat, pat_lower, plen);
      ix->last_case_insens = case_insens;
    }
  for (size_t t = 0; t < nthreads; t++)
    free (slices[t].hits);

  /* Merge the per-thread heaps into the final top-LIMIT heap.  */
  fz_hit *heap = malloc ((size_t) limit * sizeof *heap);
  if (!heap)
    {
      for (size_t t = 0; t < nthreads; t++)
        free (slices[t].heap);
      free (words_buf);
      free (pattern);
      if (pat_lower != pattern)
        free (pat_lower);
      return env->intern (env, "nil");
    }
  size_t nhits = 0;
  for (size_t t = 0; t < nthreads; t++)
    {
      for (size_t i = 0; i < slices[t].nhits; i++)
        heap_offer (heap, &nhits, (size_t) limit, slices[t].heap[i], ix);
      free (slices[t].heap);
    }

#if defined(__GLIBC__) || defined(__GNU_LIBRARY__)
  qsort_r (heap, nhits, sizeof *heap, hit_cmp_desc, ix);
#else
  /* Portable fallback: insertion sort on at most LIMIT elements.  */
  for (size_t i = 1; i < nhits; i++)
    {
      fz_hit h = heap[i];
      size_t j = i;
      while (j > 0 && hit_better (h, heap[j - 1], ix))
        {
          heap[j] = heap[j - 1];
          j--;
        }
      heap[j] = h;
    }
#endif

  emacs_value result = env->intern (env, "nil");
  emacs_value Qcons = env->intern (env, "cons");
  emacs_value Qlist = env->intern (env, "list");
  for (size_t i = nhits; i-- > 0;)
    {
      uint32_t off = ix->offs[heap[i].idx];
      const char *path = ix->paths + off;
      size_t pathlen = ix->lens[heap[i].idx];
      emacs_value epath
          = env->make_string (env, path, (ptrdiff_t) pathlen);
      emacs_value escore = env->make_integer (env, heap[i].score);
      /* Matched byte positions of every query word, for highlighting;
         collected per word with the full-matrix DP.  */
      emacs_value positions = env->intern (env, "nil");
      size_t posbuf[FZ_MAX_PATTERN];
      for (size_t w = nwords; w-- > 0;)
        if (fz_score_dp_pos (words[w], wlens[w], path, ix->lower + off,
                             pathlen, case_insens, posbuf)
            != NO_MATCH)
          for (size_t k = wlens[w]; k-- > 0;)
            positions
                = env->funcall (env, Qcons, 2,
                                (emacs_value[]) {
                                  env->make_integer (env,
                                                     (intmax_t) posbuf[k]),
                                  positions });
      emacs_value triple = env->funcall (env, Qlist, 3,
                                         (emacs_value[]) {
                                           epath, escore, positions });
      result = env->funcall (env, Qcons, 2,
                             (emacs_value[]) { triple, result });
    }

  free (heap);
  free (words_buf);
  free (pattern);
  if (pat_lower != pattern)
    free (pat_lower);
  return result;
}

/* (fz-index-destroy HANDLE) */
static emacs_value
Ffz_index_destroy (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                   void *data)
{
  (void) nargs;
  (void) data;
  fz_index *ix = env->get_user_ptr (env, args[0]);
  if (ix)
    {
      env->set_user_ptr (env, args[0], NULL);
      fz_index_free (ix);
    }
  return env->intern (env, "nil");
}

/* ------------------------------------------------------------------ */
/* On-disk cache                                                       */
/* ------------------------------------------------------------------ */

/* Cache file format (multi-byte integers in native byte order;
   all supported platforms are little-endian):
     8 bytes  magic FZ_CACHE_MAGIC
     u32      entry count
     u32      root byte length, then the root bytes (informational)
     per entry: u32 path byte length, then the path bytes (no NUL)  */
#define FZ_CACHE_MAGIC "FZIDX001"
#define FZ_CACHE_MAGIC_LEN 8
/* Sanity limits guarding against corrupted cache files.  */
#define FZ_CACHE_MAX_COUNT (1u << 26)
#define FZ_CACHE_MAX_PATH 65535
#define FZ_CACHE_MAX_FILE_SIZE ((size_t) 1 << 30) /* 1 GiB */

/* (fz-index-save HANDLE PATH) */
static emacs_value
Ffz_index_save (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                void *data)
{
  (void) nargs;
  (void) data;
  fz_index *ix = get_index (env, args[0]);
  if (!ix || atomic_load (&ix->state) != FZ_READY)
    return env->intern (env, "nil");

  ptrdiff_t len = 0;
  if (!env->copy_string_contents (env, args[1], NULL, &len))
    return env->intern (env, "nil");
  char *path = malloc (len);
  if (!path)
    return env->intern (env, "nil");
  env->copy_string_contents (env, args[1], path, &len);

  FILE *f = fopen (path, "wb");
  free (path);
  if (!f)
    return env->intern (env, "nil");
  bool ok = fwrite (FZ_CACHE_MAGIC, 1, FZ_CACHE_MAGIC_LEN, f)
            == FZ_CACHE_MAGIC_LEN;
  uint32_t v = (uint32_t) ix->count;
  ok = ok && fwrite (&v, sizeof v, 1, f) == 1;
  uint32_t rlen = ix->root ? (uint32_t) strlen (ix->root) : 0;
  ok = ok && fwrite (&rlen, sizeof rlen, 1, f) == 1;
  ok = ok && (rlen == 0 || fwrite (ix->root, 1, rlen, f) == rlen);
  for (size_t i = 0; ok && i < ix->count; i++)
    {
      uint32_t pl = ix->lens[i];
      ok = fwrite (&pl, sizeof pl, 1, f) == 1
           && fwrite (ix->paths + ix->offs[i], 1, pl, f) == pl;
    }
  ok = fclose (f) == 0 && ok;
  return ok ? env->intern (env, "t") : env->intern (env, "nil");
}

/* (fz-index-load PATH ROOT) */
static emacs_value
Ffz_index_load (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                void *data)
{
  (void) nargs;
  (void) data;
  ptrdiff_t len = 0;
  if (!env->copy_string_contents (env, args[0], NULL, &len))
    return env->intern (env, "nil");
  char *path = malloc (len);
  if (!path)
    return env->intern (env, "nil");
  env->copy_string_contents (env, args[0], path, &len);
  if (!env->copy_string_contents (env, args[1], NULL, &len))
    {
      free (path);
      return env->intern (env, "nil");
    }
  char *root = malloc (len);
  if (!root)
    {
      free (path);
      return env->intern (env, "nil");
    }
  env->copy_string_contents (env, args[1], root, &len);

  fz_index *ix = NULL;
  FILE *f = fopen (path, "rb");
  free (path);
  if (!f)
    goto fail;
  /* Read the whole file into memory in one fread, then parse from
     the buffer: per-entry fread calls would be hundreds of thousands
     of syscalls on a large index.  The file size is bounded by the
     sanity limit, so the allocation is bounded too.  */
  fseek (f, 0, SEEK_END);
  long fsize = ftell (f);
  fseek (f, 0, SEEK_SET);
  if (fsize < 0 || (size_t) fsize > FZ_CACHE_MAX_FILE_SIZE)
    goto fail_close;
  unsigned char *buf = malloc ((size_t) fsize ? (size_t) fsize : 1);
  if (!buf)
    goto fail_close;
  size_t got = fread (buf, 1, (size_t) fsize, f);
  fclose (f);
  f = NULL;                     /* avoid a second fclose on error paths */
  if (got != (size_t) fsize)
    {
      free (buf);
      goto fail;
    }
  {
    const unsigned char *p = buf;
    const unsigned char *end = buf + got;
    if ((size_t) (end - p) < FZ_CACHE_MAGIC_LEN
        || memcmp (p, FZ_CACHE_MAGIC, FZ_CACHE_MAGIC_LEN) != 0)
      goto fail_data;
    p += FZ_CACHE_MAGIC_LEN;
    uint32_t count, rlen;
    if ((size_t) (end - p) < sizeof count)
      goto fail_data;
    memcpy (&count, p, sizeof count);
    p += sizeof count;
    if (count > FZ_CACHE_MAX_COUNT)
      goto fail_data;
    if ((size_t) (end - p) < sizeof rlen)
      goto fail_data;
    memcpy (&rlen, p, sizeof rlen);
    p += sizeof rlen;
    /* The cache file name already identifies the root; the stored
       root is informational only.  */
    if ((size_t) (end - p) < rlen)
      goto fail_data;
    p += rlen;
    ix = malloc (sizeof *ix);
    if (!ix)
      goto fail_data;
    fz_index_init (ix);
    ix->root = root;
    for (uint32_t i = 0; i < count; i++)
      {
        uint32_t pl;
        if ((size_t) (end - p) < sizeof pl)
          goto fail_data;
        memcpy (&pl, p, sizeof pl);
        p += sizeof pl;
        if (pl > FZ_CACHE_MAX_PATH || (size_t) (end - p) < pl)
          goto fail_data;
        /* Skip entries that are not valid UTF-8 (e.g. written by an
           older version), the same way the scanner skips them.  */
        if (fz_utf8_valid ((const char *) p, pl)
            && fz_index_add (ix, (const char *) p, pl) != 0)
          goto fail_data;
        p += pl;
      }
    free (buf);
    fz_index_shrink (ix);
    atomic_store (&ix->state, FZ_READY);
    return wrap_index (env, ix);
  }
fail_data:
  free (buf);
fail_close:
  if (f)
    fclose (f);
fail:
  free (root);
  if (ix)
    {
      ix->root = NULL;          /* ROOT is freed separately above */
      fz_index_free (ix);
    }
  return env->intern (env, "nil");
}

/* ------------------------------------------------------------------ */
/* Registration                                                        */
/* ------------------------------------------------------------------ */

static void
defun (emacs_env *env, const char *name, ptrdiff_t min_arity,
       ptrdiff_t max_arity, emacs_function func, const char *doc)
{
  emacs_value fn = env->make_function (env, min_arity, max_arity, func,
                                       doc, NULL);
  emacs_value sym = env->intern (env, name);
  env->funcall (env, env->intern (env, "fset"), 2,
                (emacs_value[]) { sym, fn });
}

int
emacs_module_init (struct emacs_runtime *runtime)
{
  if ((size_t) runtime->size < sizeof *runtime)
    return 1;
  emacs_env *env = runtime->get_environment (runtime);
  if ((size_t) env->size < sizeof *env)
    return 2;

  defun (env, "fz-index-build", 1, 3, Ffz_index_build,
         "Build a file-path index rooted at directory ROOT.\n"
         "Returns a handle for use with `fz-query'.\n"
         "The scan runs on a background thread and honors .gitignore\n"
         "files; use `fz-index-ready-p' to check completion.  If\n"
         "NOTIFY-PROCESS is a pipe process created with\n"
         "`make-pipe-process', it receives output when the scan\n"
         "finishes.  NO-GITIGNORE non-nil disables .gitignore\n"
         "filtering.");
  defun (env, "fz-index-count", 1, 1, Ffz_index_count,
         "Return the number of file paths in index HANDLE.\n"
         "Return -1 while the index is still being built.");
  defun (env, "fz-index-ready-p", 1, 1, Ffz_index_ready_p,
         "Return t if index HANDLE has finished building.");
  defun (env, "fz-query", 3, 3, Ffz_query,
         "Fuzzy-match PATTERN against index HANDLE.\n"
         "Return up to LIMIT hits as a list of (RELATIVE-PATH . SCORE),\n"
         "sorted by descending score.  An all-lowercase PATTERN matches\n"
         "case-insensitively; any uppercase letter makes it case-sensitive.");
  defun (env, "fz-index-destroy", 1, 1, Ffz_index_destroy,
         "Free index HANDLE.  Also happens automatically via GC.");
  defun (env, "fz-index-save", 2, 2, Ffz_index_save,
         "Write the ready index HANDLE to file PATH.\n"
         "Return t on success, nil otherwise.");
  defun (env, "fz-index-load", 2, 2, Ffz_index_load,
         "Load an index previously written with `fz-index-save'.\n"
         "PATH is the cache file, ROOT the index root (informational).\n"
         "Return a ready handle, or nil if the file is missing or\n"
         "corrupt.");

  emacs_value feat = env->intern (env, "fz-index");
  env->funcall (env, env->intern (env, "provide"), 1,
                (emacs_value[]) { feat });
  return 0;
}
