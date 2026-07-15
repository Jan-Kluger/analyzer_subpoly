// Stress: many __goblint_check queries under a slack-heavy inequality
// context — each check is an assert/bound query, i.e. a reduce with a
// temporary slack. Targets the query path (bound_texpr / assert through
// reduce) rather than transfer functions. Single function only:
// interprocedural analysis currently fails with
// "SubPolyhedraDomain.unify: not implemented".
#include <goblint.h>

int main(void) {
  int acc = 0, cnt = 0, lim = 0;
  int u0, u1, u2, u3, u4, u5, u6, u7; // unknowns
  int cond;

  if (u0 >= 0 && u0 <= 50 &&
      u1 >= u0 && u1 <= u0 + 20 &&
      u2 >= u1 && u2 <= u1 + 20 &&
      u3 >= u2 && u3 <= u2 + 20 &&
      u4 >= u3 && u4 <= u3 + 20 &&
      u5 >= u4 && u5 <= u4 + 20 &&
      u6 >= u5 && u6 <= u5 + 20 &&
      u7 >= u6 && u7 <= u6 + 20) {

    while (cond) {
      acc = acc + 1;
      if (acc > 1000) { acc = 1000; }
      cnt = cnt + 1;
      lim = acc;
      if (lim < 0) { lim = 0; }
      if (lim > 1000) { lim = 1000; }

      __goblint_check(lim >= 0);
      __goblint_check(lim <= 1000);
      __goblint_check(acc >= 0);
      __goblint_check(acc <= 1000);
      __goblint_check(u1 >= u0);
      __goblint_check(u1 <= u0 + 20);
      __goblint_check(u2 >= u0);
      __goblint_check(u2 <= u0 + 40);
      __goblint_check(u3 >= u1);
      __goblint_check(u3 <= u1 + 40);
      __goblint_check(u4 >= u2);
      __goblint_check(u4 <= u2 + 40);
      __goblint_check(u5 >= u3);
      __goblint_check(u5 <= u3 + 40);
      __goblint_check(u6 >= u4);
      __goblint_check(u6 <= u4 + 40);
      __goblint_check(u7 >= u5);
      __goblint_check(u7 <= u5 + 40);
      __goblint_check(u7 <= 190);
      __goblint_check(u7 >= 0);

      if (cnt > 100) {
        acc = 0;
        cnt = 0;
      }

      __goblint_check(cnt <= 101);
      __goblint_check(acc <= 1000);
    }

    __goblint_check(u7 - u0 >= 0);
    __goblint_check(u7 - u0 <= 140);
  }
  return 0;
}
