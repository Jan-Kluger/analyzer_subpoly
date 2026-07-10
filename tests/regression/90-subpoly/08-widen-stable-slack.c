// SKIP PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
// Widening terminates and keeps what is stable: a slack on variables untouched
// by the loop survives; the loop counter keeps only its stable lower bound and
// the post-loop state is refined by the negated guard (meet after widen).

#include <goblint.h>

int main(void) {
    int a;
    int b;
    int i;

    __goblint_assume(a + b >= 3); // slack a+b in [3, inf), untouched by the loop

    i = 0;
    while (i < 10) {
        i++;
    }

    __goblint_check(a + b >= 2); // SUCCESS: stable under widening
    __goblint_check(i >= 5);     // SUCCESS: negated guard gives i >= 10
    __goblint_check(i <= 100);   // UNKNOWN: upper bound widened away

    return 0;
}
