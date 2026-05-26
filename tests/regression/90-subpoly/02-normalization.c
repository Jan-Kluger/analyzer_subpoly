// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
// NOCRASH

#include <goblint.h>

/*
Needed stubs/functions:

* Everything from 01-smoke.c
* Linexpr_managment.linexpr_of_exp for multiplication by integer constants
* Linexpr_managment.scale_linexpr with a non-unit factor
* Linexpr_managment.normalize_linexpr with a non-unit pivot
* Slack_managment.absorb_linexpr_const_into_interval with a non-zero constant
* RationalInterval.add_const
* RationalInterval.scale with a non-unit factor
*/

int main(void) {
    int a;
    int b;

    __goblint_assume(2 * a + 2 * b + 2 < 4);
    __goblint_assume(a + b + 1 < 2);

    return 0;
}
