/* bench-gen-tree.c -- deterministic Chromium-like tree for fz-index bench.el.

   Generates a synthetic source tree whose path lengths and directory
   depth resemble a Chromium checkout, so index build/query numbers
   are reproducible across machines.  Paths are 3-4 components deep
   under a fixed set of top-level and mid-level directory names; the
   LCG seed is fixed, so the same N always yields the same tree.

   Usage:
     gcc -O2 -std=c99 bench-gen-tree.c -o bench-gen-tree
     ./bench-gen-tree [ROOT [COUNT]]        (defaults: bench-tree 400000)

   Files are empty; only their names matter to the index.
   Deterministic, no network, no Emacs dependency.  */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#ifdef _WIN32
#include <direct.h>
#endif

static unsigned long long rng = 0x1234ABCD;
static unsigned long next (void)
{
  rng = rng * 6364136223846793005ULL + 1442695040888963407ULL;
  return (unsigned long) (rng >> 33);
}

static void
make_dir_chain (const char *path)
{
  char tmp[1024];
  size_t i, len = strlen (path);
  if (len >= sizeof tmp)
    exit (1);
  memcpy (tmp, path, len + 1);
  for (i = 0; i < len; i++)
    if (tmp[i] == '/' || tmp[i] == '\\')
      {
        tmp[i] = '\0';
#ifdef _WIN32
        _mkdir (tmp);
#else
        mkdir (tmp, 0777);
#endif
        tmp[i] = '/';
      }
#ifdef _WIN32
  _mkdir (tmp);
#else
  mkdir (tmp, 0777);
#endif
}

int
main (int argc, char **argv)
{
  static const char *top[] = {
    "base", "chrome", "content", "net", "ui", "components",
    "services", "third_party"
  };
  static const char *mid[] = {
    "browser", "renderer", "core", "common", "gpu", "storage",
    "strings", "security", "net", "media", "ui", "views",
    "platform", "fipsmodule", "src", "internal", "generated"
  };
  static const char *fn[] = {
    "document", "widget", "manager", "handler", "string_util",
    "browser_frame", "url_loader", "network_context", "render_frame",
    "navigation", "protocol", "session", "test", "util", "model",
    "view", "controller", "service", "factory", "impl"
  };
  static const char *ext[] = { ".cc", ".h", ".cpp", ".c", ".mm" };
  const char *root = (argc > 1) ? argv[1] : "bench-tree";
  int total = (argc > 2) ? atoi (argv[2]) : 400000;
  int i;
  long ntop = sizeof top / sizeof *top, nmid = sizeof mid / sizeof *mid;
  long nfn = sizeof fn / sizeof *fn, next2 = sizeof ext / sizeof *ext;
  char path[1024], dir[1024];
  long sumlen = 0;

  make_dir_chain (root);
  for (i = 0; i < total; i++)
    {
      /* 3 fixed levels plus a fourth with probability 2/3: deep
         enough to resemble Chromium's third_party nesting while
         keeping the path-slot space (8*17^3*100 ~ 39M) far above
         COUNT, so the generated paths are collision-free.  */
      const char *t = top[next () % ntop];
      const char *m1 = mid[next () % nmid];
      const char *m2 = mid[next () % nmid];
      const char *m3 = mid[next () % nmid];
      const char *m4 = (next () % 3 != 0) ? mid[next () % nmid] : NULL;
      const char *f = fn[next () % nfn];
      const char *e = ext[next () % next2];
      char *p = path;
      int n = snprintf (p, sizeof path, "%s/%s", root, t);
      p += n;
      n = snprintf (p, sizeof path - (size_t) (p - path), "/%s", m1);
      p += n;
      n = snprintf (p, sizeof path - (size_t) (p - path), "/%s", m2);
      p += n;
      n = snprintf (p, sizeof path - (size_t) (p - path), "/%s", m3);
      p += n;
      if (m4)
        {
          n = snprintf (p, sizeof path - (size_t) (p - path), "/%s", m4);
          p += n;
        }
      snprintf (p, sizeof path - (size_t) (p - path), "/%s%s", f, e);
      sumlen += (long) strlen (path) + 1;
      {
        char *slash = strrchr (path, '/');
        if (slash)
          {
            size_t dlen = (size_t) (slash - path);
            memcpy (dir, path, dlen);
            dir[dlen] = '\0';
            make_dir_chain (dir);
          }
      }
      {
        FILE *fp = fopen (path, "wb");
        if (!fp)
          {
            fprintf (stderr, "cannot create %s\n", path);
            return 1;
          }
        fclose (fp);
      }
    }
  fprintf (stderr,
           "created %d files under %s (avg rel path %.1f bytes incl NUL)\n",
           total, root, (double) sumlen / total);
  return 0;
}
