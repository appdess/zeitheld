#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 /path/to/ZeitHeld" >&2
  exit 2
fi

strings_output="$(mktemp -t zeitheld-release-strings.XXXXXX)"
cleanup() {
  unlink "$strings_output" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

# Do not pipe `strings` into a short-circuiting matcher here. With `pipefail`,
# grep can exit after an early match while strings receives SIGPIPE, causing the
# complete pipeline to look unsuccessful and letting a forbidden marker pass.
strings -- "$1" > "$strings_output"

grep_status=0
if grep -Eq -- '--ui-testing|sk-ui-fixture|ui-test-fixture' "$strings_output"; then
  echo "Release binary contains a UI-test switch or fixture credential." >&2
  exit 1
else
  grep_status=$?
fi

if [[ "$grep_status" -ne 1 ]]; then
  echo "Release binary marker scan failed." >&2
  exit 2
fi

echo "Release binary contains no known UI-test markers."
