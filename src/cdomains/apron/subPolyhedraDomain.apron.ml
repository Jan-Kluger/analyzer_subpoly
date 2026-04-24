(** OCaml implementation of the subpolyhedra domain.

    @see <http://doi.acm.org/NOTYETPUBLISHED>  Subpolyhedra. *)

open Batteries
open GoblintCil
open Pretty
module M = Messages
open GobApron

module Mpqf = SharedFunctions.Mpqf

(** Placeholder backing representation for subpolyhedra.
    Fill in an actual data structure (constraints, matrix, ...) here later. *)
module SubPoly = struct
  type t = unit [@@deriving eq, ord, hash]

  let copy = Fun.id
  let empty () = ()
  let is_empty _ = failwith "SubPolyhedraDomain.SubPoly.is_empty: TODO"
  let dim_add (_ch: Apron.Dim.change) _t = failwith "SubPolyhedraDomain.SubPoly.dim_add: TODO"
  let dim_remove (_ch: Apron.Dim.change) _t = failwith "SubPolyhedraDomain.SubPoly.dim_remove: TODO"

  let string_of _ = "<subpoly>"
end

(** [VarManagement] defines the type t of the subpolyhedra domain and provides
    the functions needed for handling variables. *)
module VarManagement =
struct
  include SharedFunctions.VarManagementOps (SubPoly)
end

module ExpressionBounds: (SharedFunctions.ConvBounds with type t = VarManagement.t) =
struct
  include VarManagement
  let bound_texpr _t _texpr = failwith "SubPolyhedraDomain.bound_texpr: TODO"
end

module D =
struct
  include Printable.Std
  include RatOps.ConvenienceOps (Mpqf)
  include VarManagement

  module Bounds = ExpressionBounds
  module V = RelationDomain.V
  module Arg = struct
    let allow_global = true
  end
  module Convert = SharedFunctions.Convert (V) (Bounds) (Arg) (SharedFunctions.Tracked)

  let name () = "subpoly"

  let to_yojson _ = failwith "SubPolyhedraDomain.to_yojson: TODO"

  (* pretty printing *)
  let show t = match t.d with
    | None -> "⊥"
    | Some d -> SubPoly.string_of d
  let pretty () x = text (show x)
  let pretty_diff () (x, y) = dprintf "%s: %a ≰ %a" (name ()) pretty x pretty y
  let printXml f x =
    BatPrintf.fprintf f
      "<value>\n<map>\n<key>\nconstraints\n</key>\n<value>\n%s</value>\n<key>\nenv\n</key>\n<value>\n%a</value>\n</map>\n</value>\n"
      (XmlUtil.escape (show x)) Environment.printXml x.env

  (* ********************** *)
  (* basic lattice handling *)
  (* ********************** *)

  let top () = failwith "SubPolyhedraDomain.top: TODO"
  let is_top _t = failwith "SubPolyhedraDomain.is_top: TODO"
  let is_bot t = equal t (bot ())

  (* *************************** *)
  (* fixpoint iteration handling *)
  (* *************************** *)

  let meet _a _b = failwith "SubPolyhedraDomain.meet: TODO"
  let leq _a _b = failwith "SubPolyhedraDomain.leq: TODO"
  let join _a _b = failwith "SubPolyhedraDomain.join: TODO"
  let widen _a _b = failwith "SubPolyhedraDomain.widen: TODO"
  let narrow _a _b = failwith "SubPolyhedraDomain.narrow: TODO"
  let unify _a _b = failwith "SubPolyhedraDomain.unify: TODO"

  (* ****************** *)
  (* transfer functions *)
  (* ****************** *)

  let forget_vars _t _vars = failwith "SubPolyhedraDomain.forget_vars: TODO"
  let assign_exp _ask _t _var _exp _no_ov = failwith "SubPolyhedraDomain.assign_exp: TODO"
  let assign_var _t _v _v' = failwith "SubPolyhedraDomain.assign_var: TODO"
  let assign_var_parallel _t _vvs = failwith "SubPolyhedraDomain.assign_var_parallel: TODO"
  let assign_var_parallel_with _t _vvs = failwith "SubPolyhedraDomain.assign_var_parallel_with: TODO"
  let assign_var_parallel' _t _vvs = failwith "SubPolyhedraDomain.assign_var_parallel': TODO"
  let substitute_exp _ask _t _var _exp _no_ov = failwith "SubPolyhedraDomain.substitute_exp: TODO"
  let cil_exp_of_lincons1 = Convert.cil_exp_of_lincons1

  (* ***************************** *)
  (* Module AssertionRels demands: *)
  (* ***************************** *)

  let assert_constraint _ask _d _e _negate (_no_ov: bool Lazy.t) =
    failwith "SubPolyhedraDomain.assert_constraint: TODO"
  let env t = t.env
  let eval_interval _ask = Bounds.bound_texpr
  let invariant _t = failwith "SubPolyhedraDomain.invariant: TODO"

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
