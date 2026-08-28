CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -std=c99 -fPIC
UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
SO      = fz-index.dylib
SHARED  = -dynamiclib
else
SO      = fz-index.so
SHARED  = -shared
endif

all: $(SO)

$(SO): fz-index.c emacs-module.h
	$(CC) $(CFLAGS) $(SHARED) -o $@ fz-index.c -lpthread

clean:
	rm -f $(SO)

# Cross-compile the Windows module (needs gcc-mingw-w64-x86-64).
MINGW_CC ?= x86_64-w64-mingw32-gcc

fz-index.dll: fz-index.c emacs-module.h
	$(MINGW_CC) $(CFLAGS) -shared -o $@ fz-index.c -lpthread

.PHONY: all clean
