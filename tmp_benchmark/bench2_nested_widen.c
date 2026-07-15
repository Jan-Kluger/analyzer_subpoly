// Stress: nested loops with relational invariants across the nesting levels.
// Targets widen/join at multiple loop heads plus reduce after each meet on
// the loop conditions. Extra tracked variables per level make each widen
// operate on a wider matrix.
#include <goblint.h>

int main(void) {
  int i = 0, j = 0, k = 0, l = 0;
  int si = 0, sj = 0, sk = 0, sl = 0;
  int di = 0, dj = 0, dk = 0, dl = 0;
  int t1 = 0, t2 = 0, t3 = 0, t4 = 0;
  int u1 = 0, u2 = 0, u3 = 0, u4 = 0;
  int n, m, p, q; // unknown bounds

  while (i < n) {
    j = 0; sj = 0; dj = 0;
    while (j < m) {
      k = 0; sk = 0; dk = 0;
      while (k < p) {
        l = 0; sl = 0; dl = 0;
        while (l < q) {
          l = l + 1;
          sl = sl + 1;
          dl = sl - l;
          t4 = dl + sl;
          u4 = t4 - sl;
        }
        k = k + 1;
        sk = sk + 1;
        dk = sk - k;
        t3 = dk + sk;
        u3 = t3 - sk;
      }
      j = j + 1;
      sj = sj + 1;
      dj = sj - j;
      t2 = dj + sj;
      u2 = t2 - sj;
    }
    i = i + 1;
    si = si + 1;
    di = si - i;
    t1 = di + si;
    u1 = t1 - si;
  }

  __goblint_check(si - i == 0);
  __goblint_check(di == 0);
  __goblint_check(u1 - di == 0);
  return 0;
}
