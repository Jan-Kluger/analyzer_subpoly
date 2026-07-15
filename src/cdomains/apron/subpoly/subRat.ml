(** Zarith-backed rationals for the subpolyhedra domain.

    Drop-in replacement for [SharedFunctions.Mpqf]: satisfies [RatOps.RatOps]
    plus the extras the subpoly core builds on (ocplib-simplex [Rationals]
    pieces like [cmp]/[sgn], and [of_z]). Unlike Mpqf — camlidl stubs over GMP,
    where every operation crosses the C FFI and heap-allocates a custom block —
    [Q.t] over small numerators/denominators stays on unboxed OCaml values. *)

module Rat = struct
  include Q

  let mone = Q.minus_one
  let cmp = Q.compare
  let sgn = Q.sign
  let get_num = Q.num
  let get_den = Q.den
  let of_z = Q.of_bigint
  (* [include Q] shadowed [+]/[*] with the rational ones, so bring the int ones back *)
  let hash x = Stdlib.(31 * Z.hash (Q.den x) + Z.hash (Q.num x))
  let print = Q.pp_print
end
