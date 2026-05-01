# rules_otel — design decisions

Hermetic [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
install for Bazel test compositions. Same shape as `rules_loki` /
`rules_grafana` / `rules_harbor` / `rules_external_secrets` /
`rules_kafka` / `rules_tempo` — pure glue over `rules_kubectl` +
`rules_helm`.

## Decided

| # | Decision | Choice | Source |
|---|---|---|---|
| 1 | Bzlmod / WORKSPACE | **Bzlmod-only at v0.1.** | Sibling-family |
| 2 | Module / repo name | `rules_otel`. (Module names disallow hyphens; the upstream repo + image names use them.) | Bzlmod constraint + convention |
| 3 | Architecture | **Layered.** Two macros wrapping `kubectl_apply` / `kubectl_apply_health_check`. | rules_loki precedent |
| 4 | Manifest provisioning | `opentelemetry-collector` helm chart **pre-rendered** into `private/manifests/otel.yaml` via `rules_helm`. Committed. | rules_loki pattern |
| 5 | Plain collector vs. operator | **Plain `opentelemetry-collector` chart** at v0.1. The OpenTelemetry Operator (separate `opentelemetry-operator` chart) installs an operator + ships `OpenTelemetryCollector` / `Instrumentation` CRDs — different family (operator + CRD-driven smoke, comparable to rules_cloudnativepg's shape). The plain collector is one Deployment + Service + ConfigMap, strictly simpler for v0.1. See "Plain collector vs. operator" below. | Smaller smoke surface |
| 6 | Single-version | One pinned chart (`0.153.0`, collector app `0.151.0`). | Pragmatic |
| 7 | Render mode | **Smoke fixture.** `mode: deployment` (single-replica gateway), OTLP receiver only (gRPC + HTTP), `debug` exporter at `verbosity: detailed`, traces / metrics / logs pipelines all using OTLP → batch → debug. README warns the values are not a production starting point. | Smoke pragmatic |
| 8 | Public surface | `otel_install`, `otel_health_check`. **No `otel_collector` rule** — collector configuration is dense YAML (receivers/processors/exporters/pipelines + service.telemetry); v0.1 documents the YAML pattern + ships `examples/`. | Smaller surface |
| 9 | Namespace | `otel` (default, idempotent create). | Convention |
| 10 | Wait shape | One Deployment (`otel-opentelemetry-collector`). The chart's release name is pinned to `otel` at maintainer-render time, so the Deployment name is the chart's `<release>-opentelemetry-collector` template. No CRDs (operator chart ships them; this rule set wraps the plain chart). | Plain-collector specific |
| 11 | Smoke client | **`kubectl run` a curl pod.** Same approach as rules_tempo — OTLP/JSON push from a curl pod is the lightest possible client. | Pragmatic |
| 12 | Smoke assertion | Generate a unique marker string. POST an OTLP/JSON trace at `<svc>:4318/v1/traces` with the marker as a span attribute. Poll the collector pod's logs (`kubectl logs deploy/...`) until the marker appears — the `debug` exporter at verbosity `detailed` writes every received record's attributes to stdout. Proves OTLP receiver + batch processor + debug exporter all wired correctly — **not** "collector pod is up." | Per the family's "exercise the functionality" rule |
| 13 | Cross-rule deps | `rules_kubectl` public dep. `rules_helm` + `rules_kind` + `rules_itest` + `rules_shell` dev-only. | rules_loki precedent |
| 14 | Naming | snake_case rules/macros, `MixedCaseInfo` providers (none in v0.1), `UPPER_SNAKE` constants. | All siblings |
| 15 | Update workflow | `bash tools/render_otel.sh <chart-version>` → thin shim. | rules_loki precedent |

## Plain collector vs. operator

Two reasonable paths to install OpenTelemetry on Kubernetes:

- **Plain `opentelemetry-collector` chart** — direct Deployment /
  DaemonSet / StatefulSet (configurable via `mode`). The whole
  collector configuration lives in a single ConfigMap rendered from
  Helm values. Matches rules_loki / rules_grafana shape: one
  `kubectl_apply` + done.
- **`opentelemetry-operator` chart** — operator pod + `OpenTelemetryCollector`
  CRD (declaratively reconcile collector instances) + `Instrumentation`
  CRD (auto-instrument app pods by adding init-containers + env vars).
  Matches rules_cloudnativepg's shape: install operator, smoke applies
  CRs, asserts on operator-reconciled state.

v0.1 picks the **plain collector** because:

1. Structurally simpler — one Deployment, no operator pod, no CRDs to
   wait on, no admission webhook.
2. The chart's defaults map cleanly to "smoke fixture" with a few
   overrides (mode, image, alternateConfig).
3. Most production Kubernetes deployments still use the plain chart
   directly — auto-instrumentation via `Instrumentation` CRDs is the
   value-add of the operator, but lots of teams don't want that and
   stick with explicit SDK setup.

A future `rules_otel_operator` (or this rule set with a `mode = ...`
toggle) would be a reasonable companion.

## Why `alternateConfig`, not `config`

The chart provides two ways to configure the collector:

- `config:` — deep-merged with the chart's defaults. The chart ships a
  `config:` that includes jaeger + zipkin receivers, prometheus
  self-scrape, traces / metrics / logs pipelines using all of the
  above. Helm's deep-merge keeps default keys you don't override —
  trying to *remove* a default receiver or pipeline by setting it to
  `null` doesn't work because of [a known Helm bug](https://github.com/helm/helm/pull/12879)
  that the chart's docs explicitly call out.
- `alternateConfig:` — replaces the chart's default outright (no
  merge). Documented as the escape hatch for cases where you need to
  remove default config.

v0.1 uses `alternateConfig` so the rendered collector config is
exactly what we wrote: OTLP-only receiver, batch-only processor,
debug-only exporter, traces / metrics / logs pipelines. No surprises.

## Why `verbosity: detailed` on the debug exporter

The `debug` exporter has three verbosity levels:
- `basic` (default): just record counts ("Trace #0: 1 span").
- `normal`: counts + resource attributes per record.
- `detailed`: counts + resource attributes + per-record body
  (span name, attributes, events).

The smoke greps the collector logs for a unique marker stored as a
span attribute. Only `detailed` writes attribute values to stdout —
`basic` and `normal` would pass even if the marker was wrong.

## Image — `contrib` not `core`

The chart requires `image.repository` to be set explicitly (no
default). Two valid choices:
- `otel/opentelemetry-collector-contrib` — all upstream components.
  Used here.
- `otel/opentelemetry-collector` — only the stable / "core" components
  (notably omits `prometheusremotewrite` exporter, k8s receivers,
  most of the receivers we'd add for real backends). Requires
  `command.name: otelcol` since its entrypoint differs.

v0.1 picks contrib so consumers can pivot exporters / receivers
without re-pinning the image. The size delta (~150MB) isn't large
enough to matter for a smoke fixture.

## v0.1.0 status

| Area | State |
|---|---|
| MODULE.bazel (Bzlmod-only) | done |
| `otel_install` + `otel_health_check` macros | done |
| Pinned `opentelemetry-collector` chart 0.153.0 (rendered + committed) | done |
| `config/otel-values.yaml` (exported) | done |
| Maintainer render flow (`bash tools/render_otel.sh <ver>`) | done |
| Analysis test | done |
| Smoke (kind + collector + OTLP/JSON push + log-grep round-trip) | done |
| `examples/` (debug-exporter, real backend export sketch, OTLP curl) | done |

## Deferred (not v0.1.0)

- **DaemonSet mode** — `mode: daemonset`, the canonical "node-local
  agent" topology. Different smoke shape (DaemonSet readiness,
  hostNetwork option).
- **StatefulSet mode** — for collectors with persistent queue
  exporters (e.g., `file_storage` extension).
- **OpenTelemetry Operator variant** — separate rule set or
  `mode = "operator"` toggle. Adds CRD wait + CR-driven smoke.
- **Compose with `rules_tempo` / `rules_mimir` / `rules_loki`** —
  cross-rule composition smoke: collector → real backend →
  smoke verifies the backend got it. Modeled on
  rules_mimir + rules_kafka.
- **Auto-instrumentation smoke** (operator-only) — apply an
  `Instrumentation` CR, deploy a sample app, assert the operator
  injected init-containers + the app's traces show up in the
  collector. v0.2+ when operator path lands.
- **k8s receivers smoke** — `k8sevents`, `k8sobjects`, `k8sattributes`.
  Smoke would generate a Pod event and assert it lands at the
  collector. Different chart preset (`presets.kubernetesEvents`).
- **Multi-version chart support** — single pin in v0.1.
