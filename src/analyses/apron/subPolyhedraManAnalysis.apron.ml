(** {{!RelationAnalysis} Relational integer value analysis} using the manually implemented subpolyhedra domain ([subpoly_man]).

    @see <http://doi.acm.org/NOTYETPUBLISHED>  Subpolyhedra. *)

open Analyses
include RelationAnalysis

let spec_module: (module MCPSpec) Lazy.t =
  lazy (
    let module AD = SubPolyhedraManDomain.D2
    in
    let module Priv = (val RelationPriv.get_priv ()) in
    let module Spec =
    struct
      include SpecFunctor (Priv) (AD) (RelationPrecCompareUtil.DummyUtil)
      let name () = "subpoly_man"
    end
    in
    (module Spec)
  )

let get_spec (): (module MCPSpec) =
  Lazy.force spec_module

let after_config () =
  let module Spec = (val get_spec ()) in
  MCP.register_analysis ~usesApron:true (module Spec : MCPSpec);
  GobConfig.set_string "ana.path_sens[+]"  (Spec.name ())

let _ =
  AfterConfig.register after_config
