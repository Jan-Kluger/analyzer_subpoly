// Stress: many inequality assumptions, each creating a slack variable.
// Targets meet_tcons, slack bookkeeping and reduce (the LP entry point)
// with a slack-heavy matrix.
#include <goblint.h>

int main(void) {
  int x0, x1, x2, x3, x4, x5, x6, x7, x8, x9; // unknowns
  int s = 0;
  int cond;

  if (x0 >= 0 && x0 <= 100 &&
      x1 >= x0 && x1 <= x0 + 10 &&
      x2 >= x1 && x2 <= x1 + 10 &&
      x3 >= x2 && x3 <= x2 + 10 &&
      x4 >= x3 && x4 <= x3 + 10 &&
      x5 >= x4 && x5 <= x4 + 10 &&
      x6 >= x5 && x6 <= x5 + 10 &&
      x7 >= x6 && x7 <= x6 + 10 &&
      x8 >= x7 && x8 <= x7 + 10 &&
      x9 >= x8 && x9 <= x8 + 10) {

    while (cond) {
      if (s < x9) {
        s = s + 1;
      }
      if (x9 - x0 >= 90) {
        s = s + x1 - x0;
      }
    }

    __goblint_check(x9 >= x0);
    __goblint_check(x9 <= x0 + 90);
    __goblint_check(x9 <= 190);
    __goblint_check(s >= 0);
  }
  return 0;
}
