# rules_otel — design decisions

Bazel rules for the [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/).

- **v0.1: the cluster install.** It has the same shape as `rules_loki`, `rules_grafana`, `rules_harbor`, `rules_external_secrets`, `rules_kafka` and `rules_tempo`: pure glue over `rules_kubectl` and `rules_helm`. The decisions table below is from then.
- **v0.2: build-time checks and a hermetic collector** (issue #4). It follows rules_vault, rules_valkey and rules_prometheus:
  - a binary toolchain;
  - `otel_config` checked by a validation action;
  - a launcher-based `otel_collector_server` with a health check and an `sh_test` macro.

  See [Hermetic collector (v0.2)](#hermetic-collector-v02).

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
| 8 | Public surface | v0.1: `otel_install`, `otel_health_check`; collector configuration is dense YAML, so v0.1 documented the YAML pattern and shipped `examples/`. **v0.2 adds `otel_config`, `otel_collector_server`, `otel_collector_health_check` and `otel_collector_test`** (#4). They take the YAML as written rather than modelling it in Starlark. | Smaller surface |
| 9 | Namespace | `otel` (default, idempotent create). | Convention |
| 10 | Wait shape | One Deployment (`otel-opentelemetry-collector`). The chart's release name is pinned to `otel` at maintainer-render time, so the Deployment name is the chart's `<release>-opentelemetry-collector` template. No CRDs (operator chart ships them; this rule set wraps the plain chart). | Plain-collector specific |
| 11 | Smoke client | **`kubectl run` a curl pod.** Same approach as rules_tempo — OTLP/JSON push from a curl pod is the lightest possible client. | Pragmatic |
| 12 | Smoke assertion | Generate a unique marker string. POST an OTLP/JSON trace at `<svc>:4318/v1/traces` with the marker as a span attribute. Poll the collector pod's logs (`kubectl logs deploy/...`) until the marker appears — the `debug` exporter at verbosity `detailed` writes every received record's attributes to stdout. Proves OTLP receiver + batch processor + debug exporter all wired correctly — **not** "collector pod is up." | Per the family's "exercise the functionality" rule |
| 13 | Cross-rule deps | `rules_kubectl` and (since v0.2, for the `sh_test` macro) `rules_shell` are public deps. `rules_helm`, `rules_kind` and `rules_itest` are dev-only. | rules_loki precedent |
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

## Status

v0.2.0 adds the toolchain, `otel_config`, the hermetic collector with its sink and control endpoint, and their tests (see CLAUDE.md for the inventory). v0.1.0:

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

## Hermetic collector (v0.2)

### Binary and toolchain

- **The binary:** the upstream `otelcol-contrib` release tarballs, one static Go binary per platform, for linux and darwin on amd64 and arm64. They're pinned in `private/versions.bzl` with the SHA-256s from the release's published checksums file. `tools/update_checksums.sh` downloads every tarball to cross-check them.
- **Same version as the install:** contrib, at the version of the image the chart deploys. `//tests:version_test` fails if `DEFAULT_VERSION`, `otel.version()` in `MODULE.bazel`, the manifest's image tag and the binary's `--version` disagree.
- **Repo names carry no version:** `otelcol_contrib_<platform>`. Each repo declares its own `otel_toolchain` implementation, so `//toolchain:BUILD` never changes with the version.
- **Which version:** the root module's `otel.version()` tag wins; otherwise rules_otel's own tag applies. So a consumer that only uses `otel_install` (every v0.1 consumer) declares nothing and fetches nothing: toolchain resolution only loads a repo when a target needs the toolchain. This differs from rules_valkey and rules_vault, whose versioned repo names make consumers `use_repo` four repos.
- **Core `otelcol` is not offered.** The issue called it optional, contrib includes every core component, and the image is contrib.

### `otel_config`

- **The check:** the validation action runs `otelcol-contrib validate`. It checks the config against the real component factories (unknown types, unknown fields, the pipeline graph) without starting anything, in about 0.1 s.
- **A clean environment:** the collector runs with only `otel_config(env = ...)` (plus `HOME`). A `${env:X}` that passes on a developer's machine because their shell exports X would otherwise fail in CI, or the reverse. When the check fails, the launcher names the unset `${env:X}` references that have no default.

### `otel_collector_server`'s build-time check (v0.3, #6)

`--set` overrides in `extra_args` change the config the server runs, but in v0.2 only `otel_config` was checked, without them. So a typo in a `--set` key only failed when the test ran, with a less specific message. Now:
- **At build time,** the server runs the same validation action as `otel_config`, on the config plus the `--set` / `--feature-gates` among its `extra_args`. Other arguments don't change the config, and some (`--config=<path>`) can't be resolved at build time. The built-in config is checked the same way.
- **The environment** is the `otel_config`'s `env` placeholders, overridden by the server's `env`. `{sink}` becomes `http://127.0.0.1:4318`, so an exporter endpoint built from it validates.
- **At run time,** `print-config` gets the same `--set`s, including any passed to the server on the command line. So the resolved config used for moving the listeners is the one that runs, and a refusal names the args before the collector starts.

### `otel_collector_server`: moving the listeners

A production config listens on fixed ports (`:4317`, `:4318`, `:13133`, `:8888`), and parallel tests can't share them.

- **Finding the listeners.** The launcher can't parse YAML with the standard library, and the config may use `${env:...}`, so it asks the collector: `print-config --mode=unredacted --format=json` gives the resolved config. From it the launcher finds:
  - each `otlp` / `otlp/<name>` receiver and the protocols it enables;
  - the health_check extension enabled in `service.extensions`, and its `path`.
- **Moving them.** It writes a second config (`overlay.json`) and runs the collector with both `--config` flags; the collector merges maps.
  - Each OTLP protocol and the health endpoint move to free `127.0.0.1` ports. The original config isn't rewritten, so quoting, comments and `${env:...}` keep their meaning.
  - Lists are replaced, not merged. So adding `health_check/rules_otel` (when there's none) writes the whole `service.extensions` list, and the collector's own metrics get one pull reader on a free port in place of any configured `readers`. The default, `:8888`, would collide too.
- **Other listeners** (prometheus, zipkin, …) are left alone, with a logged note: their config shapes vary too much to rewrite safely.
- **The risk:** `print-config` is marked experimental, and its JSON format unstable. A version bump that changes it fails `//tests:boundary_test` and `//tests:json_test` loudly, not silently.

### The sink

The issue asked for a built-in backend so tests can assert on what the collector *exports*, not just that it ran. The sink is a `ThreadingHTTPServer` in the launcher (`private/otlp_sink.py`), standard library only:
- **Protocols:** OTLP/HTTP in protobuf or JSON, gzip or deflate, plus Prometheus remote write 1.0 (snappy and protobuf). That covers `otlphttp` and `prometheusremotewrite`, the two usual ways to reach Mimir.
- **Decoding:** protobuf is decoded by a small wire-format reader with the OTLP field numbers written out. Snappy is decoded in Python; a hand-built test covers its copy forms. Fields are read by number in any order: the collector's encoder writes a `Metric`'s data before its name, which the first manual run caught.
- **Records:** one JSON line per span, data point or log record, flattened (name, type, value, attributes, resource attributes, scope), so tests filter with K=V, not nested OTLP JSON. `requests.log` records each request's status, path and record count.
- **Sum and histogram metadata (v0.3, #6):**
  - Sum points carry `monotonic` and `temporality`; histogram and exponential-histogram points carry `temporality`. These live on the `Sum` / `Histogram` message (fields 2 and 3), not on the points, so the decoder copies them onto each point. JSON input accepts the enum as a number or as `AGGREGATION_TEMPORALITY_*`.
  - Why: a Mimir-bound counter must be a *monotonic* sum to become a Prometheus `_total` counter. An up-down counter is stored as a gauge, so "a sum arrived" isn't enough to test.
- **Any path prefix (v0.3, #6):** production exporters often point at a path (Mimir's `<distributor>/otlp`), and `otlphttp` appends `/v1/<signal>` to it. So the sink routes on the path's *suffix* (`/v1/traces|metrics|logs`, `/api/v1/push`), and a test config can keep production's `${env:MIMIR_URL}/otlp` shape with `MIMIR_URL={sink}`.
- **gRPC:** no `otlp` (gRPC) sink. HTTP/2 isn't in the standard library, and exporters can use `otlphttp`.

**Failure modes.**
- **`down`** closes the listening socket *and* shuts down every open connection. Otherwise a kept-alive exporter connection would keep being served by its handler thread.
- **`up`** rebinds the same port, so the configured exporter endpoint stays valid.
- **`fail CODE`** answers every request with CODE, for testing 429 and 503 retry paths.

### The control endpoint and restarts

- **Why HTTP:** helpers reach the launcher over a small HTTP server on a free port (`OTEL_CONTROL_URL`). Signals can't carry an answer, and `otel_collector_start` must report whether the restarted collector became healthy.
- **Restarts** use the same argv and overlay, so the ports are unchanged.
- **Deliberate stops:** a deliberately stopped collector (`stopped_on_purpose`) doesn't count as a crash; only an exit the test didn't ask for stops the server. A restart that fails leaves the collector stopped: the helper reports the error and the log, and the test decides.
- **Signals:** the handler only sets an event and terminates the collector. It never waits or takes a lock, because control threads may hold the collector lock while starting it.

### Trampoline

`otel_collector_test` uses rules_valkey's trampoline:
- it removes its own arguments before the test sees `"$@"`;
- it runs the test rather than `exec`ing it, so its EXIT trap stops the launcher;
- HUP, INT and TERM exit 129, 130 and 143.

`//tests:server_cleanup_test` fails if the trampoline `exec`s; this was checked by making that change.

### Upstream behaviour worth knowing

`prometheusremotewrite` has its own retry, but no sending queue by default. While the backend is down it gives up after its 5 s timeout and drops the data (`Exporting failed. Dropping data.`). `otlphttp` queues and delivers after recovery. `//tests:boundary_test` asserts each behaviour as it is.

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

## Deferred (not v0.3.0)

- **TLS** on the moved OTLP receivers.
- **Moving non-OTLP listeners** (prometheus, zipkin, jaeger, …).
- **A gRPC sink** (`otlp` exporter).
- **Remote write 2.0** in the sink.
- **A non-shell `otel_collector_test`.** Other languages use `otel_collector_server` through rules_itest and read the env file.

## Release archive contents (v0.3.1)

`tests/` and `tools/` are `export-ignore` (`.gitattributes`): their packages load the dev-only `rules_itest`, `rules_kind` and `rules_helm`, which made `@rules_otel//...` unloadable for consumers. GitHub's tag tarballs honour it; a `git_override` clone still contains them. `REPO.bazel` `ignore_directories` isn't used because it would also hide them from this repo's own `bazel test`. The dev-only `use_extension("//tools:extensions.bzl", ...)` is skipped for a non-root module. `examples/` (no BUILD files) still ships. CI's `consumer` job (`.github/consumer/check.sh`) queries `//...` from the commit's `git archive`. Same fix as rules_kubectl#5 / rules_atlas#12.
