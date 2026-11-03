#!/usr/bin/env bash
# Best-effort pre-publication guardrail; not a comprehensive PHI/secrets scanner.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
while IFS= read -r -d '' path; do
  lower=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    examples/synthetic-phantom.nii) continue;;
    *.dcm|*.dicom|*.nii|*.nii.gz|*.nrrd|*.mha|*.mhd|*.raw|*.usdz|*.ipa|*.xcarchive/*|*.p12|*.p8|*.mobileprovision|*.key)
      printf 'Unexpected potentially sensitive/binary file: %s\n' "$path" >&2
      fail=1;;
  esac
  case "$lower" in
    *.env|.env*|*credentials*|*private*key*|*secrets*)
      printf 'Review potentially sensitive filename: %s\n' "$path" >&2
      fail=1;;
  esac
done < <(git ls-files -z)

if [[ "$fail" -ne 0 ]]; then
  echo 'Repository audit failed. Remove/exclude sensitive or unreviewed files.' >&2
  exit 1
fi

echo 'Basic tracked-file audit passed. Manually review content for patient data and secrets.'
