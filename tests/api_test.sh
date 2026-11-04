#!/usr/bin/env bash
# otel_collector_test with the built-in config: the env file, every helper,
# and the sink's view of what the collector exported.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$OTEL_TESTLIB"

[[ "$#" == 2 && "$1" == one && "$2" == "two words" ]] || fail "args: $*"
for v in OTEL_COLLECTOR_OTLP_GRPC OTEL_COLLECTOR_OTLP_HTTP OTEL_EXPORTER_OTLP_ENDPOINT \
         OTEL_COLLECTOR_HEALTH_URL OTEL_COLLECTOR_METRICS_URL OTEL_COLLECTOR_LOG \
         OTEL_SINK_URL OTEL_SINK_DIR OTEL_CONTROL_URL OTELCOL OTEL_TOOL; do
  [[ -n "${!v:-}" ]] || fail "$v not set"
done
[[ "$OTEL_EXPORTER_OTLP_ENDPOINT" == "$OTEL_COLLECTOR_OTLP_HTTP" ]] || fail "SDK endpoint"
[[ "$OTEL_EXPORTER_OTLP_PROTOCOL" == http/protobuf ]] || fail "SDK protocol"
"$OTELCOL" --version | grep -q "otelcol-contrib version 0.151.0" || fail "binary version"
python3 - "$OTEL_COLLECTOR_HEALTH_URL" <<'PY' || fail "health endpoint"
import sys, urllib.request
assert urllib.request.urlopen(sys.argv[1]).status == 200
PY
echo "ok: env file"

otel_send_metric api.gauge 42 env=test
otel_send_sum api.requests 3.5
otel_send_span api.op peer=db
otel_send_log "user logged in" --severity WARN user=ada

otel_sink_wait metrics api.gauge env=test
otel_sink_wait metrics api.requests
otel_sink_wait traces api.op peer=db
otel_sink_wait logs "logged in" user=ada
python3 - "$OTEL_SINK_DIR" <<'PY' || fail "sink records"
import json, sys
d = sys.argv[1]
rd = lambda s: [json.loads(l) for l in open(f"{d}/{s}.jsonl")]
g = [r for r in rd("metrics") if r["name"] == "api.gauge"][0]
assert g["type"] == "gauge" and g["value"] == 42 and g["attributes"] == {"env": "test"}, g
assert g["resource"]["service.name"] == "rules_otel_test", g
s = [r for r in rd("metrics") if r["name"] == "api.requests"][0]
assert s["type"] == "sum" and s["value"] == 3.5, s
t = rd("traces")[0]
assert t["name"] == "api.op" and len(t["trace_id"]) == 32 and len(t["span_id"]) == 16, t
l = rd("logs")[0]
assert l["body"] == "user logged in" and l["severity_text"] == "WARN" and l["severity_number"] == 13, l
PY
[[ "$(otel_sink_count metrics)" == 2 ]] || fail "metric count $(otel_sink_count metrics)"
[[ "$(otel_sink_count metrics api.gauge env=prod)" == 0 ]] || fail "attribute filter"
otel_sink_dump traces | grep -q '"name": "api.op"' || fail "dump"
grep -q '^200 /v1/metrics' "$OTEL_SINK_DIR/requests.log" || fail "requests.log"
echo "ok: send / sink helpers (protobuf + gzip from the otlphttp exporter)"

otel_self_metric_wait otelcol_exporter_sent_metric_points_total 2 exporter=otlphttp/sink >/dev/null
[[ "$(otel_self_metric otelcol_receiver_accepted_spans_total)" == 1 ]] || fail "self metric"
[[ "$(otel_self_metric no_such_metric)" == 0 ]] || fail "missing self metric"
otel_log_wait "Everything is ready" >/dev/null
echo "ok: the collector's own metrics and log"

rc=0; out=$(otel_sink_wait metrics never.sent --timeout 0.5 2>&1) || rc=$?
[[ "$rc" != 0 ]] || fail "sink wait passed for a metric never sent"
grep -q "0 of 1 after 0.5s" <<<"$out" || fail "sink wait message: $out"
echo "ok: a failed wait says what it saw"
echo "PASS"
