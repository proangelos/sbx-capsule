#!/usr/bin/env bash
# The test runner (make test). Runs every tests/*.test.sh, or the files
# named, each in its own bash process, and prints a total. Each test gets
# a scratch copy of the tool and the fake sbx (tests/fake-sbx/sbx), so no
# real VM, sandbox or .env is touched.
#
# Usage: tests/run.sh [tests/<name>.test.sh ...]
#   TEST_FILTER=<substring>  only the tests whose function names match
#   KEEP_SCRATCH=1           keep each passing test's scratch folder
#                            (failing ones are always kept)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if (( BASH_VERSINFO[0] < 4 )); then
  echo "error: the tests need bash 4 or newer (on macOS: brew install bash)" >&2
  exit 1
fi

files=("$@")
(( ${#files[@]} )) || files=(tests/*.test.sh)

export RESULTS_FILE
RESULTS_FILE="$(mktemp)"
trap 'rm -f -- "$RESULTS_FILE"' EXIT

status=0
for f in "${files[@]}"; do
  echo "${f#tests/}"
  bash -c 'source tests/lib.sh; source "$1"; run_tests' _ "$f" || status=1
done

read -r passed failed < <(awk '{ p += $1; f += $2 } END { print p + 0, f + 0 }' "$RESULTS_FILE")
echo
if (( status == 0 )); then
  echo "All $passed test(s) passed."
else
  echo "$failed of $((passed + failed)) test(s) failed. Their scratch folders were kept under ${TMPDIR:-/tmp}/sbxc-test.*"
fi
exit "$status"
