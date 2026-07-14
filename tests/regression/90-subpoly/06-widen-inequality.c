// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
#include <goblint.h>

// Paper Fig. 5(b): the Step-3 (recovery) example. Entering the loop i - k = 0; each
// iteration only increases i, so i >= k is invariant. After the pointwise widening loses
// the relation, Step 3 recovers i - k in [0, +inf] (a fresh slack whose interval is the
// widening of the two operand valuations of i - k), which proves i >= k.
int main(void) {
  int k, c;
  int i = k;

  while (c) {
    i++;
  }

  __goblint_check(i >= k); // Step 3 recovery of the widened inequality
  return 0;
}
