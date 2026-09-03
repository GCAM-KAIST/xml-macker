#!/bin/bash
# One command that checks the app.
#
#   tools/check.sh            build + logic checks
#   tools/check.sh --ui       also drive the running app through its screens
#
# What it does NOT do: replace looking at the thing. It catches the
# mistakes a machine can catch, which is most of them.

set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
step() { printf '\n=== %s ===\n' "$1"; }

step "1. Compiler, warnings treated as errors"
if swift build -c release -Xswiftc -warnings-as-errors 2>&1 | tail -20; then
  echo "compiler: clean"
else
  echo "compiler: FAILED"; fail=1
fi

step "2. Built-in logic checks"
if ./.build/release/XMLMacker --self-check; then
  echo "self-check: passed"
else
  echo "self-check: FAILED"; fail=1
fi

step "3. Element-aware diff on real GCAM files"
L=/tmp/gcam/transportation_UCD_CORE.xml
R=/tmp/gcam/transportation_UCD_SSP1.xml
if [ -f "$L" ] && [ -f "$R" ]; then
  ./.build/release/XMLMacker --diff-check "$L" "$R" || fail=1
else
  echo "skipped: put two GCAM files at $L and $R to run this"
fi

step "4. The app starts and quits"
./build-app.sh release >/dev/null 2>&1 || { echo "bundle: FAILED"; fail=1; }
open -a "$PWD/dist/xml-macker.app" 2>/dev/null
for _ in $(seq 1 20); do
  pgrep -x xml-macker >/dev/null && break
  sleep 1
done
if pgrep -x xml-macker >/dev/null; then
  echo "launch: ok"
else
  echo "launch: FAILED"; fail=1
fi

if [ "${1:-}" = "--ui" ]; then
  step "5. Screen sweep"
  # The sweep drives the Diff window, which needs two tabs open. Open the
  # same GCAM pair as step 3 and give the big files time to parse.
  if [ -f "$L" ] && [ -f "$R" ]; then
    open -a "$PWD/dist/xml-macker.app" "$L" "$R" 2>/dev/null
    sleep 45
  fi
  # The script reports each step as text and exits 0 even when a step
  # failed, so the text is what decides.
  sweep=$(osascript tools/smoke-test.applescript) || fail=1
  echo "$sweep"
  echo "$sweep" | grep -q FAIL && fail=1
fi

step "6. Crash reports from the last hour"
found=$(find ~/Library/Logs/DiagnosticReports -name "xml-macker*" -mmin -60 2>/dev/null)
if [ -n "$found" ]; then
  echo "CRASH REPORTS FOUND:"; echo "$found"; fail=1
else
  echo "none"
fi

step "Result"
if [ "$fail" = 0 ]; then echo "everything passed"; else echo "SOMETHING FAILED, see above"; fi
exit $fail
