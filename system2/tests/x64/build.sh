#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
REDVIEW="${REDVIEW:-./red-view}"
$REDVIEW -c -t Linux-64 system2/tests/x64/hello.reds
echo "OK: hello built. Run: ./hello"
