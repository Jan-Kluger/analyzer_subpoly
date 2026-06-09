# Codex implementation brief: SubPoly abstract domain without hint support

Implement a first version of the `SubPoly` abstract domain for numerical abstract interpretation.

The implementation must model SubPoly as the reduced product of:

1. a linear equality domain, `LinEq`;
2. an interval environment domain, `Intervals`.

Inequalities must be represented using slack variables. Do not implement hint generation or hint consumption. Do not implement basis-exploration reduction. Reduction must be limited to Simplex-based reduction; for the first iteration, an identity reducer is acceptable behind the same reducer interface.

## 1. Scope

Implement:

* `Interval`
* `LinearExpr`
* `LinearEquality`
* `LinEqState`
* `IntervalState`
* `SubPolyState`
* slack-variable creation and metadata
* assumption of linear equalities
* assumption of linear inequalities via slack variables
* assignment of linear expressions
* pairwise meet
* SubPoly join without hints
* SubPoly widening without hints
* approximation-order check using slack-variable matching by `info`
* reduction interface
* identity reduction as the initial reducer
* Simplex-based reduction as the intended concrete reducer
* tests for the core cases

Do not implement:

* program-text hints
* template hints
* planar convex hull hints
* basis-exploration reduction
* combinatorial reduction
* any polyhedral generator/constraint dual representation
* nonlinear arithmetic

## 2. Numeric representation

Use exact rationals for all coefficients and interval bounds.

Recommended representation:

```text
Rational = arbitrary-precision rational
Bound = -∞ | finite Rational | +∞
Interval = [lower: Bound, upper: Bound]
```

All arithmetic must be sound over rationals. Infinite bound arithmetic must be handled explicitly.

## 3. Core data types

### 3.1 Variables

```text
Variable {
    id: stable unique identifier
    name: string
    kind: Program | Slack
}
```

Slack variables must have associated metadata:

```text
SlackInfo {
    slack: Variable
    info: LinearExpr
}
```

The `info` expression is the linear form represented by the slack variable.

For an inequality:

```text
a1*x1 + ... + an*xn <= c
```

create a fresh slack variable `β` and encode:

```text
a1*x1 + ... + an*xn - c = β
β ∈ [-∞, 0]
info(β) = a1*x1 + ... + an*xn - c
```

For:

```text
a1*x1 + ... + an*xn >= c
```

normalize it to:

```text
-(a1*x1 + ... + an*xn) <= -c
```

then encode using the same `<=` form.

### 3.2 Linear expressions

```text
LinearExpr {
    terms: Map<Variable, Rational>
    constant: Rational
}
```

Canonicalize every expression:

* remove zero coefficients;
* keep variables sorted by stable id for deterministic output;
* normalize equality rows where useful.

Operations:

```text
add(expr1, expr2)
sub(expr1, expr2)
mul(k, expr)
evalInterval(expr, IntervalState) -> Interval
substitute(expr, variable, replacementExpr) -> LinearExpr
variables(expr) -> Set<Variable>
```

### 3.3 Linear equalities

Represent equality as:

```text
LinearEquality {
    expr: LinearExpr
}
```

with semantic meaning:

```text
expr == 0
```

For example:

```text
x - y - β == 0
```

means:

```text
x - y = β
```

### 3.4 Linear equality state

```text
LinEqState {
    isBottom: bool
    rows: MatrixOrRowSet
}
```

The implementation should support:

```text
top()
bottom()
meetEq(equality)
join(other)
widen(other)
containsImpliedEquality(eq)
droppedEqualitiesComparedTo(joinedState)
renameVariables(mapping)
variables()
toRowEchelon()
```

For the first implementation, `LinEq.join` may be implemented by computing the affine hull of two equality systems using standard linear algebra over rationals.

The equality domain should maintain a canonical row-echelon form after each mutating operation if practical. If that is too expensive initially, canonicalize at comparison and join boundaries.

### 3.5 Interval state

```text
IntervalState {
    isBottom: bool
    map: Map<Variable, Interval>
}
```

Missing variable means top interval.

Operations:

```text
top()
bottom()
get(v) -> Interval
set(v, interval)
meetInterval(v, interval)
join(other)
widen(other)
renameVariables(mapping)
variables()
```

Interval join:

```text
[a,b] join [c,d] = [min(a,c), max(b,d)]
```

Interval meet:

```text
[a,b] meet [c,d] = [max(a,c), min(b,d)]
```

If lower > upper, the interval state becomes bottom.

Interval widening:

```text
old = [l0,u0]
new = [l1,u1]

lower =
    l0 if l1 >= l0
    -∞ otherwise

upper =
    u0 if u1 <= u0
    +∞ otherwise
```

### 3.6 SubPoly state

```text
SubPolyState {
    linEq: LinEqState
    intervals: IntervalState
    slackInfo: Map<Variable, LinearExpr>
}
```

A state is bottom if reduction reveals bottom in either component.

A state is top if both components are top and no equality or non-top interval is present.

## 4. Reduction

Expose this interface:

```text
Reducer {
    reduce(state: SubPolyState) -> SubPolyState
}
```

Provide two implementations:

```text
IdentityReducer
SimplexReducer
```

`IdentityReducer.reduce(state)` returns the input state, except it may perform cheap consistency checks already exposed by `LinEqState` and `IntervalState`.

`SimplexReducer` is the intended real reducer. It must refine the interval bounds of variables using linear programming.

For each variable `v` in the state:

1. solve a minimization LP for `v`;
2. solve a maximization LP for `v`;
3. meet the resulting bounds into the interval component.

The LP constraints are:

* all equalities from the `LinEqState`;
* all finite lower bounds from the interval component;
* all finite upper bounds from the interval component.

The objective is either:

```text
minimize v
```

or:

```text
maximize v
```

If the LP is infeasible, return bottom.

If the LP is unbounded in one direction, keep that side infinite.

If the LP solver uses floating-point arithmetic internally, the result must be rounded outward before being converted back into rational interval bounds. Prefer exact-rational Simplex if available.

### Simplex reduction pseudocode

```text
function reduceWithSimplex(state):
    if state.linEq.isBottom or state.intervals.isBottom:
        return bottomState()

    vars = collectVariables(state.linEq, state.intervals)

    lp = buildLpSystem()
    for eq in state.linEq.rows:
        lp.addEquality(eq)

    for v in vars:
        interval = state.intervals.get(v)

        if interval.lower is finite:
            lp.addLowerBound(v, interval.lower)

        if interval.upper is finite:
            lp.addUpperBound(v, interval.upper)

    refined = state.copy()

    for v in vars:
        minResult = simplexOptimize(lp, objective = v, direction = Minimize)

        if minResult.status == Infeasible:
            return bottomState()

        if minResult.status == Optimal:
            refined.intervals.meetInterval(
                v,
                [outwardLower(minResult.value), +∞]
            )

        maxResult = simplexOptimize(lp, objective = v, direction = Maximize)

        if maxResult.status == Infeasible:
            return bottomState()

        if maxResult.status == Optimal:
            refined.intervals.meetInterval(
                v,
                [-∞, outwardUpper(maxResult.value)]
            )

        if refined.intervals.isBottom:
            return bottomState()

    return refined
```

## 5. Basic abstract operations

### 5.1 Creating top and bottom

```text
function topSubPoly():
    return SubPolyState(
        linEq = LinEqState.top(),
        intervals = IntervalState.top(),
        slackInfo = {}
    )

function bottomSubPoly():
    return SubPolyState(
        linEq = LinEqState.bottom(),
        intervals = IntervalState.bottom(),
        slackInfo = {}
    )
```

### 5.2 Assume equality

For an assumption:

```text
expr == 0
```

do:

```text
function assumeEquality(state, expr, reducer):
    state.linEq.meetEq(LinearEquality(expr))
    return reducer.reduce(state)
```

### 5.3 Assume inequality

For:

```text
expr <= 0
```

do:

```text
function assumeLessEqualZero(state, expr, reducer):
    beta = freshSlackVariable()
    state.slackInfo[beta] = expr

    equalityExpr = expr - beta
    state.linEq.meetEq(LinearEquality(equalityExpr))

    state.intervals.meetInterval(beta, [-∞, 0])

    return reducer.reduce(state)
```

For:

```text
expr <= c
```

call:

```text
assumeLessEqualZero(expr - c)
```

For:

```text
expr >= c
```

call:

```text
assumeLessEqualZero(c - expr)
```

## 6. Assignment

Assignment must update both the equality and interval components soundly.

For:

```text
x := expr
```

the simplest correct first implementation is forget-and-assume:

```text
function assign(state, x, expr, reducer):
    state = forgetVariable(state, x)
    equality = x - expr == 0
    state.linEq.meetEq(equality)
    state.intervals.set(x, evalInterval(expr, state.intervals))
    return reducer.reduce(state)
```

`forgetVariable` must existentially eliminate `x` from the equality component and remove the interval binding for `x`.

If `expr` mentions `x`, evaluate and substitute using the old state before forgetting `x`.

Pseudocode:

```text
function assign(state, x, expr, reducer):
    oldState = state.copy()
    intervalValue = evalInterval(expr, oldState.intervals)

    state = forgetVariable(state, x)

    renamedExpr = expr evaluated over old variables
    state.linEq.meetEq(LinearEquality(x - renamedExpr))
    state.intervals.set(x, intervalValue)

    return reducer.reduce(state)
```

## 7. Meet

Meet is pointwise:

```text
function meetSubPoly(a, b, reducer):
    result.linEq = a.linEq.meet(b.linEq)
    result.intervals = a.intervals.meet(b.intervals)
    result.slackInfo = mergeSlackInfo(a.slackInfo, b.slackInfo)

    return reducer.reduce(result)
```

If the same slack variable id appears in both states, its `info` must be identical. If not, rename one side before merging.

## 8. Join without hint support

Join has three steps:

1. saturate both operands with missing slack-variable information;
2. reduce both saturated operands and perform pointwise join;
3. recover dropped linear equalities when their linear form evaluates to a non-top interval in the opposite branch.

Do not add any additional precision-recovery mechanism beyond step 3.

### 8.1 Saturation

For every slack variable present in one operand but absent in the other, add its defining equality to the other operand.

```text
β = info(β)
```

In row form:

```text
β - info(β) == 0
```

Pseudocode:

```text
function saturateWithSlackInfo(target, sourceSlackInfo):
    result = target.copy()

    for beta, infoExpr in sourceSlackInfo:
        if beta not in result.slackInfo:
            result.slackInfo[beta] = infoExpr
            result.linEq.meetEq(LinearEquality(beta - infoExpr))

    return result
```

### 8.2 Join pseudocode

```text
function joinSubPoly(s0, s1, reducer):
    if s0.isBottom:
        return s1

    if s1.isBottom:
        return s0

    a0 = saturateWithSlackInfo(s0, s1.slackInfo)
    a1 = saturateWithSlackInfo(s1, s0.slackInfo)

    r0 = reducer.reduce(a0)
    r1 = reducer.reduce(a1)

    joinedLinEq = r0.linEq.join(r1.linEq)
    joinedIntervals = r0.intervals.join(r1.intervals)

    result = SubPolyState(
        linEq = joinedLinEq,
        intervals = joinedIntervals,
        slackInfo = mergeSlackInfo(r0.slackInfo, r1.slackInfo)
    )

    dropped0 = r0.linEq.droppedEqualitiesComparedTo(joinedLinEq)
    dropped1 = r1.linEq.droppedEqualitiesComparedTo(joinedLinEq)

    result = recoverDroppedEqualities(
        result,
        droppedFromLeft = dropped0,
        oppositeState = r1,
        originalStateForSlackBounds = r0
    )

    result = recoverDroppedEqualities(
        result,
        droppedFromLeft = dropped1,
        oppositeState = r0,
        originalStateForSlackBounds = r1
    )

    return reducer.reduce(result)
```

### 8.3 Recovery of dropped equalities

Given a dropped equality:

```text
κ: expr == 0
```

let:

```text
programPart = expression using only program variables
slackVars = slack variables appearing in κ
```

Support two cases only:

1. `κ` contains no slack variable;
2. `κ` contains exactly one slack variable.

Ignore equalities containing two or more slack variables.

#### Case A: no slack variable

If `expr` evaluates to a non-top interval in the opposite branch, add a fresh slack variable.

```text
β = expr
β ∈ interval(expr in opposite) join [0,0]
```

Pseudocode:

```text
function recoverNoSlack(result, eq, oppositeState):
    interval = evalLinearExprInSubPoly(eq.expr, oppositeState)

    if interval.isTop:
        return result

    beta = freshSlackVariable()
    result.slackInfo[beta] = eq.expr

    result.linEq.meetEq(LinearEquality(beta - eq.expr))
    result.intervals.meetInterval(beta, interval.join([0,0]))

    return result
```

#### Case B: exactly one slack variable

If the non-slack part evaluates to a non-top interval in the opposite branch, re-add the equality and join the slack interval.

For equality:

```text
sκ + cβ*β == 0
```

solve the implied interval for `β`:

```text
β = -(sκ) / cβ
```

Then join that interval with the slack interval from the branch where the equality was dropped.

Pseudocode:

```text
function recoverOneSlack(result, eq, oppositeState, originalStateForSlackBounds):
    beta = the only slack variable in eq
    coeff = coefficientOf(eq.expr, beta)

    rest = eq.expr without beta
    restInterval = evalLinearExprInSubPoly(rest, oppositeState)

    if restInterval.isTop:
        return result

    betaIntervalInOpposite = divideInterval(mulInterval(restInterval, -1), coeff)
    betaIntervalInOriginal = originalStateForSlackBounds.intervals.get(beta)

    recoveredInterval = betaIntervalInOpposite.join(betaIntervalInOriginal)

    result.linEq.meetEq(eq)
    result.intervals.meetInterval(beta, recoveredInterval)

    return result
```

### 8.4 Full recovery pseudocode

```text
function recoverDroppedEqualities(
    result,
    droppedFromLeft,
    oppositeState,
    originalStateForSlackBounds
):
    for eq in droppedFromLeft:
        slackVars = slackVariables(eq.expr)

        if slackVars.size == 0:
            result = recoverNoSlack(result, eq, oppositeState)

        else if slackVars.size == 1:
            result = recoverOneSlack(
                result,
                eq,
                oppositeState,
                originalStateForSlackBounds
            )

        else:
            continue

    return result
```

## 9. Widening without hint support

Widening is similar to join, but asymmetric.

Given:

```text
oldState ▽ newState
```

do:

1. propagate slack-variable information from `oldState` to `newState` only where needed;
2. reduce the new state;
3. apply pointwise widening;
4. recover dropped equalities only from the old state.

Pseudocode:

```text
function widenSubPoly(oldState, newState, reducer):
    if oldState.isBottom:
        return newState

    if newState.isBottom:
        return oldState

    widenedOld = oldState.copy()
    widenedNew = newState.copy()

    for beta, infoExpr in oldState.slackInfo:
        if beta not in widenedNew.slackInfo:
            widenedNew.slackInfo[beta] = infoExpr
            widenedNew.linEq.meetEq(LinearEquality(beta - infoExpr))

    reducedNew = reducer.reduce(widenedNew)

    widenedLinEq = widenedOld.linEq.widen(reducedNew.linEq)
    widenedIntervals = widenedOld.intervals.widen(reducedNew.intervals)

    result = SubPolyState(
        linEq = widenedLinEq,
        intervals = widenedIntervals,
        slackInfo = mergeSlackInfo(widenedOld.slackInfo, reducedNew.slackInfo)
    )

    droppedOld = widenedOld.linEq.droppedEqualitiesComparedTo(widenedLinEq)

    result = recoverDroppedEqualitiesForWidening(
        result,
        droppedOld,
        reducedNew,
        widenedOld
    )

    return reducer.reduce(result)
```

Recovery for widening follows the same two supported cases as join, except interval combination uses interval widening instead of interval join.

For no-slack equality:

```text
β = κ
β ∈ [0,0] widen eval(κ, newState)
```

For one-slack equality:

```text
β ∈ oldInterval(β) widen evalDerivedBetaInterval(κ, newState)
```

## 10. Approximation order

Implement a practical order check, not a full polyhedral inclusion check.

For:

```text
s0 <= s1
```

try to construct an injective mapping from slack variables in `s0` to slack variables in `s1` such that matching slack variables have identical `info` expressions.

Then rename `s0` through this mapping and check pointwise order:

```text
renamed(s0).linEq <= s1.linEq
renamed(s0).intervals <= s1.intervals
```

Pseudocode:

```text
function lessEqualSubPoly(s0, s1):
    mapping = {}

    for beta0, info0 in s0.slackInfo:
        candidates = []

        for beta1, info1 in s1.slackInfo:
            if info0 == info1 and beta1 not in mapping.values:
                candidates.append(beta1)

        if candidates.isEmpty:
            return false

        mapping[beta0] = chooseDeterministically(candidates)

    renamed = renameVariables(s0, mapping)

    return renamed.linEq.lessEqual(s1.linEq)
        and renamed.intervals.lessEqual(s1.intervals)
```

## 11. Linear-expression interval evaluation

Evaluation must use the reduced state.

```text
function evalLinearExprInSubPoly(expr, state):
    reduced = currentReducer.reduce(state)
    return evalInterval(expr, reduced.intervals)
```

For internal calls where the caller already reduced the state, avoid reducing twice.

Interval expression evaluation:

```text
function evalInterval(expr, intervals):
    result = [expr.constant, expr.constant]

    for variable, coeff in expr.terms:
        variableInterval = intervals.get(variable)
        termInterval = multiplyIntervalByRational(variableInterval, coeff)
        result = addIntervals(result, termInterval)

    return result
```

## 12. Control-flow fixpoint integration

The abstract interpreter should use:

```text
joinSubPoly
widenSubPoly
lessEqualSubPoly
```

at merge points and loop heads.

Basic loop pseudocode:

```text
function analyzeLoop(entryState, loopBody):
    current = bottomSubPoly()
    next = entryState

    iteration = 0

    while true:
        if iteration < wideningDelay:
            widened = joinSubPoly(current, next, reducer)
        else:
            widened = widenSubPoly(current, next, reducer)

        if lessEqualSubPoly(widened, current):
            return current

        current = widened
        next = analyzeBlock(loopBody, current)

        iteration += 1
```

For the first implementation, use `IdentityReducer` by default. Once the rest of the domain is stable, switch the default to `SimplexReducer`.

## 13. Required tests

### 13.1 Inequality representation

Input:

```text
assume x - 2*y <= 0
```

Expected internal shape:

```text
x - 2*y = β
β ∈ [-∞, 0]
info(β) = x - 2*y
```

### 13.2 Join with same slack info

Branch 1:

```text
x - y <= 0
```

Branch 2:

```text
x - y <= 5
```

Expected after join:

```text
x - y = β
β ∈ [-∞, 5]
```

Equivalent slack naming is acceptable.

### 13.3 Join recovery for dropped equality

Branch 1:

```text
x - 3*y == 0
```

Branch 2:

```text
x == 0
y == 1
```

Expected after join:

```text
x - 3*y = β
β ∈ [-3, 0]
```

### 13.4 Widening recovery

Initial:

```text
i - k == 0
```

After one iteration:

```text
i - k == 1
```

Expected widened result:

```text
i - k = β
β ∈ [0, +∞]
```

### 13.5 Bottom detection

Input:

```text
x == 0
x >= 1
```

Expected:

```text
bottom
```

This may require Simplex reduction. With `IdentityReducer`, mark this test as pending or reducer-dependent.

### 13.6 Assignment

Input:

```text
x ∈ [1, 1]
y := x + 2
```

Expected:

```text
y ∈ [3, 3]
y - x = 2
```

The exact equality row form may differ.

## 14. Acceptance criteria

The implementation is acceptable when:

1. inequalities are represented through slack variables;
2. equality and interval components are both maintained;
3. join follows saturation, pointwise join, and dropped-equality recovery;
4. widening follows the asymmetric widening algorithm;
7. the reducer interface supports identity reduction first and Simplex reduction later;
8. all core operations are deterministic;
9. all arithmetic is exact or soundly rounded outward;
10. the required tests pass, except Simplex-dependent tests may be pending while using the identity reducer.
