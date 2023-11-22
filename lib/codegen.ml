let named_values : (string, Llvm.llvalue) Hashtbl.t = Hashtbl.create 10
let context = Llvm.global_context ()
let the_module = Llvm.create_module context "grace"
let builder = Llvm.builder context
let i8_t = Llvm.i8_type context
let i32_t = Llvm.i32_type context
let void_t = Llvm.void_type context
let c8 = Llvm.const_int i8_t
let c32 = Llvm.const_int i32_t

let grace_static_lib () =
  let func_decl (name, ret_type, arg_l) =
    let ft = Llvm.function_type ret_type (Array.of_list arg_l) in
    Llvm.declare_function name ft the_module |> ignore
  in
  List.iter func_decl
    [
      ("writeInteger", void_t, [ i32_t ]);
      ("writeChar", void_t, [ i8_t ]);
      ("writeString", void_t, [ Llvm.pointer_type i8_t ]);
      ("readInteger", i32_t, []);
      ("readChar", i8_t, []);
      ("readString", void_t, [ i32_t; Llvm.pointer_type i8_t ]);
      ("ascii", i32_t, [ i8_t ]);
      ("chr", i8_t, [ i32_t ]);
      ("strlen", i32_t, [ Llvm.pointer_type i8_t ]);
      ("strcmp", i32_t, [ Llvm.pointer_type i8_t; Llvm.pointer_type i8_t ]);
      ("strcpy", void_t, [ Llvm.pointer_type i8_t; Llvm.pointer_type i8_t ]);
      ("strcat", void_t, [ Llvm.pointer_type i8_t; Llvm.pointer_type i8_t ]);
    ]

let rec type_to_lltype = function
  | Ast.Int -> i32_t
  | Ast.Char -> i8_t
  | Ast.Nothing -> void_t
  | Ast.Array (t, dims) ->
      let rec aux t dims =
        match dims with
        | [] -> type_to_lltype t
        | d :: dims -> Llvm.array_type (aux t dims) (Option.get d)
      in
      aux t dims

let var_def_lltype (vd : Ast.var_def) = type_to_lltype vd.type_t

let param_def_lltype (pd : Ast.param_def) =
  match pd.pass_by with
  | Ast.Value -> type_to_lltype pd.type_t
  | Ast.Reference -> (
      match pd.type_t with
      | Ast.Array (t, _ :: tl) ->
          Llvm.pointer_type (type_to_lltype (Ast.Array (t, tl)))
      | _ -> Llvm.pointer_type (type_to_lltype pd.type_t))

let get_parent_name (func : Ast.func) =
  String.concat "." (List.rev func.parent_path)

let get_func_name (func : Ast.func) = get_parent_name func ^ "." ^ func.id
let get_parent_frame_name (func : Ast.func) = "frame__" ^ get_parent_name func
let get_frame_name (func : Ast.func) = "frame__" ^ get_func_name func

let get_parent_frame_type_ptr (func : Ast.func) =
  let parent_frame_name = get_parent_frame_name func in
  match Llvm.type_by_name the_module parent_frame_name with
  | Some frame -> Llvm.pointer_type frame
  | None -> Llvm.pointer_type void_t

let get_frame_type_ptr (func : Ast.func) =
  let frame_name = get_frame_name func in
  match Llvm.type_by_name the_module frame_name with
  | Some frame -> Llvm.pointer_type frame
  | None -> raise (Failure ("Frame type not found: " ^ frame_name))

let get_all_frame_type_ptrs (Ast.MainFunc main_func : Ast.program) =
  let rec aux (acc : Llvm.lltype list) (funcs : Ast.func list list) =
    match funcs with
    | [] -> List.rev acc
    | [] :: tl -> aux acc tl
    | (hd :: tl1) :: tl2 ->
        let _, _, local_func_defs = Ast.reorganize_local_defs hd.local_defs in
        aux (get_frame_type_ptr hd :: acc) (local_func_defs :: tl1 :: tl2)
  in
  aux [] [ [ main_func ] ]

let gen_frame_type (func : Ast.func) =
  let parent_frame_type_ptr = get_parent_frame_type_ptr func in
  let param_lltypes = List.map param_def_lltype func.params in
  let local_var_defs, _, _ = Ast.reorganize_local_defs func.local_defs in
  let local_var_lltypes = List.map var_def_lltype local_var_defs in
  let frame_name = get_frame_name func in
  let frame_field_types =
    Array.of_list ((parent_frame_type_ptr :: param_lltypes) @ local_var_lltypes)
  in
  let frame_type = Llvm.named_struct_type context frame_name in
  Llvm.struct_set_body frame_type frame_field_types false

let gen_all_frame_types (Ast.MainFunc main_func : Ast.program) =
  let rec aux (func : Ast.func) =
    gen_frame_type func;
    let _, _, local_func_defs = Ast.reorganize_local_defs func.local_defs in
    List.iter aux local_func_defs
  in
  aux main_func

let rec get_frame_ptr fr_ptr hops =
  match hops with
  | 0 -> fr_ptr
  | hops ->
    let link_ptr = Llvm.build_struct_gep fr_ptr 0 "link_ptr" builder in
    let link = Llvm.build_load link_ptr "link" builder in
    get_frame_ptr link (hops - 1)

let rec gen_l_value frame caller_path (l_val : Ast.l_value) =
  match l_val with
  | Ast.Id l_val_id -> gen_lval_id frame caller_path l_val_id
  | Ast.LString Ast.{id;_} ->
    let str = Llvm.build_global_string id id builder in
    Llvm.build_struct_gep str 0 "str_char_ptr" builder
  | Ast.ArrayAccess (l_val, e_l) ->
    let l_val_ptr = gen_l_value frame caller_path l_val in
    let e_l_val = List.map (gen_expr frame caller_path) e_l in
    (* ?? might need a 0 index at the start of the array... ?? *)
    let e_l_val = c32 0 :: e_l_val in
    let e_l_val = Array.of_list e_l_val in
    Llvm.build_gep l_val_ptr e_l_val "array_access" builder

and gen_lval_id frame caller_path (l_val_id : Ast.l_value_id) =
  let Ast.{id; pass_by; frame_offset; parent_path;_} = l_val_id in
  let hops = List.length caller_path - List.length parent_path in
  let frame_ptr = get_frame_ptr frame hops in
  let element_ptr = Llvm.build_struct_gep frame_ptr frame_offset "element_ptr" builder in
  match pass_by with
  | Ast.Reference -> Llvm.build_load element_ptr id builder
  | Ast.Value -> element_ptr

and gen_func_arg frame caller_path ((e, pb): Ast.expr * Ast.pass_by) =
  match pb with
  | Ast.Value -> gen_expr frame caller_path e
  | Ast.Reference -> (
    let l_v = match e with
    | Ast.LValue l_v -> l_v
    | _ -> raise (Failure "Cannot pass by reference a non-lvalue")
    in gen_l_value frame caller_path l_v
)

and gen_func_call frame caller_path (func_call : Ast.func_call) =
  let func_decl = 
    match Llvm.lookup_function func_call.id the_module with
    | Some func_decl -> func_decl
    | None -> raise (Failure ("Function declaration not found: " ^ func_call.id))
  in
  let func_args = List.map (gen_func_arg frame caller_path) func_call.args in
  let hops = List.length caller_path - List.length func_call.callee_path in
  let frame_ptr = get_frame_ptr frame hops in
  let func_args = frame_ptr :: func_args in
  Llvm.build_call func_decl (Array.of_list func_args) ("func_call_" ^ func_call.id) builder 

and gen_expr frame caller_path (e : Ast.expr) =
  match e with
  | Ast.LitInt { lit_int; _ } -> c32 lit_int
  | Ast.LitChar { lit_char; _ } -> c8 (Char.code lit_char)
  | Ast.LValue l_value -> gen_l_value frame caller_path l_value
  | Ast.EFuncCall fc -> gen_func_call frame caller_path fc
  | Ast.UnAritOp (op, expr) -> (
      let rhs = gen_expr frame caller_path expr in
      match op with
      | Ast.Pos -> rhs
      | Ast.Neg -> Llvm.build_neg rhs "neg" builder)
  | Ast.BinAritOp (expr1, op, expr2) -> (
      let lhs = gen_expr frame caller_path expr1 in
      let rhs = gen_expr frame caller_path expr2 in
      match op with
      | Ast.Add -> Llvm.build_add lhs rhs "add" builder
      | Ast.Sub -> Llvm.build_sub lhs rhs "sub" builder
      | Ast.Mul -> Llvm.build_mul lhs rhs "mul" builder
      | Ast.Div -> Llvm.build_sdiv lhs rhs "div" builder
      | Ast.Mod -> Llvm.build_srem lhs rhs "mod" builder)

let rec gen_cond frame caller_path (cond : Ast.cond) =
  match cond with
  | Ast.UnLogicOp (op, cond) -> (
      match op with
      | Ast.Not ->
          let rhs = gen_cond frame caller_path cond in
          Llvm.build_not rhs "not" builder)
  | Ast.BinLogicOp (cond1, op, cond2) ->
      let lhs = gen_cond frame caller_path cond1 in
      let lhs_block = Llvm.insertion_block builder in
      let func = Llvm.block_parent lhs_block in
      let rhs_block = Llvm.append_block context "rhs" func in
      let merge_block = Llvm.append_block context "merge" func in
      let _ =
        match op with
        | Ast.And -> Llvm.build_cond_br lhs rhs_block merge_block builder
        | Ast.Or -> Llvm.build_cond_br lhs merge_block rhs_block builder
      in
      Llvm.position_at_end rhs_block builder;
      let rhs = gen_cond frame caller_path cond2 in
      let _ = Llvm.build_br merge_block builder in
      Llvm.position_at_end merge_block builder;
      Llvm.build_phi [ (lhs, lhs_block); (rhs, rhs_block) ] "phi" builder
  | Ast.CompOp (expr1, op, expr2) -> (
      let lhs = gen_expr frame caller_path expr1 in
      let rhs = gen_expr frame caller_path expr2 in
      match op with
      | Ast.Eq -> Llvm.build_icmp Llvm.Icmp.Eq lhs rhs "eq" builder
      | Ast.Neq -> Llvm.build_icmp Llvm.Icmp.Ne lhs rhs "neq" builder
      | Ast.Gt -> Llvm.build_icmp Llvm.Icmp.Sgt lhs rhs "gt" builder
      | Ast.Lt -> Llvm.build_icmp Llvm.Icmp.Slt lhs rhs "lt" builder
      | Ast.Geq -> Llvm.build_icmp Llvm.Icmp.Sge lhs rhs "geq" builder
      | Ast.Leq -> Llvm.build_icmp Llvm.Icmp.Sle lhs rhs "leq" builder)

let rec codegen_block frame caller_path (stmts : Ast.block) =
  List.iter (gen_stmt frame caller_path) stmts

and gen_stmt frame caller_path (stmt : Ast.stmt) =
  match stmt with
  | Ast.Empty -> ()
  | Ast.Assign (l_val, expr) ->
    let rhs = gen_expr frame caller_path expr in
    let l_val_ptr = gen_l_value frame caller_path l_val in
    ignore (Llvm.build_store rhs l_val_ptr builder)
  | Ast.Block block -> codegen_block frame caller_path block
  | Ast.SFuncCall func_call -> ignore (gen_func_call frame caller_path func_call)
  | Ast.If (cond, stmt1_o, stmt2_o) ->
    let cond = gen_cond frame caller_path cond in
    let icmp_ne = Llvm.build_icmp Llvm.Icmp.Ne cond (c32 0) "if" builder in
    let func = Llvm.block_parent (Llvm.insertion_block builder) in
    let then_block = Llvm.append_block context "then" func in
    let else_block = Llvm.append_block context "else" func in
    let merge_block = Llvm.append_block context "merge" func in
    let _ = Llvm.build_cond_br icmp_ne then_block else_block builder in
    Llvm.position_at_end then_block builder;
    gen_stmt frame caller_path (Option.get stmt1_o);
    (* will never be None *)
    let _ = Llvm.build_br merge_block builder in
    Llvm.position_at_end else_block builder;
    if Option.is_some stmt2_o then gen_stmt frame caller_path (Option.get stmt2_o);
    let _ = Llvm.build_br merge_block builder in
    Llvm.position_at_end merge_block builder
  | Ast.While (cond, stmt) ->
    let func = Llvm.block_parent (Llvm.insertion_block builder) in
    let cond_block = Llvm.append_block context "cond" func in
    let body_block = Llvm.append_block context "body" func in
    let merge_block = Llvm.append_block context "merge" func in
    let _ = Llvm.build_br cond_block builder in
    Llvm.position_at_end cond_block builder;
    let cond = gen_cond frame caller_path cond in
    let _ = Llvm.build_cond_br cond body_block merge_block builder in
    Llvm.position_at_end body_block builder;
    gen_stmt frame caller_path stmt;
    let _ = Llvm.build_br cond_block builder in
    Llvm.position_at_end merge_block builder
  | Return Ast.{expr_o;_} ->
    match expr_o with
    | None -> ignore (Llvm.build_ret_void builder)
    | Some expr ->
      let ret_val = gen_expr frame caller_path expr in
      ignore (Llvm.build_ret ret_val builder)

let gen_func_def (Ast.func) = () (* ΤΑ ΛΙΓΟΥΡΕΥΕΣΤΕ? *)








(*
  // grace code
  fun f(a: int): nothing
    var b: char[5];
    var c: int;
    fun g(): nothing
    {}
    fun h(): nothing
    {
      g();
    }
  {
  }

  // llvm representation (kind of)
  struct frame__f {
    void* parent;
    int a;
    char b[5];
    int c;
  }

  struct frame__f_g {
    frame__f* parent;
  }

  struct frame__f_h {
    frame__f* parent;
  }

  // llvm code (high level)
  fun func__f(ref x: frame__f): nothing
  {
  }

  fun func__f_g(ref x: frame__f_g): nothing
  {
  }

  fun func__f_h(ref x: frame__f_h): nothing
  {
    func__f_g(x.parent);
  }
*)