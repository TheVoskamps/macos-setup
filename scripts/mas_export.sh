#!/usr/bin/env bash
set -euo pipefail
: "${BUNDLE_FILE:=./MAS-from-this-Mac.snippet}"
echo "Generating MAS Install snippet from this Mac → ${BUNDLE_FILE}"
if ! command -v mas >/dev/null 2>&1; then
  echo "mas not found. Install with: brew install mas" >&2
  exit 1
fi
mas list | awk '{id=$1; $1=""; name=substr($0,2); printf "mas \"%s\", id: %s\n", name, id}' | sort -u > "${BUNDLE_FILE}"
echo "Wrote ${BUNDLE_FILE}. Review and copy desired lines into a tier's Brewfile."
