// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none

#include <goblint.h>

/*
Needed stubs/functions:

* Everything from 04-two-sided-bounds.c
* SubPolyDomain.reduce
* SubPolyDomain.eval_linear_form
* SubPolyDomain.set_interval for program variables
* ExpressionBounds.bound_texpr
* D.assert_constraint handling Eq with one or more variables
* D.assign_exp for constants and unknowns
*/

int main(void) {
    int x;
    int y;

    __goblint_assume(x - y == 0);
    __goblint_assume(x >= 5);

    __goblint_check(y >= 5); // SUCCESS

    return 0;
}
