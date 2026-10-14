#!/bin/sh
# Run the vendored AP68040 self-test suite in its three configurations:
#   base    - no AP040_* macros (what HP9K385 builds today)
#   opt     - CPU_TEST_LEA=1 CPU_TEST_XSTORE=1
#   release - CPU_TEST_RELEASE=1 (the MacQuadra800 shipping macro set)
# rtl/ap68040/ is vendored byte-identical, and upstream ships run_tests.sh
# without the exec bit, so it is invoked through sh.  Legs run in parallel;
# work directories default to build/cpu/<leg> (git-ignored).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${CPU_REGRESSION_OUT:-$ROOT/build/cpu}
mkdir -p "$OUT"
TB=$ROOT/rtl/ap68040/tb

leg() {
	name=$1; shift
	( cd "$TB" && env CPU_TEST_WORK="$OUT/$name" "$@" sh ./run_tests.sh ) > "$OUT/$name.out" 2>&1
	echo $? > "$OUT/$name.rc"
}
leg base &
leg opt CPU_TEST_LEA=1 CPU_TEST_XSTORE=1 &
leg release CPU_TEST_RELEASE=1 &
wait

fail=0
for name in base opt release; do
	rc=$(cat "$OUT/$name.rc")
	if [ "$rc" -eq 0 ]; then
		echo "pass  $name  ($(grep -c '  pass  ' "$OUT/$name.out") checks)"
	else
		echo "FAIL  $name  (see $OUT/$name.out)"
		grep '  FAIL  ' "$OUT/$name.out"
		fail=1
	fi
done
[ $fail -eq 0 ] && echo "CPU regression: ALL LEGS PASSED" || { echo "CPU regression: FAILURES"; exit 1; }
