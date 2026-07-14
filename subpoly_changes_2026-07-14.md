# SubPolyhedra: performance + correctness changes (2026-07-14)

Branch `optimization_test_tmp`, on top of `b24a2b04a`. Files touched:
`src/cdomains/apron/subpoly/subPolyhedraCore.apron.ml`,
`src/cdomains/apron/subpoly/subPolyhedraDomain.apron.ml`,
`tests/regression/90-subpoly/05-inequality-reduce.c` (stale annotation).

Motivation: profiling showed `reduce` (LP) at 23–51% of runtime, driven almost
entirely by type-bound slacks — `RelationAnalysis.assert_type_bounds` asserts
`INT_MIN <= x <= INT_MAX` for every variable after every assignment, and each
assert paid a slack insertion plus a full LP reduce. Disabling type bounds made
bench1 10× faster; these changes get that speedup without disabling anything.

## 1. `var_intervals`: single-variable constraints don't create slacks

New field in the core state:

```ocaml
type t = { affeq; intervals; infos;
           var_intervals : interval_map;  (* bounds on program-variable columns *)
           reduced : bool }               (* see §2 *)
```

Slacks are now only created for genuinely relational (multi-variable)
inequalities. A single-variable constraint `a*x + c ∈ I` is stored as a direct
interval on x's own column (`meet_single_var_constraint` in the domain):

- `meet_tcons` SUPEQ/SUP dispatch on `to_single_var_opt`;
- `substitute_expr`'s re-added stale slack constraints dispatch the same way
  (a substituted definition can collapse to a single variable);
- re-asserting an **unchanged** bound (the type-bounds common case) is detected
  by an interval-equality check and costs nothing — no slack, no LP;
- an invertible assignment `x := a*x + c` *transforms* x's direct bound instead
  of dropping it.

`var_intervals` is threaded through `lp_of` (asserted like slack intervals),
`reduce` (refined), join (`var_interval_join`, keys must exist on both sides),
widen (`interval_widen`), meet (`interval_meet`), leq, `dim_add`,
`remove_columns`, equal/compare/hash, `string_of`. The `intervals`-keys-are-
slack-columns invariant (`num_slacks`, `is_slack`, `forget_vars` partitioning)
is untouched because program-variable bounds live in the separate map.

## 2. `reduced` flag: at most one full reduce per state

`reduce` on an already-reduced state is the identity, so the state now carries a
cache flag: set by `reduce` (`Refine_all`), cleared by every mutation, ignored
by `equal`/`compare`/`hash` (it is not part of the abstract value). `leq`'s
mandatory `reduce a, reduce b` becomes free when the operands were stored
reduced.

`reduce` also gained modes (still the single LP entry point):

```ocaml
type reduce_mode = Refine_all | Feasibility_only | Refine_cols of Var.t list
```

`bound_texpr` uses `Refine_cols [tmp_slack]`: it only reads back one interval,
so refining all of them (2 LP maximizations each) was wasted work.

**Warning — do not make `reduce_to_bot` feasibility-only.** I tried; the solver
then diverges (infinite `+1` bound creep on `while (i < n) i++`, joins never
stabilize). States must be stored fully reduced (canonical/tightest) or
join/widen compare loose against tightened bounds and the fixpoint never
settles. There is a comment at `reduce_to_bot` documenting this.

## 3. `leq`: b-only slacks fixed (the Invalid_widen crash)

`leq a b` mishandled slacks that exist only in `b` (info matches no slack of
`a`) — both directions were wrong:

- **incomplete:** `b`'s defining row for such a slack cannot lie in the row span
  of `a.affeq`, so `Matrix.is_covered_by` spuriously failed. Widen introduces
  exactly such a fresh slack for any relational loop condition, so
  `leq old (widen old new)` failed ⇒ `Lattice.Invalid_widen` crash.
  Minimal repro (long-standing, back to at least Jul 10): `while (i < n) i++;`.
  The 90-subpoly regtests missed it because they only use `while (c)`.
- **unsound:** `b`'s interval constraint on such a slack was never checked
  against `a` at all (the interval loop only iterated `a`'s slacks).

Fix: b-only slacks are entailment-checked against `a`'s LP directly
(`entailed_bounds`, shared with `non_info_entailment`) and then forgotten from
`b` before `slack_lce`. Additionally:

- the info/interval checks now iterate **b**'s constraints (extra slacks of `a`
  are extra constraints on `a` and irrelevant for `a ⊑ b`; before they made
  `leq` spuriously false);
- both matrices are normalized before `is_covered_by` (it requires rref, and
  the slack remapping can break that — same issue as upstream `f8599d180`).

## 4. `slack_lce`: zero-slack guard

`find_next_slack_idx` returned `-1` (vector length 0) when both states have
zero slacks **and** empty matrices; the remap then corrupts vectors. Guarded
with `max 1 …`. Zero-slack states were previously unreachable because every
variable got a type-bound slack; with §1 they are the common case.

## Results

| test | before | after |
|---|---|---|
| bench1_many_vars | 9.9 s | **0.9 s** |
| bench2_nested_widen | crash (Invalid_widen) | **1.1 s** |
| bench3_branchy_joins | 3.0 s | **0.4 s** |
| bench4_inequalities | crash (Invalid_widen) | **does not converge** (see note) |
| bench5_query_heavy | 3.8 s | **0.9 s** |
| `while (i < n) i++;` | crash (Invalid_widen) | ok |
| 90-subpoly regtests | pass (7/7) | pass (7/7) |

Precision: unchanged or better — bench1's three relational checks still
succeed, and `05-inequality-reduce.c`'s transitive `x <= 5` check (annotated
`// UNKNOWN`) now **succeeds**; the annotation was updated.

Note on bench4 (OPEN ISSUE): it never ran to completion before (it crashed
early with Invalid_widen), so there is no valid baseline — the leq fix removed
the crash and exposed that this workload does not converge in reasonable time
(>10 min; solver evals keep climbing, 60+ updates at the `s < x9` node).
The pattern is a chain of relational inequalities (`x1 >= x0 && x1 <= x0+10 &&
...`) combined with a widening loop whose body re-asserts relational facts
(`s = s + x1 - x0` under `x3 - x0 >= 20`); a 4-variable variant already fails
to finish in 100 s, while each ingredient alone (single relational condition,
plain counter loop, 2-variable chain) terminates quickly. Suspects: per-round
slack churn from `substitute_expr` re-adds interacting with widening, and full
LP reduces over ~20 slacks per meet_tcons in the re-evaluated `&&` chain.
`tmp_benchmark/run_benchmarks.sh` now caps each run at 180 s so the suite
cannot hang on this.

## Known gaps / future work

- `unify` is still `meet` in the core, and interprocedural analysis still fails
  with `SubPolyhedraDomain.unify: not implemented` — any benchmark file with
  more than one function crashes.
- Every `reduce` rebuilds the LP from scratch; that is now the dominant cost
  (see bench4 note).
- `leq` builds `a`'s LP up to twice (once in `non_info_entailment`, once for
  b-only slacks); could share one env.
