(** Headless "shim" runtime (port of project-norebo's [norebo.c] / the Rust [shim.rs]).
    Boots an inner-core image on the {!Risc} CPU with the whole MMIO region routed to a
    host that maps Oberon's file syscalls onto the host filesystem.

    Unlike [norebo.c], the syscall ABI bounds-checks everything guest-supplied: out-of-RAM
    reads yield zeros and writes are dropped, transfer lengths clamp to RAM, and a file is
    capped at 1 GiB — so a corrupt inner core degrades into clean errors instead of host
    faults. *)

let mem_bytes = 8 * 1024 * 1024 (* norebo.c MemBytes *)
let stack_org = 0x0008_0000 (* norebo.c StackOrg *)
let max_files = 500 (* norebo.c MaxFiles *)
let max_file_bytes = 1 lsl 30 (* per-file cap: 1 GiB *)
let name_len = 32 (* norebo.c NameLength *)

(* A fixed Oberon-encoded date (2024-05-27 12:00:00): recorded but inert to a
   freshly-booted image. *)
let oberon_date = (24 lsl 26) lor (5 lsl 22) lor (27 lsl 17) lor (12 lsl 12)

(* The universal error/-1 sentinel (u32::MAX). *)
let max_u32 = U32.mask

(* ---- Byte-addressable view over the guest's int-array RAM ----------------- *)

let mem_len_bytes ram = Array.length ram * 4

(* Read the byte at [adr]; out-of-range reads yield 0. *)
let mem_read_byte ram adr =
  let wi = adr / 4 in
  if wi >= 0 && wi < Array.length ram then (ram.(wi) lsr (adr mod 4 * 8)) land 0xFF else 0
;;

(* Write the byte at [adr] (read-modify-write of its word); OOB writes drop. *)
let mem_write_byte ram adr value =
  let wi = adr / 4 in
  if wi >= 0 && wi < Array.length ram
  then (
    let shift = adr mod 4 * 8 in
    ram.(wi) <- ram.(wi) land lnot (0xFF lsl shift) lor ((value land 0xFF) lsl shift))
;;

let mem_read_bytes ram adr buf =
  for i = 0 to Bytes.length buf - 1 do
    Bytes.set buf i (Char.chr (mem_read_byte ram (adr + i)))
  done
;;

let mem_write_bytes ram adr buf =
  for i = 0 to Bytes.length buf - 1 do
    mem_write_byte ram (adr + i) (Char.code (Bytes.get buf i))
  done
;;

(* ---- Name validation ------------------------------------------------------ *)

(* Read a 32-byte Oberon name at [adr], validating it. [Some ""] is a valid (empty) name;
   [None] means an illegal character or no NUL terminator. *)
let read_name ram adr =
  let buf = Bytes.create name_len in
  mem_read_bytes ram adr buf;
  match Bytes.index_opt buf '\000' with
  | None -> None (* no terminator in 32 bytes *)
  | Some stop ->
    let name = Bytes.sub_string buf 0 stop in
    if Oberon_name.chars_ok name then Some name else None
;;

(* Whether a directory entry name is legal (non-empty, < NAME_LEN, valid chars). *)
let valid_name s =
  let n = String.length s in
  n > 0 && n < name_len && Oberon_name.chars_ok s
;;

(* ---- Open files ----------------------------------------------------------- *)

(* One open file. [data] is a capacity buffer whose logical content is its first
   [len] bytes; the region [len, capacity) is kept zero, so growing/seeking past
   the end reads as zeros (matching [Vec::resize(_, 0)]). *)
type open_file =
  { mutable data : bytes
  ; mutable len : int
  ; mutable pos : int
  ; name : string
  ; mutable persist : string option
  ; mutable registered : bool
  ; mutable dirty : bool
  }

let new_file name data =
  { data = Bytes.of_string data
  ; len = String.length data
  ; pos = 0
  ; name
  ; persist = None
  ; registered = false
  ; dirty = false
  }
;;

let ensure_capacity f need =
  if Bytes.length f.data < need
  then (
    let new_cap = max need (max 16 (2 * Bytes.length f.data)) in
    let nd = Bytes.make new_cap '\000' in
    Bytes.blit f.data 0 nd 0 f.len;
    f.data <- nd)
;;

let flush_file f =
  if f.dirty
  then (
    (match f.persist with
     | Some p ->
       (try Out_channel.with_open_bin p (fun oc -> output oc f.data 0 f.len) with
        | Sys_error e -> Printf.eprintf "shim: can't write '%s': %s\n" p e)
     | None -> ());
    f.dirty <- false)
;;

(* ---- The host: args, open-file table, syscall ABI ------------------------- *)

type host =
  { cwd : string
  ; path : string list
  ; args : string array
  ; sysarg : int array (* 3 *)
  ; mutable sysres : int
  ; files : open_file option array (* MAX_FILES *)
  ; mutable enumerate : string list
  ; mutable exit : int option
  ; start : float (* wall-clock origin for the ms counter *)
  }

let file_mut host h = if h >= 0 && h < max_files then host.files.(h) else None

let allocate host f =
  match Array.find_index Option.is_none host.files with
  | Some i ->
    host.files.(i) <- Some f;
    i
  | None ->
    host.exit <- Some 1;
    Printf.eprintf "shim: too many open files\n";
    max_u32
;;

let read_file_opt path =
  try Some (In_channel.with_open_bin path In_channel.input_all) with
  | Sys_error _ -> None
;;

let argv host idx adr siz ram =
  if idx < 0 || idx >= Array.length host.args
  then max_u32
  else (
    let arg = host.args.(idx) in
    if siz > 0
    then (
      (* [arg] truncated to fit, NUL-padded to exactly [siz] bytes. *)
      let buf = Bytes.make siz '\000' in
      Bytes.blit_string arg 0 buf 0 (min (String.length arg) (siz - 1));
      mem_write_bytes ram adr buf);
    String.length arg)
;;

let trap host trap_no name_adr pos ram =
  let msg =
    match trap_no with
    | 1 -> "array index out of range"
    | 2 -> "type guard failure"
    | 3 -> "array or string copy overflow"
    | 4 -> "access via NIL pointer"
    | 5 -> "illegal procedure call"
    | 6 -> "integer division by zero"
    | 7 -> "assertion violated"
    | _ -> "unknown trap"
  in
  let name = Option.value (read_name ram name_adr) ~default:"(unknown)" in
  Printf.eprintf "shim: %s at %s pos %d\n" msg name pos;
  host.exit <- Some (100 + trap_no);
  0
;;

let files_new host adr ram =
  match read_name ram adr with
  | None -> max_u32
  | Some name -> allocate host (new_file name "")
;;

let files_old host adr ram =
  match read_name ram adr with
  | None -> max_u32
  | Some name ->
    (* First the working directory (read-write), then the search path (read-only). *)
    let cwd_path = Filename.concat host.cwd name in
    (match read_file_opt cwd_path with
     | Some data ->
       let f = new_file name data in
       f.persist <- Some cwd_path;
       f.registered <- true;
       allocate host f
     | None ->
       (match
          List.find_map (fun dir -> read_file_opt (Filename.concat dir name)) host.path
        with
        | Some data ->
          let f = new_file name data in
          f.registered <- true (* persist stays None: read-only *);
          allocate host f
        | None -> max_u32))
;;

let files_register host h =
  match file_mut host h with
  | Some f when (not f.registered) && f.name <> "" ->
    let p = Filename.concat host.cwd f.name in
    (try
       Out_channel.with_open_bin p (fun oc -> output oc f.data 0 f.len);
       f.persist <- Some p;
       f.registered <- true;
       f.dirty <- false;
       0
     with
     | Sys_error e ->
       Printf.eprintf "shim: can't create '%s': %s\n" p e;
       max_u32)
  | _ -> 0
;;

let files_close host h =
  if h >= 0 && h < max_files
  then (
    match host.files.(h) with
    | Some f ->
      host.files.(h) <- None;
      flush_file f
    | None -> ());
  0
;;

let files_seek host h pos whence =
  (match file_mut host h with
   | Some f ->
     let base =
       match whence with
       | 1 -> f.pos
       | 2 -> f.len
       | _ -> 0
     in
     f.pos <- max 0 (base + U32.to_i32 pos)
   | None -> ());
  0
;;

let files_read host h adr siz ram =
  (* The destination is guest RAM, so the transfer can't meaningfully exceed it; clamping
     keeps a corrupt length from forcing a giant allocation. *)
  let siz = min siz (mem_len_bytes ram) in
  match file_mut host h with
  | None -> 0
  | Some f ->
    let start = f.pos in
    let avail = if f.len > start then f.len - start else 0 in
    let n = min siz avail in
    let buf =
      Bytes.make siz '\000'
      (* tail is zero-filled, as in norebo.c *)
    in
    Bytes.blit f.data start buf 0 n;
    f.pos <- start + n;
    mem_write_bytes ram adr buf;
    n
;;

let files_write host h adr siz ram =
  let siz =
    min siz (mem_len_bytes ram)
    (* the source is guest RAM *)
  in
  match file_mut host h with
  | None -> 0
  | Some f ->
    let start = f.pos in
    let stop = start + siz in
    if stop > max_file_bytes
    then (
      Printf.eprintf
        "shim: write to '%s' would exceed the %d MiB file cap\n"
        f.name
        (max_file_bytes lsr 20);
      0)
    else (
      ensure_capacity f stop;
      if f.len < stop then f.len <- stop;
      let buf = Bytes.create siz in
      mem_read_bytes ram adr buf;
      Bytes.blit buf 0 f.data start siz;
      f.pos <- stop;
      f.dirty <- true;
      siz)
;;

let files_delete host adr ram =
  match read_name ram adr with
  | Some name when name <> "" ->
    (try
       Sys.remove (Filename.concat host.cwd name);
       0
     with
     | Sys_error _ -> max_u32)
  | _ -> max_u32
;;

let files_rename host old_adr new_adr ram =
  match read_name ram old_adr, read_name ram new_adr with
  | Some old, Some nw when old <> "" && nw <> "" ->
    (try
       Sys.rename (Filename.concat host.cwd old) (Filename.concat host.cwd nw);
       0
     with
     | Sys_error _ -> max_u32)
  | _ -> max_u32
;;

let enumerate_begin host =
  let names =
    match Sys.readdir host.cwd with
    | entries -> Array.to_list entries |> List.filter valid_name
    | exception Sys_error _ -> []
  in
  host.enumerate <- names;
  0
;;

let enumerate_next host adr ram =
  match host.enumerate with
  | name :: rest ->
    host.enumerate <- rest;
    let buf = Bytes.make name_len '\000' in
    let n = min (String.length name) (name_len - 1) in
    Bytes.blit_string name 0 buf 0 n;
    mem_write_bytes ram adr buf;
    0
  | [] ->
    mem_write_byte ram adr 0;
    max_u32
;;

(* Dispatch syscall [n] with the latched arguments. Port of [sysreq_exec]. *)
let sysreq host n ram =
  let a0 = host.sysarg.(0)
  and a1 = host.sysarg.(1)
  and a2 = host.sysarg.(2) in
  match n with
  | 1 ->
    host.exit <- Some (U32.to_i32 a0);
    0 (* Norebo.Halt *)
  | 2 -> Array.length host.args (* Norebo.Argc *)
  | 3 -> argv host a0 a1 a2 ram
  | 4 -> trap host a0 a1 a2 ram
  | 11 -> files_new host a0 ram
  | 12 -> files_old host a0 ram
  | 13 -> files_register host a0
  | 14 -> files_close host a0
  | 15 -> files_seek host a0 a1 a2
  | 16 ->
    (match file_mut host a0 with
     | Some f -> f.pos
     | None -> max_u32)
    (* Files.Tell *)
  | 17 -> files_read host a0 a1 a2 ram
  | 18 -> files_write host a0 a1 a2 ram
  | 19 ->
    (match file_mut host a0 with
     | Some f -> f.len
     | None -> max_u32)
    (* Files.Length *)
  | 20 -> oberon_date (* Files.Date *)
  | 21 -> files_delete host a0 ram
  | 22 -> 0 (* Files.Purge: no-op *)
  | 23 -> files_rename host a0 a1 ram
  | 31 -> enumerate_begin host
  | 32 -> enumerate_next host a0 ram
  | 33 ->
    host.enumerate <- [];
    0
  | _ ->
    Printf.eprintf "shim: unimplemented syscall %d\n" n;
    host.exit <- Some 1;
    0
;;

(* One byte from stdin, or [max_u32] at EOF (norebo.c's getchar convention). *)
let read_stdin_byte () =
  match In_channel.input_char stdin with
  | Some c -> Char.code c
  | None -> max_u32
;;

(* MMIO load at [offset] (= address - IO base). Never reaches guest memory. *)
let host_load host offset =
  match offset with
  | 0 -> U32.wrap (int_of_float ((Unix.gettimeofday () -. host.start) *. 1000.))
  | 8 -> read_stdin_byte ()
  | 12 -> 3 (* status, carried from Oberon *)
  | 48 -> host.sysarg.(2)
  | 52 -> host.sysarg.(1)
  | 56 -> host.sysarg.(0)
  | 60 -> host.sysres
  | _ -> 0
;;

(* MMIO store at [offset]. The syscall trigger (60) is the only path that reaches into
   guest [ram]. The reversed 56/52/48 -> arg0/1/2 mapping matches norebo.c. *)
let host_store host offset value ram =
  match offset with
  | 8 -> output_char stdout (Char.chr (value land 0xFF)) (* putchar *)
  | 48 -> host.sysarg.(2) <- value
  | 52 -> host.sysarg.(1) <- value
  | 56 -> host.sysarg.(0) <- value
  | 60 -> host.sysres <- sysreq host value ram
  | _ -> ()
;;

let find_file cwd path name =
  List.find_map (fun dir -> read_file_opt (Filename.concat dir name)) (cwd :: path)
;;

let run args ~cwd ~path =
  match find_file cwd path "InnerCore" with
  | None -> Error "can't find 'InnerCore' in cwd or search path"
  | Some image ->
    let host =
      { cwd
      ; path
      ; args = Array.of_list args
      ; sysarg = [| 0; 0; 0 |]
      ; sysres = 0
      ; files = Array.make max_files None
      ; enumerate = []
      ; exit = None
      ; start = Unix.gettimeofday ()
      }
    in
    let shim =
      { Io.shim_load = host_load host
      ; shim_store = host_store host
      ; shim_exit_code = (fun () -> host.exit)
      }
    in
    let risc = Risc.make () in
    Risc.For_shim.configure_shim risc mem_bytes;
    Risc.For_shim.set_shim risc shim;
    (match Risc.For_shim.boot_inner_core risc image stack_org with
     | () ->
       (* [risc] owns [host]; flush files + stdout before returning, on any path. *)
       let flush_all () =
         Array.iter (Option.iter flush_file) host.files;
         flush stdout
       in
       Ok (Fun.protect ~finally:flush_all (fun () -> Risc.For_shim.shim_run risc))
     | exception Failure msg -> Error msg)
;;

module For_tests = struct
  let mem_read_byte = mem_read_byte
  let mem_write_byte = mem_write_byte
  let mem_read_bytes = mem_read_bytes
  let mem_write_bytes = mem_write_bytes
  let read_name = read_name
  let valid_name = valid_name
end
