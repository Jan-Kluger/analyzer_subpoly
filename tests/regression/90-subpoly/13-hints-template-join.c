// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none

#include <goblint.h>

/*
Needed stubs/functions:

* Everything from 10-widen-step3-monotone-loop.c
* Hint store attached to abstract state or analysis context
* Program-text hint generation
* Template hint generation for forms such as x - y
* Hint application in join/widen
* SubPolyDomain.eval_linear_form
* SubPolyDomain.add_slack_from_hint
*/

int main(void) {
    int x = 0;
    int y = 0;
    int c;

    while (c) {
        if (c) {
            x++;
            y += 2;
        } else {
            x++;
            y++;
        }
    }

    __goblint_check(x <= y); // SUCCESS

    return 0;
}
