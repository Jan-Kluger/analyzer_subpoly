# SubPoly fixes on `hints_more_bugfixes` — diff against `master`

This documents everything the branch changes relative to `master`
(`git diff master...hints_more_bugfixes`). Two batches are included:

- **Batch 1** (commits `097c89643..08a26a52a`, previously archived on
  `claude_subpoly_fixes`): widening, narrow, `linear_disjunct` repairs,
  bottom detection in `meet_tcons`, tracing/printing.
- **Batch 2** (commit `340fe16c2`, this branch): soundness fixes found in a
  deep review — stale slack infos, meet bottom detection, interval `compare`,
  `slack_lce` width, `leq` orphan guard — plus a distinct `SUP` case.

All line numbers refer to the current state of this branch.
Verification: all 12 tests in `tests/regression/90-subpoly/` and all 22 in
`tests/regression/63-affeq/` pass.

---

## Batch 2 — soundness fixes (commit `340fe16c2`)

### 1. Stale slack infos after invertible assignments (unsound)

**File:** `src/cdomains/apron/subpoly/subPolyhedraDomain.apron.ml`, lines **376–427** (`substitute_expr`, full rewrite)

For `x = x + 1` the matrix rows were substituted (`s = x+y` became
`s = x+y-1`) but the slack's *info* still claimed `s = x+y`. A later
constraint on `x+y` then dedup-matched the stale info in
`add_slack_constraint` and met the wrong slack's interval — asserting a fact
one off from the truth. Confirmed end-to-end: reachable code was marked dead
(`assume x+y>=3; x=x+1; assume x+y>=5; if (x+y==5)` — the branch is
reachable with `x_old=2, y=2`, but was reported as dead code).

The rewrite:
- builds the substitution vector `v_old = (v_new - rest - c)/a` once
  (lines 393–398) and applies it to matrix rows and infos through a shared
  `substitute_in` helper (399–406), replacing the previous manual
  sparse-list merging;
- partitions infos into `kept` (untouched by the assignment) and `stale`
  (mentioning `v`) at line 408; stale infos are dropped and their constraint
  is **re-added** via `add_slack_constraint` with the substituted linear form
  (411–427), so `x+y >= 3` correctly becomes `x+y >= 4` after `x = x+1`;
- pads each re-added info to the current width (417–420), because every
  re-add can grow the state by one slack column;
- the orphaned old slack keeps its interval — its *value* is unchanged, only
  its symbolic description moved into the rewritten rows, so this loses no
  soundness and no precision.

**Test:** `tests/regression/90-subpoly/12-assign-stale-info.c` (new).

### 2. Core `meet`: contradictions became top, constraints silently dropped

**File:** `src/cdomains/apron/subpoly/subPolyhedraCore.apron.ml`, lines **604–629** (`meet`)

Three defects in one function:
- `Matrix.rref_matrix` returning `None` (contradictory equality systems,
  e.g. `x=1 ⊓ x=2`) was mapped to `Some (empty ())` — **top** instead of
  bottom. Now `None` (line 617).
- Interval intersection used `VarMap.union` where an empty `I.meet`
  (contradictory bounds on the same slack) silently **dropped the key**
  instead of making the meet bottom. Now raises internal `Bottom` → `None`
  (lines 620–628).
- The result kept `infos = x.infos` although only `slack_lce` had run, so
  slacks unique to `b` ended up in `intervals` without an info (orphans that
  later joins discard). `inject_slack_for_join` now runs first (line 612) —
  injecting a fresh existential column with its defining row does not change
  the concretization, so this is exact — and both operands share the same
  infos, making `infos = x.infos` correct and preserving both sides' slack
  constraints through the meet.

### 3. `RationalInterval.compare` was not a total order

**File:** `src/cdomains/apron/subpoly/intervals/rationalinterval.ml`, lines **16–28**

The old `compare` returned `1` for *every* mixed-shape pair — including a
half-bounded interval compared with itself, so `compare x x <> 0` and
antisymmetry was broken, and `compare` disagreed with `equal`. This poisons
every derived `ord` up the chain (`interval_map` → core `t` →
`VarManagementOps` `t`), and subpoly registers itself **path-sensitive**, so
path sets are keyed by exactly this comparison (risk: lost/duplicated path
states, nondeterministic precision, potential unsoundness).

Fixed with `compare_bound_opt` (19–24): `None` is −∞ in the lower position
and +∞ in the upper position; lexicographic on (lower, upper).

### 4. `slack_lce` collapsed vectors to length 1 for slack-free operands

**File:** `src/cdomains/apron/subpoly/subPolyhedraCore.apron.ml`, lines **461–472** (inside `slack_lce`)

When neither operand had any slack, `find_next_slack_idx` answered `0`, so
the common width became `0 + 1 = 1` and `remap_vector_sparse` rebuilt every
affeq row into a length-1 vector — `set_nth` then raises `Invalid_argument`,
or (for a 1-variable env) variable coefficients get folded into the constant
slot, turning feasible states bottom. Latent in practice only because
`assert_type_bounds` gives every tracked variable a bound slack.

Now the width is taken from the operands' actual matrix width
(`Matrix.num_cols`) when both mappings are empty; if neither has a row,
nothing gets remapped and the value is irrelevant.

### 5. `leq` dropped constraining orphan slacks from the right operand

**File:** `src/cdomains/apron/subpoly/subPolyhedraCore.apron.ml`, lines **576–603** (outer `leq`)

Both the cheap check and the fallback drop *orphan* slacks (interval but no
info) from **both** sides via `forget_vars`/`slack_lce`. Dropping from the
left operand only enlarges `a` — sound for `a ⊑ b`. Dropping from the
**right** operand enlarges `b`, the unsound direction: an orphan can still
constrain `b` through matrix rows that survived Gaussian elimination (e.g.
`s - y = 0` left over from eliminating `x` out of `{s = x, y = x}` with
`s ∈ [0,10]` still bounds `y`). A wrongly-true `leq` lets the solver
stabilize on a non-fixpoint.

`b_orphan_constrains` (584–589) detects a non-top orphan of `b` whose column
still occurs in `b`'s matrix; in that case `leq` answers `false`
conservatively (only a definitely-bottom `a` is still below everything,
line 590–591). Orphans whose column vanished from the matrix constrain
nothing but themselves and remain safe to drop.

### 6. `SUP` made a distinct case in `meet_tcons` (precision)

**File:** `src/cdomains/apron/subpoly/subPolyhedraDomain.apron.ml`, lines **530–537**

`SUP` (`expr > 0`) was folded into `SUPEQ` (`expr >= 0`) — sound, but every
`<`/`>` guard maps to `SUP` and check-negation flips `SUPEQ` into `SUP`, so
zero-margin checks were never provable ("margin of one" in the old test
comments). Over integer variables `expr > 0 ⟺ expr >= 1`, *provided* the
expression is integer-valued — which rational coefficients (from division by
constants) can break. The fix scales the vector by the **lcm of the
coefficient denominators** (an equivalent constraint with integer
coefficients, hence integer-valued) and asserts interval `[1, ∞)` instead of
`[0, ∞)`.

`EQ` (affeq equality row, line 528) and `SUPEQ` (line 529) are unchanged;
`DISEQ`/`EQMOD` still soundly give up (line 538).

**Tests updated:**
- `tests/regression/90-subpoly/09-widen-equality.c` — zero-margin checks
  `j-k <= 0` / `j-k >= 0` now `SUCCESS`; `j == k` stays `UNKNOWN` (its
  negation is `DISEQ`, non-convex — comment corrected).
- `tests/regression/90-subpoly/12-assign-stale-info.c` — `x+y >= 5`
  zero-margin now `SUCCESS`.
- `tests/regression/90-subpoly/02-normalization.c` — drive-by: the `PARAM:`
  header was wrapped across two comment lines, so runners fed the *filename*
  as the value of `--set sem.int.signed_overflow`; joined onto one line.

---

## Batch 1 — from the archived `claude_subpoly_fixes` (commits `097c89643..08a26a52a`)

### 7. Widening implemented (loops used to crash on `failwith`)

**Files:**
- `src/cdomains/apron/subpoly/subPolyhedraCore.apron.ml`:
  `inject_slack_for_widen` **495–503** (asymmetric Step 1: `a`'s slacks are
  injected into `b`, never the reverse), `interval_widen` **512–522**
  (`VarMap.merge`; keys present on only one side are dropped), `widen`
  **631–653** (left operand only normalized, right operand reduced —
  reducing the left would make stable bounds look unstable; b-only slacks
  are collected as `lost_vars` and compacted away, keeping the slack count
  bounded by the first iterate, which is the termination argument).
- `src/cdomains/apron/subpoly/subPolyhedraDomain.apron.ml`: D-level `widen`
  **307–322** (env lce + dim_add, mirrors `join`), `narrow` **352**
  (identity — sound, since `b ⊑ a` holds at narrowing points).
- `src/cdomains/apron/subpoly/intervals/intervalsig.ml`: `val widen` **47**.
- `src/cdomains/apron/subpoly/intervals/rationalinterval.ml`: interval
  widening **123–126** (keep a stable bound, jump to ±∞ otherwise).

**Tests:** `90-subpoly/08` … `90-subpoly/11` (stable slack survives; stable
affeq equality survives `linear_disjunct`; join-inside-loop bound survives;
loop-born slack is dropped and columns compacted).

### 8. Bottom detection in `meet_tcons` via reduction

**File:** `src/cdomains/apron/subpoly/subPolyhedraDomain.apron.ml`, lines **500–514** (`reduce_to_bot`) and its use at **528–537**

Following the paper (§3.5), a subpolyhedron is bottom iff after reduction one
component is bottom. Contradictions *between* the affeq and the intervals
(e.g. `j - k = 0` vs a fresh slack `j - k >= 1`) are only visible to the LP,
so `reduce` now runs after every asserted `EQ`/`SUPEQ`/`SUP` constraint; the
reduced state is kept (reduction is semantics-preserving and tightened
intervals help later dedup meets).

### 9. `linear_disjunct` repairs (shared `ListMatrix`, also used by affeq)

**File:** `src/cdomains/affineEquality/sparseImplementation/listMatrix.ml`

- **459**: sign fix in `sub_and_last_aux` — the `[], (i,v)::xs` case now
  negates the value like its sibling case (column subtraction was wrong when
  the first column ran out first).
- **421–425** (`keep_rows_above`) and its use at **509–525**: in the
  `(1,0)` / `(0,1)` cases only the matrix owning the pivot loses its pivot
  row, and only result rows *above* the current row receive the other
  matrix's column (mirrors the dense reference implementation's
  `if i < r` guard); previously rows were removed from all three matrices,
  losing equalities.
- **530**: `pseudoempty` sized with `max (num_rows m1) (num_rows m2)`
  (was `m1` twice).
- **533**: unused all-zero result slots are removed (`remove_zero_rows`) —
  downstream `is_covered_by` relies on row counts of rref matrices.

**Test:** `tests/regression/63-affeq/22-join-sparse-disjunct.c` (new; joins
whose equalities span multiple pivots). The whole 63-affeq suite guards
against regressions in the shared code.

### 10. Cosmetics / debuggability (no semantic change)

- Readable `show` for sparse vectors (`sparseVector.ml` **120–135**, padded
  columns) and matrices (`listMatrix.ml` **49–52**, one row per line).
- Pretty state printing in the core (`subPolyhedraCore.apron.ml` **263–280**).
- `--trace subpoly` instrumentation: `reduce` wrapper (core **390–395**),
  `join`/`widen` traces (core), `meet`/`join`/`leq`/`assign_texpr`/
  `add_slack_constraint` traces (domain).

### 11. Superseded on this branch

Batch 1 changed `substitute_expr`'s fold seed from `empty ()` to
`{d with affeq = empty}` so intervals/infos survive the matrix rebuild
(the `empty ()` seed reset `num_slacks` to 0 and corrupted the column
layout). Batch 2's rewrite (fix 1) replaces that code entirely and also
solves the deeper stale-info problem.

---

## Known remaining gaps (not fixed here)

- `unify` and `invariant` are still `failwith` at the D level — multithreaded
  programs (privatization calls `unify`) and witness generation will crash.
- D-level `meet`'s `is_top_env` shortcuts return the other operand without
  unifying environments.
- `normalize_info` divides by the gcd of *numerators* only, so scaled
  rational constraints (e.g. `(2/3)x+(2/3)y`) don't canonicalize to the same
  info as `x+y` — dedup/join matching misses them (precision only).
- Hints (paper Step 3 join/widen recovery, threshold widening) are not yet
  implemented — that is the `hints_` part of this branch's name.
