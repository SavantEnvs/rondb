#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the MySQL Router's OWN known-answer unit tests (gtest) (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# The gtest binaries were built by mayhem/build.sh (normal flags) under build/test. They assert encode/decode
# known answers (classic-protocol wire codec), base64 round trips and URI parsing results.
TESTS=(
  routertest_mysql_protocol_classic_protocol_wire
  routertest_http_base64
  routertest_http_uri
  routertest_router_uri
)
passed=0; failed=0; skipped=0
for t in "${TESTS[@]}"; do
  bin=$(find "$SRC/build/test" -type f -name "$t" -perm -u+x 2>/dev/null | head -n1)
  if [ -z "$bin" ]; then
    echo "test.sh: missing prebuilt test runner $t (build.sh should have produced it)" >&2
    failed=$((failed + 1)); continue
  fi
  out=$(cd "$(dirname "$bin")" && "$bin" 2>&1); rc=$?
  echo "$out" | tail -n 8
  p=$(printf '%s\n' "$out" | sed -n 's/^\[  PASSED  \] \([0-9][0-9]*\) test.*/\1/p' | tail -n1)
  f=$(printf '%s\n' "$out" | sed -n 's/^\[  FAILED  \] \([0-9][0-9]*\) test.*/\1/p' | tail -n1)
  s=$(printf '%s\n' "$out" | sed -n 's/^\[  SKIPPED \] \([0-9][0-9]*\) test.*/\1/p' | tail -n1)
  p=${p:-0}; f=${f:-0}; s=${s:-0}
  if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then f=1; fi   # crashed or exited non-zero without a gtest summary
  if [ "$p" -eq 0 ] && [ "$f" -eq 0 ] && [ "$s" -eq 0 ]; then f=1; fi   # no gtest summary: runner did not actually run
  passed=$((passed + p)); failed=$((failed + f)); skipped=$((skipped + s))
done

emit_ctrf "gtest" "$passed" "$failed" "$skipped"
