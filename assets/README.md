# Vendored toolchain assets

These files are vendored from Peter De Wachter's
[project-norebo](https://github.com/pdewacht/project-norebo) and from
[Extended Oberon](https://github.com/andreaspirklbauer/Oberon-extended) (Andreas Pirklbauer),
and embedded into the `build-po-image` / `build-eo-image` binaries (via
`include_bytes!`) so they can build a bootable disk image without an external
checkout.

A build's *toolchain seed* is the host-side glue (Oberon modules adapted to talk to
the host filesystem instead of FPGA hardware) plus the prebuilt objects that seed
the first compile — you need a working Oberon to compile Oberon. The layout splits
the glue into what the two systems share and what is system-specific:

```
common/        host glue shared by both builders, byte-for-byte:
               Norebo, FileDir, Files, VDisk, VFileDir, VFiles, VDiskUtil
po/
  glue/        Project Oberon 2013 glue: Kernel, Oberon, CoreLinker
  bootstrap/   prebuilt .rsc objects + the InnerCore image (PO2013)
eo/
  glue/        Extended Oberon glue: Kernel, Disk, Oberon, CoreLinker
  bootstrap/   prebuilt .rsc objects + the Modules-topped InnerCore (EO)
```

- **`common/`** — the `.Mod` glue both builders embed unchanged. The on-disk
  filesystem format is identical between PO2013 and EO, so `FileDir`/`Files` and
  the `VDisk` family compile against either system's glue.
- **`po/glue/`**, **`eo/glue/`** — the system-specific glue (`Kernel`, `Oberon`,
  `CoreLinker`, plus EO's `Disk`). `eo/glue/Disk.Mod` is **not** embedded in
  `build-eo-image`; it is used only when regenerating the EO seed against the live
  EO emulator (see [`../BUILD-EO-IMAGE.md`](../BUILD-EO-IMAGE.md)).
- **`*/bootstrap/`** — prebuilt `.rsc` objects and the `InnerCore` image that seed
  the first compile. Each `InnerCore` is also the *golden* image its builder
  re-links during the build and checks byte-for-byte.

The upstream Wirth/Pirklbauer sources proper are *not* vendored here — they are
fetched separately into the `sources_dir` passed to the builders.

This material is under the **ISC license**, the same license as this repository,
but the copyright is held upstream. The Norebo-specific modules and build tooling
are © Peter De Wachter (project-norebo); the Extended Oberon modules are © Andreas
Pirklbauer; both derive from Project Oberon 2013, whose notice — reproduced here as
the license requires — is:

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
