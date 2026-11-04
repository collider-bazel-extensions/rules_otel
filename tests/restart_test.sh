#!/usr/bin/env bash
# The collector stops and starts again mid-test, on the same ports.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$OTEL_TESTLIB"

otel_send_metric before.restart
otel_sink_wait metrics before.restart
otel_collector_stop
if otel_send_metric while.stopped 2>/dev/null; then fail "collector still accepting after stop"; fi
python3 - "$OTEL_COLLECTOR_HEALTH_URL" <<'PY' && fail "health still up after stop"
import sys, urllib.request
urllib.request.urlopen(sys.argv[1], timeout=2)
PY
echo "ok: stopped"

otel_collector_start
otel_collector_start   # already running: no-op
otel_send_metric after.restart
otel_sink_wait metrics after.restart
[[ "$(grep -c 'rules_otel: starting' "$OTEL_COLLECTOR_LOG")" == 2 ]] || fail "expected two starts in the log"
echo "ok: started again on $OTEL_COLLECTOR_OTLP_HTTP"
echo "PASS"
