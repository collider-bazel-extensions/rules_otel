#!/usr/bin/env bash
# otel_config's validation action, run directly: a good config passes with
# its placeholders; bad ones fail with the collector's own message; the
# build host's environment never reaches the check.
#
# Argv: <launcher.py> <otelcol-contrib> <testdata dir (any file in it)>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

L="$TEST_SRCDIR/_main/$1"; B="$TEST_SRCDIR/_main/$2"; D="$(dirname "$TEST_SRCDIR/_main/$3")"
marker="$TEST_TMPDIR/marker"

check() {  # check <file> [--env K=V...]; sets $out and $rc
  local f="$1"; shift
  rm -f "$marker"; rc=0
  out=$(python3 "$L" check --otelcol "$B" --marker "$marker" --config "$D/$f" --label "//t:$f" "$@" 2>&1) || rc=$?
}

check boundary.yaml --env MIMIR_URL=http://mimir.example:9009/otlp
[[ "$rc" == 0 && -f "$marker" ]] || fail "good config refused: $out"
echo "ok: good config with placeholders"

MIMIR_URL=http://from-the-host:9009 check boundary.yaml
[[ "$rc" != 0 && ! -f "$marker" ]] || fail "passed without placeholders (host env leaked?)"
grep -q "at least one endpoint must be specified" <<<"$out" || fail "no collector message: $out"
grep -qF 'unset at build time: ${env:MIMIR_URL}' <<<"$out" || fail "no unset hint: $out"
echo "ok: host environment not used; unset variables named"

expect() {  # expect <file> <message>
  check "$1"
  [[ "$rc" != 0 && ! -f "$marker" ]] || fail "$1: accepted"
  grep -q "otel_config //t:$1: otelcol-contrib refused it" <<<"$out" || fail "$1: label not named: $out"
  grep -qF "$2" <<<"$out" || fail "$1: expected '$2' in: $out"
  echo "ok: $1 refused ($2)"
}
expect bad_component.yaml "unknown type: \"nosuchexporter\""
expect bad_field.yaml "has invalid keys: timeoutt"
expect undefined_ref.yaml "references exporter \"otlphttp/mimr\" which is not configured"
echo "PASS"
