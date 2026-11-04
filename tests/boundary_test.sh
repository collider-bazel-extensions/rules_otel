#!/usr/bin/env bash
# The case from rules_otel#4: a production-shaped config (fixed ports,
# ${env:...} backends) runs on free ports; while the backend is down the
# collector logs `Exporting failed` naming it and queues; once the backend
# answers, the queued series arrive, over OTLP/HTTP and remote write.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$OTEL_TESTLIB"

# The config's fixed ports were moved.
[[ "$OTEL_COLLECTOR_OTLP_HTTP" != *:4318 ]] || fail "OTLP/HTTP still on 4318"
[[ "$OTEL_COLLECTOR_OTLP_GRPC" != *:4317 ]] || fail "OTLP/gRPC still on 4317"
[[ "$OTEL_COLLECTOR_HEALTH_URL" != *:13133/ ]] || fail "health still on 13133"
[[ "$OTEL_COLLECTOR_METRICS_URL" != *:8888/* ]] || fail "own metrics still on 8888"
echo "ok: fixed ports moved to $OTEL_COLLECTOR_OTLP_HTTP, $OTEL_COLLECTOR_OTLP_GRPC"

otel_sink_down
otel_send_metric boundary.probe 7 cell=a
line=$(otel_log_wait 'Exporting failed.*otlphttp/mimir')
grep -qF "${OTEL_SINK_URL#http://}" <<<"$line" || fail "failure doesn't name the endpoint: $line"
otel_log_wait 'Exporting failed.*prometheusremotewrite/mimir' >/dev/null
otel_self_metric_wait otelcol_exporter_queue_size 1 exporter=otlphttp/mimir >/dev/null
[[ "$(otel_sink_count metrics)" == 0 ]] || fail "sink got data while down"
echo "ok: backend down: 'Exporting failed' naming it, the series queued"

otel_sink_up
otel_sink_wait metrics boundary.probe cell=a
otel_sink_dump metrics boundary.probe | grep -q '"value": 7' || fail "OTLP value"
echo "ok: backend up: the queued series delivered over OTLP/HTTP"

# Remote write has no queue of its own here: after its 5 s timeout it
# drops data rather than holding it. A fresh series goes through.
otel_send_metric boundary.after 9 cell=b
otel_sink_wait metrics boundary_after cell=b      # Prometheus naming
otel_sink_dump metrics boundary_after | grep -q '"type": "prometheus"' || fail "remote write record"
otel_sink_dump metrics boundary_after | grep -q '"value": 9.0' || fail "remote write value"
echo "ok: remote write decoded (snappy + protobuf)"

otel_sink_fail 503
otel_send_span boundary.span
for _ in $(seq 50); do grep -q '^503 /v1/traces' "$OTEL_SINK_DIR/requests.log" && break; sleep 0.1; done
grep -q '^503 /v1/traces' "$OTEL_SINK_DIR/requests.log" || fail "sink didn't answer 503"
otel_sink_up
otel_sink_wait traces boundary.span
echo "ok: backend 503, then recovers"
echo "PASS"
