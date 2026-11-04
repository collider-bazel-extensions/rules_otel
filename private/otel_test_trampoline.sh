#!/usr/bin/env bash
# otel_collector_test trampoline — starts the collector, then runs the
# user's test.
#
# Argv: <server> <inner> <server_name> [user args...]
set -euo pipefail

SERVER_SHORT="$1"; INNER_SHORT="$2"; SERVER_NAME="$3"
shift 3

: "${TEST_TMPDIR:?otel_collector_test: TEST_TMPDIR not set (expected under bazel test)}"
if [[ -z "${RUNFILES_DIR:-}" ]]; then
  RUNFILES_DIR="${TEST_SRCDIR:-$0.runfiles}"
  export RUNFILES_DIR
fi

resolve() {
  local p="$1"
  for c in "${RUNFILES_DIR}/_main/${p}" "${RUNFILES_DIR}/${p}" "${RUNFILES_DIR}/${p#../}"; do
    [[ -e "$c" ]] && { printf '%s\n' "$c"; return; }
  done
  echo "otel_collector_test: not in runfiles: ${p}" >&2
  exit 1
}

server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

env_file="$TEST_TMPDIR/${SERVER_NAME}.env"
rm -f "$env_file"
server="$(resolve "$SERVER_SHORT")"
inner="$(resolve "$INNER_SHORT")"
"$server" &
server_pid=$!
# The server enforces its own ready_timeout; this outer bound only guards
# against a hung launcher.
deadline=$(( $(date +%s) + 600 ))
until [[ -f "$env_file" ]]; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    wait "$server_pid" && rc=0 || rc=$?
    server_pid=""
    echo "otel_collector_test: the collector exited (status $rc) before it was healthy; see [otel] lines above" >&2
    exit 1
  fi
  (( $(date +%s) < deadline )) || { echo "otel_collector_test: timed out waiting for $env_file" >&2; exit 1; }
  sleep 0.1
done

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

# Not exec: the trap must stop the collector when the test ends.
"$inner" "$@"
