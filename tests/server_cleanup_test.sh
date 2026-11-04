#!/usr/bin/env bash
# otel_collector_test's trampoline stops the collector when the test ends:
# run it to completion (in its own session, so nothing else kills its
# children), then check the ports it recorded are closed.
#
# Argv: <trampoline> <record_port server> <record_port inner>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

export RECORD_FILE="$TEST_TMPDIR/ports"
inner_tmp="$TEST_TMPDIR/inner"; mkdir -p "$inner_tmp"
TEST_TMPDIR="$inner_tmp" setsid "$TEST_SRCDIR/_main/$1" "$2" "$3" record_port_otelcol \
  || fail "trampoline exited $?"
read -r otlp sink < "$RECORD_FILE"
[[ -n "$otlp" && -n "$sink" ]] || fail "no ports recorded"
for port in "$otlp" "$sink"; do
  closed=""
  for _ in $(seq 1 50); do
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || { closed=1; break; }
    sleep 0.1
  done
  [[ -n "$closed" ]] || fail "still listening on $port after the test ended"
done
echo "PASS: collector ($otlp) and sink ($sink) stopped"
