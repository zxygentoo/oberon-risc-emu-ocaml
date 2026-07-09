(** The embedded Extended Oberon toolchain seed (mirrors build-eo-image.rs's TOOLCHAIN).
    Structurally identical to the PO seed but for the EO glue and a [Modules]-topped
    bootstrap inner core; [eo/glue/Disk.Mod] is deliberately not embedded (it is offline
    seed-regen only). *)

let asset path =
  match Assets_data.read path with
  | Some s -> s
  | None -> failwith ("missing embedded asset: " ^ path)
;;

let toolchain =
  List.map
    (fun (name, path) -> name, asset path)
    [ (* Shared host glue *)
      "Norebo.Mod", "common/Norebo.Mod"
    ; "FileDir.Mod", "common/FileDir.Mod"
    ; "Files.Mod", "common/Files.Mod" (* EO-specific glue *)
    ; "Kernel.Mod", "eo/glue/Kernel.Mod"
    ; "Oberon.Mod", "eo/glue/Oberon.Mod"
    ; "CoreLinker.Mod", "eo/glue/CoreLinker.Mod" (* The VDisk family (shared) *)
    ; "VDisk.Mod", "common/VDisk.Mod"
    ; "VFileDir.Mod", "common/VFileDir.Mod"
    ; "VFiles.Mod", "common/VFiles.Mod"
    ; "VDiskUtil.Mod", "common/VDiskUtil.Mod"
      (* Prebuilt bootstrap inner core + objects *)
    ; "InnerCore", "eo/bootstrap/InnerCore"
    ; "Kernel.rsc", "eo/bootstrap/Kernel.rsc"
    ; "FileDir.rsc", "eo/bootstrap/FileDir.rsc"
    ; "Files.rsc", "eo/bootstrap/Files.rsc"
    ; "Modules.rsc", "eo/bootstrap/Modules.rsc"
    ; "Norebo.rsc", "eo/bootstrap/Norebo.rsc"
    ; "Oberon.rsc", "eo/bootstrap/Oberon.rsc"
    ; "CoreLinker.rsc", "eo/bootstrap/CoreLinker.rsc"
    ; "Fonts.rsc", "eo/bootstrap/Fonts.rsc"
    ; "Texts.rsc", "eo/bootstrap/Texts.rsc"
    ; "RS232.rsc", "eo/bootstrap/RS232.rsc"
    ; "ORS.rsc", "eo/bootstrap/ORS.rsc"
    ; "ORB.rsc", "eo/bootstrap/ORB.rsc"
    ; "ORG.rsc", "eo/bootstrap/ORG.rsc"
    ; "ORP.rsc", "eo/bootstrap/ORP.rsc"
    ]
;;

let seed : Pipeline.seed =
  { toolchain
  ; golden_inner_core = asset "eo/bootstrap/InnerCore"
  ; name = "build-eo-image"
  }
;;
