#!/usr/bin/env bash
# Profile the subpoly domain on the benchmark files in this directory.
#
# For each bench*.c, this produces:
#   profiles/<name>.json.gz  - samply sampling profile (flame graph).
#                              View with:  samply load profiles/<name>.json.gz
#   stats/<name>.txt         - wall time, max RSS, and Goblint's internal
#                              timing tree (dbg.timing), plus analysis output.
#
# samply does not emit SVGs; `samply load <file>` opens the interactive
# Firefox Profiler UI (flame graph / call tree / stack chart) locally.

set -u
cd "$(dirname "$0")"

# Absolute path: samply records the binary path into the profile and resolves
# it again at `samply load` time — a relative path breaks symbolication.
GOBLINT="$(cd .. && pwd)/goblint"
GOBLINT_ARGS=(--set 'ana.activated[+]' subpoly --set sem.int.signed_overflow assume_none)
SAMPLY_RATE=2000  # samples/sec; runs are a few seconds, so sample densely

mkdir -p profiles stats
failures=0

# Per-run cap (no GNU timeout on macOS): kill the analysis if it exceeds this.
# bench4-style workloads (relational inequalities re-asserted inside a widening
# loop) currently do not converge in reasonable time -- see subpoly_changes_2026-07-14.md.
TIMEOUT_S=180
run_capped() {
  "$@" & local pid=$!
  ( sleep "$TIMEOUT_S"; kill "$pid" 2>/dev/null ) & local watcher=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  return $rc
}

for src in bench*.c; do
  name="${src%.c}"
  echo "=== $name ==="

  # Run 1: sampling profile (no extra instrumentation, so samples are clean)
  echo "  recording profile..."
  if ! run_capped samply record --save-only --rate "$SAMPLY_RATE" -o "profiles/$name.json.gz" -- \
      "$GOBLINT" "${GOBLINT_ARGS[@]}" "$src" > /dev/null 2>&1; then
    echo "  !! samply/goblint failed for $src" >&2
    failures=$((failures + 1))
  fi

  # Run 2: wall time + memory + Goblint's internal timing tree
  echo "  collecting stats..."
  {
    echo "# $src"
    echo "# goblint ${GOBLINT_ARGS[*]} $src"
    echo "# date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    run_capped /usr/bin/time -l "$GOBLINT" "${GOBLINT_ARGS[@]}" \
      --enable dbg.timing.enabled "$src" 2>&1
  } > "stats/$name.txt"

  grep -E "^\s+[0-9.]+ real" "stats/$name.txt" | sed 's/^/ /'
done

echo
if [ "$failures" -gt 0 ]; then
  echo "DONE with $failures failure(s) - check output above."
  exit 1
fi
echo "DONE. View a flame graph with e.g.:"
echo "  samply load profiles/bench1_many_vars.json.gz"
