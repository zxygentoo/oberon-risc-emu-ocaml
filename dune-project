(lang dune 3.0)
(generate_opam_files true)
(name oberon-risc-emu)
(source
 (github zxygentoo/oberon-risc-emu-ocaml))
(license ISC)
(authors "zxy")
(maintainers "zxygentoo@gmail.com")

(package
 (name oberon-risc-emu)
 (allow_empty)
 (synopsis "Bit-exact OCaml port of the Oberon RISC emulator")
 (description
  "An OCaml port of Peter De Wachter's oberon-risc-emu, an emulator for the\nRISC5 machine that runs Niklaus Wirth's Project Oberon (2013). Uses tsdl\n(SDL2) for the window, rendering, and input.")
 (depends
  (ocaml (>= 5.1))
  tsdl
  imagelib
  (crunch :build)
  (qcheck-core :with-test)))
