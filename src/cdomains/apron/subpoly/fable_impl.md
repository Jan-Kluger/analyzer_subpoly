# Subpolyhedra implementation — current state

This document describes the state of the Subpolyhedra abstract domain
(Laviron & Logozzo) implemented in this Goblint fork (branch `testing`),
and two bugs found in the shared sparse-matrix library
(`src/cdomains/affineEquality/sparseImplementation/listMatrix.ml`) along the way.

## Status summary

| Check | Result |
|---|---|
| Regression tests (`tests/regression/90-subpoly/`, 30 tests) | all pass (`ruby scripts/update_suite.rb group subpoly`) |
| Same 30 tests with `--enable dbg.subpoly.check-invariants` | all pass, no invariant violations |
| QCheck property tests (33 properties, `tests/unit/subPolyhedraDomainTest.apron.ml`) | all pass, stable across repeated seeds |
| Foreign-group crash sweep (36-apron, 46-apron2, 63-affeq with subpoly activated, ~215 tests) | zero subpoly-caused crashes or timeouts |
| Build | warning-clean |

## Architecture

The domain is the reduced product of a linear-equality component and an
interval environment, with linear inequalities encoded through slack
variables.

- `src/cdomains/apron/subpoly/subPolyhedraCore.apron.ml` — the core state
  and algorithms, parametric over a variable type and an interval domain:

  ```
  type t = {
    affeq:     Matrix.t;          (* affine equalities, rref; row = Σ cᵢ·xᵢ = rhs *)
    intervals: I.t VarMap.t;      (* per-dimension bounds; missing = top *)
    infos:     info VarMap.t;     (* slack β ↦ { iterms; iconst }: β = Σ iterms + iconst *)
  }
  ```

- `src/cdomains/apron/subpoly/subPolyhedraDomain.apron.ml` — the Apron-facing
  `RelationDomain.RD` instance (`D` / `D2`): environment management, slack
  naming, lattice operations, transfer functions.
- `src/cdomains/apron/subpoly/intervals/rationalinterval.ml` — rational
  intervals (`Q.t option` bounds) implementing `IntervalSig`.
- `src/analyses/apron/subPolyhedraAnalysis.apron.ml` — registers the
  `subpoly` analysis via the generic `RelationAnalysis` functor.

An inequality `e ≤ c` over program variables is represented by a slack
dimension `β` with a *defining row* `β = e` in the matrix and an interval
`β ∈ [-∞, c]`. Slacks live in the Apron environment under canonical names
derived from their normalized linear form (`~s(c1*v1+c2*v2+...|const)`), so
the same constraint template maps to the same dimension in every state; the
`~` prefix sorts after program variables, so rref pivoting prefers program
dimensions.

Reduction between the components is a bounded interval propagation through
the equality rows (`propagate`) plus Gaussian reduction of query vectors
(`eval_vec`) — a cheap, sound approximation of the paper's Simplex-based
reduction. Reduction results are not persisted into states, except that join
operates on the refined interval maps.

## Load-bearing invariants

Each of these was violated by a real bug at some point during development;
they are now enforced and checked.

1. **Defining rows are always implied by the matrix.** The affine hull in
   join/widen can drop a slack's defining row while its info and interval are
   kept; an interval on a slack without its row is dead weight for
   propagation and, worse, makes `leq` incomplete (which crashes the solver,
   see invariant 2). Therefore `saturate` re-establishes defining rows
   *unconditionally* (a no-op when already implied — defining rows are
   universally valid), and join/widen end with `restore_defining_rows`.
   The widen *old* side is saturated with its own infos only; saturating it
   with the new side's infos would endanger termination.
2. **`leq` must be complete enough for the solver's widening assertion.**
   `Lattice.assert_valid_widen` checks `leq old (join old new)` before every
   widening and raises `Invalid_widen` otherwise — an incomplete `leq` is a
   crash, not just precision loss. `leq` saturates the left side with the
   union of both sides' infos and propagates before comparing.
3. **Slack metadata is well-formed.** Info keys are slack dimensions; info
   terms mention only program dimensions, sorted, with nonzero coefficients;
   every slack's environment name equals `slack_name(iterms, iconst)`
   (canonical naming is what lets `union_infos` merge maps by key).
4. **Dependent slacks are rescued, not dropped.** When program variables
   disappear (function return, scope exit, havoc), slacks whose info mentions
   them are first re-expressed over surviving variables
   (`rescue_dependent_slacks`: project removed dimensions and other slacks
   out of the matrix, transfer the interval to a template over the
   survivors). This is what lets constraints flow across function boundaries.
   Relatedly, `substitute_exp` (backwards assignment semantics) is implemented
   as meet-with-`var = exp`-then-forget, not assign-then-forget, so rescued
   equalities survive argument substitution at call sites.

## Verification infrastructure

### Runtime invariant checker

- `P.invariant_violations ~size ~is_slack` (core) checks: matrix in proper
  rref (rows of length `size+1`, no zero/contradiction rows, pivots are 1
  with strictly increasing positions, pivot columns zero elsewhere), defining
  row of every slack implied by the matrix, info well-formedness, intervals
  keyed in range and non-empty.
- `D.check_invariants` (domain) adds the canonical-naming check.
- Config option **`dbg.subpoly.check-invariants`** (in
  `src/config/options.schema.json`): when enabled, a `verify` wrapper asserts
  the invariants after every domain operation (join, meet, widen, narrow,
  assign, `meet_tcons`, `substitute_exp`, forget/remove/keep) and fails with
  the violation list and the offending state.

### QCheck property tests (`tests/unit/subPolyhedraDomainTest.apron.ml`)

States are generated by random sequences of domain operations (assignments,
guards of all four constraint kinds, havocs, nested joins/meets/widenings)
over a fixed `{x, y, z}` environment — only reachable states are tested,
never hand-built matrices. On top of that generator:

- **Lattice laws** via the existing `DomainProperties` functors: leq
  reflexivity/transitivity/antisymmetry, join/meet bounds, commutativity,
  idempotence, associativity, absorption, bot/top laws, connect laws,
  `leq (join a b) (widen a (join a b))` (the solver's exact assertion), and
  the narrow laws. The test wrapper uses semantic equality (mutual `leq`),
  and corrects the inherited `VarManagementOps.bot ()` (an empty *non*-bottom
  state — a quirk shared with the affeq domain) to `bot_env`.
- **Invariant properties**: generated states satisfy `check_invariants`, and
  binary operations preserve it.
- **Widening termination**: iterating `x ← widen x (join x b)` over random
  state cycles reaches a structural fixpoint within a bound.
- **Concrete-point soundness oracle**: a random integer point is run through
  the same operation trace as the abstract state, in lockstep; after every
  step the point must remain in the concretization (`mem_point`: rows hold
  exactly, intervals contain the dimension values, slack dimensions valued by
  their defining forms). Guards the point does not satisfy are skipped on
  both sides; `Forget` takes its havoc value from the trace; meets are
  skipped (the point need not lie in the other operand).
- **Bounds oracle**: `Bounds.bound_texpr` of a random linear expression must
  contain its concrete value — this exercises `propagate`/`eval_vec`, the
  machinery behind every analysis query.
- **Differential testing against Polka polyhedra**: the same operation trace
  is run in lockstep through subpoly and Apron's polkaMPQ. Polyhedra are
  strictly more expressive and polka implements the trace operations exactly,
  so γ(poly) ⊆ γ(subpoly) holds at every step — subpoly must never prove
  anything polyhedra refutes: if subpoly is bottom so is polyhedra, and every
  expression bound subpoly reports must be at least as wide as polyhedra's
  (checked per step on the program variables, plus random query expressions
  at the end of the trace). To keep the containment argument valid: the
  polka environment is *real*-typed and its texprs use Real arithmetic
  (polka's own integrality tightening is unrelated to subpoly's ceil/floor
  bound rounding and breaks comparability — e.g. on equality systems without
  integer solutions); strict guards are translated to `e − 1 ≥ 0` on the
  polka side, mirroring subpoly's integer tightening of `e > 0`; disequality
  guards send polka to bottom iff it satisfies `e = 0` (at least as precise
  as subpoly's contradiction-only use of DISEQ); widening is excluded from
  differential traces (widenings are not monotone, so no containment holds
  between the two domains' results).

The oracles were validated by mutation testing: flipping the bound direction
in `meet_tcons`'s inequality case is caught immediately by both oracles and
by the polyhedra differential test — and by none of the lattice-law tests,
confirming they cover the gap (transfer-function unsoundness is invisible to
laws relating abstract states to each other).

Run with `dune test tests/unit`, or just this suite:
`_build/default/tests/unit/mainTest.exe -only-test ":6:subPolyhedraDomain"`
(the `:6:` index shifts if suites are added to `mainTest.ml`).

## Library bug 1: `ListMatrix.is_covered_by` infinite loop

`is_covered_by m1 m2` (is every row of `m1` a linear combination of rows of
`m2`) loops forever when a row of `m1` has a pivot column for which `m2` has
no matching pivot row: the elimination step finds no row to subtract, makes
no progress, and recurses on the same state.

**Consequence here:** using it in `leq` made regression tests 28/29 hang
(states with function-call slack structure routinely have mismatched pivot
sets).

**Workaround:** the subpoly core never calls it. `row_implied_by` /
`matrix_implied_by` implement the same check self-containedly: fold over the
rref rows, subtract `(c/pivot)·row` for each pivot column occupied in the
candidate, and test whether the residual is the zero vector. Do not
reintroduce `is_covered_by`.

## Library bug 2: `ListMatrix.linear_disjunct` loses rows

`linear_disjunct` (the Karr join / affine hull of two rref matrices) is
wrong when the operands' pivot structures differ. Minimal repro at the
matrix level (3 variables x, y, z plus the rhs column):

```
m1 = [ y = -4 ]
m2 = [ x - z = -5 ;  y = -4 ]

linear_disjunct m1 m2  =  []   (top — in both argument orders)
correct affine hull    =  [ y = -4 ]
```

`y = -4` holds in both operands, so it must survive the hull. The cause is
in the asymmetric cases of `lindisjunc_aux`: when at column `c` one matrix
has a pivot and the other does not (the `(1,0)` / `(0,1)` cases), the
algorithm calls `safe_remove_row` on *both* matrices to keep row indices
aligned — discarding an unprocessed row (here m1's `y = -4`) from the side
that had no pivot at `c`.

**How it was found:** the QCheck absorption law `join a (meet a b) ≡ a`
failed on its first run with `a = {y = -4}`, `b = {x - y - z = -1}`. The 30
regression tests never caught it because the interval component retains
`y ∈ [-4, -4]`, masking the lost row for single-variable queries; only
multi-variable consequences (or the lattice law) expose it.

**Fix (subpoly-local):** the core now has its own exact hull,
`P.affine_hull ~size`, used by join and widen instead of `linear_disjunct`.
It exploits that an equality is valid on a union of nonempty affine sets iff
it is implied by each operand, so the hull's row space is the intersection
of the two augmented row spaces. The intersection is computed with the
Zassenhaus algorithm using the existing rref primitives: rref the stacked
rows `(u | u)` for `u ∈ rows(m1)` and `(v | 0)` for `v ∈ rows(m2)`; the
right halves of the rows whose left half is zero form a basis of the
intersection. This is exact (strictly more precise than the buggy library
version), and widening still terminates since the hull's row space is
contained in the old side's.

**Upstream impact:** the affeq domain (`AffineEqualityDomain`) still calls
`linear_disjunct` in its join, so it is presumably affected too. A C-level
repro attempt against affeq happened to pass (extra state structure changed
the pivot situation at the join), but the matrix-level repro above is
two lines. Both this bug and the `is_covered_by` loop are worth reporting
upstream to Goblint.

## Known quirks / open items

- `VarManagementOps.bot ()` returns `{d = Some empty; env = empty}` — an
  empty *non*-bottom (semantically top-like) state, while the actual bottom
  is `bot_env = {d = None; ...}`. This is inherited shared-functor behavior
  (affeq has the same); subpoly's `is_bot` is `is_bot_env`. Left untouched to
  avoid changing analysis behavior, but corrected inside the test wrapper.
- Remaining testing ideas (not yet implemented): analysis-level precision
  comparison against the polyhedra analysis (proven-assertion counts via
  `RelationPrecCompareUtil` — the domain-level differential test above
  already covers the soundness direction), CI-grade foreign regression-group
  sweeps with relaxed expectations, an oracle mode that can also check meets,
  and upstreaming the two library bug reports.
