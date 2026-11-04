"""Bzlmod extension. Single `version` tag — fetches the otelcol-contrib
release tarball for each supported platform as `otelcol_contrib_<platform>`.

The root module's tag wins; without one, rules_otel's own (the version
otel_install deploys) applies, so a consumer that only uses otel_install
declares nothing. (The `otel_chart` extension in //tools is the
maintainer-only chart download.)
"""

load("//private:repositories.bzl", "otelcol_binary_repo")
load("//private:versions.bzl", "DEFAULT_VERSION", "PLATFORMS")

_version_tag = tag_class(attrs = {
    "version": attr.string(mandatory = True),  # e.g. "0.151.0"
})

def _impl(mctx):
    root, own = [], []
    for mod in mctx.modules:
        if mod.is_root:
            root += [t.version for t in mod.tags.version]
        elif mod.name == "rules_otel":
            own += [t.version for t in mod.tags.version]

    # Only one module's tags apply (the same is_root rule as across this
    # organization): repos are named per platform, not per version.
    versions = root or own or [DEFAULT_VERSION]
    if len({v: True for v in versions}) > 1:
        fail("rules_otel: otel.version() named more than one version: {}".format(versions))
    for plat in PLATFORMS.keys():
        otelcol_binary_repo(
            name = "otelcol_contrib_" + plat,
            version = versions[0],
            platform = plat,
        )

otel = module_extension(
    implementation = _impl,
    tag_classes = {"version": _version_tag},
)
