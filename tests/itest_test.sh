#!/usr/bin/env bash
# The test half of a rules_itest service_test: otel_collector_server ran as
# an itest_service and its health check passed, so its env file is there.
set -euo pipefail
set -a; source "$TEST_TMPDIR/itest_server.env"; set +a
source "$OTEL_TESTLIB"
otel_send_span itest.span
otel_sink_wait traces itest.span
echo "PASS"
