(** The embedded PO2013 toolchain seed (mirrors build-po-image.rs's TOOLCHAIN). *)

let asset path =
  match Assets_data.read path with
  | Some s -> s
  | None -> failwith ("missing embedded asset: " ^ path)
;;

(* (on-disk name, crunched asset path). The host glue .Mod override the stock PO2013
   modules of the same name; flat names never collide (.Mod vs .rsc). *)
let toolchain =
  List.map
    (fun (name, path) -> name, asset path)
    [ (* Shared host glue *)
      "Norebo.Mod", "common/Norebo.Mod"
    ; "FileDir.Mod", "common/FileDir.Mod"
    ; "Files.Mod", "common/Files.Mod" (* PO2013-specific glue *)
    ; "Kernel.Mod", "po/glue/Kernel.Mod"
    ; "Oberon.Mod", "po/glue/Oberon.Mod"
    ; "CoreLinker.Mod", "po/glue/CoreLinker.Mod" (* The VDisk family (shared) *)
    ; "VDisk.Mod", "common/VDisk.Mod"
    ; "VFileDir.Mod", "common/VFileDir.Mod"
    ; "VFiles.Mod", "common/VFiles.Mod"
    ; "VDiskUtil.Mod", "common/VDiskUtil.Mod"
      (* Prebuilt bootstrap inner core + objects *)
    ; "InnerCore", "po/bootstrap/InnerCore"
    ; "Kernel.rsc", "po/bootstrap/Kernel.rsc"
    ; "FileDir.rsc", "po/bootstrap/FileDir.rsc"
    ; "Files.rsc", "po/bootstrap/Files.rsc"
    ; "Modules.rsc", "po/bootstrap/Modules.rsc"
    ; "Norebo.rsc", "po/bootstrap/Norebo.rsc"
    ; "Oberon.rsc", "po/bootstrap/Oberon.rsc"
    ; "CoreLinker.rsc", "po/bootstrap/CoreLinker.rsc"
    ; "Fonts.rsc", "po/bootstrap/Fonts.rsc"
    ; "Texts.rsc", "po/bootstrap/Texts.rsc"
    ; "RS232.rsc", "po/bootstrap/RS232.rsc"
    ; "ORS.rsc", "po/bootstrap/ORS.rsc"
    ; "ORB.rsc", "po/bootstrap/ORB.rsc"
    ; "ORG.rsc", "po/bootstrap/ORG.rsc"
    ; "ORP.rsc", "po/bootstrap/ORP.rsc"
    ]
;;

let seed : Pipeline.seed =
  { toolchain
  ; golden_inner_core = asset "po/bootstrap/InnerCore"
  ; name = "build-po-image"
  }
;;
