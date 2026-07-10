// SKIP PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
// Widening on the affeq component (paper Fig. 5b): an equality stable across
// iterations (j - k = 0) survives linear_disjunct. The relation perturbed by
// the loop body (i >= k) is lost because Step 3 (recovery) is deliberately not
// implemented. Note: checks need a margin of one because SUP is approximated
// by SUPEQ, so the negation of a zero-margin check never contradicts.

#include <goblint.h>

int main(void) {
    int i;
    int j;
    int k;
    int r;

    i = k;
    j = k;

    while (r) {
        i++;
    }

    __goblint_check(j - k <= 1);  // SUCCESS: j - k = 0 stable under widening
    __goblint_check(j - k >= -1); // SUCCESS: j - k = 0 stable under widening
    __goblint_check(j == k);      // UNKNOWN: zero-margin check, SUP ~ SUPEQ imprecision
    __goblint_check(i >= k);      // UNKNOWN: recovered only by Step 3, which is not implemented

    return 0;
}
