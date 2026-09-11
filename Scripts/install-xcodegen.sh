#!/usr/bin/env bash
set -euo pipefail

version="2.44.1"
expected_sha256="a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73"
install_root="${XCODEGEN_INSTALL_ROOT:-$PWD/.tools/xcodegen}"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/watchlearn-xcodegen.XXXXXX")"
archive="$temporary_root/xcodegen.zip"

cleanup() {
  rm -rf "$temporary_root"
}
trap cleanup EXIT

curl --fail --location --silent --show-error \
  "https://github.com/yonaskolb/XcodeGen/releases/download/${version}/xcodegen.zip" \
  --output "$archive"
printf '%s  %s\n' "$expected_sha256" "$archive" | shasum -a 256 -c -
unzip -q "$archive" -d "$temporary_root/unpacked"

installer="$(find "$temporary_root/unpacked" -type f -name install.sh -print -quit)"
if [[ -z "$installer" ]]; then
  echo "XcodeGen installer was not present in the verified archive." >&2
  exit 1
fi

mkdir -p "$install_root"
PREFIX="$install_root" bash "$installer"
"$install_root/bin/xcodegen" --version
