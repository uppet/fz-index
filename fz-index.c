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

int plugin_is_GPL_compatible;

/* ------------------------------------------------------------------ */
/* Index storage                                                       */
/* ------------------------------------------------------------------ */

/* All paths live in two arenas: PATHS holds the original bytes
   (NUL-separated, relative to the index root), LOWER holds the
   ASCII-lowercased copies.  Entries are addressed by 32-bit offsets so
   the arenas can be realloc'd freely while scanning.  */

struct fz_rule_level;

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

  /* gitignore rule stack (worker thread only).  */
  struct fz_rule_level *ign;
  size_t ign_depth;
  size_t ign_cap;
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
  free (ix->ign);
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

/* Decide whether REL (path relative to the index root) is ignored.
   IS_DIR tells whether REL names a directory.  */
static bool
fz_ignored (fz_index *ix, const char *rel, bool is_dir)
{
  for (size_t l = ix->ign_depth; l-- > 0;)
    {
      fz_rule_level *lvl = &ix->ign[l];
      const char *sub = rel + lvl->dir_len + (lvl->dir_len ? 1 : 0);
      const char *base = strrchr (sub, '/');
      base = base ? base + 1 : sub;
      for (size_t r = lvl->n; r-- > 0;)
        {
          fz_rule *rule = &lvl->rules[r];
          if (rule->dir_only && !is_dir)
            continue;
          if (glob_match (rule->pat, rule->anchored ? sub : base))
            return !rule->negate;
        }
    }
  return false;
}

/* Recursive directory scan.  DIR is the current absolute path prefix,
   REL is the path relative to the index root ("" at top level).
   Entries under any .git directory are always skipped; entries matched
   by the gitignore rule stack are skipped as well (directories are
   pruned without descending).  */
static int
fz_scan (fz_index *ix, const char *dir, const char *rel)
{
  DIR *d = opendir (dir);
  if (!d)
    return 0;              /* unreadable directory: skip silently */

  /* Push this directory's gitignore rules onto the stack.  At the root,
     .git/info/exclude is honored as well.  */
  fz_rule_level lvl = { 0 };
  lvl.dir_len = strlen (rel);
  if (!ix->no_gitignore)
    {
      size_t dirlen0 = strlen (dir);
      char *gi = malloc (dirlen0 + sizeof "/.gitignore");
      if (gi)
        {
          sprintf (gi, "%s/.gitignore", dir);
          fz_rules_load (&lvl, gi);
          free (gi);
        }
      if (lvl.dir_len == 0)
        {
          char *ex = malloc (dirlen0 + sizeof "/.git/info/exclude");
          if (ex)
            {
              sprintf (ex, "%s/.git/info/exclude", dir);
              fz_rules_load (&lvl, ex);
              free (ex);
            }
        }
    }
  if (ix->ign_depth == ix->ign_cap)
    {
      size_t newcap = ix->ign_cap ? ix->ign_cap * 2 : 16;
      fz_rule_level *n = realloc (ix->ign, newcap * sizeof *n);
      if (!n)
        {
          fz_rules_free (&lvl);
          closedir (d);
          return -1;
        }
      ix->ign = n;
      ix->ign_cap = newcap;
    }
  ix->ign[ix->ign_depth++] = lvl;

  struct dirent *de;
  int rc = 0;
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

      size_t dirlen = strlen (dir);
      size_t namelen = strlen (name);
      char *full = malloc (dirlen + 1 + namelen + 1);
      if (!full)
        {
          rc = -1;
          break;
        }
      memcpy (full, dir, dirlen);
      full[dirlen] = '/';
      memcpy (full + dirlen + 1, name, namelen + 1);

      size_t rellen = strlen (rel);
      char *newrel = malloc (rellen + (rellen ? 1 : 0) + namelen + 1);
      if (!newrel)
        {
          free (full);
          rc = -1;
          break;
        }
      if (rellen)
        {
          memcpy (newrel, rel, rellen);
          newrel[rellen] = '/';
          memcpy (newrel + rellen + 1, name, namelen + 1);
        }
      else
        memcpy (newrel, name, namelen + 1);

      struct stat st;
      if (stat (full, &st) == 0)
        {
          bool is_dir = S_ISDIR (st.st_mode) != 0;
          if (fz_ignored (ix, newrel, is_dir))
            rc = 0;
          else if (is_dir)
            rc = fz_scan (ix, full, newrel);
          else if (S_ISREG (st.st_mode))
            rc = fz_index_add (ix, newrel, strlen (newrel));
        }
      free (full);
      free (newrel);
      if (rc)
        break;
    }
  fz_rules_free (&ix->ign[--ix->ign_depth]);
  closedir (d);
  return rc;
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

/* Greedy leftmost subsequence match: fill POS with the match positions
   of PAT in HAY (LEN bytes).  Return 0 on match, -1 otherwise.  */
static int
fz_match_forward (const char *pat, size_t plen, const char *hay,
                  size_t len, size_t *pos)
{
  size_t off = 0;
  for (size_t k = 0; k < plen; k++)
    {
      if (len - off < plen - k)
        return -1;              /* remaining bytes cannot fit pattern */
      const char *p = memchr (hay + off, pat[k], len - off);
      if (!p)
        return -1;
      pos[k] = (size_t) (p - hay);
      off = pos[k] + 1;
    }
  return 0;
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

/* Score an alignment POS of PLEN matched positions against the path STR
   (LEN bytes).  BASENAME is the offset just past the last '/'.  The
   scoring model is the one reverse-engineered from Sublime Text, plus
   a per-byte bonus for matches that land in the file name itself.  */
static int
fz_score_positions (const size_t *pos, size_t plen, const char *str,
                    size_t len, size_t basename)
{
  int score = -(int) (len - plen);
  size_t lead = pos[0] < SCORE_LEADING_MAX ? pos[0] : SCORE_LEADING_MAX;
  score += SCORE_LEADING * (int) lead;
  for (size_t k = 0; k < plen; k++)
    {
      size_t i = pos[k];
      if (k > 0 && i == pos[k - 1] + 1)
        score += SCORE_CONSECUTIVE;
      if (i >= basename)
        score += SCORE_BASENAME;
      if (i > 0 && is_separator (str[i - 1]))
        score += SCORE_SEPARATOR;
      if (i > 0 && islower ((unsigned char) str[i - 1])
          && isupper ((unsigned char) str[i]))
        score += SCORE_CAMEL;
    }
  return score;
}

/* Fuzzy-match PAT (PLEN bytes, already lowercased when CASE_INSENS)
   against the path STR (original bytes) / LOWER (lowercased copy), both
   LEN bytes long.  Match positions are located with memchr/memrchr,
   which are SIMD-optimized, instead of a byte-by-byte scan.  Both the
   leftmost and the rightmost alignment are scored and the better one
   wins: the leftmost favors matches anchored at the start of the path
   (directory queries), the rightmost favors matches anchored in the
   file name.  Returns the score, or NO_MATCH when PAT is not a
   subsequence of the path.  */
static int
fz_score (const char *pat, size_t plen, const char *str,
          const char *lower, size_t len, bool case_insens)
{
  if (plen == 0)
    return -(int) len;
  if (plen > len || plen > FZ_MAX_PATTERN)
    return NO_MATCH;

  const char *hay = case_insens ? lower : str;
  const char *slash = fz_memrchr (str, '/', len);
  size_t basename = slash ? (size_t) (slash - str) + 1 : 0;

  size_t pos[FZ_MAX_PATTERN];
  int best = NO_MATCH;
  if (fz_match_forward (pat, plen, hay, len, pos) == 0)
    best = fz_score_positions (pos, plen, str, len, basename);
  if (fz_match_backward (pat, plen, hay, len, pos) == 0)
    {
      int s = fz_score_positions (pos, plen, str, len, basename);
      if (best == NO_MATCH || s > best)
        best = s;
    }
  return best;
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

typedef struct
{
  const fz_index *ix;
  const char *pat;
  size_t plen;
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
      int score = fz_score (s->pat, s->plen, ix->paths + off,
                            ix->lower + off, ix->lens[ei],
                            s->case_insens);
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
  fz_index *ix = arg;
  int rc = fz_scan (ix, ix->root, "");
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
      if (fz_scan (ix, root, "") != 0)
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

  fz_query_slice slices[FZ_MAX_THREADS];
  pthread_t threads[FZ_MAX_THREADS];
  size_t per = (pool_count + nthreads - 1) / nthreads;
  for (size_t t = 0; t < nthreads; t++)
    {
      slices[t].ix = ix;
      slices[t].pat = pat_lower;
      slices[t].plen = (size_t) (plen - 1);
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
  for (size_t i = nhits; i-- > 0;)
    {
      const char *path = ix->paths + ix->offs[heap[i].idx];
      emacs_value epath
          = env->make_string (env, path, (ptrdiff_t) strlen (path));
      emacs_value escore = env->make_integer (env, heap[i].score);
      emacs_value pair = env->funcall (env, Qcons, 2,
                                       (emacs_value[]) { epath, escore });
      result = env->funcall (env, Qcons, 2,
                             (emacs_value[]) { pair, result });
    }

  free (heap);
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

  emacs_value feat = env->intern (env, "fz-index");
  env->funcall (env, env->intern (env, "provide"), 1,
                (emacs_value[]) { feat });
  return 0;
}
