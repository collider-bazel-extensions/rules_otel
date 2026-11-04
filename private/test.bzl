"""otel_collector_test — sh_test macro with an auto-launched collector.

Each target gets its own otel_collector_server (own ports, own sink), so
tests are safe under `--jobs=N`.

The trampoline (otel_test_trampoline.sh) starts the server, waits for its
env file, sources it (OTEL_COLLECTOR_OTLP_GRPC / _HTTP, OTEL_EXPORTER_OTLP_*,
OTEL_COLLECTOR_HEALTH_URL / _METRICS_URL / _LOG, OTEL_SINK_URL / _DIR,
OTEL_CONTROL_URL, OTELCOL, OTEL_TOOL, OTEL_TESTLIB) and runs the test
with the target's args. It runs the test rather than exec'ing it, so it
can stop the collector when the test ends.
"""

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@rules_shell//shell:sh_test.bzl", "sh_test")
load(":server.bzl", "otel_collector_server")

def otel_collector_test(
        name,
        srcs,
        config = None,
        collector_env = None,
        ready_timeout = 30,
        extra_args = None,
        deps = None,
        data = None,
        args = None,
        size = "small",
        timeout = None,
        tags = None,
        **kwargs):
    """sh_test against an auto-launched OpenTelemetry Collector.

    Args:
      name: target name.
      srcs: the test script (one file).
      config: an otel_config (default: OTLP in, everything to the sink).
      collector_env: environment for the collector (`${env:NAME}` in the
        config); `{sink}` in a value is the sink's URL.
      ready_timeout: seconds to wait for the collector to be healthy.
      extra_args: extra otelcol-contrib arguments.
      deps: forwarded to the inner sh_binary.
      data: runfiles for the test (on the inner sh_binary and the
        sh_test, so `args` may use $(rootpath) on them).
      args: arguments for the test script.
      size: sh_test size. Default "small".
      timeout: sh_test timeout.
      tags: tags for the sh_test (helper targets also get "manual").
      **kwargs: forwarded to sh_test (env, env_inherit, flaky, ...).
    """
    tags = tags or []
    server_name = name + "_otelcol"
    otel_collector_server(
        name = server_name,
        config = config,
        env = collector_env or {},
        ready_timeout = str(ready_timeout),
        extra_args = extra_args or [],
        tags = tags + ["manual"],
        testonly = True,
    )

    inner_name = name + "_inner"
    sh_binary(
        name = inner_name,
        srcs = srcs,
        deps = deps,
        data = data,
        tags = tags + ["manual"],
        testonly = True,
    )

    sh_test(
        name = name,
        srcs = [Label("//private:otel_test_trampoline.sh")],
        args = [
            "$(rootpath :{})".format(server_name),
            "$(rootpath :{})".format(inner_name),
            server_name,
        ] + (args or []),
        # `data` here too, so `args` can use $(rootpath) on it.
        data = [
            ":" + server_name,
            ":" + inner_name,
        ] + (data or []),
        size = size,
        timeout = timeout,
        tags = tags,
        **kwargs
    )
