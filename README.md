# rules_otel

Bazel rules for the [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/). They check collector configs at build time, run a hermetic collector with an OTLP sink in tests, and install the collector into a cluster. Three families in one repo:

- **Config (build time)**
  - `otel_config` — a collector config, checked by `otelcol-contrib validate` as a validation action. An unknown component, a bad field or a pipeline naming an undefined component fails `bazel build` with the collector's own message.
- **Hermetic collector (test time)**
  - `otel_collector_server` — a long-running otelcol-contrib with its OTLP receivers, health check and own metrics on free ports, next to an OTLP sink its exporters can point at. Writes `$TEST_TMPDIR/<name>.env` once healthy.
  - `otel_collector_health_check` — pairs with `otel_collector_server` for `itest_service`.
  - `otel_collector_test` — `sh_test` macro with an auto-launched collector and `otel_*` helpers: send telemetry, assert on what was exported, take the backend down, restart the collector.
- **Cluster install (kind / production-shaped)**
  - `otel_install` — applies the pinned `opentelemetry-collector` Helm chart and waits for the collector Deployment.
  - `otel_health_check` — paired readiness probe.

No host collector needed. The binary is the upstream `otelcol-contrib` release for linux and darwin on amd64 and arm64, pinned by SHA-256, at the same version as the image `otel_install` deploys (0.151.0). The rules need `python3` on the host.

## Install (Bzlmod)

```python
bazel_dep(name = "rules_otel", version = "0.3.1")
git_override(
    module_name = "rules_otel",
    remote = "https://github.com/collider-bazel-extensions/rules_otel",
    tag = "v0.3.1",
)

# rules_otel depends on rules_kubectl, which isn't in the BCR either.
bazel_dep(name = "rules_kubectl", version = "0.1.0")
git_override(
    module_name = "rules_kubectl",
    remote = "https://github.com/collider-bazel-extensions/rules_kubectl",
    commit = "bb75b97850b08a18abcdca7af86514561a122b03",  # v0.1.0
)
```

To pin by archive and integrity instead of a git tag, replace the first `git_override` with:

```python
archive_override(
    module_name = "rules_otel",
    urls = ["https://github.com/collider-bazel-extensions/rules_otel/archive/refs/tags/v0.3.1.tar.gz"],
    strip_prefix = "rules_otel-0.3.1",
    integrity = "sha256-+jIf06ToM8R0tJOCnqCpfPmrC0NQqlj0flVmXT7Paw8=",
)
```

The release archive (the tag tarball) leaves out `tests/` and `tools/`, whose packages load dev-only modules (`rules_itest`, `rules_kind`, `rules_helm`), so `bazel query @rules_otel//...` works for consumers (since v0.3.1). A `git_override` clone still contains them; name packages instead (for example `@rules_otel//:all`).

That's all: rules_otel registers its toolchain, and fetches the binary only for the platform a build needs. To pick another pinned version, name it in your own `MODULE.bazel` (only the root module's tag counts):

```python
otel = use_extension("@rules_otel//:extensions.bzl", "otel")
otel.version(version = "0.151.0")
```

## Config

```python
load("@rules_otel//:defs.bzl", "otel_config")

otel_config(
    name = "collector_config",
    src = "collector.yaml",
    env = {                                   # placeholders, for the check only
        "MIMIR_URL": "http://mimir.example:9009/otlp",
    },
    feature_gates = [],                       # optional; also used by the server
)
```

- **The collector's own check.** `otelcol-contrib validate` runs on every build, so the config is checked against the components and fields of the exact collector version you deploy.
- **`${env:...}` values.** The check sees only the variables in `env`, never the build host's. A reference with a default (`${env:TENANT:-anonymous}`) needs nothing. A required one that's missing usually fails, and the error names it:

  ```
  otel_config //otel:collector_config: otelcol-contrib refused it:
    Error: exporters::otlphttp/mimir: at least one endpoint must be specified
    (unset at build time: ${env:MIMIR_URL}; give placeholders with otel_config(env = {...}))
  ```

- **Other errors are the collector's own**, for example `references exporter "otlphttp/mimr" which is not configured` or `'batchprocessor.Config' has invalid keys: timeoutt`.
- **No network.** It works with `--sandbox_default_allow_network=false`.

## Hermetic collector

### `otel_collector_test`

```python
load("@rules_otel//:defs.bzl", "otel_collector_test")

otel_collector_test(
    name = "export_test",
    srcs = ["export_test.sh"],
    config = ":collector_config",
    collector_env = {"MIMIR_URL": "{sink}"},  # point the exporter at the sink
    data = [":my_service"],
)

otel_collector_test(                          # built-in config: OTLP in, all to the sink
    name = "instrumentation_test",
    srcs = ["instrumentation_test.sh"],
    data = [":my_service"],
)
```

```sh
# export_test.sh — the backend goes down, then recovers.
source "$OTEL_TESTLIB"
otel_sink_down
otel_send_metric cell.requests 7 cell=a
otel_log_wait 'Exporting failed.*otlphttp/mimir'
otel_self_metric_wait otelcol_exporter_queue_size 1 exporter=otlphttp/mimir
otel_sink_up
otel_sink_wait metrics cell.requests cell=a
```

```sh
# instrumentation_test.sh — the service's SDK reads OTEL_EXPORTER_OTLP_*.
source "$OTEL_TESTLIB"
./my_service --handle-one-request
otel_sink_wait traces "GET /healthz" http.response.status_code=200
```

**What changes in your config.** Everything applies as written, except:
- every OTLP receiver (`otlp`, `otlp/<name>`) listens on a free `127.0.0.1` port per protocol it enables;
- the first `health_check` extension in `service.extensions` moves to a free port, keeping its `path`. Without one, `health_check/rules_otel` is added;
- the collector's own metrics are served on one free port, replacing any `service.telemetry.metrics.readers`.

Other listeners (Prometheus scrape, Zipkin, ...) keep their configured ports, and the launcher logs a note about each. Use port `0` if tests run in parallel.

**The sink** is an OTLP/HTTP backend in the launcher. It accepts, under any path prefix:
- `…/v1/traces`, `…/v1/metrics` and `…/v1/logs`, in protobuf or JSON and optionally gzip-compressed (the `otlphttp` exporter);
- `…/api/v1/push`, Prometheus remote write 1.0 (the `prometheusremotewrite` exporter, with `{sink}/api/v1/push`).

So an exporter configured like production keeps its path: with `endpoint: ${env:MIMIR_URL}/otlp` (or `collector_env = {"MIMIR_URL": "{sink}/otlp"}`), its posts to `/otlp/v1/metrics` are recorded. `requests.log` keeps the full path.

It records each span, data point and log record as a JSON line under `$OTEL_SINK_DIR`. Sum points also keep `monotonic` (`true`/`false`) and `temporality` (`delta`, `cumulative` or `unspecified`); histogram points keep `temporality`. `{sink}` in `collector_env` is its URL. gRPC exporters (`otlp`) can't point at it; use `otlphttp`.

What the test sees:

| Variable | |
|---|---|
| `OTEL_COLLECTOR_OTLP_GRPC` | `127.0.0.1:<port>`, the first OTLP receiver's gRPC listener |
| `OTEL_COLLECTOR_OTLP_HTTP` | `http://127.0.0.1:<port>`, its HTTP listener |
| `OTEL_COLLECTOR_OTLP_<NAME>_GRPC` / `_HTTP` | the same for `otlp/<name>` |
| `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL` | the first receiver, for OpenTelemetry SDKs (HTTP if it has it, else gRPC) |
| `OTEL_COLLECTOR_HEALTH_URL` | the health_check endpoint |
| `OTEL_COLLECTOR_METRICS_URL` | the collector's own metrics, Prometheus format |
| `OTEL_COLLECTOR_LOG` | the collector's log (also in the test log, prefixed `[otelcol]`) |
| `OTEL_SINK_URL`, `OTEL_SINK_DIR` | the sink and its records (`traces.jsonl`, `metrics.jsonl`, `logs.jsonl`, `requests.log`) |
| `OTEL_CONTROL_URL` | the launcher's control endpoint, used by the helpers |
| `OTELCOL`, `OTEL_TOOL`, `OTEL_TESTLIB` | the binary, the helper tool, the shell helpers |

| Helper | |
|---|---|
| `otel_send_metric NAME [VALUE] [K=V…]` | a gauge point over OTLP/HTTP |
| `otel_send_sum NAME [VALUE] [K=V…] [--temporality delta] [--monotonic false]` | a sum point (default monotonic, cumulative) |
| `otel_send_histogram NAME [VALUE] [K=V…] [--temporality delta]` | one histogram observation (default cumulative) |
| `otel_send_span NAME [K=V…]` | one span |
| `otel_send_log BODY [K=V…] [--severity WARN]` | one log record |
| `otel_sink_wait SIGNAL [NAME] [K=V…] [--min N] [--timeout S]` | waits until the sink has received N matching records (default 1). SIGNAL is `traces`, `metrics` or `logs`; NAME is the metric or span name, or a substring of a log body; K=V matches record or resource attributes |
| `otel_sink_count` / `otel_sink_dump SIGNAL [NAME] [K=V…]` | prints the number of matching records / the records as JSON lines |
| `--monotonic true\|false`, `--temporality delta\|cumulative\|unspecified` | filters for the three sink helpers, anywhere in their arguments, e.g. `otel_sink_wait metrics app.requests --monotonic true --temporality cumulative` |
| `otel_sink_down` / `otel_sink_fail CODE` / `otel_sink_up` | the sink stops listening (connection refused, kept-alive connections dropped) / answers every request with CODE / recovers on the same port |
| `otel_collector_stop` / `otel_collector_start` | stops the collector / starts it again on the same ports and waits until healthy |
| `otel_self_metric NAME [K=V…]` | the collector's own metric, summed over matching series (0 if none) |
| `otel_self_metric_wait NAME MIN [K=V…]` | waits until that is at least MIN |
| `otel_log_wait REGEX` | waits for a matching line in the collector's log and prints it |

Waits time out after `$OTEL_WAIT_TIMEOUT` seconds (default 30) and say what they saw. A NAME can't contain `=`.

| `otel_collector_test` / `otel_collector_server` argument | Default | |
|---|---|---|
| `config` | built-in | an `otel_config` |
| `collector_env` (test) / `env` (server) | `{}` | environment for the collector; `{sink}` is the sink's URL |
| `ready_timeout` | `30` | seconds to wait for the health endpoint |
| `extra_args` | `[]` | extra otelcol-contrib arguments, e.g. `["--set=processors.batch.timeout=50ms"]`. `--set` and `--feature-gates` are checked with the config at build time |
| `args`, `env`, `data`, `deps`, `size`, `timeout`, `tags`, … | | as for `sh_test` (`otel_collector_test` only) |

**Readiness.** The collector counts as ready when its health endpoint answers 200, which the health_check extension does once every component has started. That takes about 0.2 s.

**Checked at build time.** `otel_collector_server` (and so `otel_collector_test`) runs `otelcol-contrib validate` on the config it will actually run: the `otel_config` (or the built-in config) plus the `--set` / `--feature-gates` among `extra_args`. The environment is the `otel_config`'s `env` placeholders plus the server's `env`, with `{sink}` replaced by a placeholder URL. A typo in a `--set` fails `bazel build`:

```
otel_collector_server //otel:collector: otelcol-contrib refused its config with --set=processors.batch.timout=50ms:
  Error: ... 'batchprocessor.Config' has invalid keys: timout
```

**Failures.** The test fails, names the cause and shows the collector's log if:
- the collector refuses its config at run time, with the real environment and any arguments (an unset `${env:...}` is named, and so are the `--set`s); this is checked before the collector starts;
- it exits;
- it isn't healthy within `ready_timeout`.

The test body never runs. If the collector exits later, the server stops too. Each test gets its own collector and sink on their own ports, so tests are safe under `--jobs=N`. Both are stopped when the test ends.

### `otel_collector_server` + `otel_collector_health_check` (rules_itest)

```python
otel_collector_server(name = "otelcol", config = ":collector_config", env = {"MIMIR_URL": "{sink}"}, tags = ["manual"])
otel_collector_health_check(name = "otelcol_health", server = ":otelcol", tags = ["manual"])

itest_service(
    name = "otelcol_svc",
    exe = ":otelcol",
    health_check = ":otelcol_health",
)
```

The server writes `$TEST_TMPDIR/otelcol.env` (named after the target) with the variables above. A service or test in any language reads it. A shell test can `source "$OTEL_TESTLIB"` after sourcing the env file. SIGTERM stops the collector and the sink, removes the file and exits 0.

## Cluster install

```python
load("@rules_otel//:defs.bzl", "otel_install", "otel_health_check")

otel_install(name = "otel_install_bin")          # default namespace: otel
otel_health_check(name = "otel_health_bin")

# Wrappers that source the kind cluster's env file (KUBECONFIG) first;
# see tests/install_wrapper.sh and tests/health_wrapper.sh.
sh_binary(name = "otel_install_wrapper", srcs = ["install_wrapper.sh"], data = [":otel_install_bin"])
sh_binary(name = "otel_health_wrapper", srcs = ["health_wrapper.sh"], data = [":otel_health_bin"])

itest_service(
    name = "otel_svc",
    exe = ":otel_install_wrapper",
    deps = [":kind_svc"],
    health_check = ":otel_health_wrapper",
)
```

- **What's rendered:** the `opentelemetry-collector` chart 0.153.0, as a smoke fixture: `mode: deployment` with a single replica, the OTLP receiver only (gRPC `:4317`, HTTP `:4318`), and the `debug` exporter at `verbosity: detailed`. The values are exported as `@rules_otel//config:otel-values.yaml`.
- **Image:** `otel/opentelemetry-collector-contrib:0.151.0`, the build with every upstream component. `//tests:version_test` keeps it equal to the toolchain binary.
- **`otel_install`:** a `kubectl_apply` of `@rules_otel//private/manifests:otel.yaml` into `namespace` (created), server-side, waiting up to `wait_timeout` (default `300s`; the image is about 250 MB) for `deploy/otel-opentelemetry-collector`.
- **In-cluster endpoints:** `otel-opentelemetry-collector.<namespace>.svc.cluster.local`, on port 4317 (OTLP/gRPC), 4318 (OTLP/HTTP) and 13133 (health).
- **Smoke test:** `//tests:smoke_test` installs into kind, POSTs an OTLP/JSON trace with a unique marker from a curl pod, and finds the marker in the collector's log. [`examples/`](examples/) has an exporter override sketch and the curl push.

## Pinned versions

| Component | Version | Source |
|---|---|---|
| otelcol-contrib | `0.151.0` | open-telemetry/opentelemetry-collector-releases (published checksums) |
| Helm chart | `opentelemetry-collector-0.153.0` (appVersion 0.151.0) | open-telemetry/opentelemetry-helm-charts (sha256 in `tools/versions.bzl`) |

Maintainer flows:
- **New binaries:** run `tools/update_checksums.sh <version>`. It pins all four platforms from the release's checksums file, cross-checked against the downloads, and `--check` verifies the pins. Keep `DEFAULT_VERSION` and `otel.version()` in `MODULE.bazel` equal to the chart's image.
- **Chart:** edit `tools/versions.bzl` and `tools/BUILD.bazel`, then run `bash tools/render_otel.sh <version>`. CI fails if the committed manifest drifts from the render.

## Development

```sh
bazel test //tests/...                                           # no container runtime
bazel test //tests:smoke_test --test_output=streamed             # needs Docker or podman
```

See [DESIGN.md](DESIGN.md) for the architecture and trade-offs, and [CLAUDE.md](CLAUDE.md) for the repo layout and test inventory.
