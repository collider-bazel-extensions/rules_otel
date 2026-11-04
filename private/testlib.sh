#!/usr/bin/env bash
# rules_otel test helpers. Source after the otel_collector_server env file
# (otel_collector_test does both): `source "$OTEL_TESTLIB"`.
# Each wraps $OTEL_TOOL (otel_tool.py); see its docstring for details.

_otel() { python3 "$OTEL_TOOL" "$@"; }

# otel_send_metric NAME [VALUE] [K=V...]  — a gauge point (default value 1)
otel_send_metric() { _otel send metric "$@"; }
# otel_send_sum NAME [VALUE] [K=V...] [--temporality delta] [--monotonic false]
#                                         — a sum point (default monotonic, cumulative)
otel_send_sum()    { _otel send sum "$@"; }
# otel_send_histogram NAME [VALUE] [K=V...] [--temporality delta]
#                                         — one observation (default cumulative)
otel_send_histogram() { _otel send histogram "$@"; }
# otel_send_span NAME [K=V...]
otel_send_span()   { _otel send span "$@"; }
# otel_send_log BODY [K=V...] [--severity WARN]
otel_send_log()    { _otel send log "$@"; }

# Sink filters (anywhere in the arguments): --monotonic true|false (sums),
# --temporality delta|cumulative|unspecified (sums, histograms).
# otel_sink_count SIGNAL [NAME] [K=V...]  — prints how many records match
otel_sink_count()  { _otel sink count "$@"; }
# otel_sink_wait SIGNAL [NAME] [K=V...] [--min N] [--timeout S]
otel_sink_wait()   { _otel sink wait "$@"; }
# otel_sink_dump SIGNAL [NAME] [K=V...]   — matching records, JSON per line
otel_sink_dump()   { _otel sink dump "$@"; }
# The sink stops listening (connection refused) / answers CODE / recovers.
otel_sink_down()   { _otel sink mode down; }
otel_sink_fail()   { _otel sink mode "${1:?otel_sink_fail: HTTP status}"; }
otel_sink_up()     { _otel sink mode ok; }

# Stop the collector; start it again on the same ports (waits until healthy).
otel_collector_stop()  { _otel collector stop; }
otel_collector_start() { _otel collector start; }

# otel_self_metric NAME [K=V...]           — the collector's own metric, summed
otel_self_metric()      { _otel selfmetric "$@"; }
# otel_self_metric_wait NAME MIN [K=V...] [--timeout S]
otel_self_metric_wait() { local n="$1" m="$2"; shift 2; _otel selfmetric "$n" "$@" --min "$m"; }
# otel_log_wait REGEX [--timeout S]        — waits for a collector log line
otel_log_wait()         { _otel logwait "$@"; }
