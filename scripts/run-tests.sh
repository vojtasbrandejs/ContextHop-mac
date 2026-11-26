#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MINIMUM_TEST_COUNT="${CONTEXTHOP_MIN_TEST_COUNT:-170}"
OUTPUT="$(/usr/bin/mktemp -t contexthop-tests)"
trap '/bin/rm -f "$OUTPUT"' EXIT

cd "$ROOT"
swift run contexthop-tests | /usr/bin/tee "$OUTPUT"

PASS_COUNT="$(
    /usr/bin/awk '
        /^PASS: [0-9]+ assertions, 0 failures$/ { count = $2 }
        END { print count + 0 }
    ' "$OUTPUT"
)"
if (( PASS_COUNT < MINIMUM_TEST_COUNT )); then
    echo "error: passed $PASS_COUNT assertions; expected at least $MINIMUM_TEST_COUNT." >&2
    exit 1
fi

echo "Verified $PASS_COUNT assertions (minimum: $MINIMUM_TEST_COUNT)."
