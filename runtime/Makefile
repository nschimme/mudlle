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

.PHONY: wrong-file
wrong-file:
	$(error Use Makefile in the parent directory)

runtime/bigint.$(OBJEXT): CFLAGS:=-Wno-invalid-source-encoding $(CFLAGS)

RTSRC:=$(addprefix runtime/, arith.c basic.c bigint.c bitset.c bool.c	\
        debug.c files.c io.c list.c llvm.c mudlle-float.c mudlle-string.c\
        mudlle-xml.c mudllecst.c pattern.c runtime.c support.c		\
        symbol.c vector.c)

mudlle: $(RTSRC:%.c=%.$(OBJEXT))

CSTFILES := error.h module.h mtree.h print.h profile.h tree.h types.h	\
	runtime/basic.h runtime/debug.h runtime/files.h runtime/io.h	\
	runtime/runtime.h runtime/support.h

ifneq ($(USE_XML),)
XML_CFLAGS:=$(shell xml2-config --cflags || echo ' !!!FAIL!!! ')
ifneq ($(filter !!!FAIL!!!, $(XML_CFLAGS)),)
$(error Failed running xml2-config)
endif
XML_CFLAGS:=$(patsubst -I%,-isystem %,$(XML_CFLAGS))
CPPFLAGS += $(XML_CFLAGS)
CSTFILES += runtime/mudlle-xml.h
endif

RTDEPFILE:=runtime/.depend

.PHONY: clean_runtime

clean: clean_runtime
clean_runtime:
	rm -f runtime/*.$(OBJEXT) runtime/*.i runtime/mudllecst.c $(RTDEPFILE)
	rmdir runtime 2>/dev/null || true

runtime/mudllecst.c: runtime/consts.pl runtime/Makefile $(CSTFILES)
	@echo "Creating $@"
	$(Q)LC_ALL=C $(PERL) $< -o $@ -- $(wordlist 3,$(words $^),$^)

$(RTDEPFILE): $(ARCHDEP) $(RTSRC) $(OBJDEP)
	@echo "Creating $@"
	$(Q)$(MAKEDEPEND) $(CPPFLAGS) $(CFLAGS) $(wordlist 2,$(words $^),$^) \
		| sed 's!^\(.*\)\.o *:!runtime/\1.$(OBJEXT):!g' > $@

ifneq (,$(depfile))
ifeq (,$(wildcard $(RTDEPFILE)))
-include $(RTDEPFILE)
else
include $(RTDEPFILE)
endif
endif
