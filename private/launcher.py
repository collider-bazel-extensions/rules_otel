#!/usr/bin/env python3
"""Runs otelcol-contrib for rules_otel. Two modes:

  launcher.py check --otelcol BIN --marker OUT --config FILE --label L
                    [--env K=V]... [--feature-gates G]
      otel_config's validation action: `otelcol-contrib validate` on the
      config, with only the given environment (so `${env:X}` sees the
      placeholders from otel_config(env = ...), never the host's values).
      A config the collector refuses fails with its own message. Writes
      OUT on success. No network.

  launcher.py serve --otelcol BIN --env-file PATH --state-dir DIR
                    --ready-timeout S --tool PY --testlib SH
                    [--config FILE] [--env K=V]... [--feature-gates G]
                    [-- EXTRA_COLLECTOR_ARGS...]
      otel_collector_server. Starts the OTLP sink and a control endpoint,
      reads the collector's resolved config (`print-config`) to find its
      OTLP receivers and health_check extension, and runs the collector
      with a second config that moves each of them, and the collector's
      own metrics, to free 127.0.0.1 ports. `{sink}` in an --env value is
      the sink's URL. Without --config, a built-in config forwards OTLP
      traces, metrics and logs to the sink. Once the health endpoint
      answers 200 it writes the env file atomically (see _env_values) and
      runs until SIGTERM / SIGINT: then it stops the collector, removes
      the env file and exits 0. If the collector exits on its own, it
      exits non-zero, naming the status and printing the collector's log.

      The control endpoint ($OTEL_CONTROL_URL, used by otel_tool.py):
        POST /collector/stop     stop the collector (ports stay assigned)
        POST /collector/start    start it again; 200 once healthy
        POST /sink/<mode>        ok | down | <HTTP status>

A collector that refuses its config, exits, or isn't healthy within the
timeout is an error that names the cause and prints the collector's log.
"""

import argparse
import json
import os
import re
import shlex
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Failed(Exception):
    """The collector refused its config, exited, or never became healthy."""


def _log(msg):
    print(f"[otel] {msg}", file=sys.stderr, flush=True)


def _tail(path, n=60):
    try:
        with open(path, errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return "(no log)"
    return "".join(lines[-n:]) or "(empty log)"


def _free_ports(n):
    socks = []
    try:
        for _ in range(n):
            s = socket.socket()
            s.bind(("127.0.0.1", 0))
            socks.append(s)
        return [s.getsockname()[1] for s in socks]
    finally:
        for s in socks:
            s.close()


def _parse_env(pairs):
    out = {}
    for p in pairs or []:
        k, sep, v = p.partition("=")
        if not sep or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k):
            raise SystemExit(f"--env {p!r}: expected NAME=VALUE")
        out[k] = v
    return out


_ENV_REF = re.compile(r"\$\{env:([A-Za-z_][A-Za-z0-9_]*)(:-[^}]*)?\}")


def _unset_refs(config_path, env):
    """`${env:X}` references (without a `:-default`) that env doesn't set."""
    try:
        text = open(config_path).read()
    except OSError:
        return []
    return sorted({m.group(1) for m in _ENV_REF.finditer(text)
                   if m.group(2) is None and m.group(1) not in env})


def _gates(args):
    return [f"--feature-gates={args.feature_gates}"] if args.feature_gates else []


# ---- check ----------------------------------------------------------------------


def check(args):
    env = _parse_env(args.env)
    # Only the declared variables: a host value must not make the check pass.
    run_env = dict(env)
    run_env.setdefault("HOME", os.environ.get("TMPDIR", "/tmp"))
    p = subprocess.run(
        [args.otelcol, "validate", f"--config=file:{args.config}"] + _gates(args),
        env=run_env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if p.returncode != 0:
        out = "\n".join("  " + l for l in p.stdout.strip().splitlines())
        msg = f"otel_config {args.label}: otelcol-contrib refused it:\n{out}"
        unset = _unset_refs(args.config, env)
        if unset:
            msg += ("\n  (unset at build time: " + ", ".join(f"${{env:{u}}}" for u in unset)
                    + "; give placeholders with otel_config(env = {...}))")
        print(msg, file=sys.stderr)
        return 1
    with open(args.marker, "w") as f:
        f.write("ok\n")
    return 0


# ---- serve: the config overlay --------------------------------------------------

_DEFAULT_CONFIG = """\
# rules_otel built-in config: OTLP in, everything forwarded to the sink.
receivers:
  otlp:
    protocols:
      grpc: {}
      http: {}
processors:
  batch:
    timeout: 100ms
exporters:
  otlphttp/sink:
    endpoint: ${env:OTEL_SINK_URL}
    retry_on_failure:
      initial_interval: 100ms
      max_interval: 1s
service:
  pipelines:
    traces:  {receivers: [otlp], processors: [batch], exporters: [otlphttp/sink]}
    metrics: {receivers: [otlp], processors: [batch], exporters: [otlphttp/sink]}
    logs:    {receivers: [otlp], processors: [batch], exporters: [otlphttp/sink]}
"""


def _ctype(component_id):
    return component_id.split("/", 1)[0]


def _resolved(args, config, env):
    """The collector's resolved config (print-config), as a dict."""
    p = subprocess.run(
        [args.otelcol, "print-config", "--mode=unredacted", "--format=json",
         f"--config=file:{config}"] + _gates(args),
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        msg = p.stderr.strip() or p.stdout.strip()
        unset = _unset_refs(config, env)
        if unset:
            msg += ("\n(unset: " + ", ".join(f"${{env:{u}}}" for u in unset)
                    + "; set them with env = {...} on the server or test)")
        raise Failed(f"the collector refused its config:\n{msg}")
    try:
        return json.loads(p.stdout)
    except ValueError as e:
        raise Failed(f"can't read `print-config` output: {e}")


def plan(resolved):
    """Work out the overlay for a resolved config.

    Returns (overlay dict, endpoints dict, notes). endpoints:
      receivers: [(receiver id, {"grpc": port, "http": port})]
      health: (port, path), metrics: port
    """
    receivers = resolved.get("receivers") or {}
    extensions = resolved.get("extensions") or {}
    service = resolved.get("service") or {}
    enabled = list(service.get("extensions") or [])

    overlay = {"receivers": {}, "extensions": {}, "service": {}}
    otlp, notes = [], []
    for rid in sorted(receivers, key=lambda r: (r != "otlp", r)):
        cfg = receivers[rid] or {}
        if _ctype(rid) != "otlp":
            ep = json.dumps(cfg)
            if re.search(r'"endpoint": "[^"]*:(?!0")\d+"', ep):
                notes.append(f"receiver {rid} keeps its configured endpoint; "
                             f"tests running in parallel may collide on its port")
            continue
        protos = {k: v for k, v in (cfg.get("protocols") or {}).items()
                  if k in ("grpc", "http") and v is not None}
        if protos:
            otlp.append((rid, sorted(protos)))

    health = [e for e in enabled if _ctype(e) == "health_check"]
    hid = health[0] if health else "health_check/rules_otel"
    hpath = (extensions.get(hid) or {}).get("path") or "/"

    ports = iter(_free_ports(sum(len(p) for _, p in otlp) + 2))
    recv_ports = []
    for rid, protos in otlp:
        assigned = {proto: next(ports) for proto in protos}
        overlay["receivers"][rid] = {"protocols": {
            proto: {"endpoint": f"127.0.0.1:{port}"} for proto, port in assigned.items()}}
        recv_ports.append((rid, assigned))
    hport, mport = next(ports), next(ports)
    overlay["extensions"][hid] = {"endpoint": f"127.0.0.1:{hport}"}
    if not health:
        overlay["service"]["extensions"] = enabled + [hid]
    # Replaces any configured readers: the collector's own metrics are
    # served on one free port (the default, :8888, would collide).
    overlay["service"]["telemetry"] = {"metrics": {"readers": [
        {"pull": {"exporter": {"prometheus": {"host": "127.0.0.1", "port": mport}}}}]}}
    for k in [k for k, v in overlay.items() if not v]:
        del overlay[k]
    return overlay, {"receivers": recv_ports, "health": (hport, hpath), "metrics": mport}, notes


def _env_values(args, ep, sink_url, control_url, log_path):
    values = {}
    for i, (rid, ports) in enumerate(ep["receivers"]):
        suffix = "" if i == 0 else "_" + re.sub(r"[^A-Z0-9]", "_", rid.split("/", 1)[-1].upper())
        if "grpc" in ports:
            values[f"OTEL_COLLECTOR_OTLP{suffix}_GRPC"] = f"127.0.0.1:{ports['grpc']}"
        if "http" in ports:
            values[f"OTEL_COLLECTOR_OTLP{suffix}_HTTP"] = f"http://127.0.0.1:{ports['http']}"
    if ep["receivers"]:
        first = ep["receivers"][0][1]
        if "http" in first:
            values["OTEL_EXPORTER_OTLP_ENDPOINT"] = f"http://127.0.0.1:{first['http']}"
            values["OTEL_EXPORTER_OTLP_PROTOCOL"] = "http/protobuf"
        else:
            values["OTEL_EXPORTER_OTLP_ENDPOINT"] = f"http://127.0.0.1:{first['grpc']}"
            values["OTEL_EXPORTER_OTLP_PROTOCOL"] = "grpc"
    hport, hpath = ep["health"]
    values.update({
        "OTEL_COLLECTOR_HEALTH_URL": f"http://127.0.0.1:{hport}{hpath}",
        "OTEL_COLLECTOR_METRICS_URL": f"http://127.0.0.1:{ep['metrics']}/metrics",
        "OTEL_COLLECTOR_LOG": log_path,
        "OTEL_SINK_URL": sink_url,
        "OTEL_SINK_DIR": os.path.join(args.state_dir, "sink"),
        "OTEL_CONTROL_URL": control_url,
        "OTELCOL": os.path.abspath(args.otelcol),
        "OTEL_TOOL": os.path.abspath(args.tool),
        "OTEL_TESTLIB": os.path.abspath(args.testlib),
    })
    return values


def write_env(env_file, values):
    tmp = env_file + ".tmp"
    with open(tmp, "w") as f:
        for k, v in values.items():
            f.write(f"{k}={shlex.quote(str(v))}\n")
    os.replace(tmp, env_file)


# ---- serve: the collector process -----------------------------------------------


def _healthy(url):
    try:
        with urllib.request.urlopen(url, timeout=1) as r:
            return r.status == 200
    except Exception:  # noqa: BLE001 — not up yet
        return False


class Collector:
    """One otelcol-contrib process at a time, restartable on the same ports."""

    def __init__(self, argv, env, log_path, health_url, timeout):
        self.argv, self.env, self.log_path = argv, env, log_path
        self.health_url, self.timeout = health_url, timeout
        self.proc = None
        self.lock = threading.Lock()
        self.stopped_on_purpose = False

    def _pump(self, proc):
        # Collector output goes to its log file and, prefixed, to stderr.
        with open(self.log_path, "a") as log:
            for line in proc.stdout:
                log.write(line)
                log.flush()
                sys.stderr.write("[otelcol] " + line)
                sys.stderr.flush()

    def start(self):
        """Starts the collector and waits until it is healthy. Raises Failed."""
        with open(self.log_path, "a") as log:
            log.write(f"---- rules_otel: starting {shlex.join(self.argv)}\n")
        proc = subprocess.Popen(self.argv, env=self.env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, errors="replace")
        self.proc = proc
        self.stopped_on_purpose = False
        pump = threading.Thread(target=self._pump, args=(proc,), daemon=True)
        pump.start()
        deadline = time.monotonic() + self.timeout
        while True:
            if proc.poll() is not None:
                pump.join(2)
                raise Failed(f"otelcol-contrib exited with status {proc.returncode} "
                             f"before it was healthy. Log:\n{_tail(self.log_path)}")
            if _healthy(self.health_url):
                return
            if time.monotonic() > deadline:
                self.terminate()
                pump.join(2)
                raise Failed(f"otelcol-contrib not healthy at {self.health_url} after "
                             f"{self.timeout:g}s. Log:\n{_tail(self.log_path)}")
            time.sleep(0.05)

    def terminate(self):
        """Asks the collector to stop; kills it 10 s later. Doesn't wait."""
        p = self.proc
        if p is not None and p.poll() is None:
            p.terminate()
            killer = threading.Timer(10, p.kill)
            killer.daemon = True
            killer.start()

    def stop(self):
        with self.lock:
            self.stopped_on_purpose = True
            self.terminate()
            if self.proc is not None:
                self.proc.wait()


class Control:
    """The control endpoint: collector stop/start and the sink's mode."""

    def __init__(self, collector, sink, stopping):
        self.collector, self.sink, self.stopping = collector, sink, stopping

    def handle(self, path):
        if self.stopping.is_set():
            return 503, "shutting down"
        if path == "/collector/stop":
            self.collector.stop()
            _log("collector stopped (control)")
            return 200, "stopped"
        if path == "/collector/start":
            with self.collector.lock:
                p = self.collector.proc
                if p is not None and p.poll() is None:
                    return 200, "already running"
                try:
                    self.collector.start()
                except Failed as e:
                    # Left stopped: the test sees the error from the helper
                    # and can still read the log.
                    self.collector.stopped_on_purpose = True
                    _log(str(e))
                    return 500, str(e)
            _log("collector started again (control)")
            return 200, "started"
        if path.startswith("/sink/"):
            mode = path[len("/sink/"):]
            try:
                self.sink.set_mode(mode)
            except (ValueError, OSError) as e:
                return 400, str(e)
            _log(f"sink mode: {mode}")
            return 200, mode
        return 404, f"unknown control path {path}"

    def serve(self):
        control = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                status, text = control.handle(self.path)
                body = (text + "\n").encode()
                self.send_response(status)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server


def serve(args):
    # otlp_sink.py sits next to this file (in runfiles, or the source tree).
    for d in (os.path.dirname(os.path.realpath(__file__)), os.path.dirname(os.path.abspath(__file__))):
        sys.path.insert(0, d)
    import otlp_sink  # noqa: E402 — next to this file in runfiles

    os.makedirs(args.state_dir, exist_ok=True)
    try:
        os.remove(args.env_file)
    except FileNotFoundError:
        pass

    stopping = threading.Event()
    collector = None

    # Installed before the collector starts, so a signal during start-up
    # still stops it. Once ready, the handler only asks it to stop and
    # wakes the main thread; it never waits.
    ready = []

    def _on_signal(signum, _frame):
        if stopping.is_set():
            return
        _log(f"signal {signum}; stopping")
        stopping.set()
        if collector is not None:
            collector.terminate()
        if not ready:
            raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    log_path = os.path.join(args.state_dir, "collector.log")
    open(log_path, "w").close()
    sink = otlp_sink.Sink(os.path.join(args.state_dir, "sink"), _log)
    sink_url = f"http://127.0.0.1:{sink.start()}"

    env = dict(os.environ)
    env["OTEL_SINK_URL"] = sink_url
    for k, v in _parse_env(args.env).items():
        env[k] = v.replace("{sink}", sink_url)

    config = args.config
    if not config:
        config = os.path.join(args.state_dir, "default.yaml")
        with open(config, "w") as f:
            f.write(_DEFAULT_CONFIG)

    try:
        try:
            overlay, ep, notes = plan(_resolved(args, config, env))
            for n in notes:
                _log("note: " + n)
            overlay_path = os.path.join(args.state_dir, "overlay.json")
            with open(overlay_path, "w") as f:
                json.dump(overlay, f, indent=2)
            argv = ([args.otelcol, f"--config=file:{config}", f"--config=file:{overlay_path}"]
                    + _gates(args) + list(args.extra))
            hport, hpath = ep["health"]
            collector = Collector(argv, env, log_path, f"http://127.0.0.1:{hport}{hpath}",
                                  args.ready_timeout)
            started = time.monotonic()
            collector.start()
        except Failed as e:
            _log(str(e))
            if collector is not None:
                collector.stop()
            sink.stop()
            return 1
        except SystemExit:
            if collector is not None:
                collector.stop()
            raise

        control = Control(collector, sink, stopping)
        control_server = control.serve()
        control_url = f"http://127.0.0.1:{control_server.server_address[1]}"
        values = _env_values(args, ep, sink_url, control_url, log_path)
        write_env(args.env_file, values)
        ready.append(True)
        _log(f"ready in {time.monotonic() - started:.1f}s: "
             + ", ".join(f"{k}={values[k]}" for k in values
                         if k.startswith("OTEL_COLLECTOR_OTLP") or k == "OTEL_SINK_URL")
             + f"; env file {args.env_file}")

        # Run until signalled, or until the collector exits on its own.
        status = 0
        while not stopping.wait(0.2):
            p = collector.proc
            if p is not None and p.poll() is not None and not collector.stopped_on_purpose:
                with collector.lock:  # not mid-restart
                    if collector.proc is p and not collector.stopped_on_purpose:
                        _log(f"otelcol-contrib exited with status {p.returncode}. "
                             f"Log:\n{_tail(log_path)}")
                        status = p.returncode if p.returncode > 0 else 1
                        break
        stopping.set()
        control_server.shutdown()
        collector.stop()
        sink.stop()
        try:
            os.remove(args.env_file)
        except FileNotFoundError:
            pass
        return status
    finally:
        sink.stop()


def main(argv):
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="mode", required=True)

    c = sub.add_parser("check")
    c.add_argument("--otelcol", required=True)
    c.add_argument("--marker", required=True)
    c.add_argument("--config", required=True)
    c.add_argument("--label", default="")
    c.add_argument("--env", action="append")
    c.add_argument("--feature-gates", default="")

    s = sub.add_parser("serve")
    s.add_argument("--otelcol", required=True)
    s.add_argument("--env-file", required=True)
    s.add_argument("--state-dir", required=True)
    s.add_argument("--ready-timeout", type=float, default=30.0)
    s.add_argument("--tool", required=True)
    s.add_argument("--testlib", required=True)
    s.add_argument("--config")
    s.add_argument("--env", action="append")
    s.add_argument("--feature-gates", default="")
    s.add_argument("extra", nargs="*")

    args = p.parse_args(argv)
    return check(args) if args.mode == "check" else serve(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
