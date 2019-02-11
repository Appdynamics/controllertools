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

SOURCES_USING_LIB = 	controller_dbtool.sh

EMBEDDED_SOURCES =	$(SOURCES_USING_LIB:.sh=_e.sh)


all: $(EMBEDDED_SOURCES) Makefile

%_e.sh: %.sh $(EMBEDDER)
	$(EMBED) $< > $@

# useful debug aid. View variables on cmd line with:
#  make print-SOURCES print-BASH_SRC_EMBEDDED
print-%:
	@echo '$*=$($*)'
