# Auto-instrumentation — why it's NOT in v0.1

The OpenTelemetry **Operator** (separate `opentelemetry-operator` Helm
chart, not the one this rule set wraps) ships two CRDs:

- `OpenTelemetryCollector` — declarative Collector instances. Same
  outcome as the plain chart's Deployment, but reconciled by the
  operator from a custom resource.
- `Instrumentation` — auto-instrumentation. Apply an `Instrumentation`
  CR in a namespace, and any Pod with a specific annotation gets an
  init-container injected that copies the OTel SDK into the app's
  filesystem + sets `OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_RESOURCE_ATTRIBUTES`
  / `OTEL_TRACES_EXPORTER` / etc. Apps emit traces without code changes.

That's a powerful workflow but it's a different rule-set shape:
operator + CRD wait + CR-driven smoke (similar to rules_cloudnativepg).
v0.1's `rules_otel` deliberately wraps the **plain** `opentelemetry-collector`
chart — one Deployment, no operator, no CRDs.

## What a future `rules_otel_operator` would look like

```python
# Hypothetical v0.2-or-separate-rule-set API.
load("@rules_otel_operator//:defs.bzl",
     "otel_operator_install",
     "otel_collector_apply",         # Apply an OpenTelemetryCollector CR.
     "otel_instrumentation_apply")   # Apply an Instrumentation CR.

otel_operator_install(name = "operator")
otel_collector_apply(name = "collector",
                     receivers = [...], exporters = [...])
otel_instrumentation_apply(name = "instr",
                           tracer_endpoint = "...",
                           sdk = "java")
```

The smoke composition would:
1. Install the operator (waits on its CRDs becoming `Established`).
2. Apply an `Instrumentation` CR + an `OpenTelemetryCollector` CR.
3. Deploy a sample app with the auto-instrumentation annotation.
4. Make a request to the app.
5. Assert the collector saw spans from the app, with the right
   resource attributes injected by the operator.

## Until then

If you want auto-instrumentation today, install the operator chart
yourself alongside `rules_otel`:

```bash
helm install otel-operator open-telemetry/opentelemetry-operator \
    --namespace otel-operator --create-namespace
kubectl apply -f my-instrumentation.yaml
kubectl apply -f my-collector.yaml
# Annotate your app pods to pick up auto-instrumentation.
```

`rules_otel`'s collector still works as the OTLP receive endpoint
that the operator-managed instances forward to.
