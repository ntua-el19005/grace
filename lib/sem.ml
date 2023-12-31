(* all semantic actions done during semantic analysis,
   except from symbol table related stuff*)

open Ast
open Symbol
open Error

(* used to compare function declarations with definitions
 * and find undefined declarations *)
module StringSet = Set.Make (String)

(* before closing a scope check for lingering declarations *)
let sem_close_scope loc tbl =
  match tbl.scopes with
  | [] -> raise (Symbol_table_error (loc, "Tried to close empty symbol table"))
  | scope :: _ ->
      (* find function declarations and definitions in current scope *)
      let rec aux entries def_set decl_set =
        match entries with
        | [] -> (def_set, decl_set)
        | entry :: tl -> (
            match entry.entry_type with
            | Function fd_ref ->
                let fd = !fd_ref in
                if fd.status = Declared then
                  let decl_set = StringSet.add fd.id decl_set in
                  aux tl def_set decl_set
                else
                  let def_set = StringSet.add fd.id def_set in
                  aux tl def_set decl_set
            | _ -> aux tl def_set decl_set)
      in
      let get_loc_of_id id tbl =
        let entry = lookup id tbl in
        match entry with
        | Some e -> get_loc_entry e
        | None ->
            raise
              (Symbol_table_error
                 (loc, "Could not find entry for id '" ^ id ^ "'"))
      in
      (* check if all declared functions have been defined *)
      let def_set, decl_set =
        aux scope.entries StringSet.empty StringSet.empty
      in
      StringSet.iter
        (fun id ->
          if not (StringSet.mem id def_set) then
            raise
              (Semantic_error
                 ( get_loc_of_id id tbl,
                   "Function '" ^ id ^ "' declared, but not defined" )))
        decl_set

(* checks that variables defined as arrays have correct array size specifiers *)
let verify_var_def (vd : var_def) =
  match vd.var_type with
  | Array (_, dims) ->
      if
        List.find_opt
          (fun dim -> match dim with None -> false | Some n -> n <= 0)
          dims
        <> None
      then raise (Semantic_error (vd.loc, "Array dimension must be positive"))
      else if
        List.find_opt
          (fun dim -> match dim with None -> true | _ -> false)
          dims
        <> None
      then raise (Semantic_error (vd.loc, "Array dimension must be specified"))
      else ()
  | _ -> ()

(* same as above, but for parameters, therefore the first dimension can be unspecified *)
let verify_param_def (pd : param_def) =
  match pd.param_type with
  | Array (_, dims) ->
      let tl_dims = List.tl dims in
      if
        List.find_opt
          (fun dim -> match dim with None -> false | Some n -> n <= 0)
          dims (* check all dimensions *)
        <> None
      then raise (Semantic_error (pd.loc, "Array dimension must be positive"))
      else if
        List.find_opt
          (fun dim -> match dim with None -> true | _ -> false)
          tl_dims
        (* don't check the first dimension, because it can be 'None' *)
        <> None
      then raise (Semantic_error (pd.loc, "Array dimension must be specified"))
      else ()
  | _ -> ()

(* if a variable with the given variable type cannot be used as an argument
   for a parameter of the given parameter type, this function throws an error *)
let comp_var_param_types loc (vt : var_type) (pt : param_type) =
  match (vt, pt) with
  | Array (t1, dims_var), Array (t2, dims_param) ->
      if t1 <> t2 then
        raise (Semantic_error (loc, "Array element type mismatch"))
      else if List.length dims_var <> List.length dims_param then
        raise (Semantic_error (loc, "Array dimension count mismatch"))
      else
        let check_dims_var, check_dims_param =
          if List.hd dims_param = None then
            (List.tl dims_var, List.tl dims_param)
          else (dims_var, dims_param)
        in
        List.iter2
          (fun dim1 dim2 ->
            match (dim1, dim2) with
            | None, None -> ()
            | Some n1, Some n2 ->
                if n1 <> n2 then
                  raise (Semantic_error (loc, "Array dimension size mismatch"))
            | _ -> ())
          check_dims_var check_dims_param
  | t1, t2 -> if t1 <> t2 then raise (Semantic_error (loc, "Type mismatch"))

let comp_var_param_def (vd : var_def) (pd : param_def) =
  comp_var_param_types vd.loc vd.var_type pd.param_type

(* verifies that a function definition matches with a function declaration *)
let comp_param_decl_def (pd1 : param_def) (pd2 : param_def) =
  if pd1.pass_by <> pd2.pass_by then
    raise
      (Semantic_error
         (pd1.loc, "Parameter definition/declaration 'pass by' mismatch"))
  else if pd1.param_type <> pd2.param_type then
    raise
      (Semantic_error (pd1.loc, "Parameter definition/declaration type mismatch"))

let type_of_ret loc tbl =
  let sc = List.hd (List.tl tbl.scopes) in
  let entry = List.hd sc.entries in
  match entry.entry_type with
  | Function f -> !f.ret_type
  | _ ->
      raise
        (Symbol_table_error (loc, "Tried to get return type of non-function"))

(* only lvalues can be passed by reference, all other expressions can't *)
let check_ref expr pass_by =
  match (expr, pass_by) with
  | LValue _, _ -> ()
  | _, Value -> ()
  | expr, Reference ->
      raise
        (Semantic_error (get_loc_expr expr, "Passing non-l-value by reference"))

(* compare headers of a declaration and definition to see if they match *)
let compare_heads (decl : func) (def : func) =
  if decl.ret_type <> def.ret_type then
    raise
      (Semantic_error
         (def.loc, "Function definition/declaration return type mismatch"))
  else if List.length decl.params <> List.length def.params then
    raise
      (Semantic_error
         (def.loc, "Function definition/declaration parameter count mismatch"))
  else List.iter2 comp_param_decl_def decl.params def.params

(* verifies that a variable is not defined twice in the same scope *)
let sem_var_def (vd : var_def) (tbl : symbol_table) =
  verify_var_def vd;
  match lookup vd.id tbl with
  | Some _ ->
      raise
        (Semantic_error (vd.loc, "Variable already defined in current scope"))
  | None -> ()

(* inserts a variable in the current scope *)
let ins_var_def (vd : var_def) (tbl : symbol_table) =
  insert vd.loc vd.id (Variable (ref vd)) tbl

(* verifies that a parameter is not defined twice in the same scope
   and also that array parameters are always passed by reference *)
let sem_param_def (pd : param_def) (tbl : symbol_table) =
  verify_param_def pd;
  match (pd.param_type, pd.pass_by) with
  | Array _, Value ->
      raise
        (Semantic_error (pd.loc, "Array parameter must be passed by reference"))
  | _ -> (
      match lookup pd.id tbl with
      | Some _ ->
          raise
            (Semantic_error
               (pd.loc, "Parameter already defined in current scope"))
      | None -> ())

(* inserts a parameter in the current scope *)
let ins_param_def (pd : param_def) (tbl : symbol_table) =
  insert pd.loc pd.id (Parameter (ref pd)) tbl

(* fill in the missing fields of the given l value, or throw an error if it doesn't exist *)
let sem_simple_l_value (slv : simple_l_value) (tbl : symbol_table) =
  match slv with
  | Id l_val_id -> (
      match lookup_all l_val_id.id tbl with
      | None ->
          raise
            (Semantic_error (l_val_id.loc, "Variable not defined in any scope"))
      | Some { entry_type; _ } -> (
          match entry_type with
          | Variable vd_ref ->
              let vd = !vd_ref in
              (* fill in the missing values *)
              l_val_id.data_type <- vd.var_type;
              l_val_id.passed_by <- Value;
              l_val_id.frame_offset <- vd.frame_offset;
              l_val_id.parent_path <- vd.parent_path;
              l_val_id.data_type
          | Parameter pd_ref ->
              let pd = !pd_ref in
              (* fill in the missing values *)
              l_val_id.data_type <- pd.param_type;
              l_val_id.passed_by <- pd.pass_by;
              l_val_id.frame_offset <- pd.frame_offset;
              l_val_id.parent_path <- pd.parent_path;
              l_val_id.data_type
          | Function _ ->
              raise
                (Semantic_error
                   (l_val_id.loc, "Function cannot be used as l-value"))))
  | LString { data_type; _ } -> data_type

let rec sem_l_value (lv : l_value) (tbl : symbol_table) =
  match lv with
  | Simple slv -> sem_simple_l_value slv tbl
  | ArrayAccess { simple_l_value = slv; exprs } -> (
      let loc = get_loc_l_value lv in
      let rec comp_dims_exprs dims exprs loc =
        match (dims, exprs) with
        | [], [] -> []
        | [], _ ->
            raise
              (Semantic_error (loc, "Array access dimension count mismatch"))
        | dims, [] -> dims
        | _ :: tl_dims, expr :: tl_exprs ->
            let lloc = get_loc_expr expr in
            let expr_type = sem_expr expr tbl in
            if expr_type <> Scalar Int then
              raise
                (Semantic_error (lloc, "Array access dimension must be integer"))
            else comp_dims_exprs tl_dims tl_exprs lloc
      in
      let l_val_type = sem_simple_l_value slv tbl in
      (* l_val_type will be the full type of this array *)
      let type_t, dims =
        (* type_t will be the element type of this array *)
        match l_val_type with
        | Array (type_t, dims) -> (type_t, dims)
        | _ ->
            raise
              (Semantic_error (loc, "Trying to access elements of non array"))
      in
      let dims = comp_dims_exprs dims exprs loc in
      match dims with [] -> Scalar type_t | dims -> Array (type_t, dims))

and sem_func_call (func_call : func_call) (exprs : expr list) tbl =
  match lookup_all func_call.id tbl with
  | None ->
      raise
        (Semantic_error
           (func_call.loc, "Function not defined: '" ^ func_call.id ^ "'"))
  | Some { entry_type; _ } -> (
      match entry_type with
      | Function fdr ->
          let fd = !fdr in
          func_call.ret_type <- fd.ret_type;
          let param_types =
            List.map (fun (pd : param_def) -> pd.param_type) fd.params
          in
          if List.length exprs < List.length param_types then
            raise
              (Semantic_error
                 (func_call.loc, "Too few arguments in function call"))
          else if List.length exprs > List.length param_types then
            raise
              (Semantic_error
                 (func_call.loc, "Too many arguments in function call"))
          else
            let expr_types = List.map (fun expr -> sem_expr expr tbl) exprs in
            (* check that argument types match *)
            List.iter2
              (comp_var_param_types func_call.loc)
              expr_types param_types;
            (* fill in missing information of argument AST nodes *)
            func_call.args <-
              List.map2
                (fun (expr : expr) (param : param_def) ->
                  check_ref expr param.pass_by;
                  (expr, param.pass_by))
                exprs fd.params;
            func_call.callee_path <- fd.parent_path;
            Scalar func_call.ret_type
      | _ ->
          raise
            (Semantic_error
               (func_call.loc, "Function not defined: '" ^ func_call.id ^ "'")))

and sem_expr (expr : expr) (tbl : symbol_table) =
  match expr with
  | LitInt _ -> Scalar Int
  | LitChar _ -> Scalar Char
  (* LValue and FuncCall will have already been checked at this point *)
  (* We only use sem_l_value and sem_expr to get the types of these expressions... *)
  | LValue l_val -> sem_l_value l_val tbl
  (* Useful even in cases where the return type is 'Nothing', we'll see this in Return statements as well *)
  | EFuncCall func_call -> Scalar func_call.ret_type
  | UnAritOp (_, expr) -> (
      match sem_expr expr tbl with
      | Scalar Int -> Scalar Int
      | _ ->
          raise
            (Semantic_error
               ( get_loc_expr expr,
                 "Unary arithmetic operator must be applied to integer" )))
  | BinAritOp (lhs, _, rhs) -> (
      match (sem_expr lhs tbl, sem_expr rhs tbl) with
      | Scalar Int, Scalar Int -> Scalar Int
      | _, _ ->
          raise
            (Semantic_error
               ( get_loc_expr lhs,
                 "Binary arithmetic operator must be applied to integer" )))

let sem_cond cond tbl =
  match cond with
  | CompOp (lhs, _, rhs) -> (
      match (sem_expr lhs tbl, sem_expr rhs tbl) with
      | Scalar Int, Scalar Int -> ()
      | Scalar Char, Scalar Char -> ()
      | _, _ ->
          raise
            (Semantic_error (get_loc_cond cond, "Cannot compare char with int"))
      )
  | _ -> ()

(* we only check these two statement types, because all other statements will have been checked in the process of building the AST *)
let sem_stmt stmt tbl =
  match stmt with
  | Assign (l_val, expr) -> (
      let loc = get_loc_stmt stmt in
      let l_val_type = sem_l_value l_val tbl in
      let expr_type = sem_expr expr tbl in
      if Ast.contains_str_literal l_val then
        raise (Semantic_error (loc, "Cannot assign to string literal"))
      else if l_val_type <> expr_type then
        raise (Semantic_error (loc, "Assignment type mismatch"))
      else
        match l_val_type with
        | Array _ -> raise (Semantic_error (loc, "Cannot assign to array"))
        | _ -> ())
  | Return { loc; expr_o } ->
      (* expressions of the type return f(); where f return nothing are allowed, because sem_expr will return 'Scalar Nothing' *)
      let expr_type =
        match expr_o with
        | None -> Nothing
        | Some expr -> (
            match sem_expr expr tbl with
            | Scalar s -> s
            | _ -> raise (Semantic_error (loc, "Return type must be scalar")))
      in
      let ret_type = type_of_ret loc tbl in
      if ret_type <> expr_type then
        raise (Semantic_error (loc, "Return type mismatch"))
      else ()
  | _ -> ()

let sem_func_decl (func : Ast.func) (tbl : symbol_table) =
  match lookup func.id tbl with
  | Some _ ->
      raise
        (Semantic_error (func.loc, "Function already exists in current scope"))
  | None -> ()

let ins_func_decl (func : Ast.func) (tbl : symbol_table) =
  insert func.loc func.id (Function (ref func)) tbl

let sem_func_def (func : Ast.func) (tbl : symbol_table) =
  match lookup func.id tbl with
  | None -> ()
  | Some { entry_type; _ } -> (
      match entry_type with
      | Function fdr ->
          let fd = !fdr in
          if fd.status = Ast.Defined then
            raise
              (Semantic_error
                 (func.loc, "Function already defined in current scope"))
          else compare_heads fd func
      | _ ->
          raise
            (Semantic_error
               ( func.loc,
                 "Name already declared and is not a function: '" ^ func.id
                 ^ "'" )))

let ins_func_def (func : Ast.func) (tbl : symbol_table) =
  insert func.loc func.id (Function (ref func)) tbl

let sem_program (func : Ast.func) (tbl : symbol_table) =
  if List.length func.params <> 0 then
    raise (Semantic_error (func.loc, "Main function cannot have parameters"))
  else if func.ret_type <> Nothing then
    raise (Semantic_error (func.loc, "Main function cannot have return type"))
  else
    (* check for any lingering things that might be left behind from parsing *)
    Hashtbl.iter
      (fun _ entry ->
        match entry.entry_type with
        | Function fdr ->
            let fd = !fdr in
            if fd.status = Ast.Declared then
              raise
                (Symbol_table_error
                   (fd.loc, "Lingering function declaration: '" ^ fd.id ^ "'"))
            else
              raise
                (Symbol_table_error
                   (fd.loc, "Lingering function definition: '" ^ fd.id ^ "'"))
        | Variable v ->
            raise
              (Symbol_table_error
                 (!v.loc, "Lingering variable definition: '" ^ !v.id ^ "'"))
        | Parameter p ->
            raise
              (Symbol_table_error
                 (!p.loc, "Lingering parameter definition: '" ^ !p.id ^ "'")))
      tbl.table;
  func
