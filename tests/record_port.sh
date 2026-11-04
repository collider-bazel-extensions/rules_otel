#!/usr/bin/env bash
# Inner test for server_cleanup_test: records where the collector listened.
set -euo pipefail
echo "${OTEL_COLLECTOR_OTLP_HTTP##*:} ${OTEL_SINK_URL##*:}" > "$RECORD_FILE"
