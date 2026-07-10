module Mpqf = SharedFunctions.Mpqf
open Intervalsig
open OcplibSimplex
include Batteries

(** Variable type used by the subpolyhedra core. *)
module type Var = sig
  type t = int [@@deriving hash] (*Added int here so we don't need Var.to_int everywhere. This most likely won't change to another type.*)
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val string_of : t -> string
  val to_int : t -> int
  val to_t : int -> t
end

(** Simplex solver instantiation used by the LP-based reduction.
    LP variables are matrix column indices (>= 0) *)
module Simplex = struct
  (** The number type the solver computes with, for constraint coefficients, bounds and
      solution values alike. ocplib-simplex demands its own [Rationals] interface
      (extSigs.mli), which Mpqf almost satisfies: this adapter is mostly renames
      ([mult] = [mul], [minus] = [neg], [sign] = [sgn], ...) plus [floor]/[ceiling]/[is_int],
      which Mpqf lacks. With rationals we dont have the float imperciscion *)
  module LpRat = struct
    include Mpqf
    let m_one = mone
    let sign = sgn
    let is_zero x = equal x zero
    let is_one x = equal x one
    let is_m_one x = equal x m_one
    let mult = mul
    let minus = neg
    let min a b = if cmp a b <= 0 then a else b
    let is_int x = Z.equal (get_den x) Z.one
    let of_z z = of_mpz @@ Z_mlgmpidl.mpzf_of_z z
    let floor x = of_z @@ Z.fdiv (get_num x) (get_den x)
    let ceiling x = of_z @@ Z.cdiv (get_num x) (get_den x)
  end

  (** The solver's variable type: plain ints. Non-negative values are matrix column
      indices (program and slack columns); negative values are internal handles that
      name equality rows (see [assert_row]), so the two can never collide.
      [is_int = false] declares variables rational-valued: we solve over Q, not an
      integer LP. *)
  module LpVar = struct
    type t = int
    let compare = Int.compare
    let is_int _ = false
    let print fmt v = Format.fprintf fmt "v%d" v
  end

  (** "Explanations" are labels an SMT solver *)
  module LpEx = struct
    type t = unit
    let empty = ()
    let union () () = ()
    let print fmt () = Format.fprintf fmt "()"
  end

  (* [Basic.Make] wires the three parameter modules into the full solver and exposes:
     [Core]   solver state [Core.t], bounds, polys [Core.P] and the [result] type;
     [Assert] adding constraints ([Assert.var] bounds a variable, [Assert.poly] a linear form);
     [Solve]  running the algorithm ([Solve.solve] feasibility, [Solve.maximize] optimization);
     [Result] decoding a solved state into Sat/Unsat/Max/Unbounded. *)
  include Basic.Make (LpVar) (LpRat) (LpEx)
end

open Simplex


(** Internal representation of a consistent subpolyhedron. *)
module SubPoly (Var : Var) (I : IntervalSig with type bound = Mpqf.t) = struct
  (* Reuse the SparseVector and ListMatrix modules from the AffineEqualityDomain. *)
  include RatOps.ConvenienceOps (Mpqf)

  module Vector = SparseVector.SparseVector
  module CoeffVector = Vector(Mpqf)
  module Matrix =
    AffineEqualityDomain.AffineEqualityMatrix
      (Vector)
      (ListMatrix.ListMatrix) (*Question: do we actually use this, if we just use the Matrix and Vector implementations? *)
        (*QUESTION: Why don't we use the affineEqualityDenseDomain?*)
  (* Map keyed by variables. *)
  module VarMap = Map.Make(Var)
  module IntMap = Map.Make (Int)

  type affeq = Matrix.t [@@deriving eq, ord, hash] (*Our affine equality matrix.*)
  type interval_map = I.t VarMap.t [@@deriving eq, ord] (*Map from Var to Interval*)
  type info = CoeffVector.t [@@deriving eq, ord, hash] (*Coefficient vector over the matrix columns (constant in the last position)*)
  type info_map = info VarMap.t [@@deriving eq, ord] (*Map from Var to info*)

  let hash_interval_map (m: interval_map) =
    VarMap.fold (fun var interval acc ->
        Hashtbl.hash (Var.hash var, I.hash interval, acc)
      ) m 0

  let hash_slackintervals = hash_interval_map

  let hash_info_map (m: info_map) =
    VarMap.fold (fun var info acc ->
        Hashtbl.hash (Var.hash var, hash_info info, acc)
      ) m 0

  type t = {
    affeq: affeq; (*Affine Equalities stored as (sparse?) Matrix*)
    intervals: interval_map; (*Map of slack vars to intervals*)
    infos: info_map; (*Map of slack vars to info*)
  } [@@deriving eq, ord, hash]


  (* Everything here is TODO, it has AI generated placeholds so i could run the regtest *)

  let copy = Fun.id

  let empty () = { affeq = Matrix.empty (); intervals = VarMap.empty; infos = VarMap.empty }

  let is_empty (t: t) =
    Matrix.is_empty t.affeq && VarMap.is_empty t.intervals && VarMap.is_empty t.infos

  let set_info (var: Var.t) (info: info) (t : t)  =
    {t with infos = VarMap.add var info t.infos}

  let set_intv (var: Var.t) (intv: I.t) (t: t) = 
    {t with intervals = VarMap.add var intv t.intervals}
  let mem_info (var: Var.t) (t: t) = 
    VarMap.mem var t.infos

  let mem_intv (var: Var.t) (t: t) =
    VarMap.mem var t.intervals

  (**
  TODO: check if this is actually needed. Can a canonical info that is equal to another get a different length vector from dimension changes or other?
        Also check if the constant is currently in the info, i think it should not be there!
  *)
  let info_equal (a : info) (b : info) : bool = 
            let rec cmp_entries a_entries b_entries = 
          match a_entries, b_entries with 
          | (_, val1) :: r1, _ when val1 = Mpqf.zero -> cmp_entries r1 b_entries
          | _, (_, val2) :: r2 when val2 = Mpqf.zero -> cmp_entries a_entries r2
          | (idx1, val1) :: r1, (idx2, val2) :: r2 -> 
            idx1 = idx2 && Mpqf.equal val1 val2 && cmp_entries r1 r2
          | [], [] -> true
          | _ -> false 
        in
        cmp_entries (CoeffVector.to_sparse_list a) (CoeffVector.to_sparse_list b)
  
  (** Number of slack columns = size of the trailing slack block. Every slack has an
      interval *)
  let num_slacks (t: t) = VarMap.cardinal t.intervals


  let insert_slack (slack_col: int) (expr: info) (interval: I.t) (t: t) : t =
    let widen v = CoeffVector.insert_zero_at_indices v [(slack_col, 1)] 1 in
    let affeq = Matrix.add_empty_columns t.affeq [| slack_col |] in
    let expr  = widen expr in                                          (* slack col now 0, const shifted right *)
    let row   = CoeffVector.set_nth expr slack_col (Mpqf.neg Mpqf.one) in (* expr - slack = 0 *)
    let key   = Var.to_t slack_col in
    { affeq     = Matrix.append_row affeq row;
      infos     = VarMap.add key expr (VarMap.map widen t.infos);
      intervals = VarMap.add key interval t.intervals }

  let add_affeq_row (row: CoeffVector.t) (t: t) =
    { t with affeq = Matrix.append_row t.affeq row }
  

  (**[remove_columns dim t compact] is a helper for forget_vars and dim_remove that 
     forgets about a column and can compact it at the same tims.
      @param dim represents the dimensions that are forgotten
      @param t subpolyhedra
      @param compact determines if the forgotten columns should be compacted to fill the gaps,
        used for keeping the slack indices small and for dim_remove.
  *)
  let remove_columns (dim : int array) (t : t) (compact : bool) : t = 
    let shift_index_remove (old_index : Var.t) (dim_list : int list) : Var.t = 
      if compact then old_index - (List.count_matching (fun x -> x < old_index) dim_list) else old_index in
    let dim_list = List.sort_uniq Int.compare (Array.to_list dim) in 
    let dim_set = Set.of_list dim_list in
    let new_affeq = 
      (if compact then (flip Matrix.del_cols) (Array.of_list dim_list) else identity) 
      @@ Matrix.remove_zero_rows 
      @@ List.fold_left (fun acc var -> Matrix.reduce_col acc var) t.affeq dim_list 
    in
    let new_intervals = 
      VarMap.fold 
        (fun var intv acc -> 
           if Set.mem var dim_set 
           then acc 
           else VarMap.add (shift_index_remove var dim_list) intv acc ) t.intervals VarMap.empty 
    in
    let new_infos = 
      let keep info = List.for_all (fun idx -> CoeffVector.nth info idx =: Mpqf.zero) dim_list in
      VarMap.fold (fun var info acc ->
        if Set.mem var dim_set || not (keep info)
        then acc
        else 
          let info = if compact then CoeffVector.remove_at_indices info dim_list else info in
          VarMap.add (shift_index_remove var dim_list) info acc)
        t.infos VarMap.empty
    in
    {affeq = new_affeq; intervals = new_intervals; infos = new_infos}

    
  (**
    [forget_vars vars t] forgets a list of variables in the polyhedron.
    For slack variables it compacts the indices such that slack variables indices do not carry gaps.
    Future TODO: Currently we do Gaussian elimination with the variable as pivot ([Matrix.reduce_col]).
    This is fine for the affeq, but we do not want to blindly remove any slack variable info containing x
    from our info_map. Currently this happens, but refinement is needed in the future!
  *)
  let forget_vars (vars: Var.t list) (t: t) =
    let dim_array = Array.of_list vars in
    match List.partition (flip VarMap.mem t.intervals) vars with 
    | [], [] -> t
    | [], _ -> remove_columns dim_array t false
    | _, [] -> remove_columns dim_array t true
    | slack_vars, prog_vars -> remove_columns (Array.of_list prog_vars) (remove_columns (Array.of_list slack_vars) t true) false

  
  (**
  [forget_var var t] forgets a single variable using [forget_vars].
  *)
  let forget_var (var : Var.t) (t: t) : t = 
    let compact = VarMap.mem var t.intervals in
    remove_columns (Array.singleton var) t compact

  (**
  [dim_add] Apron dimension change
  *)
  
  let dim_add (ch: Apron.Dim.change) (t: t) = 
    let shift_index_add (old_index : Var.t) (occ_cols : (int * int) list) : Var.t = 
      (* find all entries that are less or equal to old_index in occ_cols, and count them (=k), then new_index = old_index + k , return new_index *)
      (let k = List.fold_left (fun acc (index, count) -> if index <= old_index then acc + count else acc) 0 occ_cols
       in let new_index = old_index + k 
       in Var.to_t new_index) in
    let new_infos_add (infos : info_map) occ_cols : info_map = 
      VarMap.fold(fun var info acc ->
          let new_var = shift_index_add var occ_cols in
          let new_info = CoeffVector.insert_zero_at_indices info occ_cols (Array.length ch.dim) in
          VarMap.add new_var new_info acc) infos VarMap.empty in
    let new_intervals_add (intervals : interval_map) occ_cols : interval_map = 
      VarMap.fold( fun var interval acc ->
          let new_var = shift_index_add var occ_cols in
          VarMap.add new_var interval acc) intervals VarMap.empty in
    let new_affeq = Matrix.dim_add ch t.affeq in
    let list = Array.to_list ch.dim in
    let grouped_indices = List.group Int.compare list in 
    let occ_cols = List.map (fun group -> 
      (List.hd group, List.length group)
      ) grouped_indices 
    in 
    (* Approach from listMatrix.ml: add_empty_columns; Example: cols_list = [1; 3; 3; 5] -> grouped_indices = [[1]; [3; 3]; [5]] -> occ_cols = [(1, 1); (3, 2); (5, 1)] *)
    let new_infos = new_infos_add t.infos occ_cols in 
    let new_intervals = new_intervals_add t.intervals occ_cols in
    {affeq = new_affeq; infos = new_infos; intervals = new_intervals}

  (**
  [dim_remove] Apron dimension change
  *)
  let dim_remove (ch : Apron.Dim.change) (t : t) = 
    remove_columns ch.dim t true

  let string_of_interval_map (m: interval_map) =
    VarMap.bindings m
    |> List.map (fun (var, interval) -> Var.string_of var ^ " -> " ^ I.show interval)
    |> String.concat "; "

  let string_of_infos (infos: info_map) = 
    VarMap.bindings infos
      |> List.map (fun (var, info) -> Var.string_of var ^ " -> " ^ CoeffVector.show info)
      |> String.concat "; "
  
  let string_of_interval (s: I.t) (i : info)=
    I.show s ^ "  (" ^ CoeffVector.show i ^ ")"

  let string_of (t: t) =
    "{ affeq = " ^ Matrix.show t.affeq
    ^ "; intervals = [" ^ string_of_interval_map t.intervals ^ "]"
    ^ "; slacks = [" ^ string_of_infos t.infos ^ "] }"
  

  (** Raised internally when the LP built from an abstract state is inconsistent, *)
  exception Infeasible

  (** A non-strict solver bound (we carry no explanations). *)
  let lp_bound (v: Mpqf.t) : Core.bound = { Core.bvalue = Core.R2.of_r v; explanation = () }

  (** [assert_row (env, i) row] asserts a matrix row [a_1*v_1 + ... + a_k*v_k + c = 0]
      as [sum in [-c, -c]] in the solver. Multi-variable rows are registered under the
      fresh negative handle [-(i+1)]. single-variable rows must use [Assert.var] instead
      ([Assert.poly] requires >= 2 variables). *)
  let assert_row ((env, i): Core.t * int) (row: CoeffVector.t) : Core.t * int =
    (* Get index of the constant term *)
    let const_idx = CoeffVector.length row - 1 in

    (* partition into coefficients cand consts *)
    let coeffs, consts = List.partition (fun (j, _) -> j <> const_idx) (CoeffVector.to_sparse_list row) in

    (* get the const from the row *)
    let c = match consts with [] -> Mpqf.zero | (_, c) :: _ -> c in

    match coeffs with
    | [] -> if c =: Mpqf.zero then (env, i) else raise Infeasible (* row reads 0 = c with c <> 0 *)
    | [(j, a)] ->
      (* We only have one coefficient (for some reason poly is 2 or more coefficients) 
      add degenerate interval to simplex *)
      let b = lp_bound (Mpqf.neg c /: a) in (* a*v_j + c = 0  <=>  v_j = -c/a *)
      (fst @@ Assert.var env ~min:b ~max:b j, i)
    | _ ->
      (* insert equation with equality *)
      let b = lp_bound (Mpqf.neg c) in
      (fst @@ Assert.poly env (Core.P.from_list coeffs) ~min:b ~max:b (-(i + 1)), i + 1)

  (** [assert_interval var intv env] asserts the finite bounds of [intv] on [var]. *)
  let assert_interval (var: Var.t) (intv: I.t) (env: Core.t) : Core.t =
    (* if interval has bounds, then insert *)
    match I.bounds intv with
    | None, None -> env
    | lower, upper -> fst @@ Assert.var env ?min:(Option.map lp_bound lower) ?max:(Option.map lp_bound upper) (Var.to_int var)

  (** [optimize env col coeff] is the optimum of [coeff * v_col]: [Some m] is the exact
      maximum, [None] means unbounded. A strict optimum [m - eps] is reported with value
      [m], which is still a sound bound. Raises [Infeasible] on an inconsistent system. *)
  let optimize (env: Core.t) (col: LpVar.t) (coeff: Mpqf.t) : Core.t * Mpqf.t option =
    let env, opt = Solve.maximize env (Core.P.from_list [(col, coeff)]) in
    match Result.get opt env with
    | Core.Max (mx, _) -> env, Some (Lazy.force mx).Core.max_v.Core.bvalue.Core.R2.v
    | Core.Unbounded _ -> env, None
    | Core.Unsat _ -> raise Infeasible
    | Core.Sat _ | Core.Unknown -> env, None (* no bound information: keep the old interval *)

  (** [refine_interval var intv (env, acc)] meets [intv] with the tightest bounds the
      solver can derive for [var] and adds the result to [acc]. *)
  let refine_interval (var: Var.t) (intv: I.t) ((env, acc): Core.t * interval_map) : Core.t * interval_map =
    (* get collumn to refine *)
    let col = Var.to_int var in

    (* optimze to get upper and lower *)
    let env, upper = optimize env col Mpqf.one in
    let env, neg_lower = optimize env col Mpqf.mone in

    (* revert negation trick *)
    let lower = Option.map Mpqf.neg neg_lower in

    (* meet with old interval to get the new bounds for the new interval *)
    match I.meet intv (I.of_bounds ~lower ~upper) with
    | None -> raise Infeasible
    | Some intv' -> (env, VarMap.add var intv' acc)

  (** [reduce t] is the LP-based redu
      after normalizing the matrix (rref), for every variable with an interval it computes, via simplex, 
      the tightest bounds implied by the affine equalities together with all other interval bounds, and meets
      them with the stored interval. 
      Returns [None] iff the constraint system is infeasible, i.e. the state is bottom.
        
      The algorithm is basically, Setup the simplex, make one run to make sure we are feasable,
      if feasable, complete run, update all intervals and return new domain. If infeasable, return none
    *)
  let reduce (t: t) : t option =
    try
      if Matrix.is_empty t.affeq then Some t (* no equalities: nothing to propagate *)
      else begin
        match Matrix.normalize t.affeq with
        | None -> None (* inconsistent equalities *)
        | Some mat ->
          (* T is now normalized matrix *)
          let t = { t with affeq = mat } in

          (* Make new simplex instance *)
          let env = Core.empty ~is_int:false ~check_invs:false in

          (* Add rows and intervals *)
          let env, _ = Matrix.fold_left assert_row (env, 0) t.affeq in
          let env = VarMap.fold assert_interval t.intervals env in

          (* Feasibility check up front: bottom must be detected even when [t.intervals] is
             empty and the refine fold below consequently never queries the solver. *)
          (match Result.get None (Solve.solve env) with
           | Core.Unsat _ -> raise Infeasible
           | _ -> ());

          (* Update the domain if we are feasable.*)
          let _, new_intervals = VarMap.fold refine_interval t.intervals (env, VarMap.empty) in
          Some { t with intervals = new_intervals }
      end
    with Infeasible -> None


  (**
     [slack_lce a b] takes two subpolyhedra [a] and [b] and maps the slack variables into a common environment based on the info field.
     - we assume that infos in the info map are canonicalized to check equality.
  *)
  let slack_lce a b = 
    (*[find_next_slack_idx (map_a, map_b)] finds the next free index in the shared slack variable space of a and b.*)
    let find_next_slack_idx (map_a, map_b) =
      if IntMap.is_empty map_a && IntMap.is_empty map_b 
      then match VarMap.min_binding_opt a.intervals, VarMap.min_binding_opt b.intervals with 
        | Some (ka, _), Some (kb, _) -> Int.min ka kb
        | Some (k, _), None | None, Some (k, _) -> k
        | None, None -> 0
      else let update_maximum_idx _ v m = max v m in (*find the smallest index that is available: *)
        (IntMap.fold update_maximum_idx map_b @@ IntMap.fold update_maximum_idx map_a 0) + 1
    in
    (*[get_mapping a b] finds a slack variable mapping from subpolyhedra a and b into a shared space. *)
    let get_mapping (a : t) (b : t) = 
      (**[find_key_on_info map info] searches a VarMap [map] for the first occurence of [info] and returns an [Option (key * value)] 
         - TODO: probably inefficient as we iterate through both maps entirely to find the maximum. *)
      let find_key_on_info map info = Seq.find (fun (_, v) -> info_equal v info) @@ VarMap.to_seq map in
      (*[process_a a b] iterates through a's slack vars and finds mappings into the shared space. All shared slacks are found here.*)
      let process_a a b : (int IntMap.t * int IntMap.t) = 
        VarMap.fold (fun var info ((a_map, b_map) as acc) ->
            let new_var = find_next_slack_idx acc in
            match find_key_on_info b.infos info with
            | None -> (IntMap.add var new_var a_map, b_map)
            | Some (k, v) -> (IntMap.add var new_var a_map, IntMap.add k new_var b_map)) 
          a.infos (IntMap.empty, IntMap.empty) 
      in
      (*[process_b b current_mappings] finds mappings for the slack vars of b not shared with a. Applied after [process_a]. *)
      let process_b b current_mappings = 
        VarMap.fold (fun var info ((a_map, b_map) as acc)-> 
            if IntMap.mem var b_map then acc else (a_map, IntMap.add var (find_next_slack_idx acc) b_map)) b.infos current_mappings in
      process_b b @@ process_a a b  (* end of get_mapping!*)
    in
    (* [remap_vector_sparse] maps a Coefficient vector based on the mapping provided. For elements in the vector 
       not present in the mapping, the index remains the same. The constant is then reinserted at the end if present.
    *)
    let remap_vector_sparse (vec : CoeffVector.t) (mapping : int IntMap.t) (len : int): CoeffVector.t = 
      (*TODO: take care of constant if it exists!*)
      let const = CoeffVector.nth vec ((CoeffVector.length vec) - 1) in
      let helper acc (v, c) = 
        let new_var = if IntMap.mem v mapping then IntMap.find v mapping else (if v = (CoeffVector.length vec) - 1 then len - 1 else v) in
        CoeffVector.set_nth acc new_var c in
      let res = List.fold_left helper (CoeffVector.of_sparse_list len []) (CoeffVector.to_sparse_list vec) in
      if const = Mpqf.zero then res else CoeffVector.set_nth res ((CoeffVector.length res) - 1) const 
    in
    (*[remap_slacks a mapping const_idx] remaps the slack variables of a subpolyhedra a using the mapping from [get_mapping a b]. *)
    let remap_slacks (a : t) (mapping : int IntMap.t) (len : int) : t =
      let new_infos =
        let helper (var : int) (info : CoeffVector.t) (acc : info VarMap.t) =
          let mapped_var = IntMap.find var mapping in
          let new_info = remap_vector_sparse info mapping len in
          VarMap.add mapped_var new_info acc in
        VarMap.fold helper a.infos VarMap.empty in
      let new_intervals =
        VarMap.fold (fun var intv acc -> VarMap.add (IntMap.find var mapping) intv acc) a.intervals VarMap.empty in
      let new_affeq  = Matrix.map (fun row -> remap_vector_sparse row mapping len) a.affeq in 
      {affeq = new_affeq; intervals = new_intervals; infos = new_infos} in
    (*Remove slacks that have no info because they cannot be kept in the join:*)
    let a_with_slacks_removed = forget_vars (VarMap.fold (fun var _ acc -> if not @@ VarMap.mem var a.infos then var :: acc else acc) a.intervals []) a in 
    let b_with_slacks_removed = forget_vars (VarMap.fold (fun var _ acc -> if not @@ VarMap.mem var b.infos then var :: acc else acc) b.intervals []) b in 
    let (a_mapping, b_mapping) = get_mapping a_with_slacks_removed b_with_slacks_removed in
    let len = (find_next_slack_idx (a_mapping, b_mapping)) + 1 in
    let a_remapped = remap_slacks a_with_slacks_removed a_mapping len in
    let b_remapped = remap_slacks b_with_slacks_removed b_mapping len in
    (a_remapped, b_remapped)

  (**
      [inject_slack_for_join (a, b)] 
      For every slack variable in {b b} but not in {b a} we insert:
      - {i info - slack_var} into  {b a.affeq}
      - {i slack_var -> info} into {b a.infos}
      - {i slack_var -> [None, None]} into {b a.intervals}

      Vice versa for slack variables in {b a} but not in {b b}.
      Prior to this [slack_lce] must be called so that a and b share the same indices for slacks.
  *)
  let inject_slack_for_join (a, b) = 
    let inject_slack var info x = 
      let new_intervals = VarMap.add var I.top x.intervals in
      let new_infos = VarMap.add var info x.infos in
      let new_affeq = Matrix.append_row x.affeq (CoeffVector.set_nth info var (Mpqf.of_int (-1))) in
      {affeq = new_affeq; infos = new_infos; intervals = new_intervals} in
    let new_a = VarMap.fold (fun var info acc -> if VarMap.mem var a.infos then acc else inject_slack var info acc ) b.infos a in
    let new_b = VarMap.fold (fun var info acc -> if VarMap.mem var b.infos then acc else inject_slack var info acc) a.infos b in
    (new_a, new_b)

  (**
  [interval_join a b] takes two interval_maps and joins them using [RationalInterval.join].
  QUESTION: How do we represent bottom in the interval domain? 
  *)
  let interval_join (a : interval_map) (b : interval_map) : interval_map = 
    VarMap.union (fun (key : Var.t) (v1 : I.t) (v2 : I.t) -> Some (I.join v1 v2)) a b
   
  (**[join a b] returns a subpolyhedra resulting from the join of two subpolyhedras a and b.
    We assume that the info fields of slack variables are canonical. 
    Slack variables with an interval bound but no info field are discarded, as they cannot be matched
    with slack variables from the other state.
  *)
  let join (a: t) (b: t) : t option =
    let (remapped_a, remapped_b) = inject_slack_for_join @@ slack_lce a b in
    let new_a = reduce remapped_a in
    let new_b = reduce remapped_b in
    match new_a, new_b with
    | None, None -> None
    | None, _ -> new_b
    | _, None -> new_a
    | Some x, Some y ->
    let new_intervals = interval_join x.intervals y.intervals in
    let new_affeq = Matrix.linear_disjunct x.affeq y.affeq in
    Some {affeq = new_affeq; intervals = new_intervals; infos = x.infos}

  (**
  [leq a b]
  TODO: Reduce here will be called for every program point because leq is called a lot! 
        Maybe keep a reduced version at all times!
  TODO: Matrix needs to be in rref!
  *)
  let leq (a: t) (b: t) =
    let collect_top_and_non_info (x : t) = 
      VarMap.fold (fun var intv acc -> 
          if (not @@ VarMap.mem var x.infos) || I.is_top intv 
          then var :: acc 
          else acc ) x.intervals []
    in
    match Matrix.normalize a.affeq, Matrix.normalize b.affeq with 
    | None, _ -> true
    | _, None -> false
    | Some a_affeq, Some b_affeq ->
    let processed_a = forget_vars (collect_top_and_non_info {a with affeq = a_affeq}) {a with affeq = a_affeq} in
    let processed_b = forget_vars (collect_top_and_non_info {b with affeq = b_affeq}) {b with affeq = b_affeq} in
    let (a_common, b_common) = slack_lce processed_a processed_b in
    VarMap.equal (fun v1 v2 -> info_equal v1 v2) a_common.infos b_common.infos (*does CoeffVector.equal derive the correct equality?*)
    && VarMap.for_all (fun k v -> I.leq v (VarMap.find k b_common.intervals)) a_common.intervals
    && Matrix.is_covered_by b_common.affeq a_common.affeq
    
  (** [meet a b] returns a subpolyhedra resulting from the meet of two subpolyhedras a and b.
      We assume that the info fields of slack variables are canonical. 
      Slack variables with an interval bound but no info field are discarded, as they cannot be matched
      with slack variables from the other state.
  *)

  (** [interval_meet a b] returns the meet of two interval maps. 
  In case some of the intervals are disjoint, it returns None, indicating that the meet is bottom.
   *)
  let interval_meet (a : interval_map) (b : interval_map) : interval_map option = 
    let exception Bot in
    try
      Some (VarMap.union (
        fun (key : Var.t) (v1 : I.t) (v2 : I.t) -> (match I.meet v1 v2 with
            | None -> raise Bot
            | Some i -> Some i)
        ) a b)
    with Bot -> None
   
  let meet (a: t) (b: t) = 
    let (new_a, new_b) = slack_lce a b in
    match reduce new_a, reduce new_b with 
    | None, None -> None
    | None, _ -> None
    | _, None -> None
    | Some x, Some y ->
      match interval_meet x.intervals y.intervals with
      | None -> None
      | Some new_intervals -> 
        match Matrix.rref_matrix x.affeq y.affeq with (* Matrix ist dann in der richtigen Form *)
        | None -> None
        | Some new_affeq -> 
          let new_infos = VarMap.union (fun _ i1 i2 -> if info_equal i1 i2 then Some i1 else failwith "inconsistent slack mapping") x.infos y.infos in
          Some {affeq = new_affeq; intervals = new_intervals; infos = new_infos}


  let widen = join
  let narrow = meet
  let unify = meet

  let _ = Var.string_of (* silence unused-functor-arg warning until Var is actually used *)
end
