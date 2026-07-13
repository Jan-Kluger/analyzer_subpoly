// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
#include <goblint.h>

// Inequalities become slack variables (x - y <= 0  =>  beta = x - y, beta in [-inf,0]).
int main(void) {
  int x, y;

  __goblint_assume(x <= y);
  __goblint_assume(y <= 5);

  __goblint_check(x <= y); // direct slack readback
  __goblint_check(y <= 5); // direct slack readback
  // Transitive x <= y <= 5 => x <= 5 is currently NOT proven: the check's strict
  // negation (x > 5) adds a fresh slack x >= 6 but meet_tcons does not reduce, so
  // the implied bound x <= 5 is never derived to expose the contradiction.
  __goblint_check(x <= 5); // UNKNOWN
  return 0;
}
