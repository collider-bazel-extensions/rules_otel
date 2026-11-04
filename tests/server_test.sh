#!/usr/bin/env bash
# otel_collector_server run directly (as rules_itest would): env file,
# extra_args, SIGTERM.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

SERVER="$TEST_SRCDIR/_main/$1"
env_file="$TEST_TMPDIR/test_server.env"
rm -f "$env_file"
"$SERVER" &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 300); do [[ -f "$env_file" ]] && break; sleep 0.1; done
[[ -f "$env_file" ]] || fail "env file not written"
set -a; source "$env_file"; set +a
source "$OTEL_TESTLIB"
grep -q -- "--set=processors.batch.timeout=50ms" "$OTEL_COLLECTOR_LOG" || fail "extra_args not passed"
otel_send_metric direct.run
otel_sink_wait metrics direct.run
echo "ok: server"

ports=("${OTEL_COLLECTOR_OTLP_HTTP##*:}" "${OTEL_COLLECTOR_OTLP_GRPC##*:}" "${OTEL_SINK_URL##*:}" "${OTEL_CONTROL_URL##*:}")
kill -TERM "$pid"
rc=0; wait "$pid" || rc=$?
trap - EXIT
[[ "$rc" == 0 ]] || fail "SIGTERM exit status $rc"
[[ ! -f "$env_file" ]] || fail "env file left after SIGTERM"
for p in "${ports[@]}"; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then fail "port $p still open"; fi
done
echo "ok: SIGTERM stops the collector and the sink, exit 0, env file removed"
echo "PASS"
