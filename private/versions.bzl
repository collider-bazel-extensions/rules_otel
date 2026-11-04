"""otelcol-contrib binary pins.

One release tarball per platform from open-telemetry/opentelemetry-collector-releases,
holding the single `otelcol-contrib` binary:

    https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v<ver>/otelcol-contrib_<ver>_<os>_<arch>.tar.gz

SHA-256s are the release's published
`opentelemetry-collector-releases_otelcol-contrib_checksums.txt`. Maintainer flow:

    tools/update_checksums.sh <ver>     # add / re-pin <ver> from the checksums file
    tools/update_checksums.sh --check   # verify every pin, no writes

//tests:checksums_test fails on an empty or malformed value, and
//tests:version_test if DEFAULT_VERSION differs from the image that
otel_install deploys.
"""

# The version the `otel` extension fetches when the root module names none.
DEFAULT_VERSION = "0.151.0"

OTELCOL_VERSIONS = {
    "0.151.0": {
        "linux_amd64": {
            "url": "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.151.0/otelcol-contrib_0.151.0_linux_amd64.tar.gz",
            "sha256": "5230d1e1ad0599a396427fc4c4dab6add94b008bc4375d393b907092a50908b2",
        },
        "linux_arm64": {
            "url": "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.151.0/otelcol-contrib_0.151.0_linux_arm64.tar.gz",
            "sha256": "d21c712ead236860c38c5a2b8d1cc2fcaf1435231188bfc490a911c98aa5a466",
        },
        "darwin_amd64": {
            "url": "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.151.0/otelcol-contrib_0.151.0_darwin_amd64.tar.gz",
            "sha256": "2c080d5c92e2742de6f0be1097f3c46446e07f666d892b7708764d28958e8d86",
        },
        "darwin_arm64": {
            "url": "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.151.0/otelcol-contrib_0.151.0_darwin_arm64.tar.gz",
            "sha256": "ee90da0191ec644d72c407a2b25d7451892d03fdd3fb67aa020b19f32a599bc4",
        },
    },
}

PLATFORMS = {
    "linux_amd64":  ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "linux_arm64":  ["@platforms//os:linux", "@platforms//cpu:arm64"],
    "darwin_amd64": ["@platforms//os:osx",   "@platforms//cpu:x86_64"],
    "darwin_arm64": ["@platforms//os:osx",   "@platforms//cpu:arm64"],
}
