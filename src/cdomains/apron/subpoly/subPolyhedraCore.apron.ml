module Rat = SubRat.Rat
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
      (extSigs.mli), which Rat (zarith's [Q]) almost satisfies: this adapter is mostly
      renames ([mult] = [mul], [minus] = [neg], ...) plus [floor]/[ceiling]/[is_int].
      With rationals we dont have the float imperciscion *)
  module LpRat = struct
    include Rat
    let m_one = mone
    let is_zero x = equal x zero
    let is_one x = equal x one
    let is_m_one x = equal x m_one
    let mult = mul
    let minus = neg
    (* [min] comes from [include Rat] (zarith provides it) *)
    let is_int x = Z.equal (get_den x) Z.one
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
module SubPoly (Var : Var) (I : IntervalSig with type bound = Rat.t) = struct
  (* Reuse the SparseVector and ListMatrix modules from the AffineEqualityDomain. *)
  include RatOps.ConvenienceOps (Rat)

  module Vector = SparseVector.SparseVector
  module CoeffVector = Vector(Rat)
  (* Own instantiation instead of AffineEqualityDomain.AffineEqualityMatrix: that one
     hardcodes Mpqf as the number type, we compute over zarith's Q. *)
  module Matrix = struct
    include ListMatrix.ListMatrix (Rat) (Vector)
    let dim_add (ch: Apron.Dim.change) m =
      add_empty_columns m ch.dim
  end
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
    var_intervals: interval_map; (*Bounds on program-variable columns (from single-variable
                                   constraints like type bounds). Unlike [intervals] these
                                   never occupy a slack column, so they do not count towards
                                   [num_slacks] or the matrix width. Missing key = unbounded.*)
    reduced: bool; (*Cache flag: [reduce] already ran on exactly this state, so running it
                     again is a no-op. Ignored by [equal]/[compare]/[hash]; every mutation
                     must reset it to false.*)
  }

  (* [reduced] is a cache flag, not part of the abstract value: two states that differ
     only in it are the same lattice element, so equal/compare/hash must ignore it. *)
  let equal (a: t) (b: t) =
    equal_affeq a.affeq b.affeq
    && equal_interval_map a.intervals b.intervals
    && equal_info_map a.infos b.infos
    && equal_interval_map a.var_intervals b.var_intervals

  let compare (a: t) (b: t) =
    let c = compare_affeq a.affeq b.affeq in if c <> 0 then c else
    let c = compare_interval_map a.intervals b.intervals in if c <> 0 then c else
    let c = compare_info_map a.infos b.infos in if c <> 0 then c else
    compare_interval_map a.var_intervals b.var_intervals

  let hash (t: t) =
    Hashtbl.hash (hash_affeq t.affeq, hash_interval_map t.intervals,
                  hash_info_map t.infos, hash_interval_map t.var_intervals)


  (* Everything here is TODO, it has AI generated placeholds so i could run the regtest *)

  let copy = Fun.id

  let empty () = { affeq = Matrix.empty (); intervals = VarMap.empty; infos = VarMap.empty;
                   var_intervals = VarMap.empty; reduced = true }

  let is_empty (t: t) =
    Matrix.is_empty t.affeq && VarMap.is_empty t.intervals && VarMap.is_empty t.infos
    && VarMap.is_empty t.var_intervals

  let set_info (var: Var.t) (info: info) (t : t)  =
    {t with infos = VarMap.add var info t.infos; reduced = false}

  let set_intv (var: Var.t) (intv: I.t) (t: t) =
    {t with intervals = VarMap.add var intv t.intervals; reduced = false}

  (** [set_var_intv var intv t] sets the direct interval bound of the program-variable
      column [var] (see [var_intervals]). *)
  let set_var_intv (var: Var.t) (intv: I.t) (t: t) =
    {t with var_intervals = VarMap.add var intv t.var_intervals; reduced = false}

  let get_var_intv (var: Var.t) (t: t) = VarMap.find_opt var t.var_intervals
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
          | (_, val1) :: r1, _ when val1 = Rat.zero -> cmp_entries r1 b_entries
          | _, (_, val2) :: r2 when val2 = Rat.zero -> cmp_entries a_entries r2
          | (idx1, val1) :: r1, (idx2, val2) :: r2 -> 
            idx1 = idx2 && Rat.equal val1 val2 && cmp_entries r1 r2
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
    let row   = CoeffVector.set_nth expr slack_col (Rat.neg Rat.one) in (* expr - slack = 0 *)
    let key   = Var.to_t slack_col in
    { affeq     = Matrix.append_row affeq row;
      infos     = VarMap.add key expr (VarMap.map widen t.infos);
      intervals = VarMap.add key interval t.intervals;
      var_intervals = t.var_intervals; (* program columns are unaffected by a new slack column *)
      reduced   = false }

  let add_affeq_row (row: CoeffVector.t) (t: t) =
    { t with affeq = Matrix.append_row t.affeq row; reduced = false }
  

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
    let remove_and_shift_keys (m: interval_map) =
      VarMap.fold
        (fun var intv acc ->
           if Set.mem var dim_set
           then acc
           else VarMap.add (shift_index_remove var dim_list) intv acc ) m VarMap.empty
    in
    let new_intervals = remove_and_shift_keys t.intervals in
    let new_var_intervals = remove_and_shift_keys t.var_intervals in
    let new_infos =
      let keep info = List.for_all (fun idx -> CoeffVector.nth info idx =: Rat.zero) dim_list in
      VarMap.fold (fun var info acc ->
        if Set.mem var dim_set || not (keep info)
        then acc
        else
          let info = if compact then CoeffVector.remove_at_indices info dim_list else info in
          VarMap.add (shift_index_remove var dim_list) info acc)
        t.infos VarMap.empty
    in
    {affeq = new_affeq; intervals = new_intervals; infos = new_infos;
     var_intervals = new_var_intervals; reduced = false}

  (* ---- Canonicalization of infos (moved here from the domain so it can be reused
          by reclamation in forget_vars and, later, by Step 3 of join/widen). ---- *)

  let rat_of_z = Rat.of_z

  (** [gcd_list v] gcd of all stored (non-zero) coefficient numerators. *)
  let gcd_list (v: info) : Z.t =
    let gcd =
      CoeffVector.to_sparse_list v
      |> List.fold_left (fun acc (_, c) -> Z.gcd acc (Rat.get_num c)) Z.zero
    in
    (* an all-zero vector has gcd 0, so fall back to 1 to make dividing a no-op *)
    if Z.equal gcd Z.zero then Z.one else gcd

  (** [lcm_den_list v] lcm of the denominators of every stored coefficient. *)
  let lcm_den_list (v: info) : Z.t =
    CoeffVector.to_sparse_list v
    |> List.fold_left (fun acc (_, c) -> Z.lcm acc (Rat.get_den c)) Z.one

  (** [normalize_info v] returns [(v / factor, factor)] where [factor = sign * gcd / lcm]:
      it clears the common content and denominators and flips the sign so the leading
      (lowest-index) coefficient is positive. *)
  let normalize_info (v: info) : info * Rat.t =
    let gcd = gcd_list v in
    let lcm = lcm_den_list v in
    let sign = match CoeffVector.find_first_non_zero v with
      | Some (_, leading) when leading <: Rat.zero -> Rat.mone
      | _ -> Rat.one
    in
    let factor = sign *: rat_of_z gcd /: rat_of_z lcm in
    CoeffVector.map_f_preserves_zero (fun c -> c /: factor) v, factor

  let negate v = CoeffVector.map_f_preserves_zero Rat.neg v

  (** [recover_def_from_non_info_intv var t] searches the matrix for a row in which [var]
      occurs with a non-zero coefficient and every other non-zero entry is a program
      variable (or the constant) - i.e. no other slack appears. Such a row proves
      [var = linear form over program variables (+ constant)]; that linear form (with the
      constant kept) is returned as [Some]. Returns [None] when no such row exists. *)
  let recover_def_from_non_info_intv (var : int) (subpoly : t) : info option =
    let only_prog_vars v  = List.for_all (fun (idx, _) -> (not @@ (VarMap.mem idx subpoly.intervals)) || (idx = var)) (CoeffVector.to_sparse_list v) in
    match Matrix.find_opt (fun vec -> ((CoeffVector.nth vec var) <>: Rat.zero) && only_prog_vars vec) subpoly.affeq with
    | None -> None
    | Some vec ->
      let coeff = CoeffVector.nth vec var in
      Some (CoeffVector.map (fun (i, c) -> (i, Rat.neg (c /: coeff))) (CoeffVector.set_nth vec var Rat.zero))

  (** [canonicalize_slack slack raw_def t] rescales the existing slack column [slack] so
      that the slack variable becomes equal to the canonical (gcd/lcm/sign-normalized,
      constant-free) form of [raw_def]. [raw_def] must be a linear form over program
      variables (possibly with a constant) that the matrix already proves equal to the
      slack. Returns the adapted state together with the canonical [info] that was stored.

      Let [normalized = raw_def / factor] and [const] its constant part (both from
      [normalize_info]); the canonical info is [normalized] with the constant stripped,
      hence the new slack value is [slack_new = slack_old / factor - const], i.e.
      [slack_old = factor * slack_new + factor * const]. We apply exactly this invertible
      change of variable:
      - every matrix row scales [slack]'s coefficient by [factor] and adds
        [coeff * factor * const] to its constant term;
      - the slack's interval is transformed the same way [add_slack_constraint] does:
        [add_const (-const) (scale (1/factor) iv)];
      - [info] is stored as the slack's canonical definition.

      This is the reusable primitive intended for Step 3 of join/widen as well. *)
  let canonicalize_slack (slack : int) (raw_def : info) (t : t) : t * info =
    let normalized, factor = normalize_info raw_def in
    let const_idx = CoeffVector.length normalized - 1 in
    let const = CoeffVector.nth normalized const_idx in
    let info = CoeffVector.set_nth normalized const_idx Rat.zero in
    let adapt_row row =
      let c = CoeffVector.nth row slack in
      if c =: Rat.zero then row
      else
        let row = CoeffVector.set_nth row slack (c *: factor) in
        let cidx = CoeffVector.length row - 1 in
        CoeffVector.set_nth row cidx (CoeffVector.nth row cidx +: c *: factor *: const)
    in
    let new_affeq = Matrix.map adapt_row t.affeq in
    let old_iv = VarMap.find slack t.intervals in
    let new_iv = I.add_const (Rat.neg const) (I.scale (Rat.one /: factor) old_iv) in
    ({ t with affeq = new_affeq;
       intervals = VarMap.add slack new_iv t.intervals;
       infos = VarMap.add slack info t.infos;
       reduced = false },
     info)

  (** [reclaim_slack slack t] tries to give the info-less slack [slack] a canonical info
      recovered from the matrix. On success returns the canonicalized state and the stored
      [info]; returns [None] when no definition over program variables is derivable (or the
      only derivable definition is a bare constant, which carries no relational info). *)
  let reclaim_slack (slack : int) (t : t) : (t * info) option =
    match recover_def_from_non_info_intv slack t with
    | None -> None
    | Some raw_def ->
      let const_idx = CoeffVector.length raw_def - 1 in
      let has_prog_term = List.exists (fun (i, c) -> i <> const_idx && c <>: Rat.zero) (CoeffVector.to_sparse_list raw_def) in
      if not has_prog_term then None
      else Some (canonicalize_slack slack raw_def t)

  (** [reclaim_slacks t] attempts to re-derive a canonical info for every slack that has
      an interval but no info (as happens after [remove_columns] drops infos mentioning a
      forgotten program variable). Each such slack whose value is still provable from the
      matrix regains an info. *)
  let reclaim_slacks (t : t) : t =
    VarMap.fold (fun slack _ acc ->
        if VarMap.mem slack acc.infos then acc
        else
          match reclaim_slack slack acc with
          | None -> acc
          | Some (acc, info) ->
            (* [acc] now has [slack] canonicalized to [info] (matrix column rescaled,
               interval scaled to match). Reclamation can make [slack] provably equal to
               another slack that already carries this canonical info. *)
            let existing =
              Seq.find (fun (k, i) -> k <> slack && info_equal i info)
                (VarMap.to_seq acc.infos)
            in
            (match existing with
             | None -> acc
             | Some (k, _) ->
               (* DEDUP (removable): keep the info map injective by folding [slack] into
                  the existing slack [k]. Both now equal [info], so we meet [slack]'s
                  (canonically-scaled) interval into [k] and strip [slack]'s info, leaving
                  it as an info-less orphan that [slack_lce] discards later. We deliberately
                  do NOT remove [slack]'s column: that would shrink the matrix width and
                  shift the constant index, breaking callers (e.g. [add_equation]) that hold
                  a coeff vector computed at the old width. This arm is the only place
                  duplicate-info merging happens for reclamation; if duplicate infos ever
                  become acceptable, delete it. *)
               let merged = match I.meet (VarMap.find k acc.intervals) (VarMap.find slack acc.intervals) with
                 | Some m -> m
                 | None -> VarMap.find k acc.intervals (* disjoint (already bottom): keep k's interval *)
               in
               { acc with intervals = VarMap.add k merged acc.intervals;
                          infos = VarMap.remove slack acc.infos }))
      t.intervals t

  (**
    [forget_vars vars t] forgets a list of variables in the polyhedron.
    For slack variables it compacts the indices such that slack variables indices do not carry gaps.
    [remove_columns] does Gaussian elimination with each forgotten program variable as pivot
    ([Matrix.reduce_col]) and drops any slack info that mentions a forgotten variable. Those
    slacks become info-less orphans; [reclaim_slacks] then tries to re-derive a canonical
    info for each from a matrix row that still proves it over the remaining variables.
  *)
  let forget_vars (vars: Var.t list) (t: t) =
    let dim_array = Array.of_list vars in
    match List.partition (flip VarMap.mem t.intervals) vars with
    | [], [] -> t
    (* forgetting program variables drops the infos mentioning them (see [remove_columns]),
       so we try to reclaim a canonical info for the resulting info-less slacks. Forgetting
       only slacks creates no info-less slacks, hence no reclamation there. *)
    | [], _ -> reclaim_slacks (remove_columns dim_array t false)
    | _, [] -> remove_columns dim_array t true
    | slack_vars, prog_vars -> reclaim_slacks (remove_columns (Array.of_list prog_vars) (remove_columns (Array.of_list slack_vars) t true) false)

  
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
    let new_var_intervals = new_intervals_add t.var_intervals occ_cols in
    {affeq = new_affeq; infos = new_infos; intervals = new_intervals;
     var_intervals = new_var_intervals; reduced = false}

  (**
  [dim_remove] Apron dimension change
  *)
  let dim_remove (ch : Apron.Dim.change) (t : t) = 
    remove_columns ch.dim t true

  let string_of_interval_map (m: interval_map) =
  VarMap.bindings m
  |> List.map (fun (var, interval) ->
      Printf.sprintf "%s -> %s" (Var.string_of var) (I.show interval))
  |> String.concat ";\n    " 

let string_of_infos (infos: info_map) = 
  VarMap.bindings infos
  |> List.map (fun (var, info) ->
      Printf.sprintf "%s -> %s" (Var.string_of var) (CoeffVector.show info))
  |> String.concat ";\n    "

let string_of (t: t) =
  Printf.sprintf
    "{\n  affeq =\n    %s;\n  intervals =\n    [\n    %s\n    ];\n  slacks =\n    [\n    %s\n    ];\n  var_intervals =\n    [\n    %s\n    ]\n}"
    (Matrix.show t.affeq)
    (string_of_interval_map t.intervals)
    (string_of_infos t.infos)
    (string_of_interval_map t.var_intervals)
  

  (** Raised internally when the LP built from an abstract state is inconsistent, *)
  exception Infeasible

  (** A non-strict solver bound (we carry no explanations). *)
  let lp_bound (v: Rat.t) : Core.bound = { Core.bvalue = Core.R2.of_r v; explanation = () }

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
    let c = match consts with [] -> Rat.zero | (_, c) :: _ -> c in

    match coeffs with
    | [] -> if c =: Rat.zero then (env, i) else raise Infeasible (* row reads 0 = c with c <> 0 *)
    | [(j, a)] ->
      (* We only have one coefficient (for some reason poly is 2 or more coefficients) 
      add degenerate interval to simplex *)
      let b = lp_bound (Rat.neg c /: a) in (* a*v_j + c = 0  <=>  v_j = -c/a *)
      (fst @@ Assert.var env ~min:b ~max:b j, i)
    | _ ->
      (* insert equation with equality *)
      let b = lp_bound (Rat.neg c) in
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
  let optimize (env: Core.t) (terms : (int * Rat.t) list) : Core.t * Rat.t option =
    let env, opt = Solve.maximize env (Core.P.from_list terms) in
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
    let env, upper = optimize env [(col, Rat.one)] in
    let env, neg_lower = optimize env [(col, Rat.mone)] in
    (* revert negation trick *)
    let lower = Option.map Rat.neg neg_lower in
    (* meet with old interval to get the new bounds for the new interval *)
    match I.meet intv (I.of_bounds ~lower ~upper) with
    | None -> raise Infeasible
    | Some intv' -> (env, VarMap.add var intv' acc)

  let lp_of (t : t) : Core.t option =
    try
      let env = Core.empty ~is_int:false ~check_invs:false in

      (* Add rows and intervals *)
      let env, _ = Matrix.fold_left assert_row (env, 0) t.affeq in
      let env = VarMap.fold assert_interval t.intervals env in
      let env = VarMap.fold assert_interval t.var_intervals env in

      (* Feasibility check up front: bottom must be detected even when [t.intervals] is
         empty and the refine fold below consequently never queries the solver. *)
      match Result.get None (Solve.solve env) with
      | Core.Unsat _ -> None
      | _ -> Some env
    with Infeasible -> None

  (** [reduce t] is the LP-based redu
      after normalizing the matrix (rref), for every variable with an interval it computes, via simplex, 
      the tightest bounds implied by the affine equalities together with all other interval bounds, and meets
      them with the stored interval. 
      Returns [None] iff the constraint system is infeasible, i.e. the state is bottom.
        
      The algorithm is basically, Setup the simplex, make one run to make sure we are feasable,
      if feasable, complete run, update all intervals and return new domain. If infeasable, return none
    *)
  (** How much work [reduce] should do. All modes detect bottom; they differ in which
      stored intervals get tightened afterwards. *)
  type reduce_mode =
    | Refine_all                (** tighten every stored interval: the full reduction *)
    | Feasibility_only          (** only detect bottom, leave all intervals as stored *)
    | Refine_cols of Var.t list (** tighten just the given columns (e.g. a query's temporary slack) *)

  let reduce ?(mode=Refine_all) (t: t) : t option =
    (* a reduced state is feasible and has tightest intervals: any mode is a no-op *)
    if t.reduced then Some t
    else
    try
      if Matrix.is_empty t.affeq then Some { t with reduced = true }
      (* no equalities: intervals are independent bounds, nothing to propagate *)
      else begin
        match Matrix.normalize t.affeq with
        | None -> None (* inconsistent equalities *)
        | Some mat ->
          (* T is now normalized matrix *)
          let t = { t with affeq = mat } in
          match lp_of t with
          | None -> None
          | Some env ->
          (* We are feasible: refine according to the requested mode. *)
          match mode with
          | Feasibility_only -> Some t (* intervals untouched, so the state stays unreduced *)
          | Refine_cols cols ->
            let refine_one (env, t) col =
              match VarMap.find_opt col t.intervals with
              | Some intv ->
                let env, m = refine_interval col intv (env, VarMap.empty) in
                (env, { t with intervals = VarMap.add col (VarMap.find col m) t.intervals })
              | None ->
                match VarMap.find_opt col t.var_intervals with
                | Some intv ->
                  let env, m = refine_interval col intv (env, VarMap.empty) in
                  (env, { t with var_intervals = VarMap.add col (VarMap.find col m) t.var_intervals })
                | None -> (env, t)
            in
            let (_, t) = List.fold_left refine_one (env, t) cols in
            Some t
          | Refine_all ->
            let env, new_intervals = VarMap.fold refine_interval t.intervals (env, VarMap.empty) in
            let _, new_var_intervals = VarMap.fold refine_interval t.var_intervals (env, VarMap.empty) in
            Some { t with intervals = new_intervals; var_intervals = new_var_intervals; reduced = true }
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
        | None, None -> (max 1 (max (Matrix.num_cols a.affeq) (Matrix.num_cols b.affeq))) - 1
           (* - 1 because we add + 1 for the length calc later in this case, max because one matrix might not have rows.
              The inner max with 1 guards the zero-slack case where BOTH matrices are empty:
              num_cols is then 0 and the resulting index -1 / vector length 0 corrupts every
              remapped vector. With the guard the length is at least 1 (the constant slot). *)
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
      if const = Rat.zero then res else CoeffVector.set_nth res ((CoeffVector.length res) - 1) const 
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
      (* var_intervals live on program columns, which the slack remapping never moves *)
      {affeq = new_affeq; intervals = new_intervals; infos = new_infos;
       var_intervals = a.var_intervals; reduced = false} in
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
      let new_affeq = Matrix.append_row x.affeq (CoeffVector.set_nth info var (Rat.of_int (-1))) in
      {affeq = new_affeq; infos = new_infos; intervals = new_intervals;
       var_intervals = x.var_intervals; reduced = false} in
    let new_a = VarMap.fold (fun var info acc -> if VarMap.mem var a.infos then acc else inject_slack var info acc ) b.infos a in
    let new_b = VarMap.fold (fun var info acc -> if VarMap.mem var b.infos then acc else inject_slack var info acc) a.infos b in
    (new_a, new_b)

  let inject_slack_for_widen (a, b) =
    let inject_slack var info x =
      let new_intervals = VarMap.add var I.top x.intervals in
      let new_infos = VarMap.add var info x.infos in
      let new_affeq = Matrix.append_row x.affeq (CoeffVector.set_nth info var (Rat.of_int (-1))) in
      {affeq = new_affeq; infos = new_infos; intervals = new_intervals;
       var_intervals = x.var_intervals; reduced = false} in
    (*let new_a = VarMap.fold (fun var info acc -> if VarMap.mem var a.infos then acc else inject_slack var info acc ) b.infos a in*)
    let new_b = VarMap.fold (fun var info acc -> if VarMap.mem var b.infos then acc else inject_slack var info acc) a.infos b in
    (a, new_b)

  (**
  [interval_join a b] takes two interval_maps and joins them using [RationalInterval.join].
  QUESTION: How do we represent bottom in the interval domain? 
  *)
  let interval_join (a : interval_map) (b : interval_map) : interval_map =
    VarMap.union (fun (key : Var.t) (v1 : I.t) (v2 : I.t) -> Some (I.join v1 v2)) a b

  (** Join of the program-variable bounds: unlike the slack intervals there is no
      injection step making the key sets equal, so a key missing on either side means
      unbounded there and the joined bound must be dropped. *)
  let var_interval_join (a : interval_map) (b : interval_map) : interval_map =
    VarMap.merge (fun _ v1 v2 ->
        match v1, v2 with
        | Some v1', Some v2' -> Some (I.join v1' v2')
        | None, _ | _, None -> None) a b
  
  (**
  [interval_widen a b] takes two interval_maps and widens them using [RationalInterval.widen].
  QUESTION: How do we represent bottom in the interval domain? 
  *)
  let interval_widen (a : interval_map) (b : interval_map) : interval_map = 
    VarMap.merge (fun (key : Var.t) (v1 : I.t option) (v2 : I.t option) -> 
      match v1, v2 with 
      | None, _ | _, None -> None
      | Some v1', Some v2' -> Some (I.widen v1' v2')) a b
   
  (* ---- Step 3 of join/widen (Algorithm 1/2 in the paper): recover inequalities that
          the pairwise LinEq join dropped. For an affine equality kappa that held in an
          operand but is not implied by the joined matrix, its program-variable part
          s_kappa is a linear form whose value in the joined state is bounded by
          [s_kappa](x) `combine` [s_kappa](y): in the operand where kappa holds s_kappa is
          pinned to a point, in the other it is whatever that operand bounds it to. Adding
          that bound as a canonicalized slack never drops a concrete state of either
          operand (so it is sound for the join) and recovers precision lost by the convex
          step. ---- *)

  (** [eval_linform env s] is the interval the program-variable linear form [s]
      (carrying no constant term) can take in the reduced operand whose LP is [env].
      Threads the solver environment like [refine_interval] does, so consecutive
      calls reuse the pivoted tableau instead of restarting the simplex. *)
  let eval_linform (env : Core.t) (s : info) : Core.t * I.t =
    match CoeffVector.to_sparse_list s with
    | [] -> env, I.top
    | terms ->
      let env, upper = optimize env terms in
      let env, neg_lower = optimize env (List.map (fun (i, c) -> (i, Rat.neg c)) terms) in
      env, I.of_bounds ~lower:(Option.map Rat.neg neg_lower) ~upper

  (** [s_kappa t row] is the program-variable linear form [s_kappa] equivalent to the
      equality [row]: the constant is dropped and every slack column [beta] is replaced by
      its info [info(beta)] (a program-variable linear form for which [beta = info(beta)]
      holds in the matrix). Substituting - rather than merely dropping - slacks is what lets
      us recover relations that are only visible through slack aliases (e.g. [x - beta = 0]
      with [info(beta) = y] yields [x - y]). A slack without info cannot be substituted and
      is dropped (such orphans have already been removed before join/widen). *)
  let s_kappa (t : t) (row : info) : info =
    let const_idx = CoeffVector.length row - 1 in
    List.fold_left (fun acc (idx, c) ->
        if idx = const_idx then acc
        else match VarMap.find_opt idx t.infos with
          | Some info -> CoeffVector.map2_f_preserves_zero (fun a b -> a +: c *: b) acc info
          | None -> if VarMap.mem idx t.intervals then acc (* info-less slack: cannot substitute *)
            else CoeffVector.set_nth acc idx c)
      (CoeffVector.zero_vec (CoeffVector.length row)) (CoeffVector.to_sparse_list row)

  (** [add_recovered_slack ~on_existing ~slack_col linform iv t] asserts the recovered
      bound [linform in iv] into [t] by giving [linform] a canonical slack (inserted at
      column [slack_col] = current state width - 1), folding into an existing slack of
      equal canonical info when possible (keeping the info map injective). [on_existing cur
      iv'] decides the interval to keep when such a slack already exists: [I.meet] for join
      (tighten), but for widen we must keep [cur] so the result stays above the old operand
      ([old <= widen old new]). Returns the new state and [true] iff a fresh slack column
      was added (so callers can track the width). [linform] must be at the state's current
      width and carry no constant. *)
  let add_recovered_slack ~(on_existing : I.t -> I.t -> I.t option) ~(slack_col : int) (linform : info) (iv : I.t) (t : t) : t * bool =
    let info, factor = normalize_info linform in
    let iv' = I.scale (Rat.one /: factor) iv in
    match Seq.find (fun (_, i) -> info_equal i info) (VarMap.to_seq t.infos) with
    | Some (k, _) ->
      ((match on_existing (VarMap.find k t.intervals) iv' with
        | Some m -> { t with intervals = VarMap.add k m t.intervals; reduced = false }
        | None -> t), false)
    | None ->
      (insert_slack slack_col info iv' t, true)

  (** [implied joined_rref row] is [true] iff the equality [row] is in the row space of
      [joined_rref] (which must be a leading-1, pivot-ascending rref): reduce [row] against
      the rref in one pass and check it vanishes. (We cannot use [Matrix.is_covered_by]
      here: it loops when [row] has a pivot column that no rref row leads with - exactly the
      dropped rows we look for.) *)
  let implied (joined_rref : Matrix.t) (row : info) : bool =
    let reduced =
      Matrix.fold_left (fun v pivot_row ->
          match CoeffVector.find_first_non_zero pivot_row with
          | None -> v
          | Some (pivot_col, _) -> (* rref: pivot coefficient is 1 *)
            let c = CoeffVector.nth v pivot_col in
            if c =: Rat.zero then v
            else CoeffVector.map2_f_preserves_zero (fun a b -> a -: c *: b) v pivot_row)
        row joined_rref
    in
    CoeffVector.is_zero_vec reduced

  (** [interval_eval vmap s] bounds the linear form [s] by interval arithmetic over the
      per-column bounds in [vmap] (missing key = unbounded). Cheap redundancy check for
      recovered bounds: a bound the joined state's own column intervals already imply
      adds no information, only a slack (plus matrix row) that every later [reduce]
      would keep paying for. *)
  let interval_eval (vmap : interval_map) (s : info) : I.t =
    let add a b = match a, b with Some a, Some b -> Some (a +: b) | _ -> None in
    List.fold_left (fun acc (col, c) ->
        let ci = match VarMap.find_opt col vmap with
          | None -> I.top
          | Some vi -> I.scale c vi
        in
        let (l1, u1) = I.bounds acc and (l2, u2) = I.bounds ci in
        I.of_bounds ~lower:(add l1 l2) ~upper:(add u1 u2))
      (I.of_bounds ~lower:(Some Rat.zero) ~upper:(Some Rat.zero))
      (CoeffVector.to_sparse_list s)

  (** [recover_step3 ~combine ~on_existing ~sources x y joined] adds the recovered
      inequalities to the pairwise-joined state [joined]. [sources] are the operands whose
      dropped equalities are scanned ([[x; y]] for join, [[x]] for widen); [combine] merges
      the two operand valuations of each [s_kappa] ([I.join] for join, [I.widen] for widen);
      [on_existing] decides how a recovered bound folds into an already-present slack of
      equal info. [x], [y] and [joined] must still share the same column layout, so this
      runs before any compaction. *)
  let recover_step3 ~(combine : I.t -> I.t -> I.t) ~(on_existing : I.t -> I.t -> I.t option) ~(sources : t list) (x : t) (y : t) (joined : t) : t =
    match Matrix.normalize joined.affeq with
    | None -> joined
    | Some joined_rref ->
      (* Candidate dropped equalities, collected without touching the LP: rows not
         implied by the joined matrix whose program-variable form is non-trivial. On
         the fixpoint's hot path (re-joining states that already agree) this list is
         empty and no simplex environment is ever built. *)
      let candidates =
        List.fold_left (fun acc src ->
            Matrix.fold_left (fun acc row ->
                if implied joined_rref row then acc
                else
                  let s = s_kappa joined row in
                  if CoeffVector.is_zero_vec s then acc else s :: acc)
              acc src.affeq)
          [] sources
      in
      if List.is_empty candidates then joined
      else begin
        (* Each operand's LP is built on first use only and the environment returned by
           the solver is threaded through later calls (the same incremental pattern as
           [reduce]'s refine fold). *)
        let cache_x = ref None and cache_y = ref None in
        let eval cache (src : t) (s : info) : I.t =
          (* Stored-bound shortcut: on a reduced operand every stored program-variable
             bound is already the tightest the LP implies (that is what [reduced]
             certifies), so a single-variable form needs no solver call at all. *)
          let stored =
            if not src.reduced then None
            else match CoeffVector.to_sparse_list s with
              | [(col, c)] -> Option.map (I.scale c) (VarMap.find_opt col src.var_intervals)
              | _ -> None
          in
          match stored with
          | Some iv -> iv
          | None ->
            let env_opt = match !cache with
              | Some e -> e
              | None -> let e = lp_of src in cache := Some e; e
            in
            match env_opt with
            | None -> I.top (* operand infeasible: it bounds nothing *)
            | Some env ->
              let env, iv = eval_linform env s in
              cache := Some (Some env); iv
        in
        (* collect (s_kappa, recovered interval) at the shared original width, before we
           start growing [joined] with recovered slacks. *)
        let recovered =
          List.filter_map (fun s ->
              let iv_x = eval cache_x x s in
              (* [combine] is [I.join] or [I.widen]; both map a top first argument to
                 top, so y's valuation is only computed when x actually bounds s. *)
              if I.is_top iv_x then None
              else
                let iv = combine iv_x (eval cache_y y s) in
                if I.is_top iv then None
                (* drop bounds the joined column intervals already imply: e.g. the
                   single-variable forms of dropped constant equalities (x=5 vs x=7)
                   recover exactly the joined var_interval and would only bloat the
                   state with a redundant slack *)
                else if I.leq (interval_eval joined.var_intervals s) iv then None
                else Some (s, iv))
            candidates
        in
        (* true state width: [joined.affeq] can be empty (branches share no equality),
           whose [num_cols] is 0, so derive it from the operands instead. Track it through
           the fold since each fresh slack widens the state by one column. *)
        let width0 =
          if not (Matrix.is_empty joined.affeq) then Matrix.num_cols joined.affeq
          else List.fold_left (fun w src ->
              max w (if Matrix.is_empty src.affeq then 0 else Matrix.num_cols src.affeq)) 0 sources
        in
        let res, _ =
          List.fold_left (fun (t, width) (s, iv) ->
              let s = CoeffVector.of_sparse_list width (CoeffVector.to_sparse_list s) in
              let t, grew = add_recovered_slack ~on_existing ~slack_col:(width - 1) s iv t in
              (t, if grew then width + 1 else width))
            (joined, width0) recovered
        in
        res
      end

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
    let joined = {affeq = new_affeq; intervals = new_intervals; infos = x.infos;
                  var_intervals = var_interval_join x.var_intervals y.var_intervals; reduced = false} in
    (* Step 3: recover inequalities dropped by the convex (LinEq) join. *)
    Some (recover_step3 ~combine:I.join ~on_existing:I.meet ~sources:[x; y] x y joined)

  (** [entailed_bounds env info] is the tightest interval the LP [env] implies for the
      linear form described by [info] (the constant slot, if any, is included). Threads
      the solver environment so consecutive calls reuse the pivoted tableau. *)
  let entailed_bounds (env: Core.t) (info: info) : Core.t * I.t =
    let info_const = CoeffVector.nth info (CoeffVector.length info - 1) in
    let info_terms = CoeffVector.to_sparse_list (CoeffVector.set_nth info (CoeffVector.length info - 1) Rat.zero) in
    let env, upper = optimize env info_terms in
    let env, neg_lower = optimize env (List.map (fun (i, c) -> (i, Rat.neg c)) info_terms) in
    env, I.of_bounds ~lower:(Option.map (fun m -> info_const -: m) neg_lower)
      ~upper:(Option.map (fun m -> m +: info_const) upper)

  (** [env_a] is [a]'s LP, built lazily so callers can share one construction across
      several entailment checks (and never pay for it when all check lists are empty). *)
  let non_info_entailment (env_a : Core.t option Lazy.t) b (non_info : int list) =
    if List.is_empty non_info then true else
    match Lazy.force env_a with
    | None -> true (*a is bottom and therefore leq to b.*)
    | Some env ->
      let env = ref env in
      List.for_all (fun orph ->
        match recover_def_from_non_info_intv orph b with
        | None -> false
        | Some info ->
          let env', iv = entailed_bounds !env info in
          env := env';
          I.leq iv (VarMap.find orph b.intervals)) non_info
  (**
  [leq a b]: is every constraint of [b] entailed by [a]? Constraints only [a] has
  (extra slacks, extra rows, extra variable bounds) make [a] smaller and are irrelevant.
  *)
  let leq (a: t) (b: t) =
    let collect_top(x : t) =
      VarMap.fold (fun var intv acc ->
          if I.is_top intv
          then var :: acc
          else acc ) x.intervals []
    in
    let collect_non_info (x : t) =
      VarMap.fold (fun var intv acc ->
          if (not @@ VarMap.mem var x.infos) && not (I.is_top intv)
          then var :: acc
          else acc) x.intervals []
    in
    match reduce a, reduce b with (*reduce here needed unfortunately. Invalid widen otherwise.*)
    | None, _ -> true
    | _, None -> false
    | Some a, Some b ->
    (* program-variable bounds: [a] is reduced, so its stored entry is the tightest bound
       the LP derives for that column; a missing entry means unbounded in [a]. *)
    VarMap.for_all (fun col b_intv ->
        match VarMap.find_opt col a.var_intervals with
        | Some a_intv -> I.leq a_intv b_intv
        | None -> I.is_top b_intv) b.var_intervals
    && begin
      let processed_a = forget_vars (collect_top a @ collect_non_info a) a in
      let b_non_info = collect_non_info b in
      (* one LP construction for [a], shared by the orphan and b-only entailment checks *)
      let env_a = lazy (lp_of a) in
      if not @@ non_info_entailment env_a b b_non_info then false else
      let processed_b = forget_vars (collect_top b @ b_non_info) b in
      (* Slacks that exist only in [b] (their info matches no slack of [a]) need special
         treatment: their interval constraint would otherwise never be compared against
         [a] at all (unsound), and their defining row in [b.affeq] cannot lie in the row
         span of [a.affeq], so the is_covered_by check below would spuriously fail --
         that was the Invalid_widen crash whenever widen introduced a fresh slack (e.g.
         any loop with a relational condition like [while (i < n)]). We check their
         constraint against [a]'s LP directly and then drop them from [b]. *)
      let b_only = VarMap.fold (fun var info acc ->
          if VarMap.exists (fun _ i -> info_equal i info) processed_a.infos then acc
          else (var, info) :: acc) processed_b.infos []
      in
      let b_only_entailed =
        match b_only with
        | [] -> true
        | _ ->
          match Lazy.force env_a with
          | None -> true (* a is bottom *)
          | Some env ->
            let env = ref env in
            List.for_all (fun (var, info) ->
                match VarMap.find_opt var processed_b.intervals with
                | None -> true (* unconstrained slack: nothing to entail *)
                | Some b_intv ->
                  let env', iv = entailed_bounds !env info in
                  env := env';
                  I.leq iv b_intv) b_only
      in
      if not b_only_entailed then false else
      let processed_b = forget_vars (List.map fst b_only) processed_b in
      let (a_common, b_common) = slack_lce processed_a processed_b in
      (* every remaining slack of b must be matched by a slack of a with equal info
         (guaranteed by the b_only handling above; checked defensively). The reverse is
         NOT required: slacks only a has are extra constraints on a. *)
      VarMap.for_all (fun v k ->
        match VarMap.find_opt v a_common.infos with
        | Some k' -> info_equal k' k
        | None -> false) b_common.infos
      && VarMap.for_all (fun k v' ->
        match VarMap.find_opt k a_common.intervals with
        | Some v -> I.leq v v'
        | None -> I.is_top v') b_common.intervals
      && (Matrix.is_empty b_common.affeq
          || (not (Matrix.is_empty a_common.affeq)
              && (* is_covered_by needs both matrices in rref and the slack remapping
                    above can break that, so normalize first *)
              match Matrix.normalize a_common.affeq, Matrix.normalize b_common.affeq with
              | Some na, Some nb -> Matrix.is_covered_by nb na
              | None, _ | _, None -> false))
    end

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
    let open GobOption.Syntax in
    let (new_a, new_b) = slack_lce a b in
    let* x = Matrix.normalize new_a.affeq in
    let* y = Matrix.normalize new_b.affeq in
    let* new_intervals = interval_meet new_a.intervals new_b.intervals in
    let* new_var_intervals = interval_meet new_a.var_intervals new_b.var_intervals in
    let* new_affeq = Matrix.rref_matrix x y in (* Matrix ist dann in der richtigen Form *)
    let new_infos = VarMap.union (fun _ i1 i2 -> if info_equal i1 i2 then Some i1 else failwith "inconsistent slack mapping") new_a.infos new_b.infos in
    Some {affeq = new_affeq; intervals = new_intervals; infos = new_infos;
          var_intervals = new_var_intervals; reduced = false}

  let widen a b =
    let (remapped_a, remapped_b) = inject_slack_for_widen @@ slack_lce a b in
    (*let new_a = reduce remapped_a in*)
    let norm_a = Matrix.normalize remapped_a.affeq in
    let new_a = match norm_a with 
      | None -> None
      | Some x -> Some {remapped_a with affeq = x} in
    let new_b = reduce remapped_b in
    match new_a, new_b with
    | None, None -> None
    | None, _ -> new_b
    | _, None -> new_a
    | Some x, Some y ->
    let new_intervals = interval_widen x.intervals y.intervals in
    let new_affeq = Matrix.linear_disjunct x.affeq y.affeq in
    (* Step 3: recover inequalities dropped by the convex step. Per Algorithm 2 this is
       one-directional (only operand 0's dropped equalities, valuations combined with the
       interval widening) so the operator stays a widening. *)
    (* widen keeps the existing slack interval on a match (never tighten) so the operator
       stays increasing: [old <= widen old new]. *)
    let joined = recover_step3 ~combine:I.widen ~on_existing:(fun cur _ -> Some cur) ~sources:[x] x y
        {affeq = new_affeq; intervals = new_intervals; infos = x.infos;
         var_intervals = interval_widen x.var_intervals y.var_intervals; reduced = false} in
    let lost_vars = Array.of_enum @@ VarMap.keys @@ VarMap.filter (fun v _ -> not (VarMap.mem v new_intervals)) y.intervals in
    Some (remove_columns lost_vars joined true)

  let narrow = meet
  let unify = meet

  let _ = Var.string_of (* silence unused-functor-arg warning until Var is actually used *)
end
