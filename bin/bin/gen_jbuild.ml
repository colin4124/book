(** Generate jbuild files for code examples within the tree *)
open Printf

(** Directory and file traversal functions *)

(** [find_dirs_containing ~exts base] will return all the sub-directories
    that contain files that match any of extension [ext], starting from
    the [base] directory. *)
let find_dirs_containing ?(ignore_dirs=[]) ~exts base =
  let rec fn base =
    Sys.readdir base |>
    Array.map (Filename.concat base) |>
    Array.map (fun d ->
      if Sys.is_directory d && not (List.mem (Filename.basename d) ignore_dirs) then
        fn d else [d]) |>
    Array.to_list |>
    List.flatten |>
    List.filter (fun f -> List.exists (Filename.check_suffix f) exts) in
  fn base |>
  List.map Filename.dirname |>
  List.sort_uniq String.compare

(** [files_with ~exts base] will return all the files matching the
    extension [exts] in directory [base]. *)
let files_with ~exts base =
  Sys.readdir base |>
  Array.to_list |>
  List.filter (fun f -> List.exists (Filename.check_suffix f) exts) 

(** [emit_sexp file sexp] writes [sexp] to [file] with a
    jbuild header and comment marking that it is autogenerated. *)
let emit_sexp file s =
  eprintf "Processing %s\n%!" file;
  let fout = open_out file in
  sprintf "((jbuild_version 1) %s)" s |>
  Sexplib.Sexp.of_string |> fun l ->
  match l with
  | Sexplib.Sexp.Atom _ -> assert false
  | Sexplib.Sexp.List l ->
      List.iter (fun s ->
        Sexp_pretty.sexp_to_string s |>
        output_string fout;
        output_string fout "\n") l;
      close_out fout

let book_extensions =
  [ ".ml"; ".mli"; ".mly"; ".mll"; ".rawtopscript";
    ".syntax"; ".scm"; ".rawscript"; ".java"; ".cpp";
    ".topscript"; ".sh"; ".errsh"; ".rawsh"; "jbuild";
    ".json"; ".atd"; ".rawsh"; ".c"; ".h"; ".cmd"; ".S" ]

(** Process the book chapters *)

(** Find the dependencies within an HTML file *)
let sexp_deps_of_chapter file =
  let open Soup in
  read_file file |>
  parse |> fun s ->
  s $$ "link[rel][href]" |>
  fold (fun a n -> R.attribute "href" n :: a) [] |>
  List.sort_uniq String.compare

let jbuild_for_chapter base_dir file =
  let examples_dir = "../examples" in
  let deps =
    sexp_deps_of_chapter (Filename.concat base_dir file) |>
    List.map (sprintf "%s/%s.sexp" examples_dir) |>
    List.map (fun s -> "     " ^ s) |>
    String.concat "\n" in
  sprintf {|
  (alias ((name site) (deps (%s))))
  (rule
  ((targets (%s))
   (deps (../book/%s ../bin/bin/app.exe ../topexpect/src/main.exe
%s))
   (action
     (setenv TOPEXPECT_BIN ${path:../topexpect/src/main.exe}
       (run rwo-build build chapter -o . -code ../examples -repo-root .. ${<})
     )))) |} file file file deps

let starts_with_digit b =
  try Scanf.sscanf b "%d-" (fun _ -> ()); true
  with _ -> false

let process_chapters book_dir output_dir =
  files_with ~exts:[".html"] book_dir |>
  List.filter (starts_with_digit) |>
  List.sort String.compare |>
  List.map (jbuild_for_chapter book_dir) |>
  String.concat "\n" |>
  emit_sexp (Filename.concat output_dir "jbuild")

(** Handle examples *)

(** todo replace with an sexp file in the directory *)
let topscript_extra_deps =
  function
  |"parse_book.topscript" -> " book.json"
  |"example_load.topscript" -> " example.scm example_broken.scm comment_heavy.scm"
  |_ -> ""

let topscript_rule f =
  sprintf {|
(alias ((name code) (deps (%s.stamp))))
(alias ((name sexp) (deps (%s.sexp))))

(rule
 ((targets (%s.sexp))
  (deps    (%s))
  (action  (with-stdout-to ${@}
    (run ocaml-topexpect -dry-run -sexp -short-paths -verbose ${<})))))

(rule
 ((targets (%s.stamp))
  (deps    (%s%s))
  (action  (progn
    (setenv OCAMLRUNPARAM "" (run ocaml-topexpect -short-paths -verbose ${<}))
    (write-file ${@} "")
    (diff? %s %s.corrected)
    ))
  )) |} f f f f f f (topscript_extra_deps f) f f

let rwo_eval_rule f =
  sprintf {|
(alias ((name sexp) (deps (%s.sexp))))

(rule
  ((targets (%s.sexp))
  (deps (%s))
  (action (with-stdout-to ${@}
  (run rwo-build eval ${<}))))) |} f f f

let jbuild_rule f =
  (* TODO filter out the include here *)
  rwo_eval_rule f

let sh_rule f =
  (* as a special case, touch a jbuild.inc file until
   * https://github.com/ocaml/dune/issues/431 is answered *)
  sprintf {|
(alias ((name sexp) (deps (%s.sexp))))

(rule
  ((targets (%s.sexp))
  (deps (%s))
  (action (progn (bash "touch jbuild.inc") (with-stdout-to ${@} (run rwo-build eval ${<})))))) |} f f f

let process_examples dir =
  Filename.concat dir "jbuild.inc" |> fun jbuild ->
  files_with ~exts:book_extensions dir |>
  List.map (fun f ->
    printf "handling %s/%s\n%!" dir f;
    match f with 
    | "jbuild" -> jbuild_rule f 
    | f when Filename.extension f = ".topscript" -> topscript_rule f
    | f when Filename.extension f = ".sh" -> sh_rule f
    | f when List.mem (Filename.extension f) book_extensions -> rwo_eval_rule f
    | _ -> printf "skipping %s/%s\n%!" dir f; ""
  ) |>
  List.filter ((<>) "") |>
  String.concat "\n" |>
  emit_sexp jbuild 

let _ =
  find_dirs_containing ~ignore_dirs:["_build"] ~exts:book_extensions "examples" |>
  List.iter process_examples;
  process_chapters "book" "site"

