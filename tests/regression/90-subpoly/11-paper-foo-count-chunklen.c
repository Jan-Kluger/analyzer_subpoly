// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none

#include <goblint.h>

/*
Needed stubs/functions:

* Everything from 06-constant-assignment.c
* D.assign_exp for linear expressions
* D.assert_constraint for non-unary coefficient constraints such as wb >= 2 * count
* SubPolyDomain.reduce strong enough for derived linear forms
* ExpressionBounds.bound_texpr or D.invariant
* Optional later: interprocedural propagation/precondition checking
*/

int main(void) {
    int wb;
    int count;
    int chunkLen;
    int arrayLen;

    __goblint_assume(wb >= 2 * count);
    __goblint_assume(count + chunkLen >= arrayLen);

    {
        int len = arrayLen - chunkLen;
        __goblint_check(wb >= 2 * len); // SUCCESS
    }

    return 0;
}
