#!/usr/bin/env bash
# Round-trip a trace through the OpenTelemetry Collector to prove the
# receiver → processor → exporter pipeline works. Strategy:
#
#   1. `kubectl run` a curl pod inside the cluster.
#   2. POST an OTLP/JSON trace at the collector's OTLP/HTTP endpoint:
#      `http://otel-opentelemetry-collector.otel.svc.cluster.local:4318/v1/traces`.
#      The payload has one resource, one scope, one span carrying a
#      unique `smoke.marker` attribute.
#   3. The collector's `debug` exporter (verbosity=detailed in
#      otel-values.yaml) prints every received record to stdout — span
#      name, attributes, the works.
#   4. Grep the collector pod's logs for the unique marker.
#
# Proves: OTLP receiver + batch processor + debug exporter all wired
# correctly. Not "collector pod is up". The marker is uniquely
# generated per run so we don't flake on stale log lines from a
# previous test (which can't happen anyway in a fresh kind cluster,
# but the discipline transfers to consumers running in long-lived
# clusters).
set -euo pipefail

CLUSTER_NAME="cluster"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

NS="smoke"
OTEL_NS="otel"
OTEL_SVC="otel-opentelemetry-collector.${OTEL_NS}.svc.cluster.local"
TRACE_ID=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
SPAN_ID=$(head -c 8  /dev/urandom | od -An -tx1 | tr -d ' \n')
MARKER="rules-otel-smoke-$RANDOM-$(date +%s)"
NOW_NS=$(( $(date +%s) * 1000000000 ))
END_NS=$(( NOW_NS + 1000000 ))

echo "smoke_test: trace_id=$TRACE_ID marker=$MARKER"

echo "smoke_test: launching curl pod"
"${KCTL[@]}" create namespace "$NS" --dry-run=client -o yaml | "${KCTL[@]}" apply -f - >/dev/null
"${KCTL[@]}" -n "$NS" run otel-curl --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- sleep 600
trap '"${KCTL[@]}" -n "$NS" delete pod otel-curl --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
"${KCTL[@]}" -n "$NS" wait pod/otel-curl --for=condition=Ready --timeout=60s

PAYLOAD=$(cat <<EOF
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        {"key": "service.name", "value": {"stringValue": "smoke"}}
      ]
    },
    "scopeSpans": [{
      "scope": {"name": "rules-otel-smoke"},
      "spans": [{
        "traceId": "${TRACE_ID}",
        "spanId": "${SPAN_ID}",
        "name": "smoke-span",
        "kind": 1,
        "startTimeUnixNano": "${NOW_NS}",
        "endTimeUnixNano": "${END_NS}",
        "attributes": [
          {"key": "smoke.marker", "value": {"stringValue": "${MARKER}"}}
        ]
      }]
    }]
  }]
}
EOF
)

echo "smoke_test: POSTing OTLP/JSON trace to ${OTEL_SVC}:4318/v1/traces"
post_status=$("${KCTL[@]}" -n "$NS" exec otel-curl -- \
    curl -s -o /dev/null -w "%{http_code}" \
    -X POST -H "Content-Type: application/json" \
    --data-binary "$PAYLOAD" \
    "http://${OTEL_SVC}:4318/v1/traces")
if [[ "$post_status" != "200" ]]; then
  echo "smoke_test: FAIL — OTLP push returned HTTP $post_status (expected 200)" >&2
  exit 1
fi
echo "smoke_test: OTLP push -> 200"

# The batch processor flushes on its `timeout` (default 200ms) or when
# the batch fills (default 8192 records). One record well under the
# size threshold, so we wait the timeout + headroom. Poll the logs for
# up to 60s in case the runner is loaded.
echo "smoke_test: polling collector pod logs for marker '${MARKER}'"
deadline=$(( $(date +%s) + 60 ))
got=""
while (( $(date +%s) < deadline )); do
  if "${KCTL[@]}" -n "$OTEL_NS" logs deploy/otel-opentelemetry-collector --tail=2000 2>/dev/null \
       | grep -q "$MARKER"; then
    got=1
    break
  fi
  sleep 2
done

if [[ -z "$got" ]]; then
  echo "smoke_test: FAIL — marker '${MARKER}' never appeared in collector logs" >&2
  echo "---- collector logs (tail) ----" >&2
  "${KCTL[@]}" -n "$OTEL_NS" logs deploy/otel-opentelemetry-collector --tail=80 >&2 || true
  exit 1
fi

echo "smoke_test: OK — marker '${MARKER}' appeared in collector logs (OTLP -> batch -> debug exporter)"
