(** Compile-set and compile-order resolution (port of [host_tools::resolve]). *)

module SSet = Set.Make (String)
module SMap = Map.Make (String)

type candidate =
  { file : string
  ; module_ : string
  }

(* ---- Scanning Oberon source (Latin-1, CR line endings) -------------------- *)

(* The scanners are pure: each takes the source [b] and a position [i] and returns the
   position past what it consumed (paired with any value read). A [None] means no match,
   leaving the caller at the position it passed in. Every scanner skips leading trivia
   first, so re-scanning from an un-advanced position is always safe. *)

let is_alpha c = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
let is_alnum c = is_alpha c || (c >= '0' && c <= '9')

(* Rust's [u8::is_ascii_whitespace]: space, \t, \n, form feed, \r (not \v). *)
let is_ws c = c = ' ' || c = '\t' || c = '\n' || c = '\012' || c = '\r'

(* Is the literal [str] at position [i] (no trivia skipped, no advance)? *)
let looking_at b i str =
  let len = String.length str in
  let rec eq k = k = len || (b.[i + k] = str.[k] && eq (k + 1)) in
  i + len <= String.length b && eq 0
;;

(* Skip whitespace and nesting [(* *)] comments, returning the first significant position. *)
let rec skip_trivia b i =
  if i < String.length b && is_ws b.[i]
  then skip_trivia b (i + 1)
  else if looking_at b i "(*"
  then skip_trivia b (skip_comment b (i + 2) 1)
  else i

and skip_comment b i depth =
  if depth = 0 || i >= String.length b
  then i
  else if looking_at b i "(*"
  then skip_comment b (i + 2) (depth + 1)
  else if looking_at b i "*)"
  then skip_comment b (i + 2) (depth - 1)
  else skip_comment b (i + 1) depth
;;

(* An Oberon identifier (a letter, then letters/digits) and the position past it, or
   [None]. *)
let ident b i =
  let i = skip_trivia b i in
  let n = String.length b in
  if i < n && is_alpha b.[i]
  then (
    let rec find_end j = if j < n && is_alnum b.[j] then find_end (j + 1) else j in
    let stop = find_end i in
    Some (String.sub b i (stop - i), stop))
  else None
;;

(* Consume [ch] if it is next (after trivia), returning the position past it. *)
let eat b i ch =
  let i = skip_trivia b i in
  if i < String.length b && b.[i] = ch then Some (i + 1) else None
;;

(* Consume the literal [str] if it is next (after trivia). *)
let eat_str b i str =
  let i = skip_trivia b i in
  if looking_at b i str then Some (i + String.length str) else None
;;

(* Parse a module header into [(module name, imported module names)]. Handles the optional
   [MODULE*] marker, alias imports ([IMPORT B := A] depends on [A]), and [SYSTEM]
   (dropped). Raises [Failure] on non-Oberon input. *)
let parse_header src =
  let expect_ident i msg =
    match ident src i with
    | Some result -> result
    | None -> failwith msg
  in
  let i =
    match ident src 0 with
    | Some ("MODULE", i) -> i
    | Some (other, _) -> failwith (Printf.sprintf "starts with `%s`, not MODULE" other)
    | None -> failwith "no MODULE header"
  in
  let i = Option.value (eat src i '*') ~default:i in
  let name, i = expect_ident i "missing module name" in
  let i =
    match eat src i ';' with
    | Some i -> i
    | None -> failwith "missing `;` after the module name"
  in
  (* A header has at most one IMPORT clause, right here; anything else (CONST/TYPE/VAR/…)
     means there are no imports. *)
  let rec read_imports i acc =
    let first, i = expect_ident i "malformed IMPORT list" in
    let module_, i =
      match eat_str src i ":=" with
      | Some i -> expect_ident i "malformed IMPORT alias"
      | None -> first, i
    in
    let acc = if module_ = "SYSTEM" then acc else module_ :: acc in
    match eat src i ',' with
    | Some i -> read_imports i acc
    | None -> List.rev acc
  in
  let imports =
    match ident src i with
    | Some ("IMPORT", i) -> read_imports i []
    | _ -> []
  in
  name, imports
;;

(* Topologically sort so every module follows those it imports. Imports outside the node
   set are ignored; ties break by name for a reproducible order. Raises [Failure] on a
   cycle. *)
let topo_sort nodes =
  let names = SSet.of_list (List.map fst nodes) in
  (* [waiting]: each node -> the in-set imports it still awaits. [dependents]: each node
     -> the nodes that import it (the reverse edges). *)
  let waiting, dependents =
    List.fold_left
      (fun (waiting, dependents) (name, imports) ->
         let deps =
           SSet.of_list (List.filter (fun d -> d <> name && SSet.mem d names) imports)
         in
         let dependents =
           SSet.fold
             (fun d acc ->
                SMap.add d (name :: Option.value ~default:[] (SMap.find_opt d acc)) acc)
             deps
             dependents
         in
         SMap.add name deps waiting, dependents)
      (SMap.empty, SMap.empty)
      nodes
  in
  (* Kahn's algorithm; [ready] is a sorted set, so ties break by name. Emitting [name]
     removes it from every dependent's wait set, readying those left with none. *)
  let ready =
    SMap.fold
      (fun n deps acc -> if SSet.is_empty deps then SSet.add n acc else acc)
      waiting
      SSet.empty
  in
  let rec drain ready waiting acc =
    match SSet.min_elt_opt ready with
    | None -> List.rev acc, waiting
    | Some name ->
      let ready, waiting =
        List.fold_left
          (fun (ready, waiting) m ->
             match SMap.find_opt m waiting with
             | None -> ready, waiting
             | Some deps ->
               let deps = SSet.remove name deps in
               ( (if SSet.is_empty deps then SSet.add m ready else ready)
               , SMap.add m deps waiting ))
          (SSet.remove name ready, SMap.remove name waiting)
          (Option.value ~default:[] (SMap.find_opt name dependents))
      in
      drain ready waiting (name :: acc)
  in
  let order, stuck = drain ready waiting [] in
  if not (SMap.is_empty stuck)
  then (
    let cycle = List.map fst (SMap.bindings stuck) in
    failwith (Printf.sprintf "import cycle among: %s" (String.concat ", " cycle)));
  order
;;

let resolve sources visible =
  let manifest = Filename.concat sources Packonly.file_name in
  let text =
    match Fsutil.read_file_opt manifest with
    | Some t -> t
    | None ->
      failwith
        (Printf.sprintf
           "can't read %s; every source tree needs a .packonly listing the files to pack \
            without compiling (an empty file compiles everything)"
           manifest)
  in
  let pack = Packonly.parse text in
  let present = Packonly.StringSet.of_list visible in
  Packonly.StringSet.iter
    (fun name ->
       if not (Packonly.StringSet.mem name present)
       then
         failwith
           (Printf.sprintf
              ".packonly lists `%s`, but there is no such file in %s"
              name
              sources))
    pack;
  (* Every visible file that isn't pack-only is an Oberon source: parse its header for the
     module it declares and its imports, rejecting duplicate module names. *)
  let file_of, nodes_rev =
    List.fold_left
      (fun (file_of, nodes) file ->
         if Packonly.StringSet.mem file pack
         then file_of, nodes
         else (
           let src =
             match Fsutil.read_file_opt (Filename.concat sources file) with
             | Some s -> s
             | None -> failwith (Printf.sprintf "can't read %s" file)
           in
           let module_, imports =
             try parse_header src with
             | Failure e ->
               failwith
                 (Printf.sprintf
                    "%s: not Oberon source (%s); if it is data, add it to .packonly"
                    file
                    e)
           in
           (match SMap.find_opt module_ file_of with
            | Some other ->
              failwith
                (Printf.sprintf
                   "%s and %s both declare MODULE %s; list one in .packonly"
                   other
                   file
                   module_)
            | None -> ());
           SMap.add module_ file file_of, (module_, imports) :: nodes))
      (SMap.empty, [])
      visible
  in
  let order = topo_sort (List.rev nodes_rev) in
  List.map (fun module_ -> { file = SMap.find module_ file_of; module_ }) order
;;

module For_tests = struct
  let parse_header = parse_header
  let topo_sort = topo_sort
end
