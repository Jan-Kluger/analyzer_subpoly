// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none

#include <goblint.h>

/*
Needed stubs/functions:

* Everything from 08-join-same-template.c
* SubPolyDomain.saturate_slack_info_for_join
* SubPolyDomain.reduce
* SubPolyDomain.meet or add equality row during saturation
* SubPolyDomain.join with slack renaming
* SubPolyDomain.eval_linear_form
*/

int main(void) {
    int x;
    int y;
    int z;
    int c;

    if (c) {
        __goblint_assume(x == y);
        __goblint_assume(y <= z);
    } else {
        __goblint_assume(x <= y);
        __goblint_assume(y == z);
    }

    __goblint_check(x <= y); // SUCCESS
    __goblint_check(y <= z); // SUCCESS

    return 0;
}
