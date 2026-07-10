// SKIP PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
// Join of two branches carrying the same linear form with different bounds
// (paper Fig. 4a): slack_lce matches the slacks by info, interval join keeps
// the weaker bound x-y <= 5.

#include <goblint.h>

int main(void) {
    int x;
    int y;
    int r;

    if (r) {
        __goblint_assume(x - y <= 0);
    } else {
        __goblint_assume(x - y <= 5);
    }

    __goblint_check(x - y <= 6); // SUCCESS: joined slack has x-y in (-inf, 5]
    __goblint_check(x - y <= 0); // UNKNOWN: only held on the then-branch

    return 0;
}
