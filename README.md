# rules_otel

Hermetic [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
install for Bazel test compositions. Pure glue layer over
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl) —
`otel_install` is a macro emitting a `kubectl_apply` target pre-configured
with the collector's pinned manifest and the right wait shape.

```python
load("@rules_otel//:defs.bzl", "otel_install", "otel_health_check")

otel_install(name = "otel_install_bin")          # default ns: otel
otel_health_check(name = "otel_health_bin")
```

That's the whole API. The OpenTelemetry Collector receives telemetry
(traces / metrics / logs) over OTLP / Jaeger / Zipkin / Prometheus,
runs it through processors (batch, filter, transform), and exports
to backends (Tempo / Mimir / Loki / OTLP-compatible vendors). This
rule set installs the collector ready to receive OTLP and emit to
the `debug` exporter for inspection — pivot the exporter to a real
backend in your consumer override.

**Pinned versions:** `opentelemetry-collector` helm chart `0.153.0`
(collector app `0.151.0`). Smoke-fixture render — `mode: deployment`
(gateway topology), single replica, OTLP receiver only (gRPC `:4317`
and HTTP `:4318`), `debug` exporter at `verbosity: detailed`. The
values file is exported as `@rules_otel//config:otel-values.yaml`
for inspection / extension.

**Image:** `otel/opentelemetry-collector-contrib` — the "contrib"
build with all upstream receivers / processors / exporters. The chart
requires `image.repository` to be set explicitly (no default); we
pick contrib so consumers can swap in any real backend exporter
without re-pinning the image.

**Supported platforms (v0.1):** any platform where rules_kubectl runs.
Validated on Linux x86\_64 in CI.

---

## Contents

- [Installation](#installation) (Bzlmod-only)
- [Quickstart](#quickstart)
- [Pushing telemetry](#pushing-telemetry)
- [Macros](#macros)
- [Hermeticity exceptions](#hermeticity-exceptions)
- [Contributing](#contributing)

---

## Installation

```python
bazel_dep(name = "rules_otel", version = "0.1.0")
```

Bzlmod-only. Transitively pulls in
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl).

---

## Quickstart

```python
load("@rules_itest//:itest.bzl", "itest_service", "service_test")
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")
load("@rules_otel//:defs.bzl", "otel_install", "otel_health_check")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

# 1. Cluster.
kind_cluster(name = "cluster", k8s_version = "1.35")
kind_health_check(name = "cluster_health", cluster = ":cluster")
itest_service(name = "kind_svc", exe = ":cluster", health_check = ":cluster_health")

# 2. OpenTelemetry Collector.
otel_install(name = "otel_install_bin")
otel_health_check(name = "otel_health_bin")
sh_binary(name = "otel_install_wrapper", srcs = ["install_wrapper.sh"], data = [":otel_install_bin"])
sh_binary(name = "otel_health_wrapper",  srcs = ["health_wrapper.sh"],  data = [":otel_health_bin"])

itest_service(
    name = "otel_svc",
    exe = ":otel_install_wrapper",
    deps = [":kind_svc"],
    health_check = ":otel_health_wrapper",
)

# 3. Your push workload — see `examples/` for shapes.
```

---

## Pushing telemetry

Once the collector is up, the in-cluster Service
`otel-opentelemetry-collector.<namespace>.svc.cluster.local` exposes:

| Port | Protocol | Use |
|---|---|---|
| 4317 | OTLP/gRPC | Push from OpenTelemetry SDKs (gRPC) |
| 4318 | OTLP/HTTP | Push from OpenTelemetry SDKs (HTTP/JSON or HTTP/protobuf) |
| 13133 | Health check | Liveness / readiness probe target |

The smoke-fixture render only enables the OTLP receiver. To pivot to
real workloads, override `alternateConfig` in your values file —
add receivers (jaeger, zipkin, k8s_events, etc.), processors (filter,
transform, attributes), and exporters (otlp pointing at a backend,
prometheusremotewrite, etc.).

Example — push an OTLP/JSON trace via curl from inside the cluster:

```bash
curl -X POST -H 'Content-Type: application/json' \
    --data-binary @trace.json \
    http://otel-opentelemetry-collector.otel.svc.cluster.local:4318/v1/traces
```

See [`examples/`](examples/) for an OpenTelemetry SDK shape, a
collector → Tempo composition sketch, and a `debug` exporter sample.

---

## Macros

### `otel_install`

```python
otel_install(
    name = "otel_install_bin",
    namespace = "otel",         # default
    wait_timeout = "300s",      # default
)
```

Expands to a `kubectl_apply(...)` target that:

- Applies `@rules_otel//private/manifests:otel.yaml`.
- `create_namespace = True` (default `otel`).
- `server_side = True`.
- `wait_for_deployments = ["otel-opentelemetry-collector"]`.
- `wait_timeout = "300s"` — the contrib image is ~250MB.

Drops into `itest_service.exe`.

### `otel_health_check`

```python
otel_health_check(name = "otel_health_bin", namespace = "otel")
```

Drops into `itest_service.health_check`. Same wait shape with
`--timeout=0s`.

---

## Hermeticity exceptions

| Component | Status | Notes |
|---|---|---|
| Collector manifest | Fully hermetic. URL + sha256 pinned in `tools/versions.bzl`; pre-rendered + committed. | Re-render via `bash tools/render_otel.sh <ver>`. |
| `kubectl` | Inherited from `rules_kubectl`. | |
| Target cluster | Out of scope. | |
| Collector container image | Pulled at runtime by the cluster's nodes. `docker.io/otel/opentelemetry-collector-contrib`. | Future: pre-load via `kind_cluster.images`. |

---

## Contributing

PRs welcome. Conventions match the sibling rule sets:

- New rules need an analysis test in `tests/analysis_tests.bzl`.
- Bumping the pinned chart version: edit `tools/versions.bzl`, add a
  `helm_template + sh_binary` block in `tools/BUILD.bazel`, run
  `bash tools/render_otel.sh <new-version>`, commit.
- `MODULE.bazel.lock` is intentionally not committed.

### Help wanted

- macOS validation
- DaemonSet mode smoke (collector-per-node, the canonical agent shape)
- StatefulSet mode smoke (persistent queue exporters)
- Compose with [`rules_tempo`](https://github.com/collider-bazel-extensions/rules_tempo)
  to use OTLP exporter pointing at Tempo (cross-rule smoke)
- Compose with [`rules_mimir`](https://github.com/collider-bazel-extensions/rules_mimir)
  for `prometheusremotewrite` exporter / metrics pipeline
- OpenTelemetry **Operator** variant (different rule set / mode toggle):
  installs the operator + provides `OpenTelemetryCollector` /
  `Instrumentation` CRD-driven workflows
- Multi-collector pipeline smoke (collector → collector OTLP forwarding,
  the canonical "agent + gateway" production topology)
