#!/usr/bin/env bash
# A collector that refuses its config, exits, or isn't healthy in time
# makes the server exit non-zero, name the cause, print the log and write
# no env file; otel_collector_test fails before running the test body.
#
# Argv: <unset_env server> <bad_set server> <slow server> <trampoline>
#       <failing test server> <failing test inner>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

run() {
  local name="$1" path="$TEST_SRCDIR/_main/$2" rc=0
  out=$(timeout 120 "$path" 2>&1) || rc=$?
  [[ "$rc" != 0 ]] || fail "$name: exited 0. Output: $out"
  [[ "$rc" != 124 ]] || fail "$name: hung. Output: $out"
  [[ ! -f "$TEST_TMPDIR/$name.env" ]] || fail "$name: env file written"
}

run unset_env_server "$1"
grep -q "the collector refused its config" <<<"$out" || fail "unset_env: cause: $out"
grep -q "at least one endpoint must be specified" <<<"$out" || fail "unset_env: collector message: $out"
grep -qF 'unset: ${env:MIMIR_URL}' <<<"$out" || fail "unset_env: variable not named: $out"
echo "ok: config refused (unset variable named)"

run bad_set_server "$2"
grep -q "otelcol-contrib exited with status 1 before it was healthy" <<<"$out" || fail "bad_set: cause: $out"
grep -q "timeout" <<<"$out" || fail "bad_set: collector log not shown: $out"
echo "ok: collector that exits at start"

run slow_server "$3"
grep -q "otelcol-contrib not healthy at http://127.0.0.1:[0-9]*/ after 0.001s" <<<"$out" || fail "slow: cause: $out"
echo "ok: health timeout"
# Nothing left behind: the collector it started was stopped.
hport=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["extensions"]["health_check/rules_otel"]["endpoint"].split(":")[1])' \
  "$TEST_TMPDIR/otel-slow_server/overlay.json")
for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$hport") 2>/dev/null || break; sleep 0.1; done
if (exec 3<>"/dev/tcp/127.0.0.1/$hport") 2>/dev/null; then fail "slow: collector left running on $hport"; fi

inner_tmp="$TEST_TMPDIR/inner"; mkdir -p "$inner_tmp"
rc=0
out=$(TEST_TMPDIR="$inner_tmp" timeout 120 "$TEST_SRCDIR/_main/$4" "$5" "$6" failing_otel_test_otelcol 2>&1) || rc=$?
[[ "$rc" != 0 && "$rc" != 124 ]] || fail "failing otel_collector_test: status $rc: $out"
grep -q "otel_collector_test: the collector exited" <<<"$out" || fail "otel_collector_test: cause: $out"
if grep -q "TEST BODY RAN" <<<"$out"; then fail "otel_collector_test ran the test body"; fi
echo "ok: otel_collector_test fails before the test runs"
echo "PASS"
