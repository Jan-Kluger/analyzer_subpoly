// SKIP PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
// Assignments: s := a + b is recorded as the affine equality s - a - b = 0.
// Together with the slack a+b >= 3 the reduction (run at the join) must bound s.

#include <goblint.h>

int main(void) {
    int a;
    int b;
    int r;
    int s;

    __goblint_assume(a + b >= 3); // slack: a+b in [3, inf)

    s = a + b;                    // affeq row: s - a - b = 0

    if (r) { } else { }           // join triggers the simplex reduction

    __goblint_check(s >= 2);  // SUCCESS: reduce derives s >= 3
    __goblint_check(s <= 10); // UNKNOWN

    return 0;
}
