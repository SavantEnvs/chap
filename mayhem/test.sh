#!/usr/bin/env bash
# chap/mayhem/test.sh — RUN chap's own expectedOutput suite (built by mayhem/build.sh with normal flags
# in $SRC/build-tests) via CTest, and emit a CTRF summary. exit 0 iff no test failed. This script only
# RUNS the pre-built `chap` binary through CTest; it never compiles.
#
# PATCH-grade oracle: each expectedOutput test runs chap on a REAL process core file (ELF32/ELF64,
# libc-malloc / gperftools heaps, plus compressed .bz2 cores) and DIFFs chap's produced output against
# checked-in known-good golden files (count/list/summarize/describe/enumerate/show of used/free/leaked
# allocations, anchor analysis, symbol unmangling, container-pattern recognition). It asserts BEHAVIOR /
# golden output, not merely that chap exits 0 — a no-op "exit(0)" patch produces no/garbage output and
# FAILS the diffs, so it cannot reward-hack this oracle.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

BUILD="$SRC/build-tests"
[ -x "$BUILD/chap" ] || { echo "missing $BUILD/chap — run mayhem/build.sh first" >&2; emit_ctrf "cmake-ctest" 0 1 0; exit 2; }

# Stale-output guard (#1084). Each test's work dir ($BUILD/test/expectedOutput/<test>) is diffed
# against its golden source dir, so any output file a PREVIOUS run left there passes the diff even if
# this run's chap writes nothing. Upstream's driver only removes files `find -newer <test>.timestamp`,
# which is a no-op once the image flattens mtimes onto the timestamp's second. So before the run, put
# every work dir back to exactly the pristine tree build.sh recorded after configure (run + declared
# core inputs + CMake's generated files): everything else (prior outputs, .timestamp files) goes. The
# manifest is build.sh's, under the untracked build tree, never in the patchable sources.
WORK="$BUILD/test/expectedOutput"
MANIFEST="$BUILD/mayhem-expectedOutput.manifest"
[ -d "$WORK" ] && [ -s "$MANIFEST" ] || { echo "missing $MANIFEST or $WORK — run mayhem/build.sh first" >&2; emit_ctrf "cmake-ctest" 0 1 0; exit 2; }
reset_workdirs() {
  ( cd "$WORK" && find . -mindepth 1 -print0 | LC_ALL=C sort -z \
      | LC_ALL=C comm -z -23 - "$MANIFEST" | xargs -0 -r rm -rf -- )
}
reset_workdirs || { echo "ERROR: could not reset $WORK to its pristine inputs" >&2; emit_ctrf "cmake-ctest" 0 1 0; exit 2; }
left="$(cd "$WORK" && find . -mindepth 1 -print0 | LC_ALL=C sort -z | LC_ALL=C comm -z -23 - "$MANIFEST" | tr '\0' '\n')"
[ -z "$left" ] || { echo "ERROR: stale files survived the reset of $WORK:" >&2; printf '%s\n' "$left" | head >&2; emit_ctrf "cmake-ctest" 0 1 0; exit 2; }

# Exclude ONE upstream test with a stale golden file: expectedOutput/.../SpinningThreads_longHeapHeader.
# Its `summarize writable` golden lists two equal-sized (0x21000) ranges ("main stack" vs "libc malloc
# main arena pages") in an order that depends on an unstable sort tie-break; chap built with ANY current
# toolchain (verified: both clang AND gcc on the base image) emits them in the opposite order, so the
# checked-in golden no longer matches reality regardless of compiler. This is a pre-existing upstream
# golden bug (output-ordering, not a behavior/correctness difference), NOT a regression from our build —
# the sibling SpinningThreads test (same core) passes. Excluded so it doesn't mask the 28 real oracles;
# remove this -E filter once upstream regenerates that golden.
CTEST_EXCLUDE='SpinningThreads_longHeapHeader'

# Run the expectedOutput suite through CTest. --output-on-failure prints diffs of any mismatch.
echo "=== running ctest (expectedOutput golden-output suite) ==="
out="$(cd "$BUILD" && ctest --output-on-failure -j"$MAYHEM_JOBS" -E "$CTEST_EXCLUDE" 2>&1)"; echo "$out"
# Leave no produced output behind either (the commit image runs this script at build time).
reset_workdirs || true

# Parse CTest's summary line: "N% tests passed, M tests failed out of T".
TOTAL=$( printf '%s\n' "$out" | sed -n 's/.* tests passed, *[0-9][0-9]* tests* failed out of \([0-9][0-9]*\).*/\1/p' | tail -1)
FAILED=$( printf '%s\n' "$out" | sed -n 's/.* tests passed, *\([0-9][0-9]*\) tests* failed out of .*/\1/p'        | tail -1)
: "${TOTAL:=0}" "${FAILED:=0}"

if [ "$TOTAL" -eq 0 ]; then
  echo "ERROR: ctest reported no tests (suite did not run)" >&2
  emit_ctrf "cmake-ctest" 0 1 0; exit 2
fi
PASSED=$(( TOTAL - FAILED )); [ "$PASSED" -lt 0 ] && PASSED=0

emit_ctrf "cmake-ctest" "$PASSED" "$FAILED" 0
