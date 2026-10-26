(lang dune 3.0)

(generate_opam_files true)

(name oberon-risc-emu)

(source
 (github zxygentoo/oberon-risc-emu-ocaml))

(license ISC)

(authors "zxy <zxygentoo@gmail.com>")

(maintainers "zxy <zxygentoo@gmail.com>")

; Three packages, so a consumer of the machine never pulls in SDL: the core library
; (OCaml's own distribution only), the SDL frontend, and the host tools. They are
; released together, at one version (Oberon_risc.Version.version).

(package
 (name oberon-risc)
 (synopsis "Bit-exact emulator core for Wirth's RISC5 machine (Project Oberon)")
 (description
  "The RISC5 machine that runs Niklaus Wirth's Project Oberon (2013), as a\nlibrary: CPU and software floating point, the memory map and MMIO, the SPI\nSD card, serial and PCLink, the clipboard bridge, the instruction codec, and a\ndeterministic headless driver. A port of Peter De Wachter's oberon-risc-emu,\nverified against its C reference instruction by instruction. Needs nothing\nbeyond the OCaml distribution.")
 (depends
  (ocaml
   (>= 5.1))
  (qcheck-core
   (and
    (>= 0.90)
    :with-test))))

(package
 (name oberon-risc-emu)
 (synopsis "SDL2 frontend for the oberon-risc RISC5 emulator: the risc command")
 (description
  "The `risc` command: boots a Project Oberon disk image in a window (tsdl/SDL2),\nwith the C frontend's options and hotkeys, PNG screenshots, a raw serial line,\nand a deterministic headless mode that prints the boot's FNV-1a hashes.")
 (depends
  (ocaml
   (>= 5.1))
  (oberon-risc
   (= :version))
  (tsdl
   (>= 1.0.0))
  (imagelib
   (>= 20210511))
  (qcheck-core
   (and
    (>= 0.90)
    :with-test))))

(package
 (name oberon-risc-tools)
 (synopsis
  "Host tools for Project Oberon disk images: converters, extractor, image builders")
 (description
  "ob2txt / txt2ob convert Oberon text to and from host text; extract-source\nunpacks a build-ready source tree from a disk image; build-po-image and\nbuild-eo-image compile a tree into a bootable Project Oberon 2013 or Extended\nOberon image, driving the Oberon compiler headless with the bootstrap\ntoolchain embedded. Also oat, an experimental client for driving a live\nOberon over a serial line (outside the stability promise).")
 (depends
  (ocaml
   (>= 5.1))
  (oberon-risc
   (= :version))
  (crunch
   (and
    (>= 3.3.0)
    :build))))
