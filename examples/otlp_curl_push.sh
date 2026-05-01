#!/usr/bin/env bash
# Minimal OTLP/JSON push from a curl pod. Same shape the rule set's
# `tests/smoke_test.sh` uses — extracted for reference. Run after
# `otel_install` is healthy.
#
# Assumes:
#   - kubectl on PATH, KUBECONFIG pointing at the cluster.
#   - Collector installed in namespace `otel`, OTLP/HTTP on 4318.
#   - debug exporter at verbosity=detailed (the v0.1 smoke render).
set -euo pipefail

NS="${NS:-default}"
OTEL_NS="${OTEL_NS:-otel}"
OTEL_SVC="${OTEL_SVC:-otel-opentelemetry-collector.${OTEL_NS}.svc.cluster.local}"
TRACE_ID=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
SPAN_ID=$(head -c 8  /dev/urandom | od -An -tx1 | tr -d ' \n')
MARKER="example-$RANDOM-$(date +%s)"
NOW_NS=$(( $(date +%s) * 1000000000 ))
END_NS=$(( NOW_NS + 1000000 ))

echo "[otlp_push] launching curl pod, marker=$MARKER"
kubectl -n "$NS" run otel-push --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- sleep 300
trap 'kubectl -n "$NS" delete pod otel-push --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
kubectl -n "$NS" wait pod/otel-push --for=condition=Ready --timeout=60s

PAYLOAD=$(cat <<EOF
{
  "resourceSpans": [{
    "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "demo"}}]},
    "scopeSpans": [{
      "scope": {"name": "demo-tracer"},
      "spans": [{
        "traceId": "${TRACE_ID}",
        "spanId": "${SPAN_ID}",
        "name": "demo-span",
        "kind": 1,
        "startTimeUnixNano": "${NOW_NS}",
        "endTimeUnixNano": "${END_NS}",
        "attributes": [{"key": "demo.marker", "value": {"stringValue": "${MARKER}"}}]
      }]
    }]
  }]
}
EOF
)

echo "[otlp_push] POSTing trace_id=$TRACE_ID"
kubectl -n "$NS" exec otel-push -- \
    curl -sS -X POST -H 'Content-Type: application/json' \
    --data-binary "$PAYLOAD" \
    "http://${OTEL_SVC}:4318/v1/traces"

echo "[otlp_push] tail of collector logs (debug exporter at verbosity=detailed):"
sleep 2
kubectl -n "$OTEL_NS" logs deploy/otel-opentelemetry-collector --tail=40 | grep -E "${MARKER}|smoke-span|demo-span" || \
    echo "[otlp_push] (marker not in tail — try `kubectl logs ... -f` to see live)"
