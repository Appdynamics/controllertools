#
# Makefile to prepare files for distribution
#

#
# @(#) $Id: Makefile 1.2 2016-06-07 23:03:28 rob.navarro $
#

.POSIX:

SHELL = 	/bin/bash
EMBEDDER :=	../embed.pl
EMBED :=	perl $(EMBEDDER)

BASH_LIBS= ../obfus_lib.sh
SOURCES_USING_LIB := $(wildcard mon*[0-9].sh)

#$(warning SOURCES_USING_LIB= $(SOURCES_USING_LIB) )
EMBEDDED_SOURCES := $(patsubst %.sh, %_e.sh, $(SOURCES_USING_LIB))

all: $(EMBEDDED_SOURCES)

%_e.sh: %.sh $(EMBEDDER) $(BASH_LIBS) Makefile
	$(EMBED) $< > $@

# https://www.cmcrossroads.com/article/printing-value-makefile-variable
# useful debug aid. View variables on cmd line with:
#  make print-SOURCES print-BASH_SRC_EMBEDDED
print-%:
	@echo '$*=$($*)'
