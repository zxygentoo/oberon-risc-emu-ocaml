(** The embedded toolchain seeds (mirrors the TOOLCHAIN tables of build-po-image.rs /
    build-eo-image.rs). Both variants carry the same on-disk names; only the
    crunched-asset directory for the variant-specific glue and bootstrap entries differs
    ([po/] vs [eo/]). (The Rust binaries keep two literal tables only because
    [include_bytes!] needs compile-time paths; [Assets_data.read] is string-keyed, so
    one table serves both.) *)

let asset path =
  match Assets_data.read path with
  | Some s -> s
  | None -> failwith ("missing embedded asset: " ^ path)
;;

(* (on-disk name, crunched asset path). The host glue .Mod override the stock system
   modules of the same name; flat names never collide (.Mod vs .rsc). *)
let table variant =
  let common name = name, "common/" ^ name in
  let glue name = name, variant ^ "/glue/" ^ name in
  let bootstrap name = name, variant ^ "/bootstrap/" ^ name in
  [ (* Shared host glue *)
    common "Norebo.Mod"
  ; common "FileDir.Mod"
  ; common "Files.Mod" (* Variant-specific glue *)
  ; glue "Kernel.Mod"
  ; glue "Oberon.Mod"
  ; glue "CoreLinker.Mod" (* The VDisk family (shared) *)
  ; common "VDisk.Mod"
  ; common "VFileDir.Mod"
  ; common "VFiles.Mod"
  ; common "VDiskUtil.Mod" (* Prebuilt bootstrap inner core + objects *)
  ; bootstrap "InnerCore"
  ; bootstrap "Kernel.rsc"
  ; bootstrap "FileDir.rsc"
  ; bootstrap "Files.rsc"
  ; bootstrap "Modules.rsc"
  ; bootstrap "Norebo.rsc"
  ; bootstrap "Oberon.rsc"
  ; bootstrap "CoreLinker.rsc"
  ; bootstrap "Fonts.rsc"
  ; bootstrap "Texts.rsc"
  ; bootstrap "RS232.rsc"
  ; bootstrap "ORS.rsc"
  ; bootstrap "ORB.rsc"
  ; bootstrap "ORG.rsc"
  ; bootstrap "ORP.rsc"
  ]
;;

let make ~variant ~name : Pipeline.seed =
  { toolchain = List.map (fun (name, path) -> name, asset path) (table variant)
  ; golden_inner_core = asset (variant ^ "/bootstrap/InnerCore")
  ; name
  }
;;

let po = make ~variant:"po" ~name:"build-po-image"

(* The EO bootstrap inner core is [Modules]-topped; [eo/glue/Disk.Mod] is deliberately
   not embedded (it is offline seed-regen only). *)
let eo = make ~variant:"eo" ~name:"build-eo-image"
