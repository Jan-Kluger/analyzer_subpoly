---
marp: true
theme: default
paginate: true
size: 16:9
---

<!--
TEMPLATE NOTES
This file is a Marp-flavored Markdown deck (works with Marp CLI / Marp for VS Code,
and can be adapted to Slidev or reveal-md with minimal changes).
Each slide is separated by `---`. Replace [bracketed] placeholders with real content,
and swap `Bla.` / TBD markers for the finished material.
-->

# Subpolyhedra

Leonie Houzer, Yannick Schürmann, Nicolas Roth, Florin-Vlad Sabău  
16.07.2026 

---

# Polyhedra

$a_0 \cdot x_0 + \ldots + a_n \cdot x_n \le c$  
*e.g.* $-x + 5y - 4z - 9 \le 0$

# Subpolyhedra

<u>idea</u>: combine linear equalities & intervals

linear equalities: $a_0 \cdot x_0 + \ldots + a_n \cdot x_n + c = 0$ $\longrightarrow$ quite cheap to compute

instead of storing  $a_0 \cdot x_0 + \ldots + a_n \cdot x_n \le c$
we store  $a_0 \cdot x_0 + \ldots + a_n \cdot x_n = \beta$ and $\beta \in [-\infty, c]$.    [$\beta$ is called a slack variable]

In the linear equalities we always have $=0$. Therefore we store
$a_0 \cdot x_0 + \ldots + a_n \cdot x_n - \beta = 0$ instead of $a_0 \cdot x_0 + \ldots + a_n \cdot x_n = \beta$.

---

# Our Data type for the subpoly

<u>we need to store:</u>

- the linear equalities $\Rightarrow$ Reuse the matrix from affine equality dense
- the intervals $\Rightarrow$ Map: maps every slack variable to an interval
- somehow remember what is a slack variable and for which equality is it $\Rightarrow$ Map: maps every slack variable to an info (basically the row entries)

```ocaml
type t = {
  affeq: affeq;
  intervals: interval_map;
  infos: info_map;
}
```
---
Decisions at the start:
- No Apron names for slacks, we need to do all bookkeeping of slacks
- Reuse the sparse `ListMatrix`/`SparseVector` kit from the affeq domain
- Use Exact rationals everywhere
- Canonical infos: gcd/lcm-scaled, sign-normalized


---

# Overview

- dim_add, dim_remove
- forget_var
- assign-Functions + simplify texpr
- <mark>join</mark>, meet, <mark>leq</mark> + <mark>slack_lce</mark>
- <mark>widen</mark>, narrow, unify
- bound_texpr
- assert_constraint + meet_tcons
- <mark>reduce</mark>

---



## Outline (TODO)

1. What is Subpoly?
2. How We Model Subpoly
3. Previous Attempts
4. Modelling Improvements
5. Domain Operations (Meet / Join / Reduce / Leq)
6. Benchmarking
7. Drawbacks & Troubles
8. Outlook

---

## What is Subpoly?

SubPoly = LinEq ⊗ Intv
Inequalities become **equalities over slack variables + interval bounds**:

$$\textstyle\sum a_i x_i \le c \;\Longleftrightarrow\; \beta = \sum a_i x_i \;\wedge\; \beta \in (-\infty, c]$$

Our state (`subPolyhedraCore`):

| Field | Content |
|---|---|
| `affeq` | sparse rref matrix of affine equalities (program + slack columns) |
| `intervals` | slack var → rational interval |
| `infos` | slack var → canonical defining linear form (`info(β)`) |


---

## Our type & early design decisions

```ocaml
type t = {
  affeq:     Matrix.t;          (* sparse rref matrix: [prog vars | slack vars | const] *)
  intervals: I.t VarMap.t;      (* slack var > rational interval            *)
  infos:     info VarMap.t;     (* slack var > canonical info     *)
}
```

Decisions at the start:

- No Apron names for slacks, we need to do all bookkeeping of slacks
- Reuse the sparse `ListMatrix`/`SparseVector` kit from the affeq domain
- Use Exact rationals everywhere
- Canonical infos: gcd/lcm-scaled, sign-normalized
---



## Reduce

- Uses **LP (Linear Programming)** to find new bounds
- ⚠️ Currently **expensive** — [maybe try to find a cheaper approach]
- Key win: **no imprecision errors** like in the reference paper
- [Add complexity/cost notes, ideas for optimization]

---

## Slack_lce

- Maps indices of two states into shared states
- Slack variables are matched on canonical info field
- Has to drop all slack variables with an interval bound but no info!
- Most initial bugs lived there
- Used before every binary operation
- Can be avoided using canonical slack naming
  &rarr; let apron handle indices!

---

## Join


1. **Propagate slack info:** for every slack $\beta$ known to only one operand, add $\beta = \mathrm{info}(\beta)$ to the other
2. **Pairwise join** on the reduced operands: LinEq join (affine hull) ⊗ interval join
3. **Recover lost equalities:** each equality $\kappa$ dropped by the hull whose linear form is also bounded in the other operand is re-added.

---



## Join — our code

```
join a b =
  slack_lce a b                 (* shared slack indices, matched on info *)
  |> inject_slack_for_join      (* Step 1: β = info(β) into both sides   *)
  |> reduce both operands       (* saturate via LP                       *)
  matrix:    Matrix.linear_disjunct   (* Karr's affine hull *)
  intervals: interval_join            (* pointwise I.join   *)
```

- Bottom operands short-circuit: join with ⊥ returns the other side
- Step 3 (recovering dropped equalities) is **not implemented** on master

---

## Leq

The precise order is too expensive.

The paper uses a weaker order $\sqsubseteq_S$ instead:

1. **Match slacks:** find an injective renaming $\theta$ of the slack variables of $s_0$ into those of $s_1$ with $\mathrm{info}(\beta) = \mathrm{info}(\theta(\beta))$
2. **Pairwise order** after renaming: LinEq inclusion ⊗ interval inclusion

$\sqsubseteq_S \subsetneq \sqsubseteq_S^*$ — may cause extra widening steps (precision loss), but suffices to detect fixpoints in practice.

---

## Leq — our code

```
leq a b =
  reduce a, reduce b                               (* needed for valid widen *)
  forget top-interval slacks + a's no-info slacks
  non_info_entailment a b       
  slack_lce + normalize both matrices
  check:  injective infos  ∧  intervals pointwise I.leq
          ∧  Matrix.is_covered_by b a
```

- `slack_lce` takes care of injective renaming
- Extra `non_info_entailment` step: slacks with a bound but no info can't be renamed, so entailment is checked semantically via LP - expensive!
- `reduce` needed, also expensive! `leq old (widen old new)` crashes
- leq one of the biggest headaches!

---


## Conclusions & Results

### Benchmarking

- Benchmarks to be presented [tomorrow / insert date]
- Comparing: **Subpoly** vs **Fable** vs **Poly**
- [Insert benchmark table / chart here]

---

## Drawbacks / Troubles
 
 Paper was sometimes very underspecified:
 | Paper says | Paper doesn't say |
|---|---|
| slacks have `info(β)` | how info changes during Gauss elimination, renaming, substitution |
| Step 3 re-adds "dropped equalities"  | how to compute what the pairwise join dropped |

The paper does not specify a narrow algorithm.
Variable removal forced an invention the paper never names: **non-info slacks** -
interval survives, info is dropped, defining row is eliminated.

---
## Outlook

- Bugfixes & efficiency improvements done with Claude's help
- Take a closer look at **Fable's** approach
- Hints give a **big boost** :))
- [Next steps / future work]

---

## Questions?

[Contact / links / repo]
