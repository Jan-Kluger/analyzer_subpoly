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

  
  (** Number of slack columns = size of the trailing slack block. Every slack has an
      interval *)
  let num_slacks (t: t) = VarMap.cardinal t.intervals

  (**[insert_w_resize vec idx value] is a workaround to dynamically grow a CoeffVector without changing the module itself.
     This could be in the module if approved my Michael.*)
  let set_nth_w_resize vec idx value = 
    let len = CoeffVector.length vec in
    let wide = if idx >= len
      then 
        let zeroes = (idx - len) + 1 in
        CoeffVector.insert_zero_at_indices vec [(len, zeroes)] zeroes 
      else vec in
    CoeffVector.set_nth wide idx value

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
     VarMap.filter (fun _ (info : info) -> CoeffVector.nth info var =: Mpqf.zero) infos
  
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
          let new_info = List.fold_left 
              (fun acc (v,c) -> set_nth_w_resize acc (shift_index_add v occ_cols) c) 
              (CoeffVector.of_list []) (CoeffVector.to_sparse_list info) in
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
  let dim_remove (ch: Apron.Dim.change) (t: t) =
    let shift_index_remove (old_index : Var.t) (dim_list : int list) : Var.t = 
      (let k = List.fold_left (fun acc index -> 
        if index < (Var.to_int old_index) 
        then acc + 1 
        else acc) 0 dim_list
    in let new_index = (Var.to_int old_index) - k 
    in Var.to_t new_index) in
    let new_infos_remove (infos : info_map) dim_list : info_map = 
    VarMap.fold (fun var info acc ->
      let new_var = shift_index_remove var dim_list in
      let new_info =(List.fold_left (fun acc (v, c) -> set_nth_w_resize acc (shift_index_remove v dim_list) c) (CoeffVector.of_list []) (CoeffVector.to_sparse_list info)) in
      VarMap.add new_var new_info acc) infos VarMap.empty in
    let new_intervals_remove (intervals : interval_map) dim_list : interval_map =
      VarMap.fold( fun var interval acc ->
          let new_var = shift_index_remove var dim_list in
          VarMap.add new_var interval acc
        ) intervals VarMap.empty 
      in
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



  (**
     [slack_lce a b] takes two subpolyhedra [a] and [b] and maps the slack variables into a common environment based on the info field.
     - we assume that infos in the info map are canonicalized to check equality.
  *)
  let slack_lce a b = 
    (*[get_mapping a b] finds a slack variable mapping from subpolyhedra a and b into a shared space. *)
    let get_mapping (a : t) (b : t) = 
      (**[find_key_on_info map info] searches a VarMap [map] for the first occurence of [info] and returns an [Option (key * value)] 
         - TODO: probably inefficient as we iterate through both maps entirely to find the maximum. *)
      let find_key_on_info map info = Seq.find (fun (_, v) -> CoeffVector.equal v info) @@ VarMap.to_seq map in
      (*[find_next_slack_idx (map_a, map_b)] finds the next free index in the shared slack variable space of a and b.*)
      let find_next_slack_idx (map_a, map_b) =
        if IntMap.is_empty map_a && IntMap.is_empty map_b then fst @@ VarMap.min_binding a.intervals (*If no mapping is present, we just use the first slack index from a.*)
        else let update_maximum_idx _ v m = max v m in (*find the smallest index that is available: *)
          (IntMap.fold update_maximum_idx map_b @@ IntMap.fold update_maximum_idx map_a 0) + 1
      in
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
    let remap_vector_sparse (vec : CoeffVector.t) (mapping : int IntMap.t) : CoeffVector.t = 
      (*TODO: take care of constant if it exists!*)
      let const = CoeffVector.nth vec ((CoeffVector.length vec) - 1) in
      let helper acc (v, c) = 
        let new_var = if IntMap.mem v mapping then IntMap.find v mapping else v in
        set_nth_w_resize acc new_var c in
      let res = List.fold_left helper (CoeffVector.of_list []) (CoeffVector.to_sparse_list vec) in
      if const = Mpqf.zero then res else set_nth_w_resize res (CoeffVector.length res) const 
    in
    (*[remap_slacks a mapping const_idx] remaps the slack variables of a subpolyhedra a using the mapping from [get_mapping a b]. *)
    let remap_slacks (a : t) (mapping : int IntMap.t) : t =
      let new_infos = 
        let helper (var : int) (info : CoeffVector.t) (acc : info VarMap.t) = 
          let mapped_var = IntMap.find var mapping in
          let new_info = remap_vector_sparse info mapping in
          VarMap.add mapped_var new_info acc in
        VarMap.fold helper VarMap.empty a.infos in
      let new_intervals =
        VarMap.fold (fun var intv acc -> VarMap.add (IntMap.find var mapping) intv acc) VarMap.empty a.intervals in
      let new_affeq  = Matrix.map (fun row -> remap_vector_sparse row mapping) a.affeq in 
      {affeq = new_affeq; intervals = new_intervals; infos = new_infos} in
    (*Remove slacks that have no info because they cannot be kept in the join:*)
    let a_with_slacks_removed = VarMap.fold (fun var _ acc -> if not @@ VarMap.mem var a.infos then forget_var var acc else acc) a.intervals a in 
    let b_with_slacks_removed = VarMap.fold (fun var _ acc -> if not @@ VarMap.mem var b.infos then forget_var var acc else acc) b.intervals b in 
    let (a_mapping, b_mapping) = get_mapping a_with_slacks_removed b_with_slacks_removed in
    let a_remapped = remap_slacks a_with_slacks_removed a_mapping in
    let b_remapped = remap_slacks b_with_slacks_removed b_mapping in
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
      let new_affeq = Matrix.append_row x.affeq (set_nth_w_resize info var (Mpqf.of_int (-1))) in
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
  let join (a: t) (b: t) : t =
    let (remapped_a, remapped_b) = inject_slack_for_join @@ slack_lce a b in
    let new_a = reduce remapped_a in
    let new_b = reduce remapped_b in
    let new_intervals = interval_join new_a.intervals new_b.intervals in
    let new_affeq = Matrix.linear_disjunct new_a.affeq new_b.affeq in
    {affeq = new_affeq; intervals = new_intervals; infos = new_a.infos}

  (**
  [leq a b]
  TODO: Reduce here will be called for every program point because leq is called a lot! 
        Maybe keep a reduced version at all times!
  *)
  let leq (a: t) (b: t) =
    let drop_top_and_non_info_slacks var intv acc = 
      if VarMap.mem var acc.infos || I.is_top intv 
      then forget_var var acc 
      else acc 
    in
    let processed_a = VarMap.fold drop_top_and_non_info_slacks a.intervals @@ reduce a  in
    let processed_b = VarMap.fold drop_top_and_non_info_slacks b.intervals @@ reduce b in
    let (a_common, b_common) = slack_lce processed_a processed_b in
    VarMap.equal (fun v1 v2 -> CoeffVector.equal v1 v2) a_common.infos b_common.infos (*does CoeffVector.equal derive the correct equality?*)
    && VarMap.for_all (fun k v -> I.leq v (VarMap.find k b_common.intervals)) a_common.intervals
    && Matrix.is_covered_by b_common.affeq a_common.affeq

  let widen = join
  let narrow (a: t) (_b: t) = a
  let unify = meet

  let _ = Var.string_of (* silence unused-functor-arg warning until Var is actually used *)
end
