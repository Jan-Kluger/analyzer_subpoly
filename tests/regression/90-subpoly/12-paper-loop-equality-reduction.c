// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none

#include <goblint.h>

/*
Needed stubs/functions:

* D.assign_var for x = i and y = j
* D.assign_exp for x-- and y--
* SubPolyDomain.join
* SubPolyDomain.widen
* SubPolyDomain.reduce
* D.assert_constraint for loop guards and equality guards
* ExpressionBounds.bound_texpr for equality check
* SubPolyDomain.leq
*/

int main(void) {
    int i;
    int j;
    int x = i;
    int y = j;

    if (x <= 0) {
        return 0;
    }

    while (x > 0) {
        x--;
        y--;
    }

    if (y == 0) {
        __goblint_check(i == j); // SUCCESS
    }

    return 0;
}
