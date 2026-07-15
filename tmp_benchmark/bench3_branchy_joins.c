// Stress: many branches inside a loop, so every iteration of the fixpoint
// performs a cascade of joins. Targets join / linear_disjunct and the LP
// calls it triggers.
#include <goblint.h>

int main(void) {
  int x = 0, y = 0, z = 0, w = 0;
  int d = 0, e = 0, f = 0, g = 0;
  int h = 0, o = 0, r = 0, s = 0;
  int cond;
  int c1, c2, c3, c4, c5, c6, c7, c8;
  int c9, c10, c11, c12, c13, c14, c15, c16; // unknown branch conditions

  while (cond) {
    if (c1) { x = x + 1; y = y + 1; } else { x = x + 2; y = y + 2; }
    if (c2) { z = x - y; } else { z = 0; }
    if (c3) { w = z + 1; } else { w = 1 + z; }
    if (c4) { d = w - z; } else { d = 1; }
    if (c5) { e = d + x - y; } else { e = d + z; }
    if (c6) { f = e + 1; } else { f = 1 + e; }
    if (c7) { g = f - e; } else { g = 1; }
    if (c8) { x = x + g; y = y + g; } else { x = x + 1; y = y + 1; }
    if (c9) { h = g + d; } else { h = 2; }
    if (c10) { o = h - g; } else { o = d; }
    if (c11) { r = o + z; } else { r = o; }
    if (c12) { s = r - o; } else { s = z; }
    if (c13) { w = w + s; } else { w = w + z; }
    if (c14) { e = e + s; } else { e = e + z; }
    if (c15) { f = e + 1; } else { f = 1 + e; }
    if (c16) { x = x + s; y = y + s; } else { x = x + z; y = y + z; }
  }

  __goblint_check(x - y == 0);
  __goblint_check(z == 0);
  __goblint_check(d == 1);
  __goblint_check(s == 0);
  return 0;
}
