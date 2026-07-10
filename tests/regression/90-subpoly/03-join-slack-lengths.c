// SKIP PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
// NOCRASH

#include <goblint.h>

// The two branches reach the join with a DIFFERENT number of slack variables:
//  - true branch:  one slack   (info a+b)
//  - false branch: two slacks  (infos a+b and a-b)
// so the info vectors compared in slack_lce have different lengths even though
// the linear form a+b is shared. This exercises info_equal vs CoeffVector.equal.
int main(void) {
  int a;
  int b;
  int x;

  if (x) {
    __goblint_assume(a + b < 5);
  } else {
    __goblint_assume(a + b < 3);
    __goblint_assume(a - b < 7);
  }
  // join point here
  return 0;
}
