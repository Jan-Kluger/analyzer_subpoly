// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none

#include <goblint.h>

/*
Needed stubs/functions:

* Everything from 02-normalization.c
* D.invariant or ExpressionBounds.bound_texpr
* D.eval_interval
* SubPolyDomain.leq
* SubPolyDomain.meet, if assertions are handled via meet/assert transfer
*/

int main(void) {
    int a;
    int b;

    __goblint_assume(a + b <= 10);
    __goblint_check(a + b <= 10); // SUCCESS

    return 0;
}
