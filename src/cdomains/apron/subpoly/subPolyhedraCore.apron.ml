module Mpqf = SharedFunctions.Mpqf
open Intervalsig

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

(** Internal representation of a consistent subpolyhedron. *)
module SubPoly (Var : Var) (I : IntervalSig) = struct
  (* Reuse the SparseVector and ListMatrix modules from the AffineEqualityDomain. *)
  include RatOps.ConvenienceOps (Mpqf)

  module Vector = SparseVector.SparseVector
  module CoeffVector = Vector(Mpqf)
  module Matrix =
    AffineEqualityDomain.AffineEqualityMatrix
      (Vector)
      (ListMatrix.ListMatrix) (*Question: do we actually use this, if we just use the Matrix and Vector implementations? *)

  (* Map keyed by variables. *)
  module VarMap = Map.Make(Var)

  type affeq = Matrix.t [@@deriving eq, ord, hash] (*Our affine equality matrix.*)
  type interval_map = I.t VarMap.t [@@deriving eq, ord] (*Map from Var to Interval*)
  type info = CoeffVector.t [@@deriving eq, ord, hash] (*similar to sparse vector, might acutally use sparse vector here? QUESTION*)
  type info_map = info VarMap.t [@@deriving eq, ord] (*Map from Var to info (maybe sparse vector)*)

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

  let add_affeq_row (row: CoeffVector.t) (t: t) =
    { t with affeq = Matrix.append_row t.affeq row }
  

  (**
    [rem_row_containing_var affeq var] uses [Matrix.reduce_col] and [Matrix.remove_zero_rows] to remove all occurences of the variable from a matrix. 

    Used in forget_vars.
  *)  
  let rem_rows_containing_var (affeq : affeq) (var : Var.t) : affeq = 
    if Matrix.is_empty affeq then affeq
    else 
      Matrix.remove_zero_rows @@ Matrix.reduce_col affeq (Var.to_int var)

  (**
    [rem_infos_containing_var slacks var] takes a slack_map and removes all slack variables whose info contains mention of the var.

    Used in forget_vars.
  *) 
  let rem_infos_containing_var (infos : info_map) (var : Var.t) : info_map = 
     VarMap.filter (fun _ (info : info) -> CoeffVector.nth info (Var.to_int var) =: Mpqf.zero) infos
  
  (**
    [forget_vars vars t] forgets a list of variables in the polyhedron.

    Future TODO: Currently we do Gaussian elimination with the variable as pivot ([Matrix.reduce_col]).
    This is fine for the affeq, but we do not want to blindly remove any slack variable info containing x
    from our info_map. Currently this happens, but refinement is needed in the future!
  *)
  let forget_vars (vars: Var.t list) (t: t) = 
    let new_affeq = List.fold_left rem_rows_containing_var t.affeq vars in
    let new_intervals = List.fold_left (flip VarMap.remove) t.intervals vars in
    let new_infos = List.fold_left rem_infos_containing_var t.infos vars in
      {affeq = new_affeq ; intervals = new_intervals ; infos = new_infos}
  
  (**
  [forget_var var t] forgets a single variable using [forget_vars].
  *)
  let forget_var (var : Var.t) (t: t) : t = 
    forget_vars [var] t
  
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
      let (info_list : (Var.t * Mpqf.t) list) = CoeffVector.to_sparse_list info in
      let set_infos acc (v, c) = CoeffVector.set_nth acc (shift_index_add v occ_cols) c in
      let new_info = List.fold_left set_infos (CoeffVector.of_list []) info_list in
      VarMap.add new_var new_info acc) infos VarMap.empty in
    let new_intervals_add (intervals : interval_map) occ_cols : interval_map = 
    VarMap.fold( fun var interval acc ->
      let new_var = shift_index_add var occ_cols in
      VarMap.add new_var interval acc) intervals VarMap.empty in
    let new_affeq = Matrix.dim_add ch t.affeq in
    let list = Array.to_list ch.dim in
    let grouped_indices = List.group Int.compare list in 
    let occ_cols = List.map (fun group -> ((List.hd group, List.length group))) grouped_indices in 
    (* Approach from listMatrix.ml: add_empty_columns; Example: cols_list = [1; 3; 3; 5] -> grouped_indices = [[1]; [3; 3]; [5]] -> occ_cols = [(1, 1); (3, 2); (5, 1)] *)
    let new_infos = new_infos_add t.infos occ_cols in 
    let new_intervals = new_intervals_add t.intervals occ_cols in
    {affeq = new_affeq; infos = new_infos; intervals = new_intervals}

  (**
  [dim_remove] Apron dimension change
  *)
  let dim_remove (ch: Apron.Dim.change) (t: t) =
    let shift_index_remove (old_index : Var.t) (dim_list : int list) : Var.t = 
    (let k = List.fold_left (fun acc index -> if index < (Var.to_int old_index) then acc + 1 else acc) 0 dim_list
    in let new_index = (Var.to_int old_index) - k 
    in Var.to_t new_index) in
    let new_infos_remove (infos : info_map) dim_list : info_map = 
    VarMap.fold (fun var info acc ->
      let new_var = shift_index_remove var dim_list in
      let new_info =(List.fold_left (fun acc (v, c) -> CoeffVector.set_nth acc (shift_index_remove v dim_list) c) (CoeffVector.of_list []) (CoeffVector.to_sparse_list info)) in
      VarMap.add new_var new_info acc) infos VarMap.empty in
    let new_intervals_remove (intervals : interval_map) dim_list : interval_map =
    VarMap.fold( fun var interval acc ->
      let new_var = shift_index_remove var dim_list in
      VarMap.add new_var interval acc) intervals VarMap.empty in
    let new_affeq = Matrix.dim_remove ch t.affeq in
    let dim_list = Array.to_list ch.dim in
    let new_t = forget_vars (List.map Var.to_t dim_list) t in
    let dim_list = List.sort_uniq Int.compare dim_list in (* remove duplicates *)
    let new_infos = new_infos_remove new_t.infos dim_list in 
    let new_intervals = new_intervals_remove new_t.intervals dim_list in
    {affeq = new_affeq; infos = new_infos; intervals = new_intervals}

  let string_of_interval_map (m: interval_map) =
    VarMap.bindings m
    |> List.map (fun (var, interval) -> Var.string_of var ^ " -> " ^ I.show interval)
    |> String.concat "; "

  (*let string_of_info (e: info) =
      match e with
      | [] -> ""
      | terms ->
        terms
        |> List.map (fun (v, c) -> Mpqf.to_string c ^ "*" ^ Var.string_of v)
        |> String.concat " + "*)
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
  
  let reduce = identity (*TODO: implement reduction with simplex or base exploration.*)
  let meet (a: t) (b: t) =
    if equal a b then a else empty ()

  let leq (a: t) (b: t) =
    equal a b || is_empty b

  (**
  [interval_join a b] takes two interval_maps and joins them using [RationalInterval.join].
  QUESTION: How do we represent bottom in the interval domain?
  *)
  let interval_join (a : interval_map) (b : interval_map) : interval_map = 
    VarMap.union (fun (key : Var.t) (v1 : I.t) (v2 : I.t) -> Some (I.join v1 v2)) a b
   
    (**[join a b] returns a subpolyhedra resulting from the join of two subpolyhedras a and b.
    QUESTION: dies dim_add and dim_remove change the canonicalization of [info]? We may need to 
    canonicalize after each dimension change.
    QUESTION: Do we need a join in this module or can it be realized only in the Domain file?
 
    General Structure:
    Incoming a, b:
    We introduce infos of slack variables that are in one state but not the other into the affeq 
    with intervals [None, None]. Then we reduce both states and do a pairwise join on affeq and 
    intervals. 
   
    We need some way to have both states in the same variable space for slack variables.
    Either, we take care of this upon insertion by keeping a global counter or another naming scheme.
    Or, we have to create a joint state where we call a function in the join that takes care of this.
    The "danger" lies in the case where two branches create slack variables with the same integer identifier
    but different info and interval data. This is also propagated in the affeq, as the identifier is used in 
    the affeq to represent a slack variable.
   *) 
  let join (a: t) (b: t) =
    let propagate_slacks (a : t) (b : t) : t =  
      VarMap.fold (fun var info acc -> 
        if VarMap.exists (fun _ v -> CoeffVector.equal info v) a.infos then acc
        else acc)  (*Question here how we do this. Outlined more above.*)
        b.infos a in
    let new_a = reduce @@ propagate_slacks a b in
    let new_b = reduce @@ propagate_slacks b a in
    let new_intervals = interval_join new_a.intervals new_b.intervals in
    let new_affeq = Matrix.linear_disjunct new_a.affeq new_b.affeq in
    {affeq = new_affeq; intervals = new_intervals; infos = a.infos (*What are the new infos?*)}
  

  let widen = join
  let narrow (a: t) (_b: t) = a
  let unify = meet

  let _ = Var.string_of (* silence unused-functor-arg warning until Var is actually used *)
end
