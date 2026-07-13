// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
#include <goblint.h>

// Paper Fig. 5(b): the Step-3 (recovery) example. Entering the loop i - k = 0; each
// iteration only increases i, so i >= k is invariant. Recovering i >= k after the
// pointwise widening requires Step 3, which is deliberately not implemented, so the
// inequality is expected to be lost here (documents the current limitation).
int main(void) {
  int k, c;
  int i = k;

  while (c) {
    i++;
  }

  __goblint_check(i >= k); // UNKNOWN (needs Step 3 recovery, not implemented)
  return 0;
}
