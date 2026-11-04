"""otel_collector_server + otel_collector_health_check — a hermetic
OpenTelemetry Collector for tests.

`otel_collector_server` is a long-running executable (see launcher.py):
otelcol-contrib on the given config (or a built-in one that forwards
everything to the sink), with its OTLP receivers, health_check extension
and own metrics moved to free 127.0.0.1 ports, next to an OTLP sink the
exporters can point at (`{sink}` in `env`). Once the health endpoint
answers it writes `$TEST_TMPDIR/<name>.env`:

    OTEL_COLLECTOR_OTLP_GRPC=127.0.0.1:<port>
    OTEL_COLLECTOR_OTLP_HTTP=http://127.0.0.1:<port>
    OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_EXPORTER_OTLP_PROTOCOL
    OTEL_COLLECTOR_HEALTH_URL, OTEL_COLLECTOR_METRICS_URL, OTEL_COLLECTOR_LOG
    OTEL_SINK_URL, OTEL_SINK_DIR, OTEL_CONTROL_URL
    OTELCOL, OTEL_TOOL, OTEL_TESTLIB

and runs until SIGTERM. `otel_collector_health_check` exits 0 iff that
file exists; it drops into `itest_service.health_check`.
"""

load(":config.bzl", "check_env")
load(":providers.bzl", "OtelConfigInfo")

_TOOLCHAIN = "//toolchain:otel"

OtelCollectorInfo = provider(
    doc = "An otel_collector_server target.",
    fields = {
        "binary": "OtelBinaryInfo: the toolchain's binary.",
        "config": "File or None: the collector config (None = built-in).",
    },
)

def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def check_timeout(label, value):
    """Validate a timeout attribute: a positive number of seconds."""
    raw = value.strip()
    digits = raw.replace(".", "", 1)
    if not raw or not digits.isdigit() or not digits.replace("0", ""):
        fail("{}: ready_timeout = {}: expected a positive number of seconds.".format(
            label, repr(value)))
    return raw

def _otel_collector_server_impl(ctx):
    oc = ctx.toolchains[_TOOLCHAIN].otel
    files = []
    config_line = ""
    gates = []
    config = None
    check_env_values = {}
    if ctx.attr.config:
        info = ctx.attr.config[OtelConfigInfo]
        config = info.config
        files.append(config)
        gates = info.feature_gates
        check_env_values.update(info.env)

        # Resolved into a variable first: a failing $(resolve) inside an
        # argument list would not stop the script under `set -e`.
        config_line = "p=\"$(resolve {})\"; opts+=(--config \"$p\")".format(
            _shell_quote(config.short_path))
    opts = check_env(ctx.label, ctx.attr.env)
    if gates:
        opts += ["--feature-gates", ",".join(gates)]

    wrapper = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = wrapper,
        substitutions = {
            "__NAME__":          ctx.label.name,
            "__LAUNCHER__":      ctx.file._launcher.short_path,
            "__SINK__":          ctx.file._sink.short_path,
            "__TOOL__":          ctx.file._tool.short_path,
            "__TESTLIB__":       ctx.file._testlib.short_path,
            "__OTELCOL__":       oc.otelcol.short_path,
            "__READY_TIMEOUT__": check_timeout(ctx.label, ctx.attr.ready_timeout),
            "__CONFIG__":        config_line,
            "__OPTS__":          " ".join([_shell_quote(o) for o in opts]),
            "__EXTRA_ARGS__":    " ".join([_shell_quote(a) for a in ctx.attr.extra_args]),
        },
        is_executable = True,
    )
    # Build-time check of the config this server will run: the config (or
    # the built-in one) plus the `--set` / `--feature-gates` extra args,
    # with the config's placeholders and this server's env ({sink} becomes
    # a placeholder URL). A bad --set fails `bazel build`, not the test.
    check_env_values.update(ctx.attr.env)
    marker = ctx.actions.declare_file(ctx.label.name + ".config_checked")
    args = ctx.actions.args()
    args.add(ctx.file._launcher)
    args.add("check")
    args.add("--kind", "otel_collector_server")
    args.add("--otelcol", oc.otelcol)
    args.add("--marker", marker)
    label = str(ctx.label)
    args.add("--label", label[2:] if label.startswith("@@//") else label)
    if config:
        args.add("--config", config)
    args.add_all(check_env(ctx.label, check_env_values))
    if gates:
        args.add("--feature-gates", ",".join(gates))
    args.add_all(ctx.attr.extra_args, format_each = "--extra-arg=%s")
    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = [ctx.file._launcher, oc.otelcol] + files,
        outputs = [marker],
        use_default_shell_env = True,
        mnemonic = "OtelCheckServerConfig",
        progress_message = "Checking collector config of %{label}",
    )

    runfiles = ctx.runfiles(files = [
        wrapper,
        ctx.file._launcher,
        ctx.file._sink,
        ctx.file._tool,
        ctx.file._testlib,
        oc.otelcol,
    ] + files)
    return [
        DefaultInfo(executable = wrapper, runfiles = runfiles),
        OtelCollectorInfo(binary = oc, config = config),
        OutputGroupInfo(_validation = depset([marker])),
    ]

otel_collector_server = rule(
    implementation = _otel_collector_server_impl,
    executable = True,
    doc = """\
Long-running otelcol-contrib for tests and rules_itest compositions, with
an OTLP sink. Writes `$TEST_TMPDIR/<name>.env` once the collector's health
endpoint answers. If the collector refuses its config, exits, or isn't
healthy within `ready_timeout`, it exits non-zero, naming the cause and
printing the collector's log.
""",
    attrs = {
        "config": attr.label(
            providers = [OtelConfigInfo],
            doc = "An otel_config. Its OTLP receivers, health_check extension " +
                  "and the collector's own metrics move to free ports; " +
                  "everything else applies as written. Default: OTLP in, " +
                  "everything to the sink.",
        ),
        "env": attr.string_dict(
            doc = "Environment for the collector, for `${env:NAME}` in the " +
                  "config. `{sink}` in a value is the sink's URL, e.g. " +
                  "{\"MIMIR_URL\": \"{sink}\"}.",
        ),
        "ready_timeout": attr.string(
            default = "30",
            doc = "Seconds to wait for the collector to be healthy.",
        ),
        "extra_args": attr.string_list(
            doc = "Extra otelcol-contrib arguments, e.g. " +
                  "[\"--set=processors.batch.timeout=50ms\"].",
        ),
        "_launcher": attr.label(default = "//private:launcher.py", allow_single_file = True),
        "_sink": attr.label(default = "//private:otlp_sink.py", allow_single_file = True),
        "_tool": attr.label(default = "//private:otel_tool.py", allow_single_file = True),
        "_testlib": attr.label(default = "//private:testlib.sh", allow_single_file = True),
        "_tmpl": attr.label(default = "//private:server.sh.tmpl", allow_single_file = True),
    },
    toolchains = [_TOOLCHAIN],
)

# ---- otel_collector_health_check -------------------------------------------------

def _otel_collector_health_check_impl(ctx):
    wrapper = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = wrapper,
        substitutions = {"__ENV_FILE_NAME__": ctx.attr.server.label.name + ".env"},
        is_executable = True,
    )
    return [DefaultInfo(executable = wrapper)]

otel_collector_health_check = rule(
    implementation = _otel_collector_health_check_impl,
    executable = True,
    attrs = {
        "server": attr.label(
            mandatory = True,
            providers = [OtelCollectorInfo],
            doc = "The otel_collector_server this check pairs with.",
        ),
        "_tmpl": attr.label(default = "//private:health_check.sh.tmpl", allow_single_file = True),
    },
)
