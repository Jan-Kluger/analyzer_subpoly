// SKIP PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
// Invertible assignment x = x + 1: the slack recorded for x+y must have its
// info re-expressed over the new x (the matrix row becomes s = x+y-1). With a
// stale info the second assume meets the wrong slack interval, effectively
// claiming x+y >= 6 and marking the then-branch dead -- but it is reachable
// (x_old=2, y=2).

#include <goblint.h>

int main(void) {
    int x;
    int y;

    __goblint_assume(x + y >= 3); // slack: x+y in [3, inf)
    x = x + 1;                    // slack constraint must become x+y >= 4
    __goblint_assume(x + y >= 5); // dedup against the re-added slack: [5, inf)

    __goblint_check(x + y >= 5); // SUCCESS
    __goblint_check(x + y >= 6); // UNKNOWN: x+y == 5 is possible

    if (x + y == 5) {
        __goblint_check(1); // SUCCESS: reachable, must not be dead code
    }

    return 0;
}
