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
### [Subtitle — e.g. "A Slack-Based Abstract Domain"]

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



## Agenda (TODO)

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


## Previous Attempts (is this actually interesting?)

- Earlier approach used **weird slack modelling**
- [What specifically was weird / what broke]
- [Why it motivated the redesign]

---

## Modelling Improvements

- Introduced a **canonical slack representation**
- [Before → after comparison]
- [What this canonical form buys us — uniqueness, simpler ops, etc.]

---

## Domain Operations — Overview

All operations are built on the same underlying **piecewise** approach.

| Operation | Owner | Notes |
|---|---|---|
| Meet / Unify | — | Same piecewise machinery |
| Join | Nico | [details] |
| Reduce | — | Uses LP to find new bounds |
| Leq | Nico | [details] |

---

## Meet / Unify

- All the same **piecewise** thingy
- [Formal definition / pseudocode]
- [Example]

---

## Join

**Owner: Nico**

- [Algorithm summary]
- [Example / edge cases]

---

## Reduce

- Uses **LP (Linear Programming)** to find new bounds
- ⚠️ Currently **expensive** — [maybe try to find a cheaper approach]
- Key win: **no imprecision errors** like in the reference paper
- [Add complexity/cost notes, ideas for optimization]

---

## Leq

**Owner: Nico**

- [Algorithm summary]
- [Example]

---

## Conclusions & Results

### Benchmarking

- Benchmarks to be presented [tomorrow / insert date]
- Comparing: **Subpoly** vs **Fable** vs **Poly**
- [Insert benchmark table / chart here]

---

## Drawbacks / Troubles

- [Replace "Bla." with the actual pain points]
- [Known limitations]
- [Open bugs]

---

## Outlook

- Bugfixes & efficiency improvements done with Claude's help
- Take a closer look at **Fable's** approach
- Hints give a **big boost** :))
- [Next steps / future work]

---

## Questions?

[Contact / links / repo]
