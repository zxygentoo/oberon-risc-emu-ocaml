(* Oberon FS reader tests, ported from image.rs (the format's executable spec). *)

open Oberon_tools

let failures = ref 0
let total = ref 0

let check name cond =
  incr total;
  if not cond
  then (
    incr failures;
    Printf.printf "FAIL: %s\n" name)
;;

let eqx name got want =
  incr total;
  if got <> want
  then (
    incr failures;
    Printf.printf "FAIL: %s\n" name)
;;

let raises_bad name f =
  incr total;
  match f () with
  | _ ->
    incr failures;
    Printf.printf "FAIL: %s (expected Bad_image)\n" name
  | exception Image.Bad_image _ -> ()
;;

(* Format constants (private in image.ml; mirrored here to build test images). *)
let sector_size = 1024
let header_size = 352
let off_name = 4
let off_aleng = 36
let off_bleng = 40
let off_sec = 96
let off_dir_m = 4
let off_dir_p0 = 8
let off_dir_e = 64
let fn_length = 32
let dir_entry_size = fn_length + 4 + 4
let dir_mark = 0x9B1EA38D
let header_mark = 0x9BA71D86
let nsec = 16
let blank () = Bytes.make (nsec * sector_size) '\000'
let at sector off = ((sector - 1) * sector_size) + off
let put_u32 img sector off v = Bytes.set_int32_le img (at sector off) (Int32.of_int v)

let put_bytes img sector off s =
  Bytes.blit_string s 0 img (at sector off) (String.length s)
;;

let put_name = put_bytes
let adr sector = sector * 29

let put_entry img sector i name header child =
  let base = off_dir_e + (i * dir_entry_size) in
  put_name img sector base name;
  put_u32 img sector (base + fn_length) header;
  put_u32 img sector (base + fn_length + 4) child
;;

let put_dir_page img sector p0 entries =
  put_u32 img sector 0 dir_mark;
  put_u32 img sector off_dir_m (List.length entries);
  put_u32 img sector off_dir_p0 p0;
  List.iteri (fun i (name, header) -> put_entry img sector i name header 0) entries
;;

let put_small_file img sector name content =
  put_u32 img sector 0 header_mark;
  put_name img sector off_name name;
  put_u32 img sector off_aleng 0;
  put_u32 img sector off_bleng (header_size + String.length content);
  put_u32 img sector off_sec (adr sector);
  put_bytes img sector header_size content
;;

let () =
  (* reads_a_single_small_file *)
  (let img = blank () in
   put_dir_page img 1 0 [ "Hello.Mod", adr 2 ];
   put_small_file img 2 "Hello.Mod" "Hello, Oberon!";
   let image = Image.from_bytes (Bytes.to_string img) in
   let entries = Image.entries image in
   eqx "single_len" (List.length entries) 1;
   let e = List.hd entries in
   eqx "single_name" e.Image.name "Hello.Mod";
   eqx "single_content" (Image.read_file image e.Image.header) "Hello, Oberon!");
  (* reconstructs_a_multi_sector_file: 672 inline + 328 in sector 3 *)
  (let img = blank () in
   let content = String.init 1000 (fun i -> Char.chr (i mod 251)) in
   put_dir_page img 1 0 [ "Big.Mod", adr 2 ];
   put_u32 img 2 0 header_mark;
   put_name img 2 off_name "Big.Mod";
   put_u32 img 2 off_aleng 1;
   put_u32 img 2 off_bleng (1000 + header_size - sector_size) (* 328 *);
   put_u32 img 2 off_sec (adr 2);
   put_u32 img 2 (off_sec + 4) (adr 3);
   put_bytes img 2 header_size (String.sub content 0 672);
   put_bytes img 3 0 (String.sub content 672 (1000 - 672));
   let image = Image.from_bytes (Bytes.to_string img) in
   let e = List.hd (Image.entries image) in
   eqx "multi_name" e.Image.name "Big.Mod";
   eqx "multi_content" (Image.read_file image e.Image.header) content);
  (* walks_the_btree_in_name_order *)
  (let img = blank () in
   put_u32 img 1 0 dir_mark;
   put_u32 img 1 off_dir_m 1;
   put_u32 img 1 off_dir_p0 (adr 4);
   put_entry img 1 0 "M" (adr 3) (adr 5);
   put_dir_page img 4 0 [ "A", adr 6 ];
   put_dir_page img 5 0 [ "Z", adr 7 ];
   put_small_file img 3 "M" "m";
   put_small_file img 6 "A" "a";
   put_small_file img 7 "Z" "z";
   let image = Image.from_bytes (Bytes.to_string img) in
   let names = List.map (fun (e : Image.entry) -> e.name) (Image.entries image) in
   check "btree_order" (names = [ "A"; "M"; "Z" ]));
  (* rejects_a_non_filesystem_image *)
  raises_bad "non_fs" (fun () -> Image.from_bytes (String.make sector_size '\000'));
  (* rejects_a_pathologically_deep_directory (> MAX_DIR_DEPTH) *)
  raises_bad "deep_directory" (fun () ->
    let n = 100 in
    let img = Bytes.make ((n + 1) * sector_size) '\000' in
    for s = 1 to n do
      put_dir_page img s (if s < n then adr (s + 1) else 0) []
    done;
    Image.entries (Image.from_bytes (Bytes.to_string img)));
  (* has_dir_mark finds the mark and tolerates out-of-range *)
  (let d = Bytes.make 16 '\000' in
   Bytes.set_int32_le d 4 (Int32.of_int dir_mark);
   let ds = Bytes.to_string d in
   check "hasmark_at4" (Image.For_tests.has_dir_mark ds 4);
   check "hasmark_not0" (not (Image.For_tests.has_dir_mark ds 0));
   check "hasmark_oob" (not (Image.For_tests.has_dir_mark ds 14)));
  (* read_name enforces the Oberon charset *)
  check "name_ok" (Image.For_tests.read_name "Kernel.Mod\x00\x00" 0 = Some "Kernel.Mod");
  check "name_empty" (Image.For_tests.read_name "\x00" 0 = None);
  check "name_leading_digit" (Image.For_tests.read_name "9bad\x00" 0 = None);
  check "name_slash" (Image.For_tests.read_name "a/b\x00" 0 = None);
  if !failures = 0
  then Printf.printf "ok: %d image checks passed\n" !total
  else (
    Printf.printf "FAILED: %d/%d image checks failed\n" !failures !total;
    exit 1)
;;
