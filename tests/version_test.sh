#!/usr/bin/env bash
# The binary otel_collector_server runs is the version otel_install
# deploys: DEFAULT_VERSION, MODULE.bazel's otel.version(), the image tag in
# the rendered manifest and the toolchain binary all agree.
#
# Argv: <versions.bzl> <MODULE.bazel> <otel.yaml> <otelcol-contrib>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
r="$TEST_SRCDIR/_main"

default=$(sed -n 's/^DEFAULT_VERSION = "\(.*\)"/\1/p' "$r/$1")
module=$(sed -n 's/^otel.version(version = "\(.*\)")/\1/p' "$r/$2")
image=$(sed -n 's|.*image: "otel/opentelemetry-collector-contrib:\(.*\)"|\1|p' "$r/$3" | sort -u)
binary=$("$r/$4" --version | awk '{print $NF}')
echo "DEFAULT_VERSION=$default MODULE.bazel=$module image=$image binary=$binary"
[[ -n "$default" && "$module" == "$default" && "$image" == "$default" && "$binary" == "$default" ]] \
  || fail "versions differ (re-render the chart, or re-pin with tools/update_checksums.sh)"
echo "PASS"
