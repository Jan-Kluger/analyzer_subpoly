open Goblint_lib
open OUnit2

module Var = struct
  type t = string [@@deriving hash]

  let equal = String.equal
  let compare = String.compare
  let string_of = Fun.id
end

module I = Rationalinterval.RationalInterval
module S = Subpolycore.SubPoly (Var) (I)
module Mpqf = SharedFunctions.Mpqf

let q x = Q.of_int x
let mpqf x = Mpqf.of_int x

let interval lower upper =
  I.of_bounds ~lower:(Option.map q lower) ~upper:(Option.map q upper)

let slack ?(terms = []) ?(const = 0) intv =
  {
    S.info = {
      terms = List.map (fun (var, coeff) -> (var, mpqf coeff)) terms;
      const = mpqf const;
    };
    intv;
  }

let assert_subpoly_equal expected actual =
  assert_equal ~cmp:S.equal ~printer:S.string_of expected actual

let test_empty _ =
  let d = S.empty () in
  assert_bool "empty domain should be empty" (S.is_empty d);
  assert_bool "empty domain should not contain slack s" (not (S.mem_slack "s" d))

let test_set_interval _ =
  let x_interval = interval (Some 0) (Some 10) in
  let d = S.empty () |> S.set_interval "x" x_interval in
  assert_bool "domain with an interval should not be empty" (not (S.is_empty d));
  assert_equal
    ~cmp:I.equal
    ~printer:I.show
    x_interval
    (S.VarMap.find "x" d.intervals)

let test_set_slack _ =
  let s_interval = interval (Some 0) (Some 5) in
  let s = slack ~terms:["x", 1; "y", -1] s_interval in
  let d = S.empty () |> S.set_slack "s" s in
  assert_bool "inserted slack should be present" (S.mem_slack "s" d);
  assert_equal
    ~cmp:S.equal_slack
    ~printer:S.string_of_slack
    s
    (S.VarMap.find "s" d.slacks)

let test_add_affeq_row _ =
  let row = S.CoeffVector.of_sparse_list 3 [0, mpqf 1; 1, mpqf (-1); 2, mpqf 4] in
  let d = S.empty () |> S.add_affeq_row row in
  assert_bool "domain with an affine equality row should not be empty" (not (S.is_empty d));
  assert_equal
    ~cmp:S.Matrix.equal
    ~printer:S.Matrix.show
    (S.Matrix.init_with_vec row)
    d.affeq

let test_meet_intersects_interval_bounds _ =
  let x = S.empty () |> S.set_interval "x" (interval (Some 0) (Some 10)) in
  let y = S.empty () |> S.set_interval "x" (interval (Some 5) (Some 15)) in
  let expected = S.empty () |> S.set_interval "x" (interval (Some 5) (Some 10)) in
  assert_subpoly_equal expected (S.meet x y)

let test_meet_with_top_preserves_constraints _ =
  let d =
    S.empty ()
    |> S.set_interval "x" (interval (Some 0) (Some 10))
    |> S.set_slack "s" (slack ~terms:["x", 1] (interval (Some 0) (Some 10)))
  in
  assert_subpoly_equal d (S.meet d (S.empty ()));
  assert_subpoly_equal d (S.meet (S.empty ()) d)

let test_join_unions_interval_bounds _ =
  let x = S.empty () |> S.set_interval "x" (interval (Some 0) (Some 10)) in
  let y = S.empty () |> S.set_interval "x" (interval (Some 5) (Some 15)) in
  let expected = S.empty () |> S.set_interval "x" (interval (Some 0) (Some 15)) in
  assert_subpoly_equal expected (S.join x y)

let test_join_with_top_is_top _ =
  let d = S.empty () |> S.set_interval "x" (interval (Some 0) (Some 10)) in
  assert_subpoly_equal (S.empty ()) (S.join d (S.empty ()));
  assert_subpoly_equal (S.empty ()) (S.join (S.empty ()) d)

let test_leq_uses_interval_containment _ =
  let smaller = S.empty () |> S.set_interval "x" (interval (Some 2) (Some 8)) in
  let larger = S.empty () |> S.set_interval "x" (interval (Some 0) (Some 10)) in
  assert_bool "narrower interval should be below wider interval" (S.leq smaller larger);
  assert_bool "wider interval should not be below narrower interval" (not (S.leq larger smaller));
  assert_bool "constrained domain should be below unconstrained top" (S.leq smaller (S.empty ()));
  assert_bool "unconstrained top should not be below constrained domain" (not (S.leq (S.empty ()) smaller))

let test_string_of_slack _ =
  let s = slack ~terms:["x", 2; "y", -1] ~const:3 (interval (Some 0) (Some 7)) in
  assert_equal
    "[0, 7]  (2*x + -1*y + 3)"
    (S.string_of_slack s)

let test () =
  "subpolycoreTest" >::: [
    "empty" >:: test_empty;
    "set_interval" >:: test_set_interval;
    "set_slack" >:: test_set_slack;
    "add_affeq_row" >:: test_add_affeq_row;
    "meet_intersects_interval_bounds" >:: test_meet_intersects_interval_bounds;
    "meet_with_top_preserves_constraints" >:: test_meet_with_top_preserves_constraints;
    "join_unions_interval_bounds" >:: test_join_unions_interval_bounds;
    "join_with_top_is_top" >:: test_join_with_top_is_top;
    "leq_uses_interval_containment" >:: test_leq_uses_interval_containment;
    "string_of_slack" >:: test_string_of_slack;
  ]
