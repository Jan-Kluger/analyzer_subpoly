// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
#include <goblint.h>

// Step 3 of the join (Algorithm 1 in the paper): the two branches pin the linear form
// x - y to different constants, so the pointwise (convex) join drops the equality. Step 3
// evaluates x - y in each reduced operand ([0,0] and [5,5]) and joins them, recovering the
// relational bound x - y in [0, 5] as a fresh slack.
int main(void) {
  int x, y, c;

  if (c) {
    x = 0;
    y = 0;
  } else {
    x = 10;
    y = 5;
  }

  __goblint_check(x - y >= 0); // recovered relational lower bound (x >= y)
  __goblint_check(x - y <= 5); // recovered relational upper bound
  __goblint_check(x - y >= 1); // UNKNOWN (x - y can be 0)
  return 0;
}
