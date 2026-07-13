// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
#include <goblint.h>

// Exercises widening at the loop head. The relational equality i - k = 0 must be
// preserved across the widening; the main point is that widen must not crash
// (Invalid_widen from Lattice.assert_valid_widen: leq old (widen old new)).
int main(void) {
  int i = 0;
  int k = 0;
  int c; // unknown loop condition, forces widening rather than unrolling

  while (c) {
    i++;
    k++;
  }

  // Written as i - k == 0 (single relational expr) rather than i == k: the latter is
  // checked via a strict-inequality negation that meet_tcons cannot yet refute
  // (SUP is treated as SUPEQ). The relation itself is tracked correctly.
  __goblint_check(i - k == 0); // relational invariant maintained through the loop
  return 0;
}
