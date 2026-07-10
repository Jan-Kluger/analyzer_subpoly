// SKIP PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
// Widen combined with join: the loop body joins two branches bounding the same
// linear form x-y; the joined bound (-inf, 5] equals the entry bound, so it is
// stable and must survive the widening at the loop head.

#include <goblint.h>

int main(void) {
    int x;
    int y;
    int r;
    int t;

    __goblint_assume(x - y <= 5);

    while (t) {
        if (r) {
            __goblint_assume(x - y <= 0);
        } else {
            __goblint_assume(x - y <= 5);
        }
    }

    __goblint_check(x - y <= 6); // SUCCESS: stable joined bound survives widening
    __goblint_check(x - y <= 4); // UNKNOWN: only the then-branch bound was tighter

    return 0;
}
