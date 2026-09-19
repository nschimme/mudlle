#                                                              -*- makefile -*-

# Copyright (c) 1993-2012 David Gay and Gustav Hållberg
# All rights reserved.
#
# Permission to use, copy, modify, and distribute this software for any
# purpose, without fee, and without written agreement is hereby granted,
# provided that the above copyright notice and the following two paragraphs
# appear in all copies of this software.
#
# IN NO EVENT SHALL DAVID GAY OR GUSTAV HALLBERG BE LIABLE TO ANY PARTY FOR
# DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT
# OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF DAVID GAY OR
# GUSTAV HALLBERG HAVE BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# DAVID GAY AND GUSTAV HALLBERG SPECIFICALLY DISCLAIM ANY WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
# FITNESS FOR A PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS ON AN
# "AS IS" BASIS, AND DAVID GAY AND GUSTAV HALLBERG HAVE NO OBLIGATION TO
# PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.

# disable built-in rules
.SUFFIXES:

srcdir := $(dir $(lastword $(MAKEFILE_LIST)))
OBJEXT := o

VPATH:=$(srcdir)

USE_GMP        := yes
# USE_ICU        := yes
# USE_LPSOLVE    := yes
# LPSOLVE_HEADER := LP_LIB_H            # for <lp_lib.h>
# LPSOLVE_HEADER := LPSOLVE_LP_LIB_H    # for <lpsolve/lp_lib.h>
# NOCOMPILER     := yes
# USE_PCRE       := yes
USE_READLINE   := yes
# USE_VALGRIND   := yes
# USE_XML        := yes

ifeq ($(verbose),yes)
  Q :=
else
  Q := @
endif

ifeq ($(optimize),no)
  NO_OPT := t
endif

ARCH := $(shell uname -m)
ifneq ($(filter x86-64 x86_64 x64,$(ARCH)),)
override ARCH := amd64
endif

ifeq ($(shell uname -s),Darwin)
DARWIN := t
else
DARWIN :=
endif

ifeq ($(filter amd64 arm64,$(ARCH)),)
$(error Unsupported ARCH=$(ARCH); expected amd64 or arm64)
endif

ifeq ($(ARCH),amd64)
ARCHFLAG := -m64
MUDARCH := x64
ARCH_CFLAGS := -fpie
ARCH_LDFLAGS := -fpie $(if $(DARWIN),-Xlinker) -pie
endif

ifeq ($(ARCH),arm64)
NOCOMPILER := yes
endif

_:=$(shell [ -e compiler ] || ln -s $(srcdir) compiler)

ifeq ($(NOCOMPILER),)
BUILTINS := $(MUDARCH)builtins.$(OBJEXT)
BUILTINDEPS := $(MUDARCH)consts.h
else
endif

CPP_INDENT ?= | indent

ARCHDEP:=.mudlle-arch

OLD_ARCH:=$(shell [ -f $(ARCHDEP) ] && cat $(ARCHDEP))
ifneq ($(OLD_ARCH),$(ARCH))
 ifneq ($(OLD_ARCH),)
  $(info Architecture changed. Recompiling.)
 endif
.PHONY: $(ARCHDEP)
endif

$(ARCHDEP):
	@echo "$(ARCH)" > $@

OBJDEP:=$(ARCHDEP) mudlle-macro-n.h

SRC := alloc.c array.c assoc.c call.c calloc.c charset.c compile.c	\
	context.c dlist.c dwarf.c elf.c env.c error.c global.c hash.c	\
	inline.c ins.c interpret.c jitdump.c lexer.c mcompile.c		\
	module.c mtree.c mudlle-main.c mudlle.c objenv.c parser.tab.c	\
	ports.c print.c profile.c random.c stack.c strbuf.c table.c	\
	tree.c types.c utils.c

OBJS := $(BUILTINS) $(SRC:%.c=%.$(OBJEXT))

warnings := all missing-declarations missing-prototypes nested-externs	\
        shadow unused-macros write-strings

ifeq ($(DARWIN),)
MARCH_NATIVE:=-march=native 
else
MARCH_NATIVE:=
endif

CC := gcc -std=gnu11
CFLAGS := $(MARCH_NATIVE) -g3 $(if $(NO_OPT),-O0,-O2) \
	$(addprefix -W,$(warnings)) $(ARCH_CFLAGS)
CPPFLAGS := $(ARCHFLAG)
override CPPFLAGS += -I. -I$(srcdir)
LDFLAGS := $(ARCHFLAG) $(ARCH_LDFLAGS)
LIBS := -lm
MAKEDEPEND = $(CC) -MM
PERL := perl

ifneq ($(NOCOMPILER),)
CFLAGS += -DNOCOMPILER=1
endif

ifneq ($(DARWIN),)
override CPPFLAGS += $(addprefix -isystem , \
	$(wildcard /opt/local/include $(HOMEBREW_PREFIX)/include))
override LDFLAGS += $(addprefix -L, \
	$(wildcard /opt/local/lib $(HOMEBREW_PREFIX)/lib))
LIBS += -liconv
endif # DARWIN

export CC CFLAGS CPPFLAGS LDFLAGS MAKEDEPEND PERL

ifneq ($(USE_GMP),)
override CPPFLAGS += -DUSE_GMP
LIBS += -lgmp
endif

ifneq ($(USE_ICU),)
override CPPFLAGS += -DUSE_ICU
LIBS += -licuuc
endif

ifneq ($(USE_LPSOLVE),)
override CPPFLAGS += -DUSE_LPSOLVE -DHAVE_$(LPSOLVE_HEADER)
LIBS += -llpsolve55 -ldl -lcolamd -lsuitesparseconfig
endif

ifneq ($(USE_PCRE),)
override CPPFLAGS += -DUSE_PCRE
LIBS += -lpcre2-8
endif

ifneq ($(USE_READLINE),)
override CPPFLAGS += -DUSE_READLINE
LIBS += -lreadline
endif

ifneq ($(USE_VALGRIND),)
override CPPFLAGS += -DHAVE_VALGRIND_MEMCHECK_H
endif

ifneq ($(USE_XML),)
override CPPFLAGS += -DUSE_XML $(shell xml2-config --cflags)
LIBS += -lxml2
endif

NO_UNUSED_MACROS:=$(BUILTINS)
charset.$(OBJEXT): CFLAGS:=-Wno-invalid-source-encoding $(CFLAGS)

.PHONY: all
all: mudlle

mudlle: $(OBJS)
	@echo "Linking $@"
	$(Q)$(CC) $(LDFLAGS) -o $@ $^ $(LIBS)

.PHONY: clean depclean
depclean:
	rm -f .depend $(RTDEPFILE)

clean:
	rm -f *.$(OBJEXT) *.i *.obj lexer.c tokens.h parser.tab.c	\
	    parser.tab.h .depend compiler genconst			\
	    genconstdefs.h mudlle mudlle-macro-n.h parser.output	\
	    x64consts.h $(ARCHDEP)					\
	    $(addprefix build0/,*.obj .comp*)				\
	    $(addprefix build1/,*.obj .comp*)				\
	    $(addprefix build2/,.comp*)
	rmdir build0 build1 build2 2>/dev/null || true

ifneq (yes,$(cpp))
%.$(OBJEXT): %.c $(OBJDEP)
	@echo "Compiling $(patsubst $(srcdir)%,%,$<)"
	$(Q)$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ -c $<
else
%.$(OBJEXT): %.i
	@echo "Compiling $(patsubst $(srcdir)%,%,$<)"
	$(Q)$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ -c $<

.PRECIOUS: %.i
%.i: %.c $(OBJDEP)
	@echo "Creating $@"
	$(Q)$(CC) $(CPPFLAGS) $(CFLAGS) -E $< | LC_ALL=C grep -a -v '^#' \
	    $(subst {FILENAME},$<,$(CPP_INDENT)) > $@
endif

.depend parser.tab.$(OBJEXT) lexer.$(OBJEXT) $(NO_UNUSED_MACROS): \
	CFLAGS:=$(filter-out -Wunused-macros,$(CFLAGS))

lexer.$(OBJEXT): parser.tab.h

lexer.c: lexer.l
	@echo "Creating $@"
	$(Q)flex -CFe -8 -o $@ $<

%.tab.c %.tab.h: %.y
	@echo "Generating $*.tab.[ch]"
	$(Q)bison -dtv $<

$(MUDARCH)builtins.$(OBJEXT): $(MUDARCH)builtins.S $(BUILTINDEPS) $(OBJDEP)
	@echo "Compiling $(patsubst $(srcdir)%,%,$<)"
	$(Q)$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(MUDARCH)consts.h: genconst Makefile
	@echo "Creating $@"
	$(Q)./genconst > $@

genconst: genconst.$(OBJEXT) Makefile
	@echo "Linking $@"
	$(Q)$(CC) $(LDFLAGS) -o $@ $<

genconst.$(OBJEXT) genconst.i: genconstdefs.h

ASM_CONST_H := context.h error.h mvalues.h types.h

genconstdefs.h: runtime/consts.pl Makefile $(ASM_CONST_H)
	@echo "Creating $@"
	$(Q)LC_ALL=C $(PERL) $< -d -o $@ -- $(wordlist 3, $(words $^), $^)

mudlle-macro-n.h: make-macro-n.pl
	@echo "Creating $@"
	$(Q)LC_ALL=C $(PERL) $< > $@

.PHONY: dep depend
dep depend: .depend
	@mkdir -p runtime
	$(Q)$(MAKE) -C runtime -f $(srcdir)Makefile depend

.depend: $(SRC) genconst.c genconstdefs.h $(BUILTINS:%.$(OBJEXT)=%.S) \
	    $(BUILTINDEPS) $(OBJDEP)
	@echo "Creating $@"
	$(Q)$(MAKEDEPEND) $(CPPFLAGS) $(CFLAGS)		\
		$(filter-out %.h $(ARCHDEP),$^)		\
		> $@

.PHONY: compiler

ifeq ($(NOCOMPILER),)

MUD_FILES := $(patsubst %, $(srcdir)%.mud, a$(MUDARCH) compile		\
	compiler cxc dihash dlist flow gen$(MUDARCH) graph icxc		\
	inference ins3 interface ixc lib link misc m$(MUDARCH) noinf	\
	optimise phase1 phase2 phase3 phase4 pxslow sequences vars	\
	$(MUDARCH) xc)

# Currently 22 files, split into at most 8 groups for parallel builds
GROUPS=0 1 2 3 4 5 6 7

define BUILDER # <workdir> <dstdir> <loader> <parentrule> <parendir> <group>
$(1)/.comp-$(6): build-slice.sh $(4)
	@echo "Compiling $(1) ($(3)) compiler files $(6)/$(words $(GROUPS))"
	$(Q)mkdir -p $(1)
	$(Q)/bin/sh $$< $(srcdir) $(5) $(2) $(3) $(6) $(words $(GROUPS))
	$(Q)touch $$@
endef

define PASS	# <workdir> <dstdir> <loader> <parentrule> <parentdir>
$$(foreach g, $$(GROUPS), \
    $$(eval $$(call BUILDER,$(1),$(2),$(3),$(4),$(5),$$(g))))

$(1)/.compiler: $$(foreach g,$$(GROUPS),$(1)/.comp-$$(g))
	$(Q)touch $$@

endef

$(eval $(call PASS,build0,build0,xc,mudlle $(MUD_FILES),unused))
$(eval $(call PASS,build1,build1,icxc,build0/.compiler,build0))
$(eval $(call PASS,build2,.,icxc,build1/.compiler,build1))

compiler: build2/.compiler

else

compiler:
	@echo "The compiler is not supported on $(ARCH)" >&2 && false

endif # ! NOCOMPILER


COMPILER_HELP:=$(if $(NOCOMPILER), (not on $(ARCH)))

.PHONY: help
help:
	@echo 'Available make targets:' ;				\
	echo '  mudlle    the mudlle binary (default)' ;		\
	echo '  compiler  the mudlle compiler$(COMPILER_HELP)' ;	\
	echo '  clean     remove build files' ;				\
	echo '  depclean  remove dependency files' ;			\
	echo ;								\
	echo 'Useful make variables:' ;					\
	echo '  ARCH      set to "$(ARCH)" (default)' ;			\
	echo '  cpp       set to "yes" to save CPP-processed files' ;	\
	echo '  optimize  set to "no" for -O0 builds' ;			\
	echo '  verbose   set to "yes" for verbose builds'

depfile:=.depend

# include dependency files unless we are only running cleaning targets
NO_DEP_TGT:=clean depclean help

ifneq (,$(MAKECMDGOALS))
ifeq ($(MAKECMDGOALS),$(filter $(NO_DEP_TGT),$(MAKECMDGOALS)))
depfile:=
endif
endif

include $(srcdir)/runtime/Makefile

ifeq (,$(wildcard $(depfile)))
-include $(depfile)
else
include $(depfile)
endif
