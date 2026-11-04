# rules_otel

Bazel rules for the OpenTelemetry Collector:
- build-time config checks by `otelcol-contrib validate` (`otel_config`);
- a hermetic per-test collector with an OTLP sink (`otel_collector_server`, `otel_collector_test`);
- a cluster install over the pinned `opentelemetry-collector` chart (`otel_install`).

The hermetic half mirrors rules_vault and rules_valkey; see DESIGN.md.

## Commit requirements

- All tests must pass before any commit with code changes: `bazel test //tests/...`. Run the kind smoke `//tests:smoke_test` too when install code changes.
- All documentation (`README.md`, `DESIGN.md`, `CLAUDE.md`) must be updated to reflect any code changes before committing: new rules, changed attributes, new public API surface, behaviour changes.

## Repo layout

```
rules_otel/
├── MODULE.bazel              # module; otel extension + toolchains; dev deps (helm, itest, kind)
├── defs.bzl                  # public API re-exports
├── extensions.bzl            # `otel.version()` → otelcol_contrib_<plat> repos (root tag, else ours)
├── private/
│   ├── versions.bzl          # DEFAULT_VERSION, OTELCOL_VERSIONS (sha256 pins), PLATFORMS
│   ├── repositories.bzl      # per-platform repo: tarball + its otel_toolchain impl
│   ├── providers.bzl         # OtelBinaryInfo, OtelConfigInfo
│   ├── config.bzl            # otel_config (+ validation action)
│   ├── launcher.py           # `check` (validate) and `serve` (overlay, collector, control)
│   ├── otlp_sink.py          # the sink: OTLP/HTTP (pb/json, gzip) + remote write, any path prefix → JSONL
│   ├── otel_tool.py          # test-side: send metric/sum/histogram/span/log, sink count/wait/dump/mode
│   │                         # (--monotonic, --temporality), collector stop/start, selfmetric, logwait
│   ├── testlib.sh            # otel_* shell helpers over otel_tool.py
│   ├── server.bzl            # otel_collector_server (+ build-time config check), health check, OtelCollectorInfo
│   ├── server.sh.tmpl        # runfiles resolution (into variables) → launcher.py serve
│   ├── test.bzl              # otel_collector_test
│   ├── otel_test_trampoline.sh   # server → env → test (not exec)
│   ├── install.bzl           # otel_install, otel_health_check (kubectl_apply)
│   └── manifests/otel.yaml   # rendered chart (committed; do not hand-edit)
├── toolchain/                # toolchain_type, per-platform toolchains, :current
├── config/otel-values.yaml   # chart render values
├── tools/                    # update_checksums.sh; chart pin + render flow
├── examples/                 # in-cluster push / exporter sketches
└── tests/
    ├── BUILD.bazel
    ├── analysis_tests.bzl    # providers, executables, bad timeout, bad env name
    ├── testdata/             # boundary.yaml (fixed ports, ${env}), json.yaml, bad configs
    ├── config_check_test.sh  # check mode: good; host env not used; bad component/field/ref
    ├── api_test.sh           # built-in config: env, every helper, sink records, own metrics, args
    ├── boundary_test.sh      # #4's case: ports moved; backend down/up; remote write; 503
    ├── json_test.sh          # two OTLP receivers, health path, OTLP/JSON export
    ├── restart_test.sh       # collector stop/start on the same ports
    ├── server_test.sh        # direct run: extra_args, SIGTERM, ports closed
    ├── server_failure_test.sh  # refused config (unset env named) / exits / timeout / body skipped
    ├── server_cleanup_test.sh, itest_test.sh, health_check_test.sh,
    ├── checksums_test.sh, version_test.sh
    └── smoke_test.sh (+ install_wrapper.sh, health_wrapper.sh)   # kind + otel_install
```

## Key concepts

- **Toolchain.** `otelcol_contrib_<plat>` repos, unversioned names. The root module's `otel.version()` wins, else rules_otel's. Keep `DEFAULT_VERSION`, `otel.version()` in `MODULE.bazel` and the chart image equal (`//tests:version_test`).
- **Check isolation.** `otel_config`'s action gives the collector only `env` (+ `HOME`), never the host's environment.
- **Overlay, not rewrite.** `serve` reads the resolved config with `print-config --format=json`. It then passes a second `--config` (`overlay.json`) that moves:
  - the OTLP receivers;
  - the enabled health_check (or adds `health_check/rules_otel`);
  - the telemetry metrics readers.

  The user's file is never edited. Lists replace, maps merge.
- **Build-time server check.** `otel_collector_server` validates config + `--set`/`--feature-gates` extra args (placeholders: otel_config env + server env, `{sink}` → http://127.0.0.1:4318). Run time: `print-config` gets the same `--set`s.
- **Sink.** `{sink}` in `env` / `collector_env` is its URL; any path prefix (`{sink}/otlp`). Sums keep `monotonic` + `temporality`, histograms `temporality`. Records go to `$OTEL_SINK_DIR/<signal>.jsonl`. `down` also drops kept-alive connections; `up` rebinds the same port.
- **Control endpoint.** `POST /collector/stop|start`, `/sink/<ok|down|code>`. A stop the test asked for isn't a crash; a failed restart leaves the collector stopped.
- **Shutdown.** Handlers are installed before start. Once ready, they only set an event and terminate the collector (kill after 10 s).

## Public API

```python
load("@rules_otel//:defs.bzl",
    "otel_config",                  # src, env, feature_gates
    "otel_collector_server",        # config, env, ready_timeout, extra_args
    "otel_collector_health_check",  # server
    "otel_collector_test",          # srcs + config, collector_env, ready_timeout, extra_args + sh_test attrs
    "otel_install",                 # namespace, wait_timeout
    "otel_health_check",            # namespace
    "OtelBinaryInfo", "OtelConfigInfo", "OtelCollectorInfo",
)
```

## Development

```sh
bazel test //tests/...                                  # no container runtime
systemd-run --scope --user --property=Delegate=yes -- \
    bazel test //tests:smoke_test --test_output=streamed   # kind (podman)
tools/update_checksums.sh 0.151.0     # re-pin; --check verifies
bash tools/render_otel.sh 0.153.0     # re-render the chart manifest
```

To find stray collectors, use `pgrep -x otelcol-contrib` (an exact process name), never `pkill -f` with a pattern. The pattern matches the shell running it.

### Test results (last full run: 2026-11-04)

All 20 test targets in `//tests/...` pass on Linux x86_64 (otelcol-contrib 0.151.0), 8 of them analysis tests; the kind smoke runs in CI. Other checks:
- 6 parallel runs each of the 8 collector tests (v0.3.0) left no stray collectors.
- Checked by hand:
  - `bazel build //tests/testdata:bad_ref` and `bazel build //tests:bad_set_server` fail with the collector's message (CI checks both);
  - the good configs build with network blocked in the sandbox;
  - switching the trampoline to `exec` fails `server_cleanup_test`;
  - all four platform archives fetch, with the binary at their root.
- A scratch consumer module ran a configured and a default `otel_collector_test`, with and without an `otel.version()` tag; an unpinned version fails with the known list.

| Test target | What it verifies | Result |
|---|---|---|
| `//tests:config_check_test` | good config with placeholders; host env not used (unset vars named); unknown component, bad field, undefined pipeline ref | PASSED |
| `//tests:api_test` | env file, send metric/sum/histogram/span/log, sink records (pb + gzip) incl. sum monotonic/temporality and histogram temporality, filters, dump, own metrics, log wait, failed-wait message, args | PASSED |
| `//tests:boundary_test` | fixed ports moved; backend down → `Exporting failed` naming it + queue; up → delivered; remote write decoded; 503 then recovery | PASSED |
| `//tests:json_test` | second OTLP receiver's vars, custom health path, OTLP/JSON export under `{sink}/otlp` incl. sum/histogram metadata | PASSED |
| `//tests:restart_test` | stop (refused, health down), start on the same ports, start when running | PASSED |
| `//tests:server_test` | direct run: extra_args, SIGTERM exit 0, env file removed, ports closed | PASSED |
| `//tests:server_failure_test` | refused config (unset var named), runtime bad `--set` refused before start (named), exits at start, health timeout (collector stopped), test body skipped | PASSED |
| `//tests:server_cleanup_test` | collector and sink stopped when an otel_collector_test ends | PASSED |
| `//tests:itest_test` | otel_collector_server + health check as an itest_service | PASSED |
| `//tests:health_check_test` | env-file probe | PASSED |
| `//tests:checksums_test`, `//tests:version_test` | pins well-formed; binary = chart image = DEFAULT_VERSION = MODULE.bazel | PASSED |
| `//tests:analysis_tests_*` (8) | providers, executables, bad timeout, bad env name | PASSED |
| `//tests:smoke_test` | kind: OTLP/JSON trace from a curl pod reaches the collector's debug exporter | PASSED |

## Known limitations

- `python3` is required on the host: the validation action, the launcher, the sink and the helpers.
- Only OTLP receivers, the health_check extension and the collector's own metrics move to free ports.
- The sink speaks OTLP/HTTP and remote write 1.0, not gRPC.
- `otel_collector_test` wraps `sh_test`; other languages use `otel_collector_server` through rules_itest.
