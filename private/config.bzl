"""otel_config — a collector config checked by `otelcol-contrib validate`
at build time.

The validation action runs `otelcol-contrib validate` with only the
variables in `env`: `${env:X}` references see those placeholders, never
the build host's values. An unknown component, a bad field or a pipeline
naming an undefined component fails `bazel build` with the collector's
own message, e.g.

    otel_config //otel:config: otelcol-contrib refused it:
      Error: service::pipelines::metrics: references exporter "otlphttp/mimr" which is not configured
"""

load(":providers.bzl", "OtelConfigInfo")

_TOOLCHAIN = "//toolchain:otel"

def check_env(label, env):
    """Validate an `env` dict's names; returns ["--env", "K=V", ...]."""
    out = []
    for k, v in env.items():
        ok = k and (k[0].isalpha() or k[0] == "_") and k.replace("_", "a").isalnum()
        if not ok:
            fail("{}: env name {}: expected [A-Za-z_][A-Za-z0-9_]*.".format(label, repr(k)))
        out += ["--env", "{}={}".format(k, v)]
    return out

def _otel_config_impl(ctx):
    oc = ctx.toolchains[_TOOLCHAIN].otel
    config = ctx.actions.declare_file(ctx.label.name + "/" + ctx.file.src.basename)
    ctx.actions.symlink(output = config, target_file = ctx.file.src)

    marker = ctx.actions.declare_file(ctx.label.name + ".checked")
    args = ctx.actions.args()
    args.add(ctx.file._launcher)
    args.add("check")
    args.add("--otelcol", oc.otelcol)
    args.add("--marker", marker)
    args.add("--config", config)
    label = str(ctx.label)
    args.add("--label", label[2:] if label.startswith("@@//") else label)
    args.add_all(check_env(ctx.label, ctx.attr.env))
    if ctx.attr.feature_gates:
        args.add("--feature-gates", ",".join(ctx.attr.feature_gates))
    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = [config, ctx.file._launcher, oc.otelcol],
        outputs = [marker],
        # python3 from the user's PATH, as for the test-time launcher. The
        # collector itself runs with only `env`.
        use_default_shell_env = True,
        mnemonic = "OtelCheckConfig",
        progress_message = "Checking collector config %{label}",
    )
    return [
        DefaultInfo(files = depset([config])),
        OtelConfigInfo(config = config, feature_gates = ctx.attr.feature_gates, env = ctx.attr.env),
        OutputGroupInfo(_validation = depset([marker])),
    ]

otel_config = rule(
    implementation = _otel_config_impl,
    doc = "A collector config, checked by `otelcol-contrib validate` on every build.",
    attrs = {
        "src": attr.label(
            mandatory = True,
            allow_single_file = [".yaml", ".yml", ".json"],
            doc = "The collector config.",
        ),
        "env": attr.string_dict(
            doc = "Values for `${env:NAME}` references during the check only " +
                  "(placeholders such as an endpoint URL). Nothing else from " +
                  "the build host's environment is visible.",
        ),
        "feature_gates": attr.string_list(
            doc = "Collector feature gates (e.g. [\"-service.AllowNoPipelines\"]), " +
                  "for the check and for otel_collector_server.",
        ),
        "_launcher": attr.label(default = "//private:launcher.py", allow_single_file = True),
    },
    toolchains = [_TOOLCHAIN],
)
