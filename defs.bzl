"""Public API for rules_otel."""

load("@rules_kubectl//:defs.bzl", "kubectl_apply", "kubectl_apply_health_check")

# In `mode: deployment` (smoke render), the chart emits one Deployment
# named `<release>-opentelemetry-collector`. Release name pinned to
# `otel` at maintainer-render time, so the Deployment is
# `otel-opentelemetry-collector`. No CRDs (the operator chart ships
# CRDs; this rule set wraps the plain collector chart).
_OTEL_DEPLOYS = [
    "otel-opentelemetry-collector",
]
_OTEL_ROLLOUTS = []
_OTEL_CRD = ""

def otel_install(
        name,
        namespace = "otel",
        wait_timeout = "300s",
        **kwargs):
    """Apply the pinned OpenTelemetry Collector manifest into `namespace`
    and block until the collector Deployment is Available before idling.

    Drops into `itest_service.exe`. Wait timeout 300s — the
    `otel/opentelemetry-collector-contrib` image is ~250MB.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    kubectl_apply(
        name = name,
        manifests = ["@rules_otel//private/manifests:otel.yaml"],
        namespace = namespace,
        create_namespace = True,
        server_side = True,
        wait_for_deployments = list(_OTEL_DEPLOYS) + list(extra_deploys),
        wait_for_rollouts = list(_OTEL_ROLLOUTS) + list(extra_rollouts),
        wait_timeout = wait_timeout,
        **kwargs
    )

def otel_health_check(
        name,
        namespace = "otel",
        **kwargs):
    """Readiness probe paired with `otel_install`."""
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_deployments = list(_OTEL_DEPLOYS) + list(extra_deploys),
        wait_for_rollouts = list(_OTEL_ROLLOUTS) + list(extra_rollouts),
        **kwargs
    )
