//SKIP PARAM: --set ana.activated[+] affeq --set sem.int.signed_overflow assume_none
// Regression test for two bugs in the sparse ListMatrix.linear_disjunct (Karr join).
//
// 1. Asymmetric pivot case (1,0)/(0,1): the row at the current row index was removed
//    from the matrix that does NOT own the pivot (and from the result) although that
//    row was never examined. With operands of different row counts every following
//    column re-entered the asymmetric case and the cascade deleted all rows, so the
//    join below lost y == z (a fact of both branches). The check must be relational:
//    a constant assignment would be proven by the base interval domain and mask the
//    affeq loss.
//
// 2. sub_and_lastterm dropped the negation in the "first column exhausted" branch, so
//    the column difference c1 - c2 had the wrong sign when c1 had no entries left.
//    The join of {s = 0, t = 0} with {s = 1, t = 1} then produced s + t = 0 instead
//    of s - t = 0, which is unsound (it excludes the reachable state s = t = 1) and
//    makes s == t unprovable.

#include <goblint.h>

int main(void) {
    int r;
    int k;
    int m;
    int x;
    int y;
    int z;

    // bug 1: operands with different numbers of rows; x = 1 gives the then branch an
    // extra pivot column between the common pivots
    if (r > 0) {
        x = 1;
        y = k;
        z = k;
    } else {
        y = m;
        z = m;
    }

    __goblint_check(y == z); // SUCCESS: holds relationally on both branches
    __goblint_check(x == 1); // UNKNOWN: only holds on the then branch

    // bug 2: operands differing only in the constant column
    int s;
    int t;
    if (r > 0) {
        s = 0;
        t = 0;
    } else {
        s = 1;
        t = 1;
    }

    __goblint_check(s == t); // SUCCESS
    __goblint_check(s == 0); // UNKNOWN: only holds on the then branch

    return 0;
}
