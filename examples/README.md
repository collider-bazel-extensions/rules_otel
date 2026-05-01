# Examples

Reference push / configuration shapes for the OpenTelemetry Collector.
Apply them after `otel_install` has the collector running.

| File | Use case | Exercised by smoke? |
|---|---|---|
| [`otlp_curl_push.sh`](otlp_curl_push.sh) | Minimal OTLP/JSON push from a curl pod — same shape as `tests/smoke_test.sh` but extracted for reading. POSTs a single trace and prints the collector's debug-exporter output. | Yes (the rule set's smoke uses this exact pattern) |
| [`backend_export.yaml`](backend_export.yaml) | `alternateConfig:` override that swaps the `debug` exporter for `otlp` pointing at an external backend (Tempo / Mimir / Honeycomb / etc.). The realistic production shape. | No (sketch — not exercised by v0.1's smoke) |
| [`auto_instrumentation_note.md`](auto_instrumentation_note.md) | Why the OpenTelemetry Operator + `Instrumentation` CRD are NOT in v0.1, and how a downstream rule set would compose if/when they land. | N/A (doc) |

## Connecting from your own code

Inside the cluster, point your OpenTelemetry SDK / instrumentation at:

```
OTLP/gRPC:   otel-opentelemetry-collector.otel.svc.cluster.local:4317
OTLP/HTTP:   http://otel-opentelemetry-collector.otel.svc.cluster.local:4318
```

The smoke render only enables the OTLP receiver. If you need Jaeger,
Zipkin, or Prometheus scraping, override `alternateConfig` to add
those receivers + map them into the appropriate pipeline.

## Things this directory deliberately does NOT show

- **The `Instrumentation` CRD path** — that's the operator chart's
  feature. v0.1 wraps the plain collector chart only.
- **DaemonSet / StatefulSet mode renders** — chart supports them via
  `mode: daemonset` / `mode: statefulset`, but the rendered manifest
  + wait shape differ. v0.1 ships `mode: deployment` only.
- **Specific backend credentials** — Honeycomb, Datadog, Lightstep,
  Grafana Cloud. Each backend has its own auth flow; consumers
  should use their secret-management of choice (`extraEnvs`,
  `extraEnvsFrom: secretRef`, etc.).
- **Auto-scaling** — chart supports HPA via `autoscaling.enabled`.
  Single-replica smoke fixture doesn't need it.
