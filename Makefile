# Build bootable Project Oberon 2013 / Extended Oberon disk images with
# AgentTool.Mod compiled in and our patches applied (port of oberon-agent's
# Makefile onto this repo's dune-built emulator + host tools).
#
# Pipeline per variant V (po | eo):
#   1. tools         -> dune build the emulator + host tools + oat
#   2. <v>-source    -> extract source from a stock disk image
#                       (PO: DiskImage/Oberon-2020-08-18.dsk, vendored here
#                        EO: downloaded S3RISCinstall.tar.gz from upstream)
#   3. <v>-image     -> assemble build/<v>-src/ = source + oat/Mod/<Variant>/ + patches,
#                       then build_{po,eo}_image -> DiskImage/<Variant>Oberon.dsk
#
# `make image` builds both. `make po-image` / `make eo-image` build one each.
# Unlike upstream, `clean` must NOT remove DiskImage/ — the stock PO image is
# vendored there; only the two built images are artifacts. Nor build/ wholesale:
# it is a handy place for other files (SD-card dumps, say), so `clean` removes
# exactly what these rules write there, and `distclean` the EO download too.

# Every recipe runs under `sh -e`: the first failing command fails the target —
# a patch that no longer applies must stop the build, not ship an image without
# it. A target whose recipe fails is deleted, so no half-written image survives.
.SHELLFLAGS := -ec
.DELETE_ON_ERROR:

# The dune command; e.g. DUNE='opam exec --switch default -- dune'.
DUNE        ?= dune

BIN         := _build/default
RISC        := $(BIN)/bin/risc.exe
BUILD_PO    := $(BIN)/tools/bin/build_po_image.exe
BUILD_EO    := $(BIN)/tools/bin/build_eo_image.exe
EXTRACT     := $(BIN)/tools/bin/extract_source.exe
OB2TXT      := $(BIN)/tools/bin/ob2txt.exe
TXT2OB      := $(BIN)/tools/bin/txt2ob.exe
OAT_BIN     := $(BIN)/oat/bin/oat.exe

# Modules shared verbatim by both variants (the AgentProtocol wire server).
COMMON_MODS := $(wildcard oat/Mod/Common/*.Mod)

PO_STOCK    := DiskImage/Oberon-2020-08-18.dsk
PO_SRC      := build/po
PO_IMAGE    := DiskImage/ProjectOberon.dsk
PO_MOD_DIR  := oat/Mod/ProjectOberon
PO_PATCHES  := $(wildcard $(PO_MOD_DIR)/*.patch)
PO_NEW_MODS := $(wildcard $(PO_MOD_DIR)/*.Mod)

# EO stock disk image: downloaded from upstream (not vendored — the full
# Oberon-extended repo is ~12 MB but we only consume this one file). The URL is
# pinned to a known-good commit (git content addressing makes it immutable) and
# the checksum is verified — to move to a newer upstream, update both together.
EO_TARBALL_COMMIT := bf51d8087e04838a1c474ec750004e80055337a6
EO_TARBALL_SHA256 := 3354a7d449377f7defe8df7d3d27b5972a35bb48ebfeb8e3e73762b28c810d12
EO_TARBALL_URL := https://github.com/andreaspirklbauer/Oberon-extended/raw/$(EO_TARBALL_COMMIT)/Documentation/S3RISCinstall.tar.gz
EO_TARBALL  := build/S3RISCinstall.tar.gz
EO_STOCK    := build/eo-stock.dsk
EO_SRC      := build/eo
EO_IMAGE    := DiskImage/ExtendedOberon.dsk
EO_MOD_DIR  := oat/Mod/ExtendedOberon
EO_PATCHES  := $(wildcard $(EO_MOD_DIR)/*.patch)
EO_NEW_MODS := $(wildcard $(EO_MOD_DIR)/*.Mod)

# The image toolchain, by content (see $(TOOLCHAIN_SUM) below).
TOOLCHAIN     := $(BUILD_PO) $(BUILD_EO) $(EXTRACT) $(OB2TXT) $(TXT2OB)
TOOLCHAIN_SUM := build/toolchain.cksum

# GNU tar warns about the macOS pax headers in the EO tarball; others lack the flag.
TAR_QUIET   := $(shell tar --version 2>/dev/null | grep -q GNU && echo --warning=no-unknown-keyword)
SHA256      := $(shell command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo 'shasum -a 256')

FIFO_IN     ?= /tmp/p.in
FIFO_OUT    ?= /tmp/p.out

.PHONY: image po-image eo-image tools oat po-source eo-source po-emu eo-emu check-fifos clean distclean test test-unit test-po test-eo

# Default goal — bare `make` builds both images.
.DEFAULT_GOAL := image

# --- combined targets --------------------------------------------------------

image: po-image eo-image

po-image: tools $(PO_IMAGE)

eo-image: tools $(EO_IMAGE)

# --- PO image ----------------------------------------------------------------

$(PO_IMAGE): $(PO_SRC)/.stamp $(PO_PATCHES) $(PO_NEW_MODS) $(COMMON_MODS) $(TOOLCHAIN_SUM)
	@rm -rf build/po-src && mkdir -p build/po-src
	cp -a $(PO_SRC)/. build/po-src/
	@for p in $(PO_PATCHES); do \
	  m=$$(basename $$p .patch); \
	  $(OB2TXT) build/po-src/$$m >/dev/null; \
	  patch --silent build/po-src/$$m.txt < $$p; \
	  $(TXT2OB) build/po-src/$$m.txt >/dev/null; \
	  rm build/po-src/$$m.txt; \
	done
	@for f in $(COMMON_MODS) $(PO_NEW_MODS); do \
	  name=$$(basename $$f); \
	  cp $$f build/po-src/$$name.txt; \
	  $(TXT2OB) build/po-src/$$name.txt >/dev/null; \
	  rm build/po-src/$$name.txt; \
	done
	$(BUILD_PO) build/po-src $(PO_IMAGE)
	@echo "built $(PO_IMAGE)"

po-source: $(PO_SRC)/.stamp

# Extract into a fresh dir: leftovers from an earlier extraction would be built.
$(PO_SRC)/.stamp: $(PO_STOCK) $(TOOLCHAIN_SUM)
	@rm -rf $(PO_SRC) && mkdir -p $(PO_SRC)
	$(EXTRACT) $(PO_STOCK) $(PO_SRC)
	@touch $@

# --- EO image ----------------------------------------------------------------

$(EO_IMAGE): $(EO_SRC)/.stamp $(EO_PATCHES) $(EO_NEW_MODS) $(COMMON_MODS) $(TOOLCHAIN_SUM)
	@rm -rf build/eo-src && mkdir -p build/eo-src
	cp -a $(EO_SRC)/. build/eo-src/
	@for p in $(EO_PATCHES); do \
	  m=$$(basename $$p .patch); \
	  $(OB2TXT) build/eo-src/$$m >/dev/null; \
	  patch --silent build/eo-src/$$m.txt < $$p; \
	  $(TXT2OB) build/eo-src/$$m.txt >/dev/null; \
	  rm build/eo-src/$$m.txt; \
	done
	@for f in $(COMMON_MODS) $(EO_NEW_MODS); do \
	  name=$$(basename $$f); \
	  cp $$f build/eo-src/$$name.txt; \
	  $(TXT2OB) build/eo-src/$$name.txt >/dev/null; \
	  rm build/eo-src/$$name.txt; \
	done
	$(BUILD_EO) build/eo-src $(EO_IMAGE)
	@echo "built $(EO_IMAGE)"

eo-source: $(EO_SRC)/.stamp

$(EO_SRC)/.stamp: $(EO_TARBALL) $(TOOLCHAIN_SUM)
	@mkdir -p build
	tar $(TAR_QUIET) -xzf $(EO_TARBALL) \
	  -C build --strip-components=1 S3RISCinstall/RISC.img
	mv build/RISC.img $(EO_STOCK)
	@rm -rf $(EO_SRC)
	$(EXTRACT) $(EO_STOCK) $(EO_SRC)
	@touch $@

$(EO_TARBALL):
	@mkdir -p build
	@echo "downloading $(EO_TARBALL_URL)"
	@if command -v curl >/dev/null 2>&1; then \
	  curl -fsSL -o $@.tmp $(EO_TARBALL_URL); \
	elif command -v wget >/dev/null 2>&1; then \
	  wget -q -O $@.tmp $(EO_TARBALL_URL); \
	else \
	  echo "need curl or wget to fetch the EO stock image" >&2; exit 1; \
	fi
	@got=$$($(SHA256) $@.tmp | cut -d' ' -f1); \
	if [ "$$got" != "$(EO_TARBALL_SHA256)" ]; then \
	  echo "$@: checksum mismatch — refusing to build from it" >&2; rm -f $@.tmp; exit 1; \
	fi
	@mv $@.tmp $@

# --- prerequisites -----------------------------------------------------------

# dune owns staleness for every binary; a cheap no-op when nothing changed.
tools:
	$(DUNE) build

# The toolchain's checksum, rewritten only when it changes. The images depend on
# it rather than on the binaries' mtimes, so a changed builder, compiler seed or
# converter rebuilds them, and a no-op `dune build` does not. (`tools` is phony,
# so this recipe runs every time; make re-reads the stamp's mtime afterwards.)
$(TOOLCHAIN_SUM): tools
	@mkdir -p build
	@cksum $(TOOLCHAIN) >$@.tmp
	@if cmp -s $@.tmp $@; then rm $@.tmp; else mv $@.tmp $@; fi

oat: tools

# --- run ---------------------------------------------------------------------

# `make {eo,po}-emu` builds the image if stale, then boots it on the FIFO pair.
# Override the FIFOs with `make eo-emu FIFO_IN=... FIFO_OUT=...`.
eo-emu: eo-image check-fifos
	$(RISC) --serial-in $(FIFO_IN) --serial-out $(FIFO_OUT) $(EO_IMAGE)

po-emu: po-image check-fifos
	$(RISC) --serial-in $(FIFO_IN) --serial-out $(FIFO_OUT) $(PO_IMAGE)

# Verify both FIFOs exist and are actually named pipes (vs missing or a
# regular file someone `touch`ed by accident).
check-fifos:
	@for f in $(FIFO_IN) $(FIFO_OUT); do \
	  if [ ! -e "$$f" ]; then \
	    echo "missing FIFO: $$f" >&2; \
	    echo "  create with: mkfifo $(FIFO_IN) $(FIFO_OUT)" >&2; \
	    exit 1; \
	  elif [ ! -p "$$f" ]; then \
	    echo "not a FIFO (regular file?): $$f" >&2; \
	    echo "  remove it and run: mkfifo $(FIFO_IN) $(FIFO_OUT)" >&2; \
	    exit 1; \
	  fi; \
	done

# --- tests -------------------------------------------------------------------

# `make test` = the dune suite + live integration battery on both images.
# The integration script boots the emulator headless on a private FIFO pair
# and drives oat against the running system: see test/integration.sh.
test: test-unit test-po test-eo

test-unit:
	$(DUNE) runtest

test-po: po-image
	test/integration.sh $(PO_IMAGE) $(RISC) $(OAT_BIN)

test-eo: eo-image
	test/integration.sh $(EO_IMAGE) $(RISC) $(OAT_BIN)

# --- cleanup -----------------------------------------------------------------

# Exactly what the rules above write; anything else in build/ is left alone.
clean:
	rm -rf $(PO_SRC) $(EO_SRC) build/po-src build/eo-src
	rm -f $(EO_STOCK) build/RISC.img $(EO_TARBALL).tmp $(TOOLCHAIN_SUM) $(TOOLCHAIN_SUM).tmp
	rm -f $(PO_IMAGE) $(EO_IMAGE)

# clean, plus the EO download (the next eo-image fetches it again).
distclean: clean
	rm -f $(EO_TARBALL)
