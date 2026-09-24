CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -std=c99 -fPIC
UNAME_S := $(shell uname -s)

# The module's basename must differ from fz-index.el's: load-suffixes
# puts the module suffix first, so a "fz-index.so" next to
# "fz-index.el" shadows the library on every autoload.
ifeq ($(UNAME_S),Darwin)
SO      = fz-index-core.dylib
SHARED  = -dynamiclib
else
SO      = fz-index-core.so
SHARED  = -shared
endif

all: $(SO)

$(SO): fz-index.c emacs-module.h
	$(CC) $(CFLAGS) $(SHARED) -o $@ fz-index.c -lpthread

clean:
	rm -f $(SO)

# Cross-compile the Windows module (needs gcc-mingw-w64-x86-64).
MINGW_CC ?= x86_64-w64-mingw32-gcc

fz-index-core.dll: fz-index.c emacs-module.h
	$(MINGW_CC) $(CFLAGS) -shared -o $@ fz-index.c -lpthread

.PHONY: all clean
