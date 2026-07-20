#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT=""
ALLOW_DIRTY=false

usage() {
  cat <<USAGE
Usage: $0 --output PATH [--allow-dirty]

Exports the complete MeetingVault product source, tests, build/release scripts,
public policies, and CI configuration into a new directory. Internal release
evidence, private planning artifacts, generated output, and Git history are not
copied. The default path requires a clean tracked working tree.

--allow-dirty is only for local validation of an in-progress export change.
Never use it to create a public release source tree.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT="${2:-}"
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '[BLOCKED] Unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$OUTPUT" ]]; then
  printf '[BLOCKED] --output is required.\n' >&2
  exit 2
fi

OUTPUT_PARENT="$(cd "$(dirname "$OUTPUT")" && pwd)"
OUTPUT="$OUTPUT_PARENT/$(basename "$OUTPUT")"
if [[ "$OUTPUT" == "/" || "$OUTPUT" == "$ROOT_DIR" || "$OUTPUT" == "$ROOT_DIR/"* ]]; then
  printf '[BLOCKED] Output must be outside the source repository: %s\n' "$OUTPUT" >&2
  exit 2
fi
if [[ -e "$OUTPUT" ]]; then
  printf '[BLOCKED] Output already exists; choose a new path: %s\n' "$OUTPUT" >&2
  exit 2
fi

if [[ "$ALLOW_DIRTY" != "true" ]]; then
  tracked_status="$(git -C "$ROOT_DIR" status --short --untracked-files=no)"
  if [[ -n "$tracked_status" ]]; then
    printf '[BLOCKED] Public source export requires a clean tracked working tree.\n' >&2
    printf '%s\n' "$tracked_status" >&2
    exit 1
  fi
fi

"$ROOT_DIR/script/check_local_model_supply_chain.sh"

mkdir -p "$OUTPUT"
cleanup_on_failure() {
  rm -rf "$OUTPUT"
}
trap cleanup_on_failure EXIT

copy_path() {
  local relative="$1"
  if [[ ! -e "$ROOT_DIR/$relative" ]]; then
    printf '[BLOCKED] Required public source path is missing: %s\n' "$relative" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$OUTPUT/$relative")"
  cp -R "$ROOT_DIR/$relative" "$OUTPUT/$relative"
}

for path in \
  Package.swift \
  Package.resolved \
  Sources \
  Tests \
  config \
  docs/screenshots \
  docs/architecture.md \
  docs/release-notes-0.1.0.md \
  docs/troubleshooting.md \
  script \
  .github \
  .editorconfig \
  .gitattributes \
  .gitignore \
  LICENSE \
  NOTICE \
  MAINTAINERS.md \
  README.md \
  CONTRIBUTING.md \
  SECURITY.md \
  SUPPORT.md \
  CODE_OF_CONDUCT.md \
  TRADEMARKS.md \
  PRIVACY.md \
  RELEASING.md \
  CHANGELOG.md \
  PUBLIC_SOURCE.md
do
  copy_path "$path"
done

# This repository-owned suite asserts private release-evidence pins and is not
# product code. Public CI covers every shipped source target and product test.
rm -f "$OUTPUT/Tests/MeetingVaultCoreTests/ReleaseGateApprovedReportTests.swift"

find "$OUTPUT" -name '.DS_Store' -delete
find "$OUTPUT" -type d \( -name '.build' -o -name 'dist' -o -name 'DerivedData' -o -name 'evidence' -o -name 'superpowers' -o -name '__pycache__' -o -name '.pytest_cache' -o -name '.mypy_cache' -o -name '.ruff_cache' \) -prune -exec rm -rf {} +
find "$OUTPUT" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
find "$OUTPUT" -type f \( -name '*.p12' -o -name '*.cer' -o -name '*.provisionprofile' -o -name '*.mobileprovision' \) -print -quit | grep -q . && {
  printf '[BLOCKED] Signing material reached the public export.\n' >&2
  exit 1
}
if grep -RIlE --exclude-dir=.git -- '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----' "$OUTPUT" >/dev/null; then
  printf '[BLOCKED] Private-key material reached the public export.\n' >&2
  exit 1
fi
personal_fixture_matches="$(grep -RIlE --exclude-dir=.git --exclude=export_public_source.sh -- '/Users/s1kor|rafal@example\.com|mrsikorarafal@gmail\.com' "$OUTPUT" || true)"
if [[ -n "$personal_fixture_matches" ]]; then
  printf '[BLOCKED] Machine-specific or personal fixture identity reached the public export.\n' >&2
  printf '%s\n' "$personal_fixture_matches" >&2
  exit 1
fi

git -C "$ROOT_DIR" rev-parse HEAD >"$OUTPUT/SOURCE_COMMIT"
printf '[OK] Public source export created: %s\n' "$OUTPUT"
trap - EXIT
