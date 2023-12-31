(* every possible error of the compiler, plus functions for printing them nicely *)

(* loc is a type which saves the starting and ending position of a token.
 * This definition of loc matches Menhir's location interface and that is why we use it.
 * In our code we only care about the starting position (line, column). *)
type loc = Lexing.position * Lexing.position

exception Lexing_error of loc * string

(* a parsing error is the default error of menhir *)

exception Semantic_error of loc * string
exception Symbol_table_error of loc * string
exception Internal_compiler_error of string
exception Codegen_error of loc * string

let string_of_loc
    ( {
        Lexing.pos_fname = filename;
        Lexing.pos_lnum = line;
        Lexing.pos_bol;
        Lexing.pos_cnum;
      },
      _ ) =
  let col = pos_cnum - pos_bol + 1 in
  Printf.sprintf "file: %s, line: %d, column: %d" filename line col

let pr_lexing_error (loc, msg) =
  prerr_endline ("Lexing error at " ^ string_of_loc loc ^ ": " ^ msg)

let pr_parser_error (loc, msg) =
  prerr_endline ("Parser error at " ^ string_of_loc loc ^ ": " ^ msg)

let pr_semantic_error (loc, msg) =
  prerr_endline ("Semantic error at " ^ string_of_loc loc ^ ": " ^ msg)

let pr_symbol_table_error (loc, msg) =
  prerr_endline ("Symbol table error at " ^ string_of_loc loc ^ ": " ^ msg)

let pr_internal_compiler_error msg =
  prerr_endline ("Internal compiler error " ^ msg)

let pr_codegen_error (loc, msg) =
  prerr_endline ("Codegen error at " ^ string_of_loc loc ^ ": " ^ msg)
