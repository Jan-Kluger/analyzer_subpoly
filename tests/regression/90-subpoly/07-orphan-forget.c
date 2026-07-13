// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
// NOCRASH
#include <goblint.h>

// Orphan-slack scenario: a slack's info references a variable that is then forgotten.
//
//   assume x + y >= 5   -> slack s = x + y in [5, inf), info(s) = x + y
//   assume w == x + y   -> w = x + y  (gives a route s = w after x is gone)
//   x = u               -> forget x. remove_columns drops s's info (it mentions x) but
//                          keeps s's interval and rewrites its defining row to s = w.
//                          s is now an ORPHAN (interval, no info).
//
// The loop on the unrelated k keeps s bounded and non-top while the fixpoint runs, so
// the orphan flows through join / widen / leq. This exercises the orphan-creation path
// (info stripping in remove_columns), slack_lce dropping infoless slacks, and leq's
// collect_non_info handling. Verified (via temporary instrumentation) to actually
// create orphans that reach leq on the left operand. The property under test is only
// that none of this crashes and the analysis stays sound.
int main(void) {
  int x, y, w, u, c, k;

  __goblint_assume(x + y >= 5);
  __goblint_assume(w == x + y);
  x = u; // forget x -> s becomes an orphan (info dropped, interval [5,inf) kept)

  k = 0;
  while (c) {
    k++;
  }

  return 0;
}
