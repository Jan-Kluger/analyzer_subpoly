// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none

#include <goblint.h>

/*
Needed stubs/functions:

* Everything from 03-single-ineq.c
* RationalInterval.meet
* RationalInterval.join
* SubPolyDomain.set_interval
* SubPolyDomain.mem_slack
* D.meet
* Slack identity/canonicalization in Slack_managment.slack_var_of_constraint
*/

int main(void) {
    int a;
    int b;

    __goblint_assume(a + b <= 10);
    __goblint_assume(a + b >= 3);

    __goblint_check(a + b <= 10); // SUCCESS
    __goblint_check(a + b >= 3);  // SUCCESS

    return 0;
}
