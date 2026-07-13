// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
#include <goblint.h>

// Both branches establish the same relational equality i - k = 0 (with different
// constants). The join must preserve it: linear_disjunct keeps equalities implied
// by both operands. Checks the join path (SubPolyDomain.join) plus reduce.
int main(void) {
  int i, k, x;

  if (x) {
    i = 0;
    k = 0;
  } else {
    i = 5;
    k = 5;
  }

  __goblint_check(i - k == 0); // common relational invariant survives the join
  return 0;
}
