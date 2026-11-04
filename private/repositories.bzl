"""Per-platform otelcol-contrib repo: downloads the release tarball at the
pinned sha and declares the platform's toolchain implementation, so the
repo name (`otelcol_contrib_<platform>`) doesn't change with the version.
"""

load(":versions.bzl", "OTELCOL_VERSIONS")

_BUILD = """\
load("{toolchain_bzl}", "otel_toolchain")

package(default_visibility = ["//visibility:public"])

exports_files(["otelcol-contrib"])

otel_toolchain(
    name = "toolchain_impl",
    version = "{version}",
    otelcol = "otelcol-contrib",
)
"""

def _impl(rctx):
    version = rctx.attr.version
    platform = rctx.attr.platform
    if version not in OTELCOL_VERSIONS:
        fail("rules_otel: unknown otelcol-contrib version '{}'. Known: {} ".format(
            version, sorted(OTELCOL_VERSIONS.keys()),
        ) + "(add one with tools/update_checksums.sh <version>)")
    pin = OTELCOL_VERSIONS[version].get(platform)
    if not pin:
        fail("rules_otel: platform '{}' missing for version {}".format(platform, version))

    rctx.download_and_extract(url = pin["url"], sha256 = pin["sha256"])
    rctx.file("BUILD.bazel", _BUILD.format(
        toolchain_bzl = str(Label("//toolchain:toolchain.bzl")),
        version = version,
    ))

otelcol_binary_repo = repository_rule(
    implementation = _impl,
    attrs = {
        "version":  attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
    },
)
