"""Providers exposed by rules_otel."""

OtelBinaryInfo = provider(
    doc = "The otelcol-contrib toolchain binary.",
    fields = {
        "version": "string — pinned otelcol-contrib version",
        "otelcol": "File — the otelcol-contrib executable",
    },
)

OtelConfigInfo = provider(
    doc = "A collector config checked by `otelcol-contrib validate` (otel_config).",
    fields = {
        "config":        "File — the collector config (YAML)",
        "feature_gates": "list of string — --feature-gates for the check and the server",
        "env":           "dict string→string — the check's ${env:...} placeholders " +
                         "(also used by otel_collector_server's build-time check)",
    },
)
