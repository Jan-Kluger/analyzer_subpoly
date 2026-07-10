// SKIP PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
// A slack born inside the loop body exists only in the right widening operand:
// widen must drop it (lost_vars) and compact the slack columns. The assume and
// checks after the loop verify the column bookkeeping is still intact (a broken
// compaction makes add_slack_constraint write into the wrong column).

#include <goblint.h>

int main(void) {
    int p;
    int q;
    int t;

    while (t) {
        __goblint_assume(p + q <= 8);
    }

    __goblint_check(p + q <= 8);  // UNKNOWN: the loop may run zero times

    __goblint_assume(p - q >= 2);
    __goblint_check(p - q >= 1);       // SUCCESS: meet after widen on a compacted state
    __goblint_check(p + 3 * q <= 100); // UNKNOWN

    return 0;
}
