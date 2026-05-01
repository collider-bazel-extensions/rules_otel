#!/usr/bin/env bash
set -euo pipefail

SRC_BAZEL_BIN="${1:?usage: writeback.sh <bazel-bin source> <dest path under workspace>}"
DEST_REL="${2:?missing dest path}"

WORKSPACE="${BUILD_WORKSPACE_DIRECTORY:?BUILD_WORKSPACE_DIRECTORY not set; run via 'bazel run'}"

if [[ -z "${RUNFILES_DIR:-}" ]]; then
  if [[ -d "${0}.runfiles" ]]; then RUNFILES_DIR="${0}.runfiles"
  elif [[ -d "$(dirname "$0").runfiles" ]]; then RUNFILES_DIR="$(dirname "$0").runfiles"
  fi
  export RUNFILES_DIR
fi
RENDERED="${RUNFILES_DIR}/_main/${SRC_BAZEL_BIN}"
[[ -f "$RENDERED" ]] || { echo "writeback: missing rendered YAML at $RENDERED" >&2; exit 1; }

DEST="${WORKSPACE}/${DEST_REL}"
mkdir -p "$(dirname "$DEST")"
cp -f "$RENDERED" "$DEST"

SHA256=$(sha256sum "$DEST" | awk '{print $1}')
LINES=$(wc -l < "$DEST")
echo "writeback: wrote $DEST"
echo "  sha256: $SHA256"
echo "  lines:  $LINES"
