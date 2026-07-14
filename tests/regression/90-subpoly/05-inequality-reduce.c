// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
#include <goblint.h>

// Inequalities become slack variables (x - y <= 0  =>  beta = x - y, beta in [-inf,0]).
int main(void) {
  int x, y;

  __goblint_assume(x <= y);
  __goblint_assume(y <= 5);

  __goblint_check(x <= y); // direct slack readback
  __goblint_check(y <= 5); // direct slack readback
  // Transitive x <= y <= 5 => x <= 5: proven since meet_tcons reduces after adding
  // constraints and single-variable bounds are tracked directly (var_intervals).
  __goblint_check(x <= 5);
  return 0;
}
