// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none

#include <goblint.h>

/*
Needed stubs/functions:

* Everything from 04-two-sided-bounds.c
* SubPolyDomain.join
* RationalInterval.join
* SubPolyDomain.leq
* SubPolyDomain.copy
* Slack info equality/renaming
* Environment alignment for joins
*/

int main(void) {
    int x;
    int y;
    int c;

    if (c) {
        __goblint_assume(x - y <= 0);
    } else {
        __goblint_assume(x - y <= 5);
    }

    __goblint_check(x - y <= 5); // SUCCESS

    return 0;
}
