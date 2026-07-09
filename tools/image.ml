(** Read-only reader for the Project Oberon on-disk filesystem (port of
    [host_tools::image]). No emulator, no boot. *)

open Risc_core

(* Constants from FileDir.Mod. *)
let sector_size = 1024
let fn_length = 32
let sec_tab_size = 64
let ex_tab_size = 12
let index_size = sector_size / 4 (* 256 addresses per index sector *)
let header_size = 352
let dir_root_adr = 29 (* sector 1 *)
let dir_pg_size = 24
let max_dir_depth = 64
let dir_mark = 0x9B1EA38D
let header_mark = 0x9BA71D86
let sd_fs_offset = 0x10000400
let off_aleng = 36
let off_bleng = 40
let off_ext = 48 (* ext[12] *)
let off_sec = 96 (* sec[64] *)
let off_dir_m = 4
let off_dir_p0 = 8
let off_dir_e = 64 (* e[24] *)
let dir_entry_size = fn_length + 4 + 4 (* name + adr + p = 40 *)

type entry =
  { name : string
  ; header : int
  }

type t =
  { data : string
  ; base : int (* filesystem start within [data]: 0 for a raw .dsk *)
  }

exception Bad_image of string

let bad msg = raise (Bad_image msg)

(* Little-endian u32 at [off] as a non-negative OCaml int. *)
let rd_u32 buf off =
  Char.code buf.[off]
  lor (Char.code buf.[off + 1] lsl 8)
  lor (Char.code buf.[off + 2] lsl 16)
  lor (Char.code buf.[off + 3] lsl 24)
;;

(* Same four bytes reinterpreted as a signed 32-bit value (Rust's [rd_u32 as i32]). *)
let rd_i32 buf off =
  let u = rd_u32 buf off in
  if u >= 0x8000_0000 then u - 0x1_0000_0000 else u
;;

(* Whether the four bytes at [off] are the directory mark, bounds-checked so an
   out-of-range [off] is simply [false] rather than an exception. *)
let has_dir_mark data off =
  off >= 0 && off + 4 <= String.length data && rd_u32 data off = dir_mark
;;

let from_bytes data =
  let base =
    if has_dir_mark data 0
    then 0
    else if has_dir_mark data sd_fs_offset
    then sd_fs_offset
    else bad "not an Oberon filesystem image (no directory mark at sector 1)"
  in
  { data; base }
;;

let open_image path = from_bytes (In_channel.with_open_bin path In_channel.input_all)

(* Byte offset of the 1024-byte sector at disk address [adr] within [data]. *)
let sector_off img adr =
  let s = adr / 29 in
  if s = 0 then bad "invalid disk address 0";
  let off = img.base + ((s - 1) * sector_size) in
  if off + sector_size > String.length img.data
  then bad "disk address points past the end of the image";
  off
;;

(* Decode the 32-byte name field at [base], enforcing the Oberon charset. Returns [None]
   for an empty or malformed name. (A NUL-less field is the full 32 characters.) *)
let read_name data base =
  let rec name_end i =
    if i < fn_length && data.[base + i] <> '\000' then name_end (i + 1) else i
  in
  let name = String.sub data base (name_end 0) in
  if name <> "" && Oberon_name.chars_ok name then Some name else None
;;

(* Parse a header sector into [(aleng, bleng, sec, ext)], validating it. *)
let header img hdr =
  let off = sector_off img hdr in
  if rd_u32 img.data off <> header_mark then bad "file header has the wrong mark";
  let aleng = rd_i32 img.data (off + off_aleng) in
  let bleng = rd_i32 img.data (off + off_bleng) in
  if aleng < 0 || bleng < 0 || bleng > sector_size
  then bad "file header has an invalid length";
  let table toff n = Array.init n (fun k -> rd_u32 img.data (off + toff + (k * 4))) in
  aleng, bleng, table off_sec sec_tab_size, table off_ext ex_tab_size
;;

(* Map a 0-based page index to its data sector's disk address. *)
let page_sector img page sec ext =
  if page < sec_tab_size
  then sec.(page)
  else (
    let i = (page - sec_tab_size) / index_size in
    let j = (page - sec_tab_size) mod index_size in
    if i >= ex_tab_size then bad "file is too large (extension table overflow)";
    rd_u32 img.data (sector_off img ext.(i) + (j * 4)))
;;

let read_file img hdr =
  let aleng, bleng, sec, ext = header img hdr in
  (* Don't pre-size from [aleng]: a corrupt header could claim a huge length, and the loop
     bails on the first out-of-range sector anyway. *)
  let out = Buffer.create sector_size in
  for page = 0 to aleng do
    let off = sector_off img (page_sector img page sec ext) in
    let start = if page = 0 then header_size else 0 in
    let finish = if page = aleng then bleng else sector_size in
    if start > finish then bad "file header length is inconsistent";
    Buffer.add_substring out img.data (off + start) (finish - start)
  done;
  Buffer.contents out
;;

(* In-order B-tree walk (mirrors VFileDir.enumerate). [seen] guards a cyclic directory;
   [depth] caps recursion so a hostile page chain errors out rather than overflowing the
   stack. Entries are prepended in visitation (name) order, then reversed, so the result
   is ascending. *)
let entries img =
  let seen = Hashtbl.create 64 in
  let rec walk adr depth acc =
    if adr = 0 || Hashtbl.mem seen (adr / 29)
    then acc
    else (
      Hashtbl.add seen (adr / 29) ();
      if depth >= max_dir_depth then bad "directory tree is too deep (corrupt image?)";
      let off = sector_off img adr in
      if rd_u32 img.data off <> dir_mark then bad "directory page has the wrong mark";
      let m = min dir_pg_size (max 0 (rd_i32 img.data (off + off_dir_m))) in
      let rec slots i acc =
        if i >= m
        then acc
        else (
          let base = off + off_dir_e + (i * dir_entry_size) in
          let acc =
            match read_name img.data base with
            | Some name -> { name; header = rd_u32 img.data (base + fn_length) } :: acc
            | None -> acc
          in
          slots (i + 1) (walk (rd_u32 img.data (base + fn_length + 4)) (depth + 1) acc))
      in
      slots 0 (walk (rd_u32 img.data (off + off_dir_p0)) (depth + 1) acc))
  in
  List.rev (walk dir_root_adr 0 [])
;;

module For_tests = struct
  let has_dir_mark = has_dir_mark
  let read_name = read_name
end
