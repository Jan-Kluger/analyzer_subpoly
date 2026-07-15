(** OCaml implementation of the subpolyhedra domain.

    @see <https://www.microsoft.com/en-us/research/wp-content/uploads/2011/06/subpolyhedra.pdf>  Subpolyhedra. *)

open Batteries
open GoblintCil
open Pretty
module M = Messages
open GobApron
open SubPolyhedraCore

module Mpqf = SharedFunctions.Mpqf
module RationalInterval = Rationalinterval.RationalInterval

(** Variable
 * type t, basically ordered and printable
*)
module type Var = sig
  type t [@@deriving hash]
  val compare : t -> t -> int
  val string_of : t -> string
end

module VarManagement = struct
  module Int = struct
    type t = int
    let equal = Int.equal
    let compare = Int.compare
    let string_of = Int.to_string
    let hash = Hashtbl.hash
    let to_int = identity
    let to_t = identity
  end
  module SubPolyDomain = SubPoly(Int)(RationalInterval)
  include SharedFunctions.VarManagementOps (SubPolyDomain)

  let dim_add = SubPolyDomain.dim_add
  (*potentially add dim_remove here, not sure though*)  
end

module Linexpr_managment = struct
  include VarManagement
  include RatOps.ConvenienceOps (Mpqf)

  module V = RelationDomain.V
  module CoeffVector = VarManagement.SubPolyDomain.CoeffVector
  type linexpr = CoeffVector.t

  (* Adapted version of Leonie's Texpr parsing from her SparseOctagon domain. Instead of monomials we now use coeff vector. *)
  let mpqf_of_scalar (x: Scalar.t) =
    match x with
    | Float f -> Mpqf.of_float f
    | Mpqf q -> q
    | Mpfrf m -> Mpfr.to_mpq m

  (** [to_constant_opt v] is [Some c] iff [v] has no variable coefficients, i.e. it
     represents just the constant [c] (the first non-zero entry is the last slot). *)
  let to_constant_opt (v: linexpr) : Mpqf.t option =
    match CoeffVector.find_first_non_zero v with
    | None -> Some Mpqf.zero
    | Some (i, value) when i = CoeffVector.length v - 1 -> Some value
    | _ -> None

  let mpqf_of_z z = Mpqf.of_mpz @@ Z_mlgmpidl.mpzf_of_z z

  (** [gcd_list v] gcd of coeffvec. Gcd with all coefficients. *)
  let gcd_list (v: linexpr) : Z.t =
    (* fold Z.gcd over the numerators of every stored (non-zero) coefficient *)
    let gcd =
      CoeffVector.to_sparse_list v
      |> List.fold_left (fun acc (_, c) -> Z.gcd acc (Mpqf.get_num c)) Z.zero
    in
    (* an all-zero vector has gcd 0, so fall back to 1 to make dividing a no-op *)
    if Z.equal gcd Z.zero then Z.one else gcd

  (** [lcm_den_list v] lcm of the denominators of every stored coefficient. *)
  let lcm_den_list (v: linexpr) : Z.t =
    CoeffVector.to_sparse_list v
    |> List.fold_left (fun acc (_, c) -> Z.lcm acc (Mpqf.get_den c)) Z.one

  let normalize_info (v: linexpr) : linexpr * Mpqf.t =
    let gcd = gcd_list v in
    let lcm = lcm_den_list v in
    (* sign normalization, flip so the leading (lowest-index) coefficient is positive *)
    let sign = match CoeffVector.find_first_non_zero v with
      | Some (_, leading) when leading <: Mpqf.zero -> Mpqf.mone
      | _ -> Mpqf.one
    in
    (* the factor we divide out carries both the magnitude (the content gcd/lcm) and the sign *)
    let factor = sign *: mpqf_of_z gcd /: mpqf_of_z lcm in
    (* divide every (non-zero) coefficient, zeros are left untouched *)
    CoeffVector.map_f_preserves_zero (fun c -> c /: factor) v, factor

  let negate v = CoeffVector.map_f_preserves_zero Mpqf.neg v

  (* if one of them is a constant, then multiply. Otherwise, the expression is not linear, return None *)
(** [multiply], multiplies two [linexpr]s. Return s Some [value] iff. exactly one of the two [linexpr]s is a constant.*)
  let multiply (a : linexpr) (b : linexpr) =
    match to_constant_opt a, to_constant_opt b with
    | _, Some c -> Some (CoeffVector.map_f_preserves_zero (fun x -> c *: x) a)
    | Some c, _ -> Some (CoeffVector.map_f_preserves_zero (fun x -> c *: x) b)
    | _ -> None

    (** [get_coeff_vec], get a coeffvec from a linexpr.  *)
  let get_coeff_vec (t: t) (texp : Texpr1.expr) : linexpr option =
    let open Apron.Texpr1 in
    let exception NotLinearExpr in
    let num_slacks = match t.d with Some d -> SubPolyDomain.num_slacks d | None -> 0 in
    let zero_vec = CoeffVector.zero_vec (Environment.size t.env + num_slacks + 1) in
    let const_idx = CoeffVector.length zero_vec - 1 in
    let rec convert_texpr texp =
      begin match texp with
        | Cst (Interval _) -> 
          (* interval constants are not supported *)
          raise NotLinearExpr
        | Cst (Scalar x) ->
          (* convert the scalar to an Mpqf *)
          let c = mpqf_of_scalar x in
          CoeffVector.set_nth zero_vec const_idx c
        | Var x -> CoeffVector.set_nth zero_vec (Environment.dim_of_var t.env x) Mpqf.one
        | Unop  (Neg,  e, _, _) -> negate (convert_texpr e)
        | Unop  (Cast, e, _, _) -> convert_texpr e
        | Binop (Add, e1, e2, _, _) -> CoeffVector.map2_f_preserves_zero (+:) (convert_texpr e1) (convert_texpr e2)
        | Binop (Sub, e1, e2, _, _) -> CoeffVector.map2_f_preserves_zero (+:) (convert_texpr e1) (negate (convert_texpr e2))
        | Binop (Mul, e1, e2, _, _) -> 
          begin match multiply (convert_texpr e1) (convert_texpr e2) with
            | Some v -> v
            | None -> raise NotLinearExpr end
        (*Future TODO: sound division handling, not supported yet.*)
        | _  -> raise NotLinearExpr end
    in match convert_texpr texp with
    | exception NotLinearExpr -> None
    | x -> Some(x)
end

module Slack_managment = struct
  include Linexpr_managment
  include RatOps.ConvenienceOps (Mpqf)

  (** [is_slack t col] is [true] iff column [col] is a slack column. *)
  let is_slack (t: t) (col: int) : bool =
    (* Get the interval map from the domain, false if domain option is None *)
    match t.d with
    | None -> false
    | Some d -> SubPolyDomain.mem_intv col d

  (** [fold_slacks f t acc] folds [f col interval info] over every slack,
      where [info] is the slack's linear definition over the real variables*)
  let fold_slacks (f: int -> RationalInterval.t -> SubPolyDomain.info option -> 'a -> 'a) (t: t) (acc: 'a) : 'a =
    match t.d with
    | None -> acc
    | Some d ->
      SubPolyDomain.VarMap.fold (fun col iv acc ->
          f col iv (SubPolyDomain.VarMap.find_opt col d.infos) acc
        ) d.intervals acc

  (** [add_slack_constraint t linexpr interval] introduces a fresh slack [s = linexpr]
      constrained to [interval]. Here the constant is pulled out of the linear expression
      into the interval and also stripped out of the info.*)
  let add_slack_constraint (t: t) (linexpr: linexpr) (interval: RationalInterval.t) : t =
    if is_bot_env t then t
    else
      match t.d with
      | None -> t
      | Some d ->
        (* normalize expr and then insert when adding slacks *)
        let normalized, factor = normalize_info linexpr in
        (*get normalized const*)
        let const = CoeffVector.nth normalized ((CoeffVector.length normalized) - 1) in
        (*Strip constant of info*)
        let info = CoeffVector.set_nth normalized ((CoeffVector.length normalized) - 1) Mpqf.zero in
        (* Tweak interval *)
        let interval = RationalInterval.scale (Mpqf.one /: factor) interval in
        (* add the constant into the interval*)
        let interval = RationalInterval.add_const (Mpqf.neg const) interval in
        let find_key_on_info map info = Seq.find (fun (_, v) -> SubPolyDomain.info_equal v info) @@ SubPolyDomain.VarMap.to_seq map in
        match find_key_on_info  d.infos info with 
        | None -> (*There is no slack yet with that info, we insert a new one.*)
          (* the new slack goes at column n+m = the current constant-column index *)
          let slack_col = Environment.size t.env + SubPolyDomain.num_slacks d in (*Not sure if this is safe, as there might be a gap no?*)
          { t with d = Some (SubPolyDomain.insert_slack slack_col info interval d) }
        | Some (k, _) -> (* We already have a slack with that info and update its interval.*)
          match RationalInterval.meet (SubPolyDomain.VarMap.find k d.intervals) interval with 
          | None -> bot_env
          | Some i -> {t with d = Some (SubPolyDomain.set_intv k i d)} 
        
end

module ExpressionBounds: (SharedFunctions.ConvBounds with type t = VarManagement.t) = struct
  include Linexpr_managment

  (* reduce solves over Q, but the expression is integer-valued. rounding the upper
     bound down and the lower bound up *)
  let z_floor q = Z.fdiv (Mpqf.get_num q) (Mpqf.get_den q)
  let z_ceil q = Z.cdiv (Mpqf.get_num q) (Mpqf.get_den q)

  (* [None] anywhere in the chain (bot state, non-linear expression, infeasible after
     reduce) means "no bounds": the caller gets [(None, None)]. *)
  let bound_texpr (t: t) (texpr : Texpr1.t) : Z.t option * Z.t option =
    let bounds =
      (* Get monad *)
      let open GobOption.Syntax in
      let* d = t.d in
      let* v = get_coeff_vec t (Texpr1.to_expr texpr) in
      match to_constant_opt v with
      | Some c when Z.equal (Mpqf.get_den c) Z.one ->
        let n = Mpqf.get_num c in
        Some (Some n, Some n)
      | Some _ -> None (* non-integral constant *)
      | None ->

        (* Give the expression a temporary slack (row s = expr, interval top) and let
           reduce compute the tightest interval for it. The constant stays inside the
           row (unlike add_slack_constraint), so s equals the full expression and the
           refined interval needs no shifting. The temporary state is discarded. *)

        let slack_col = Environment.size t.env + SubPolyDomain.num_slacks d in
        let* d' = SubPolyDomain.reduce (SubPolyDomain.insert_slack slack_col v RationalInterval.top d) in
        let lower, upper = RationalInterval.bounds (SubPolyDomain.VarMap.find slack_col d'.intervals) in
        Some (Option.map z_ceil lower, Option.map z_floor upper)
    in
    Option.default (None, None) bounds
end

module D =
struct
  include Printable.Std
  include RatOps.ConvenienceOps (Mpqf)
  include VarManagement
  include Linexpr_managment
  include Slack_managment

  module Bounds = ExpressionBounds
  module V = RelationDomain.V
  module Arg = struct
    let allow_global = true
  end
  module Convert = SharedFunctions.Convert (V) (Bounds) (Arg) (SharedFunctions.Tracked)

  let name () = "subpoly"

  let to_yojson _ = failwith "doesn't exist"

  (* pretty printing *)
  let show (t: t) =
    let env = Environment.show t.env in
    match t.d with
    | None -> "\tBot env = " ^ env ^ "\n"
    | Some d -> SubPolyDomain.string_of d ^ "; env = " ^ env
  
    let pretty () (x: t) = text (show x)
  
  let pretty_diff () ((x, y): t * t) =
    dprintf "%s: %a not leq %a" (name ()) pretty x pretty y
  
    let printXml (f: _ BatInnerIO.output) (x: t) = BatPrintf.fprintf f "<value>\n%s</value>\n" (XmlUtil.escape (show x))

  (* basic lattice handling *)
  let top () = { d = Some (SubPolyDomain.empty ()); env = empty_env }
  let is_top (t: t) = GobOption.exists SubPolyDomain.is_empty t.d
  let is_bot = is_bot_env

  let is_top_env t = (not @@ Environment.equal t.env empty_env) && is_top t


  (* fixpoint iteration handling *)
  (* here we wire up the things from Core *)
  

  let meet a b = (* concept copied from the join, just changed a few cases. should be done now *) 
    if is_bot a then a 
    else if is_bot b then b
    else
      match a.d, b.d with 
      | None, _ -> b
      | _, None -> a
      | Some x, Some y when is_top_env a -> b
      | Some x, Some y when is_top_env b -> a
      | Some x, Some y when (Environment.cmp a.env b.env <> 0)->
        let sup_env = Environment.lce a.env b.env in
        let a = dim_add (Environment.dimchange a.env sup_env) x in
        let b = dim_add (Environment.dimchange b.env sup_env) y in 
        {d = SubPolyDomain.meet a b; env = sup_env}
      | Some x, Some y when SubPolyDomain.equal x y -> a
      | Some x, Some y -> {d = SubPolyDomain.meet x y; env = a.env }

(**
[join a b ] joins two subpolyhedra. It adapts the apron environment so that both share the 
same indices. Then it calls SubPolyDomain.join on the updated subpolyhedra. Adapted from ltve.
*)
  let join a b =
    if is_bot a then b
    else if is_bot b then a
    else 
      let sup_env = Environment.lce a.env b.env in
      match a.d, b.d with 
      | None, _ -> b
      | _, None -> a
      | Some x, Some y when is_top_env a || is_top_env b ->
       {d = Some (SubPolyDomain.empty ()); env = sup_env}
      | Some x, Some y when (Environment.cmp a.env b.env <> 0)->
       let a = dim_add (Environment.dimchange a.env sup_env) x in
       let b = dim_add (Environment.dimchange b.env sup_env) y in 
       {d = (SubPolyDomain.join a  b); env = sup_env}
      | Some x, Some y when SubPolyDomain.equal x y -> a
      | Some x, Some y -> {d = SubPolyDomain.join x y; env = a.env }


(**
[widen a b ] widens two subpolyhedra. It adapts the apron environment so that both share the
same indices. Then it calls SubPolyDomain.widen on the updated subpolyhedra. Adapted from ltve.
*)
  let widen a b =
    if is_bot a then b
    else if is_bot b then a
    else 
      let sup_env = Environment.lce a.env b.env in
      match a.d, b.d with 
      | None, _ -> b
      | _, None -> a
      | Some x, Some y when is_top_env a || is_top_env b ->
       {d = Some (SubPolyDomain.empty ()); env = sup_env}
      | Some x, Some y when (Environment.cmp a.env b.env <> 0)->
       let a = dim_add (Environment.dimchange a.env sup_env) x in
       let b = dim_add (Environment.dimchange b.env sup_env) y in 
       {d = (SubPolyDomain.widen a  b); env = sup_env}
      | Some x, Some y when SubPolyDomain.equal x y -> a
      | Some x, Some y -> {d = SubPolyDomain.widen x y; env = a.env }


  let leq a b =
    let env_comp = Environment.cmp a.env b.env in (* Apron's Environment.cmp has defined return values. *)
    if env_comp = -2 || env_comp > 0 then
      (* -2:  environments are not compatible (a variable has different types in the 2 environements *)
      (* -1: if env1 is a subset of env2,  (OK)  *)
      (*  0:  if equality,  (OK) *)
      (* +1: if env1 is a superset of env2, and +2 otherwise (the lce exists and is a strict superset of both) *)
      false
    else if is_bot a || is_top_env b then
      true
    else if is_bot b || is_top_env a then
      false
    else
      let a_d, b_d = Option.get a.d, Option.get b.d in
      let a_d' = if env_comp = 0 then a_d else dim_add (Environment.dimchange a.env b.env) a_d in
      SubPolyDomain.leq a_d' b_d
  
  let narrow = meet
  let unify = meet

  (* transfer functions *)

  (**************
    Removes all rows in the affeq Matrix containing the vars, removes the corresponding entry in the 
  **************)
  let forget_vars t vars =
    if vars = [] || is_bot t || is_top t then t
    else 
      let d = Option.get t.d in 
      let dims = List.map (Environment.dim_of_var t.env) vars in (* map of vars in Env. to dimensions in matrix.*)
      {t with d = Some (SubPolyDomain.forget_vars dims d)}
  
  let forget_var (t: t) (v: V.t) = forget_vars t [v]
  
  let add_equation (t: t) (v: int) (coeffvector: CoeffVector.t) =
    match t.d with
    | None -> t
    | Some d ->
      let row = CoeffVector.set_nth coeffvector v (Mpqf.neg Mpqf.one) in (* -x zur linexpr hinzufügen; x = linexpr --> 0 = linexpr - x*)
      { t with d = Some (SubPolyDomain.add_affeq_row row d) } 

  (** [substitute_expr t assigned_dim rhs] is the transfer function for the invertible
      assignment [x := rhs] where [x] is the variable at column [assigned_dim] and
      occurs in [rhs] with nonzero coefficient. *)
  let substitute_expr (t: t) (assigned_dim: int) (rhs: linexpr) : t =
    match t.d with
    | None -> t
    | Some d ->
      match CoeffVector.nth rhs assigned_dim with
      | assigned_coeff when assigned_coeff =: Mpqf.zero -> failwith "substitute_expr: assigned variable not in expression"
      | assigned_coeff ->
        let substitute_x_by_this = 
          CoeffVector.mapi_f_preserves_zero
            (fun idx coeff ->
              if idx = assigned_dim then Mpqf.one /: assigned_coeff 
              else Mpqf.neg (coeff /: assigned_coeff)
            ) rhs in
        
        let substitute_in = (fun vec ->
          match CoeffVector.nth vec assigned_dim with
          | coef when coef =: Mpqf.zero -> vec
          | coef ->
            let zero_vec = (CoeffVector.set_nth vec assigned_dim Mpqf.zero) in
            CoeffVector.map2_f_preserves_zero (fun x s -> x +: coef *: s)  zero_vec substitute_x_by_this
        )
        in
        (* infos mentioning the assigned var go stale: the slack keeps its column and
           interval (its value is unchanged), but the symbolic description is dropped
           and the substituted definition is re-asserted via add_slack_constraint,
           which re-canonicalizes *)
        let stale, kept = SubPolyDomain.VarMap.partition (fun _ info -> not (CoeffVector.nth info assigned_dim =: Mpqf.zero)) d.infos in

        (* Make enw domain with kept infos *)
        let t = { t with d = Some { d with affeq = SubPolyDomain.Matrix.map substitute_in d.affeq; infos = kept } } in
        
        (* Now add new intervals. Walk over stale intervals, and re add, this is the value to return *)
        SubPolyDomain.VarMap.fold (fun svar info t ->
            match SubPolyDomain.VarMap.find_opt svar d.intervals, t.d with
            | None, _ | _, None -> t
            | Some interval, Some d_cur ->
              let info' = substitute_in info in
              (* each re-add may grow the state by a slack column, so pad info'
                 (computed at the old width) with zeros before the constant *)

              (* Resize to fit *)
              let delta = Environment.size t.env + SubPolyDomain.num_slacks d_cur + 1 - CoeffVector.length info' in
              let info' = if delta = 0 then info'
                else CoeffVector.insert_zero_at_indices info' [(CoeffVector.length info' - 1, delta)] delta in
              add_slack_constraint t info' interval) stale t

  let assign_texpr (t: VarManagement.t) var texp =
    match t.d with
    | None -> t
    | Some d ->
      let var_i = Environment.dim_of_var t.env var (* this is the variable we are assigning to *) in
      begin match get_coeff_vec t texp with 
        | Some coeffvector when  List.exists (fun (var, _ ) -> var = var_i) (CoeffVector.to_sparse_list coeffvector) -> substitute_expr t var_i coeffvector
        | Some coeffvector -> add_equation (forget_var t var) var_i coeffvector
        | _ -> forget_vars t [var] (* all other cases: var := texp, where texp is not of any form we can handle, so we forget var *)
      end
  
  (*< Copy-pasted from ltve >*)
  let assign_exp ask (t: VarManagement.t) var exp (no_ov: bool Lazy.t) : VarManagement.t =
    let t = if not @@ Environment.mem_var t.env var then add_vars t [var] else t in
    match Convert.texpr1_expr_of_cil_exp ask t t.env exp no_ov with
    | texp -> assign_texpr t var texp
    | exception Convert.Unsupported_CilExp _ -> forget_vars t [var]
  (*</ Copy-pasted from ltve >*)

  (*< Copy-pasted from ltve >*)
  let assign_var (t: VarManagement.t) v v' =
    let t = add_vars t [v; v'] in
    assign_texpr t v (Var v') 
  (*</ Copy-pasted from ltve >*)

  (*< Copy-pasted from ltve >*)
  let assign_var_parallel t vv's =
    let assigned_vars = List.map fst vv's in
    let t = add_vars t assigned_vars in
    let primed_vars = List.init (List.length assigned_vars) (fun i -> Var.of_string (string_of_int i  ^"'")) in
    let t_primed = add_vars t primed_vars in
    let multi_t = List.fold_left2 (fun t' v_prime (_,v') -> assign_var t' v_prime v') t_primed primed_vars vv's in
    match multi_t.d with
    | Some arr when not @@ is_top multi_t ->
      let switched_arr = List.fold_left2 (fun multi_t assigned_var primed_var-> assign_var multi_t assigned_var primed_var) multi_t assigned_vars primed_vars in
      remove_vars switched_arr primed_vars
    | _ -> t
  (*</ Copy-pasted from ltve >*)

  (*< Copy-pasted from ltve >*)
  let assign_var_parallel_with t vv's =
    (* TOD0: If we are angling for more performance, this might be a good place ot try. `assign_var_parallel_with` is used whenever a function is entered (body),
       in unlock, at sync edges, and when entering multi-threaded mode. *)
    let t' = assign_var_parallel t vv's in
    t.d <- t'.d;
    t.env <- t'.env
  (*</ Copy-pasted from ltve >*)

  (*< Copy-pasted from ltve >*)
  let assign_var_parallel' t vs1 vs2 =
    let vv's = List.combine vs1 vs2 in
    assign_var_parallel t vv's
  (*</ Copy-pasted from ltve >*)

  (*< Copy-pasted from ltve >*)
  let substitute_exp ask t var exp no_ov =
    let t = if not @@ Environment.mem_var t.env var then add_vars t [var] else t in
    let res = assign_exp ask t var exp no_ov in
    forget_vars res [var] 
  (*</ Copy-pasted from ltve >*)

  (*< Copy-pasted from ltve >*)
  let cil_exp_of_lincons1 = Convert.cil_exp_of_lincons1

(* reduce in meet tcons *)
  let reduce_to_bot (t: t) : t =
    match t.d with
    | None -> t
    | Some d ->
      match SubPolyDomain.reduce d with
      | None -> bot_env
      | Some d' -> { t with d = Some d' }

  (* tried to adapt something from LTVE, dont quite get what is, to my understandinf its checking if some expr holds.
    We either have true, go through control flow with new constraint, or false and go with negated? *)
  let meet_tcons _ask (t: t) tcons1 _e _no_ov =
    if is_bot_env t then t
    else
      match get_coeff_vec t (Texpr1.to_expr @@ Tcons1.get_texpr1 tcons1) with
      | None -> t (* non-linear expression: no information gained *)
      | Some v ->
        begin match to_constant_opt v, Tcons1.get_typ tcons1 with
          (* expr collapses to a constant c: immediate feasibility check *)
          | Some c, EQ    -> if c <>: Mpqf.zero then bot_env else t
          | Some c, SUPEQ -> if c <:  Mpqf.zero then bot_env else t
          | Some c, SUP   -> if c <=: Mpqf.zero then bot_env else t
          | Some c, DISEQ -> if c =:  Mpqf.zero then bot_env else t
          (* expr has variables: record it (inconsistency caught later, at rref) *)
          | None, EQ            -> reduce_to_bot { t with d = Some (SubPolyDomain.add_affeq_row v (Option.get t.d)) }
          | None, SUPEQ -> reduce_to_bot @@ add_slack_constraint t v (RationalInterval.of_bounds ~lower:(Some Mpqf.zero) ~upper:None)
          | None, SUP ->
            (* over integer variables expr > 0 <=> expr >= 1, provided expr is
               integer-valued: scale by the lcm of the coefficient denominators
               (an equivalent constraint) to clear fractions first *)
            let lcm = List.fold_left (fun acc (_, c) -> 
              Z.lcm acc (Mpqf.get_den c)
              ) Z.one (CoeffVector.to_sparse_list v) 
            in
            let v = if Z.equal lcm Z.one then v else CoeffVector.map_f_preserves_zero (fun c -> c *: mpqf_of_z lcm) v in
            reduce_to_bot (add_slack_constraint t v (RationalInterval.of_bounds ~lower:(Some Mpqf.one) ~upper:None))
          | _ -> t (* DISEQ / EQMOD over variables: not representable, give up (sound) *)
        end

  (* Module AssertionRels demands: *)
  (* cehck if constraints hold. Copied from LTVE *)
    let assert_constraint ask d e negate (no_ov: bool Lazy.t) =
    match Convert.tcons1_of_cil_exp ask d d.env e negate no_ov with
    | tcons1 -> meet_tcons ask d tcons1 e no_ov
    | exception Convert.Unsupported_CilExp _ -> d

  let env t = t.env
  let eval_interval _ask = Bounds.bound_texpr
  let invariant _t = failwith "SubPolyhedraDomain.invariant:   not implemented"

  type marshal = t
  (* marshal is not compatible with apron, therefore we don't have to implement it *)
  let marshal t = t
  let unmarshal t = t
  let relift t = t
end

module D2: RelationDomain.RD with type var = Var.t =
struct
  module D = D
  module ConvArg = struct
    let allow_global = false
  end
  include SharedFunctions.AssertionModule (D.V) (D) (ConvArg)
  include D
end
