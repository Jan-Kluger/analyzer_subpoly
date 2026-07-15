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

## Polyhedra
Inequalities of the form: 
$$\sum a_i x_i \le c$$


<span style="color: #606060;">*e.g.* $-x + 5y - 4z \le 9$</span>

## Linear Equalities
Equalities of the form:
$$(\sum a_i x_i ) +c = 0$$

$\longrightarrow$ quite cheap to compute



---

## Subpolyhedra

SubPoly = LinEq ⊗ Intv
Inequalities become **equalities over slack variables + interval bounds**:

$$\textcolor{#C2185B}{\sum a_i x_i}  \le \textcolor{green}{c}  \;\Longleftrightarrow\; \textcolor{#C2185B}{\sum a_i x_i} \textcolor{orange}{= \beta} \;\wedge\; \textcolor{orange}{\beta} \in (-\infty, \textcolor{green}{c}]$$

#### Example:
$$\textstyle \textcolor{#C2185B}{2x +3y -7z} \le \textcolor{green}{67} 
\;\Longleftrightarrow\;  \textcolor{#C2185B}{2x +3y -7z} \textcolor{orange}{ = \beta}  \;\wedge\; \textcolor{orange}{\beta} \in (-\infty, \textcolor{green}{67}]$$
 
$\longrightarrow$  $\textcolor{orange}{\beta}$ is called a **slack variable**

In the linear equalities we always have $=0$. Therefore we store $\sum a_i x_i - \beta = 0$ instead of $\sum a_i x_i = \beta$.


---

## Outline

1. Implementation
  1.1 Type representation
  1.2 Functions
2. Evaluation
  2.1 Benchmarking
  2.2 Deviations and Optimizations

---

# Implementation

---

## Our type & early design decisions

<u>We need to store:</u>
- the linear equalities
- the intervals for each slack variable
- which equality and which slack variable belong together

---

Our type (`subPolyhedraCore`):

| Field | Content |
|---|---|
| `affeq` | sparse rref matrix of affine equalities  [prog vars \| slack vars \| const]
| `intervals` | slack var → rational interval |
| `infos` | slack var → canonical defining linear form (`info(β)`) |

---

Decisions at the start:
- No Apron names for slacks, we need to do all bookkeeping of slacks
- Reuse the sparse `ListMatrix`/`SparseVector` kit from the affeq domain
- Use Exact rationals everywhere (no float)
- Canonical infos

---

# Functions

- dim_add, dim_remove
- forget_var
- assign-Functions + simplify texpr
- <mark>join</mark>, meet, <mark>leq</mark> + <mark>slack_lce</mark>
- <mark>widen</mark>, narrow, unify
- bound_texpr
- assert_constraint + meet_tcons
- <mark>reduce</mark>

---




## Reduce

- Uses **LP (Linear Programming)** to find new bounds
- Basic Algorithm:
  - Setup the simplex, 
  - Make one run to make sure we are feasable
  - If feasable, complete run, update all intervals and return new domain
- Currently **expensive**
- Key win: **no imprecision errors** like in the reference paper, since we use rationals, not float

---
## Other Reduction Strategies

- Paper present Linear programming approach (which we went with)
- Also descibes a "Base exploration approach" which we did not consider
- Fable branch implements novel approach, which is surprisingly efficient

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

 May cause extra widening steps (precision loss), but suffices to detect fixpoints in practice.

---

## Leq 
###### Our code

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

# Evaluation

---

# Results of our code

---

## Profiling Discrepancies
### Quick fixes
- Mpqf is FFI to c. In some of the benchmarks we spent 60% of the time building numbers
- Reduction rebuilds on every call
### Significant improvments
- Batch reductions?
- Hints provide information recovery as mentioned on join slide 

---

# Results of improved code
### Hotfixed with claude

---

## Fundemental improvments
- Canonical slack naming
  - More efficient leq 
  - Better leq passes more lattice properties together with reclamation
  - We tried this and dropped it, in hindsight could lead to improvments
- Different reduce algorithm
  - Only so much can be done with micro optimizations, Algorithm seems just inneficient
  - Novel fable reduction, Base exploration
- Better modelling of subpoly with functors 
  - more modular

---

# Comparisons of *All* Benchmarks

---
