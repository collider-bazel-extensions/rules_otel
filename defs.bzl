"""Public API for rules_otel.

Config (build time):
  otel_config                 — a collector config, checked by
                                `otelcol-contrib validate` on every build.

Hermetic collector (test time):
  otel_collector_server       — long-running otelcol-contrib on free ports,
                                with an OTLP sink; writes
                                $TEST_TMPDIR/<name>.env once healthy
  otel_collector_health_check — pairs with otel_collector_server
  otel_collector_test         — sh_test macro: auto-launched collector and
                                otel_* helpers

Cluster install (kind / production-shaped):
  otel_install / otel_health_check — the pinned opentelemetry-collector
                                Helm chart, pre-rendered
"""

load("//private:config.bzl", _otel_config = "otel_config")
load("//private:install.bzl", _otel_health_check = "otel_health_check", _otel_install = "otel_install")
load("//private:providers.bzl", _OtelBinaryInfo = "OtelBinaryInfo", _OtelConfigInfo = "OtelConfigInfo")
load(
    "//private:server.bzl",
    _OtelCollectorInfo = "OtelCollectorInfo",
    _otel_collector_health_check = "otel_collector_health_check",
    _otel_collector_server = "otel_collector_server",
)
load("//private:test.bzl", _otel_collector_test = "otel_collector_test")

otel_config = _otel_config
otel_collector_server = _otel_collector_server
otel_collector_health_check = _otel_collector_health_check
otel_collector_test = _otel_collector_test
otel_install = _otel_install
otel_health_check = _otel_health_check

OtelBinaryInfo = _OtelBinaryInfo
OtelConfigInfo = _OtelConfigInfo
OtelCollectorInfo = _OtelCollectorInfo
