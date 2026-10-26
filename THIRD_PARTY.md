# Third-party material

What in this repository comes from elsewhere, where it came from, and the terms it
carries. Everything not listed here is this project's own work under the ISC license
in [`LICENSE`](LICENSE).

| Path | What it is | Upstream | Terms |
| --- | --- | --- | --- |
| `lib/`, `bin/` | The emulator: an OCaml port (by way of the Rust port [`oberon-risc-emu-rs`][rs], same author as this repository) of Peter De Wachter's C emulator | [`pdewacht/oberon-risc-emu`][c] | ISC, © 2014 Peter De Wachter — [notice A](#a-oberon-risc-emu) |
| `lib/boot_rom.ml`, `test/cosim/risc-boot.inc` | The Project Oberon boot loader PROM image, as the C reference carries it | [`pdewacht/oberon-risc-emu`][c] `src/risc-boot.inc` | [notice A](#a-oberon-risc-emu); the image itself is Project Oberon 2013 software — [notice B](#b-project-oberon-2013) |
| `lib/fp.ml` | Port of the C reference's software floating point (`risc-fp.c`) | [`pdewacht/oberon-risc-emu`][c] | [notice A](#a-oberon-risc-emu) |
| `test/cosim/risc.c`, `risc.h`, `risc-io.h`, `risc_fp.c`, `risc-fp.h`, `risc-boot.inc` | The C reference itself, vendored unmodified for the differential tests (`risc_fp.c` is `risc-fp.c` renamed) | [`pdewacht/oberon-risc-emu`][c] `src/` at `26c8ac5` (2020-08-18) | [notice A](#a-oberon-risc-emu) |
| `test/data/fp_vectors.txt` | Floating-point test vectors: the output of [`oberon-risc-emu-rs`][rs]'s `tools/gen_fp_vectors.c` run over the C reference's `risc-fp.c` | [`pdewacht/oberon-risc-emu`][c] | [notice A](#a-oberon-risc-emu) |
| `DiskImage/Oberon-2020-08-18.dsk` | A Project Oberon 2013 system disk image | [`pdewacht/oberon-risc-emu`][c] `DiskImage/` at `26c8ac5` | [notice B](#b-project-oberon-2013) |
| `assets/common/`, `assets/po/` | The headless build toolchain's host glue (Oberon modules derived from Project Oberon 2013) and its bootstrap objects | Peter De Wachter's [`project-norebo`][norebo] (`Norebo/`, `Bootstrap/`), by way of [`oberon-risc-emu-rs`][rs]'s `crates/host-tools/assets/` | project-norebo's `license.txt`, which is [notice B](#b-project-oberon-2013) |
| `assets/eo/` | The same for Extended Oberon: host glue adapted from Extended Oberon's modules and project-norebo's, and bootstrap objects compiled from Extended Oberon | Andreas Pirklbauer's [Extended Oberon][eo], by way of [`oberon-risc-emu-rs`][rs] | Extended Oberon derives from Project Oberon 2013 ([notice B](#b-project-oberon-2013)); **its repository states no license of its own** for Andreas Pirklbauer's changes |
| `oat/` | The live-system serial client and its on-system modules | [`zxygentoo/oberon-agent`][oa], released under the MIT license by its author — the author of this repository, who relicenses it here under ISC | ISC ([`LICENSE`](LICENSE)) |
| `oat/Mod/ProjectOberon/Oberon.Mod.patch`, `oat/Mod/ExtendedOberon/Oberon.Mod.patch` | Patches whose context lines quote `Oberon.Mod` from Project Oberon 2013 and from Extended Oberon | as above | [notice B](#b-project-oberon-2013) for the quoted lines |

Not vendored: the root `Makefile` downloads Extended Oberon's stock image
(`Documentation/S3RISCinstall.tar.gz`, pinned to a commit and checksum) at build time.

## Notices

### A. oberon-risc-emu

```
Copyright © 2014 Peter De Wachter

Permission to use, copy, modify, and/or distribute this software for
any purpose with or without fee is hereby granted, provided that the
above copyright notice and this permission notice appear in all
copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL
DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR
PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.
```

### B. Project Oberon 2013

```
Project Oberon, Revised Edition 2013

Book copyright (C)2013 Niklaus Wirth and Juerg Gutknecht;
software copyright (C)2013 Niklaus Wirth (NW), Juerg Gutknecht (JG), Paul
Reed (PR/PDR).

Permission to use, copy, modify, and/or distribute this software and its
accompanying documentation (the "Software") for any purpose with or
without fee is hereby granted, provided that the above copyright notice
and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHORS DISCLAIM ALL WARRANTIES
WITH REGARD TO THE SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY, FITNESS AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS BE LIABLE FOR ANY CLAIM, SPECIAL, DIRECT, INDIRECT, OR
CONSEQUENTIAL DAMAGES OR ANY DAMAGES OR LIABILITY WHATSOEVER, WHETHER IN
AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE DEALINGS IN OR USE OR PERFORMANCE OF THE SOFTWARE.
```

[c]: https://github.com/pdewacht/oberon-risc-emu
[rs]: https://github.com/zxygentoo/oberon-risc-emu-rs
[norebo]: https://github.com/pdewacht/project-norebo
[eo]: https://github.com/andreaspirklbauer/Oberon-extended
[oa]: https://github.com/zxygentoo/oberon-agent
