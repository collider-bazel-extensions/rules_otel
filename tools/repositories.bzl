"""Maintainer-only chart fetch."""

load("//tools:versions.bzl", "OTEL_CHART_VERSIONS")

_BUILD = """\
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "files",
    srcs = glob(["**/*"]),
)
"""

def _impl(rctx):
    version = rctx.attr.version
    if version not in OTEL_CHART_VERSIONS:
        fail("rules_otel: unknown chart version '{}'. Known: {}".format(
            version, sorted(OTEL_CHART_VERSIONS.keys()),
        ))
    pin = OTEL_CHART_VERSIONS[version]
    rctx.download_and_extract(
        url    = pin["chart_url"],
        sha256 = pin["chart_sha256"],
    )
    rctx.file("WORKSPACE", "workspace(name = \"{}\")\n".format(rctx.name))
    rctx.file("BUILD.bazel", _BUILD)

otel_chart_repository = repository_rule(
    implementation = _impl,
    attrs = {
        "version": attr.string(mandatory = True),
    },
)
