#!/usr/bin/env bash
# Two OTLP receivers (the second gets its own variables), a health_check on
# a custom path, and an exporter sending OTLP/JSON to the sink.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$OTEL_TESTLIB"

[[ -n "${OTEL_COLLECTOR_OTLP_HTTP:-}" && -z "${OTEL_COLLECTOR_OTLP_GRPC:-}" ]] || fail "first receiver vars"
[[ -n "${OTEL_COLLECTOR_OTLP_INTERNAL_HTTP:-}" && -n "${OTEL_COLLECTOR_OTLP_INTERNAL_GRPC:-}" ]] || fail "otlp/internal vars"
[[ "$OTEL_COLLECTOR_HEALTH_URL" == */status ]] || fail "health path: $OTEL_COLLECTOR_HEALTH_URL"
[[ "$OTEL_COLLECTOR_HEALTH_URL" != *:13133/status ]] || fail "health port not moved"
echo "ok: receivers and health path"

otel_send_log "via the first receiver" n=1
OTEL_COLLECTOR_OTLP_HTTP="$OTEL_COLLECTOR_OTLP_INTERNAL_HTTP" otel_send_span via.internal
otel_sink_wait logs "first receiver" n=1
otel_sink_wait traces via.internal
grep -q '^200 /v1/logs' "$OTEL_SINK_DIR/requests.log" || fail "requests.log"
echo "ok: OTLP/JSON exports decoded"
echo "PASS"
