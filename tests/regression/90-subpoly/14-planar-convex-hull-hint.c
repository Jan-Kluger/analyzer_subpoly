// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none

#include <goblint.h>

/*
Needed stubs/functions:

* Everything from 13-hints-template-join.c
* Planar projection of interval components
* 2D convex-hull hint generator
* Hint deduplication/bounding for termination
* Hint materialization as slack constraints
* SubPolyDomain.join/widen with hint refinement
*/

int main(void) {
    int x = 0;
    int y = 0;
    int c;

    while (c) {
        if (c) {
            x++;
            y += 100;
        } else {
            x++;
            y++;
        }
    }

    __goblint_check(y <= 100 * x); // SUCCESS

    return 0;
}
