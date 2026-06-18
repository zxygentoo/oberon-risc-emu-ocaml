(* Property-based (QCheck) tests — the "oracle-free" set: algebraic laws,
   round-trips, and invariants that hold without a reference implementation. They
   complement the enumerated tests and the FP vectors by exploring the input
   spaces randomly. *)

open Risc_core
open Tsdl
module Q = QCheck2
module G = QCheck2.Gen
module F = Risc.For_tests

(* ---- generators ---------------------------------------------------------- *)

let u32 = G.int_range 0 0xFFFF_FFFF
let shamt = G.int_range 0 31

(* ---- helpers ------------------------------------------------------------- *)

let make_cpu () =
  let r = Risc.make () in
  F.set_pc r 0;
  r
;;

let ram = F.ram
let regs = F.regs

let popcount x =
  let rec go x n = if x = 0 then n else go (x lsr 1) (n + (x land 1)) in
  go x 0
;;

(* Memory-instruction encoders (port of the Rust test helpers). *)
let mem u v a b off =
  0x8000_0000
  lor (u lsl 29)
  lor (v lsl 28)
  lor (a lsl 24)
  lor (b lsl 20)
  lor (off land 0x000F_FFFF)
;;

let store_word a b off = mem 1 0 a b off
let load_word a b off = mem 0 0 a b off

let send_command (s : Io.spi) cmd arg =
  s.spi_write_data cmd;
  s.spi_write_data ((arg lsr 24) land 0xFF);
  s.spi_write_data ((arg lsr 16) land 0xFF);
  s.spi_write_data ((arg lsr 8) land 0xFF);
  s.spi_write_data (arg land 0xFF);
  s.spi_write_data 0xFF
;;

let disk_write (s : Io.spi) secnum data =
  send_command s 88 secnum;
  s.spi_write_data 0xFF;
  ignore (s.spi_read_data ());
  s.spi_write_data 254;
  Array.iter (fun w -> s.spi_write_data w) data;
  s.spi_write_data 0xFF;
  s.spi_write_data 0xFF;
  s.spi_write_data 0xFF;
  ignore (s.spi_read_data ())
;;

let disk_read (s : Io.spi) secnum =
  send_command s 81 secnum;
  let out = Array.make 128 0 in
  for i = 0 to 129 do
    s.spi_write_data 0xFF;
    let b = s.spi_read_data () in
    if i >= 2 then out.(i - 2) <- b
  done;
  out
;;

let counter = ref 0

let temp_dir () =
  incr counter;
  let d =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "oberon_prop_%d_%d" (Unix.getpid ()) !counter)
  in
  Unix.mkdir d 0o755;
  d
;;

let rmrf d =
  (try
     Array.iter
       (fun f ->
          try Sys.remove (Filename.concat d f) with
          | Sys_error _ -> ())
       (Sys.readdir d)
   with
   | Sys_error _ -> ());
  try Unix.rmdir d with
  | Unix.Unix_error _ -> ()
;;

let write_file dir name content =
  let oc = open_out_bin (Filename.concat dir name) in
  output_string oc content;
  close_out oc
;;

(* Run [f] with stdout redirected to /dev/null (PCLink logs each transfer). *)
let silenced f =
  flush stdout;
  let saved = Unix.dup Unix.stdout in
  let dn = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  Unix.dup2 dn Unix.stdout;
  Unix.close dn;
  Fun.protect
    ~finally:(fun () ->
      flush stdout;
      Unix.dup2 saved Unix.stdout;
      Unix.close saved)
    f
;;

(* ---- U32: algebraic laws ------------------------------------------------- *)

let u32_props =
  [ Q.Test.make ~name:"u32: wrap (to_i32 x) = x" ~count:1000 u32 (fun x ->
      U32.wrap (U32.to_i32 x) = x)
  ; Q.Test.make ~name:"u32: to_i32 sign = bit 31" ~count:1000 u32 (fun x ->
      U32.to_i32 x < 0 = (x land 0x8000_0000 <> 0))
  ; Q.Test.make
      ~name:"u32: sub (add a b) b = a"
      ~count:1000
      (G.pair u32 u32)
      (fun (a, b) -> U32.sub (U32.add a b) b = a)
  ; Q.Test.make ~name:"u32: add a (neg a) = 0" ~count:1000 u32 (fun a ->
      U32.add a (U32.neg a) = 0)
  ; Q.Test.make ~name:"u32: neg (neg a) = a" ~count:1000 u32 (fun a ->
      U32.neg (U32.neg a) = a)
  ; Q.Test.make ~name:"u32: ror round-trips" ~count:1000 (G.pair u32 shamt) (fun (a, n) ->
      U32.ror (U32.ror a n) ((32 - n) land 31) = a)
  ; Q.Test.make
      ~name:"u32: ror preserves popcount"
      ~count:1000
      (G.pair u32 shamt)
      (fun (a, n) -> popcount (U32.ror a n) = popcount a)
  ; Q.Test.make
      ~name:"u32: shr (shl a n) n keeps low 32-n bits"
      ~count:1000
      (G.pair u32 shamt)
      (fun (a, n) -> U32.shr (U32.shl a n) n = a land ((1 lsl (32 - n)) - 1))
  ; Q.Test.make
      ~name:"u32: sar = shr when bit 31 clear"
      ~count:1000
      (G.pair (G.int_range 0 0x7FFF_FFFF) shamt)
      (fun (a, n) -> U32.sar a n = U32.shr a n)
  ; Q.Test.make
      ~name:"u32: every op stays in [0, 2^32)"
      ~count:1000
      (G.pair u32 shamt)
      (fun (a, n) ->
         let inr x = x >= 0 && x <= 0xFFFF_FFFF in
         inr (U32.shl a n)
         && inr (U32.shr a n)
         && inr (U32.sar a n)
         && inr (U32.ror a n)
         && inr (U32.neg a))
  ]
;;

(* ---- Memory: round-trips ------------------------------------------------- *)

(* Aligned byte addresses well above the two instruction words at 0 and 4. *)
let word_addr = G.map (fun w -> w * 4) (G.int_range 0x40 0x3FFF)

let mem_props =
  [ Q.Test.make
      ~name:"mem: store_word then load_word = identity"
      ~count:500
      (G.pair u32 word_addr)
      (fun (v, addr) ->
         let r = make_cpu () in
         (ram r).(0) <- store_word 1 2 0;
         (ram r).(1) <- load_word 3 2 0;
         (regs r).(1) <- v;
         (regs r).(2) <- addr;
         F.single_step r;
         F.single_step r;
         (regs r).(3) = v)
  ; Q.Test.make
      ~name:"mem: word store, byte loads are little-endian"
      ~count:500
      (G.pair u32 word_addr)
      (fun (w, addr) ->
         let r = make_cpu () in
         (ram r).(0) <- store_word 1 2 0;
         (regs r).(1) <- w;
         (regs r).(2) <- addr;
         F.single_step r;
         List.for_all
           (fun k -> F.load_byte r (addr + k) = (w lsr (8 * k)) land 0xFF)
           [ 0; 1; 2; 3 ])
  ]
;;

(* ---- CPU: the Z/N invariant over all register ops ------------------------ *)

(* A random register-format instruction (top bit clear), plus a random R0..R15. *)
let reg_word = G.map (fun w -> w land 0x7FFF_FFFF) u32
let reg16 = G.list_size (G.return 16) u32

let cpu_props =
  [ Q.Test.make
      ~name:"cpu: Z/N flags reflect the written register"
      ~count:2000
      (G.pair reg_word reg16)
      (fun (word, regs_init) ->
         let r = make_cpu () in
         List.iteri (fun i v -> (regs r).(i) <- v) regs_init;
         (ram r).(0) <- word;
         F.single_step r;
         let a = (word lsr 24) land 0xF in
         let res = (regs r).(a) in
         F.flags r land 1 <> 0 = (res = 0) (* Z *)
         && F.flags r land 2 <> 0 = (res >= 0x8000_0000)
         (* N *))
  ]
;;

(* ---- Disk: a sector survives a write/read round-trip --------------------- *)

let sector_words = G.list_size (G.return 128) u32

let disk_props =
  [ Q.Test.make
      ~name:"disk: write then read sector round-trips"
      ~count:100
      (G.pair sector_words (G.int_range 0 15))
      (fun (words, secnum) ->
         let data = Array.of_list words in
         let path = Filename.temp_file "oberon_prop_" ".img" in
         let oc = open_out_bin path in
         output_bytes oc (Bytes.make (512 * 16) '\000');
         close_out oc;
         Fun.protect
           ~finally:(fun () ->
             try Sys.remove path with
             | Sys_error _ -> ())
           (fun () ->
              let s = Disk.to_spi (Disk.create (Some path)) in
              disk_write s secnum data;
              disk_read s secnum = data))
  ]
;;

(* ---- PCLink: a REC transfer delivers the file bytes exactly -------------- *)

let byte_string = G.string_size ~gen:G.char (G.int_range 0 600)

let pclink_props =
  [ Q.Test.make
      ~name:"pclink: REC delivers exact bytes (any size)"
      ~count:100
      byte_string
      (fun content ->
         silenced (fun () ->
           let dir = temp_dir () in
           Fun.protect
             ~finally:(fun () -> rmrf dir)
             (fun () ->
                write_file dir "payload" content;
                write_file dir "PCLink.REC" "payload";
                let s = Pclink.to_serial (Pclink.in_dir dir) in
                ignore (s.serial_read_status ());
                ignore (s.serial_read_data () : int) (* mode byte *);
                s.serial_write_data 0x10 (* ACK *);
                (* skip the echoed filename ("payload") + NUL *)
                for _ = 1 to String.length "payload" + 1 do
                  ignore (s.serial_read_data () : int)
                done;
                (* read length-prefixed blocks until a 0-length terminator *)
                let buf = Buffer.create (String.length content) in
                let rec blocks () =
                  let len = s.serial_read_data () in
                  if len > 0
                  then (
                    for _ = 1 to len do
                      Buffer.add_char buf (Char.chr (s.serial_read_data ()))
                    done;
                    blocks ())
                in
                blocks ();
                Buffer.contents buf = content)))
  ]
;;

(* ---- Frontend: display scaling ------------------------------------------- *)

let dim = G.int_range 64 4096

let scale_props =
  [ Q.Test.make
      ~name:"scale_rect: fits, fills a dimension, centered"
      ~count:1000
      (G.tup4 dim dim dim dim)
      (fun (ww, wh, tw, th) ->
         let scale, r = Render.scale_rect ~win_w:ww ~win_h:wh ~tex_w:tw ~tex_h:th in
         let rw = Sdl.Rect.w r
         and rh = Sdl.Rect.h r in
         scale > 0.0
         && rw > 0
         && rh > 0
         && rw <= ww + 1
         && rh <= wh + 1 (* fits in the window *)
         && (rw >= ww - 1 || rh >= wh - 1) (* fills the limiting dimension *)
         && abs ((2 * Sdl.Rect.x r) + rw - ww) <= 1 (* centered horizontally *)
         && abs ((2 * Sdl.Rect.y r) + rh - wh) <= 1 (* centered vertically *))
  ]
;;

(* ---- FP: metamorphic laws of the bit-exact model ------------------------- *)

let fp_props =
  [ Q.Test.make
      ~name:"fp_add is commutative (plain FAD)"
      ~count:2000
      (G.pair u32 u32)
      (fun (x, y) -> Fp.fp_add x y false false = Fp.fp_add y x false false)
  ; Q.Test.make ~name:"fp_mul is commutative" ~count:2000 (G.pair u32 u32) (fun (x, y) ->
      Fp.fp_mul x y = Fp.fp_mul y x)
  ; Q.Test.make
      ~name:"fp_mul sign = sign x xor sign y (non-zero result)"
      ~count:2000
      (G.pair u32 u32)
      (fun (x, y) ->
         let r = Fp.fp_mul x y in
         r = 0 || r land 0x8000_0000 = x lxor y land 0x8000_0000)
  ]
;;

let () =
  QCheck_base_runner.run_tests_main
    (List.concat
       [ u32_props
       ; mem_props
       ; cpu_props
       ; disk_props
       ; pclink_props
       ; scale_props
       ; fp_props
       ])
;;
