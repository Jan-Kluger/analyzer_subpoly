// SKIP PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
// Simplex (LP) reduction: the join reduces both operands, so bounds implied by
// the affine equalities together with other slack intervals are propagated.
// From a >= 5 and b - a >= 1 the reduction must derive b >= 6.

#include <goblint.h>

int main(void) {
    int a;
    int b;
    int r;
    int e = 100;
    e = e - 10;
    int f = 13;
    e = e + f;

    __goblint_assume(a >= 5);     // slack: a in [5, inf)
    __goblint_assume(b - a >= 1); // slack: a-b in (-inf, -1] (normalized)

    // empty branch forces a join, whose reduce runs the simplex and refines
    // b's interval through the equalities: b = a - (a-b) >= 5 + 1 = 6
    if (r) { } else { }

    __goblint_check(b >= 5);  // SUCCESS: needs the reduction-derived b >= 6
    __goblint_check(b >= 42); // UNKNOWN

    return 0;
}
