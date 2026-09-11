#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
checker="$script_dir/verify-release-binary.sh"
fixture_dir="$(mktemp -d -t zeitheld-release-guard-tests.XXXXXX)"
clean_fixture="$fixture_dir/clean-large-file"
early_fixture="$fixture_dir/early-marker-file"
late_fixture="$fixture_dir/late-marker-file"
sigpipe_bin="$fixture_dir/sigpipe-bin"
grep_error_bin="$fixture_dir/grep-error-bin"
fake_strings="$sigpipe_bin/strings"
fake_grep="$grep_error_bin/grep"

cleanup() {
  unlink "$clean_fixture" 2>/dev/null || true
  unlink "$early_fixture" 2>/dev/null || true
  unlink "$late_fixture" 2>/dev/null || true
  unlink "$fake_strings" 2>/dev/null || true
  unlink "$fake_grep" 2>/dev/null || true
  rmdir "$sigpipe_bin" 2>/dev/null || true
  rmdir "$grep_error_bin" 2>/dev/null || true
  rmdir "$fixture_dir" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

awk 'BEGIN { for (i = 0; i < 250000; i++) print "safe-release-padding" }' \
  > "$clean_fixture"
awk 'BEGIN { print "--ui-testing"; for (i = 0; i < 250000; i++) print "padding-after-early-marker" }' \
  > "$early_fixture"
awk 'BEGIN { for (i = 0; i < 250000; i++) print "padding-before-late-marker"; print "sk-ui-fixture" }' \
  > "$late_fixture"
mkdir "$sigpipe_bin" "$grep_error_bin"

# Deterministically recreate the original short-circuit failure: grep finds the
# early marker, while the producer exits as if it received SIGPIPE. The old
# `strings | grep -q` implementation incorrectly treated this as marker-free.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "--ui-testing"' \
  'exit 141' \
  > "$fake_strings"
chmod +x "$fake_strings"

# A matcher/tooling error must also fail closed instead of being confused with
# grep status 1 (the only status that means no marker was found).
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exit 2' \
  > "$fake_grep"
chmod +x "$fake_grep"

if ! "$checker" "$clean_fixture" >/dev/null; then
  echo "Release guard rejected a marker-free fixture." >&2
  exit 1
fi

if PATH="$sigpipe_bin:$PATH" "$checker" "$early_fixture" >/dev/null 2>&1; then
  echo "Release guard missed an early marker in a large file." >&2
  exit 1
fi

if "$checker" "$late_fixture" >/dev/null 2>&1; then
  echo "Release guard missed a late marker in a large file." >&2
  exit 1
fi

if PATH="$grep_error_bin:$PATH" "$checker" "$clean_fixture" >/dev/null 2>&1; then
  echo "Release guard treated a matcher failure as a clean scan." >&2
  exit 1
fi

echo "Release guard regression tests passed."
