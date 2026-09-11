#!/usr/bin/env bash
set -euo pipefail

workspace="$(cd "$(dirname "$0")/.." && pwd)"
cd "$workspace"

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/watchlearn-security.XXXXXX")"
cleanup() {
  rm -rf "$temporary_root"
}
trap cleanup EXIT

# Filename-only reporting prevents an accidentally discovered value from being
# copied into CI or terminal output. Perl is part of the macOS runner image;
# ripgrep is deliberately not required. Obvious test-fixture tokens are removed
# in memory before the remaining content is checked.
git ls-files -co --exclude-standard -z > "$temporary_root/files"
: > "$temporary_root/secret-files"

while IFS= read -r -d '' path; do
  if perl -0777 -e '
    my $source = do { local $/; <> };
    $source =~ s/sk-(?:fixture|test|ui-fixture|audio-fixture|live-test|example|placeholder)[A-Za-z0-9_-]*//g;
    my $has_secret = $source =~ /sk-[A-Za-z0-9_-]{20,}/
      || $source =~ /(?:OPENAI_API_KEY|APP_BROKER_TOKEN)[ \t]*=[ \t]*[^\s#`]+/
      || $source =~ /(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})/
      || $source =~ /AKIA[0-9A-Z]{16}/
      || $source =~ /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/;
    exit($has_secret ? 0 : 1);
  ' -- "$path"; then
    printf '%s\n' "$path" >> "$temporary_root/secret-files"
  fi
done < "$temporary_root/files"

if [[ -s "$temporary_root/secret-files" ]]; then
  echo "Potential credential found in:" >&2
  sed -n '1,120p' "$temporary_root/secret-files" >&2
  exit 1
fi

if git ls-files --error-unmatch Artifacts >/dev/null 2>&1; then
  echo "Artifacts/ must remain untracked." >&2
  exit 1
fi

if git ls-files | grep -Eq '\.(p8|p12|cer|mobileprovision)$'; then
  echo "Signing material must not be tracked." >&2
  exit 1
fi

echo "Security hygiene checks passed."
