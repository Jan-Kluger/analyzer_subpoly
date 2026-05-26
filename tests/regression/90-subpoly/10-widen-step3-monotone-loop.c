// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none

#include <goblint.h>

/*
Needed stubs/functions:

* D.assign_var or D.assign_exp for i = k
* D.assign_exp for i++
* SubPolyDomain.widen
* SubPolyDomain.recover_dropped_equalities_widen
* SubPolyDomain.eval_linear_form
* SubPolyDomain.leq
* SubPolyDomain.reduce
*/

int main(void) {
    int i;
    int k;

    i = k;

    while (i < 100) {
        i++;
    }

    __goblint_check(i >= k); // SUCCESS

    return 0;
}
