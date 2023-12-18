(* header *)
{
  open Error

  (* token hashtable used to reduce the states of the DFA generated by ocamllex *)
  let keyword_table =
    let keywords =
      [
        (* logical operators *)
        ("and", Tokens.AND);
        ("or", Tokens.OR);
        ("not", Tokens.NOT);
        (* (some) arithmetic operators *)
        ("div", Tokens.DIV);
        ("mod", Tokens.MOD);
        (* statement keywords *)
        ("var", Tokens.VAR);
        ("fun", Tokens.FUN);
        ("ref", Tokens.REF);
        ("return", Tokens.RETURN);
        ("if", Tokens.IF);
        ("then", Tokens.THEN);
        ("else", Tokens.ELSE);
        ("while", Tokens.WHILE);
        ("do", Tokens.DO);
        (* reserved type names *)
        ("char", Tokens.CHAR);
        ("int", Tokens.INT);
        ("nothing", Tokens.NOTHING);
      ]
    in
    let tbl = Hashtbl.create (List.length keywords) in
    List.iter (fun (key, value) -> Hashtbl.add tbl key value) keywords;
    tbl

  let get_loc lexbuf = (lexbuf.Lexing.lex_start_p, lexbuf.Lexing.lex_curr_p)

  (* used for debugging purposes only *)
  let string_of_token = function
    | Tokens.CHAR -> "char"
    | Tokens.INT -> "int"
    | Tokens.NOTHING -> "nothing"
    | Tokens.LIT_CHAR c -> Printf.sprintf "lit_char (%c)" c
    | Tokens.LIT_INT i -> Printf.sprintf "lit_int (%d)" i
    | Tokens.LIT_STR s -> Printf.sprintf "lit_str (%s)" s
    | Tokens.ID i -> Printf.sprintf "id (%s)" i
    | Tokens.VAR -> "var"
    | Tokens.FUN -> "fun"
    | Tokens.REF -> "ref"
    | Tokens.RETURN -> "return"
    | Tokens.IF -> "if"
    | Tokens.THEN -> "then"
    | Tokens.ELSE -> "else"
    | Tokens.WHILE -> "while"
    | Tokens.DO -> "do"
    | Tokens.EQ -> "equal"
    | Tokens.NOT_EQ -> "not_equal"
    | Tokens.GREATER -> "greater"
    | Tokens.LESSER -> "lesser"
    | Tokens.GREATER_EQ -> "greater_equal"
    | Tokens.LESSER_EQ -> "lesser_equal"
    | Tokens.AND -> "and"
    | Tokens.OR -> "or"
    | Tokens.NOT -> "not"
    | Tokens.PLUS -> "plus"
    | Tokens.MINUS -> "minus"
    | Tokens.MULT -> "star"
    | Tokens.DIV -> "div"
    | Tokens.MOD -> "mod"
    | Tokens.LEFT_PAR -> "lparen"
    | Tokens.RIGHT_PAR -> "rparen"
    | Tokens.LEFT_BRACKET -> "lbracket"
    | Tokens.RIGHT_BRACKET -> "rbracket"
    | Tokens.LEFT_CURL -> "lbrace"
    | Tokens.RIGHT_CURL -> "rbrace"
    | Tokens.COMMA -> "comma"
    | Tokens.COLON -> "colon"
    | Tokens.SEMICOLON -> "semicolon"
    | Tokens.ASSIGN -> "larrow"
    | Tokens.EOF -> "eof"
}

(* regex definitions *)
let dig  = ['0'-'9']
let xdig = ['0'-'9' 'a'-'f' 'A'-'F']
let ws   = [' ' '\t']
let nl   = '\n' | "\r\n"
let id   = ['a'-'z' 'A'-'Z' '_']['a'-'z' 'A'-'Z' '0'-'9' '_']*
let chr  = [' '-'~'] (* valid ASCII characters found in a normal text/string *)

(* rules *)
rule token = parse
  (* whitespace and comments *)
  | ws+  { token lexbuf }
  | nl   { Lexing.new_line lexbuf; token lexbuf }
  | "$$" { ml_comment lexbuf }
  | '$'  { sl_comment lexbuf }

  (* relational operators *)
  | '='  { Tokens.EQ }
  | '#'  { Tokens.NOT_EQ }
  | '>'  { Tokens.GREATER }
  | '<'  { Tokens.LESSER }
  | ">=" { Tokens.GREATER_EQ }
  | "<=" { Tokens.LESSER_EQ }

  (* (most) arithmetic operators *)
  | '+'  { Tokens.PLUS }
  | '-'  { Tokens.MINUS }
  | '*'  { Tokens.MULT }

  (* structural symbols *)
  | '('  { Tokens.LEFT_PAR }
  | ')'  { Tokens.RIGHT_PAR }
  | '['  { Tokens.LEFT_BRACKET }
  | ']'  { Tokens.RIGHT_BRACKET }
  | '{'  { Tokens.LEFT_CURL }
  | '}'  { Tokens.RIGHT_CURL }
  | ','  { Tokens.COMMA }
  | ':'  { Tokens.COLON }
  | ';'  { Tokens.SEMICOLON }
  | "<-" { Tokens.ASSIGN }
  
  (* identifiers and all keywords *)
  | id as word  { try Hashtbl.find keyword_table word
                  with Not_found -> Tokens.ID word }
  | dig+ as n   { Tokens.LIT_INT (int_of_string n) }
  | '\''        { char_lit lexbuf }
  | '\"'        { str_lit (Buffer.create 32) lexbuf }
  | eof         { Tokens.EOF }
  | _ as c      { raise (Lexing_error (get_loc lexbuf, "Bad character: '" ^ (String.make 1 c) ^ "'")) }

and sl_comment = parse
  | nl          { Lexing.new_line lexbuf; token lexbuf }
  | eof         { EOF }
  | _           { sl_comment lexbuf }

and ml_comment = parse             
  | "$$"        { token lexbuf }
  | '\n'        { Lexing.new_line lexbuf; ml_comment lexbuf }
  | eof         { raise (Lexing_error (get_loc lexbuf, "Multiline comment does not terminate")) }
  | _           { ml_comment lexbuf }

and char_lit = parse
  | '\\'        { escape end_char_lit lexbuf }
  | chr as c    { end_char_lit c lexbuf }
  | eof         { raise (Lexing_error (get_loc lexbuf, "Improper use of character syntax")) }
  | _ as c      { raise (Lexing_error (get_loc lexbuf, "Bad character: '" ^ (String.make 1 c) ^ "'")) }

and end_char_lit c = parse
  | '\''        { Tokens.LIT_CHAR c }
  | _           { raise (Lexing_error (get_loc lexbuf, "Improper use of character syntax")) }

and str_lit buf = parse
  | '\"'        { Buffer.add_char buf (char_of_int 0); Tokens.LIT_STR (Buffer.contents buf) }
  | '\\'        { escape (fun c lb -> Buffer.add_char buf c; str_lit buf lb) lexbuf }
  | chr as c    { Buffer.add_char buf c; str_lit buf lexbuf }
  | eof         { raise (Lexing_error (get_loc lexbuf, "String does not terminate")) }
  | _ as c      { raise (Lexing_error (get_loc lexbuf, "Bad character: '" ^ (String.make 1 c) ^ "'")) }  

and escape exec_func = parse
  | 'n'                   { exec_func '\n' lexbuf }
  | 't'                   { exec_func '\t' lexbuf }
  | 'r'                   { exec_func '\r' lexbuf }
  | '0'                   { exec_func (char_of_int 0) lexbuf }
  | '\\'                  { exec_func '\\' lexbuf }
  | '\''                  { exec_func '\'' lexbuf }
  | '\"'                  { exec_func '\"' lexbuf }
  | 'x' xdig xdig as code { exec_func (char_of_int (int_of_string ("0" ^ code))) lexbuf }
  | _ as c                { raise (Lexing_error (get_loc lexbuf, "Bad escape: '\\" ^ (String.make 1 c) ^ "'")) }

(* trailer *)
{
}
