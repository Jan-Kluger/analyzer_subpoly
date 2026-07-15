// Stress: many variables with chained linear assignments inside a loop.
// Targets assign_texpr / substitute_expr and the cost of a wide matrix
// (env size ~ 24 vars, so matrix width = env + slacks + 1 gets large).
#include <goblint.h>

int main(void) {
  int a0 = 0, a1 = 0, a2 = 0, a3 = 0, a4 = 0, a5 = 0, a6 = 0, a7 = 0;
  int b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0, b7 = 0;
  int c0 = 0, c1 = 0, c2 = 0, c3 = 0, c4 = 0, c5 = 0, c6 = 0, c7 = 0;
  int cond; // unknown, forces widening

  while (cond) {
    a0 = a0 + 1;
    a1 = a0 + 1;
    a2 = a1 + 2;
    a3 = a2 - a1;
    a4 = a3 + a0;
    a5 = a4 + 1;
    a6 = a5 - a4;
    a7 = a6 + a0;

    b0 = a7 + 1;
    b1 = b0 - a7;
    b2 = b1 + b0;
    b3 = b2 + 3;
    b4 = b3 - b2;
    b5 = b4 + b1;
    b6 = b5 + 1;
    b7 = b6 - b5;

    c0 = b7 + a0;
    c1 = c0 + 1;
    c2 = c1 - c0;
    c3 = c2 + b0;
    c4 = c3 + 2;
    c5 = c4 - c3;
    c6 = c5 + c2;
    c7 = c6 + 1;
  }

  __goblint_check(a3 - a2 + a1 == 0);
  __goblint_check(b1 + a7 - b0 == 0);
  __goblint_check(c2 + c0 - c1 == 0);
  return 0;
}
