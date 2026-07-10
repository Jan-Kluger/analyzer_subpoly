// SKIP PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
// Slack dedup: repeated constraints on the same linear form must update one
// slack (interval meet), not insert duplicates. Checks are proven when the
// negated constraint contradicts the stored slack interval.

#include <goblint.h>

int main(void) {
    int a;
    int b;

    __goblint_assume(a + b >= 3);         // fresh slack: a+b in [3, inf)
    __goblint_assume(a + b >= 5);         // same info: meet -> [5, inf)
    __goblint_assume(2 * a + 2 * b >= 4); // normalizes to a+b >= 2: interval stays [5, inf)

    __goblint_check(a + b >= 4); // SUCCESS
    __goblint_check(a + b >= 9); // UNKNOWN

    return 0;
}
