// PARAM: --set ana.activated[+] subpoly --set sem.int.signed_overflow assume_none
#include <goblint.h>

// Reclamation of an orphaned slack in forget_vars.
//
// A slack's info mentions a variable that is later forgotten; forget_vars strips the
// info (leaving an orphan), then reclaims a *canonical* new info for it from a matrix
// row that still proves the slack over the remaining variables. Canonicalization must
// gcd/lcm/sign-normalize the recovered linear form and scale the interval accordingly.
//
//   assume 2x + 4y >= 6   -> slack s = 2x+4y, canonical info x+2y, interval [3, inf)
//   assume w == x + 2y    -> w = x+2y  (route s = w once x is gone)
//   x = u                 -> forget x. s's info (mentions x) is dropped, then reclaimed
//                            from the matrix as s = w and re-canonicalized.
//
// The reclaimed/scaled interval must be tight: x+2y>=3 (so w>=3), never w>=4.
int main(void) {
  int x, y, w, u;

  __goblint_assume(2 * x + 4 * y >= 6);
  __goblint_assume(w == x + 2 * y);
  x = u; // forget x -> reclaim s = w in [3, inf)

  __goblint_check(w >= 3);       // tight lower bound survives reclamation
  __goblint_check(w >= 4); // UNKNOWN (only w >= 3 is implied)
  return 0;
}
