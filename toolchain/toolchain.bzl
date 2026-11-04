"""otel_toolchain — exposes the platform-resolved `otelcol-contrib` binary
as a `ToolchainInfo`, so rules resolve it via
`ctx.toolchains["@rules_otel//toolchain:otel"]`.

`current_otel_toolchain` forwards the resolved binary as a plain target
(files + runfiles) for `data = [...]` use in tests.
"""

load("//private:providers.bzl", "OtelBinaryInfo")

OTEL_TOOLCHAIN_TYPE = Label("//toolchain:otel")

def _toolchain_impl(ctx):
    info = OtelBinaryInfo(
        version = ctx.attr.version,
        otelcol = ctx.file.otelcol,
    )
    return [
        platform_common.ToolchainInfo(otel = info),
        DefaultInfo(
            files = depset([ctx.file.otelcol]),
            runfiles = ctx.runfiles(files = [ctx.file.otelcol]),
        ),
    ]

otel_toolchain = rule(
    implementation = _toolchain_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "otelcol": attr.label(allow_single_file = True, mandatory = True),
    },
)

def _current_impl(ctx):
    info = ctx.toolchains[OTEL_TOOLCHAIN_TYPE].otel
    return [
        info,
        DefaultInfo(
            files = depset([info.otelcol]),
            runfiles = ctx.runfiles(files = [info.otelcol]),
        ),
    ]

current_otel_toolchain = rule(
    implementation = _current_impl,
    toolchains = [OTEL_TOOLCHAIN_TYPE],
    doc = "The resolved otelcol-contrib binary, as files and runfiles.",
)
