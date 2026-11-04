#!/usr/bin/env python3
"""Test-side helper for otel_collector_server / otel_collector_test. Reads
the variables from the server's env file (OTEL_COLLECTOR_OTLP_HTTP,
OTEL_SINK_DIR, OTEL_CONTROL_URL, ...). Standard library only.

  send metric NAME [VALUE] [K=V...]      OTLP/JSON gauge to the collector
  send sum NAME [VALUE] [K=V...]         monotonic cumulative sum
  send span NAME [K=V...]
  send log BODY [K=V...] [--severity S]
  sink count SIGNAL [NAME] [K=V...]      records the sink received
  sink wait SIGNAL [NAME] [K=V...] [--min N] [--timeout S]
  sink dump SIGNAL [NAME] [K=V...]       matching records, one JSON per line
  sink mode ok|down|<HTTP status>
  collector stop|start
  selfmetric NAME [K=V...] [--min X] [--timeout S]
                                         the collector's own metric (summed
                                         over matching series); --min waits
  logwait REGEX [--timeout S]            wait for a line in the collector log

SIGNAL is traces, metrics or logs. NAME is the metric or span name (exact)
or, for logs, a substring of the body; it can't contain `=`, since any
argument with `=` is a K=V attribute. K=V matches record attributes or
resource attributes. Timeouts default to $OTEL_WAIT_TIMEOUT or 30 s.
"""

import argparse
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.request


def die(msg):
    print(f"otel_tool: {msg}", file=sys.stderr)
    sys.exit(1)


def need(var):
    v = os.environ.get(var)
    if not v:
        die(f"${var} is not set (source the otel_collector_server env file first)")
    return v


def split_rest(rest):
    """-> ([plain args], {K: V}). An argument with `=` is an attribute."""
    plain, attrs = [], {}
    for a in rest:
        k, sep, v = a.partition("=")
        if sep:
            attrs[k] = v
        else:
            plain.append(a)
    return plain, attrs


def one_name(plain, what, most=1):
    if len(plain) > most:
        die(f"{what}: unexpected argument {plain[most]!r} (attributes are K=V)")
    return plain[0] if plain else None


def _kv(attrs):
    return [{"key": k, "value": {"stringValue": v}} for k, v in attrs.items()]


def _post(url, body, ctype="application/json"):
    req = urllib.request.Request(url, data=body, method="POST",
                                 headers={"Content-Type": ctype})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except OSError as e:
        die(f"POST {url}: {e}")


_RESOURCE = {"attributes": _kv({"service.name": "rules_otel_test"})}
_SEVERITY = {"TRACE": 1, "DEBUG": 5, "INFO": 9, "WARN": 13, "ERROR": 17, "FATAL": 21}


def send(args):
    base = need("OTEL_COLLECTOR_OTLP_HTTP")
    plain, attrs = split_rest(args.rest)
    metric = args.what in ("metric", "sum")
    name = one_name(plain, "send " + args.what, 2 if metric else 1)
    if name is None:
        die(f"send {args.what}: missing the name")
    now = time.time_ns()
    if metric:
        value = plain[1] if len(plain) > 1 else 1
        try:
            num = float(value)
        except ValueError:
            die(f"send {args.what}: value {value!r} is not a number")
        point = {"timeUnixNano": str(now), "attributes": _kv(attrs)}
        if num.is_integer():
            point["asInt"] = str(int(num))
        else:
            point["asDouble"] = num
        if args.what == "metric":
            data = {"gauge": {"dataPoints": [point]}}
        else:
            point["startTimeUnixNano"] = str(now - 10**9)
            data = {"sum": {"aggregationTemporality": 2, "isMonotonic": True,
                            "dataPoints": [point]}}
        doc = {"resourceMetrics": [{"resource": _RESOURCE, "scopeMetrics": [
            {"scope": {"name": "rules_otel"}, "metrics": [dict(name=name, **data)]}]}]}
        path = "/v1/metrics"
    elif args.what == "span":
        doc = {"resourceSpans": [{"resource": _RESOURCE, "scopeSpans": [
            {"scope": {"name": "rules_otel"}, "spans": [{
                "traceId": "%032x" % random.getrandbits(128),
                "spanId": "%016x" % random.getrandbits(64),
                "name": name, "kind": 1,
                "startTimeUnixNano": str(now - 10**6), "endTimeUnixNano": str(now),
                "attributes": _kv(attrs)}]}]}]}
        path = "/v1/traces"
    else:
        sev = args.severity.upper()
        doc = {"resourceLogs": [{"resource": _RESOURCE, "scopeLogs": [
            {"scope": {"name": "rules_otel"}, "logRecords": [{
                "timeUnixNano": str(now), "observedTimeUnixNano": str(now),
                "severityText": sev, "severityNumber": _SEVERITY.get(sev, 9),
                "body": {"stringValue": name}, "attributes": _kv(attrs)}]}]}]}
        path = "/v1/logs"
    status, text = _post(base + path, json.dumps(doc).encode())
    if status != 200:
        die(f"collector answered {status} to {path}: {text.strip()}")


# ---- sink ------------------------------------------------------------------------

_SIGNALS = ("traces", "metrics", "logs")


def records(signal):
    if signal not in _SIGNALS:
        die(f"signal {signal!r}: expected one of {', '.join(_SIGNALS)}")
    path = os.path.join(need("OTEL_SINK_DIR"), signal + ".jsonl")
    out = []
    try:
        with open(path) as f:
            for line in f:
                if line.endswith("\n"):  # skip a line still being written
                    out.append(json.loads(line))
    except FileNotFoundError:
        pass
    return out


def matches(signal, rec, name, attrs):
    if name is not None:
        if signal == "logs":
            if name not in str(rec.get("body")):
                return False
        elif rec.get("name") != name:
            return False
    for k, v in attrs.items():
        got = rec.get("attributes", {}).get(k, rec.get("resource", {}).get(k))
        if got is None or str(got) != v:
            return False
    return True


def _timeout(args):
    if args.timeout is not None:
        return args.timeout
    return float(os.environ.get("OTEL_WAIT_TIMEOUT", "30"))


def sink(args):
    if args.what == "mode":
        if len(args.rest) != 1:
            die("sink mode: expected ok, down or an HTTP status")
        return control("/sink/" + args.rest[0])
    if not args.rest:
        die(f"sink {args.what}: missing the signal (traces, metrics, logs)")
    signal = args.rest[0]
    plain, attrs = split_rest(args.rest[1:])
    name = one_name(plain, "sink " + args.what)
    found = lambda: [r for r in records(signal) if matches(signal, r, name, attrs)]  # noqa: E731
    if args.what == "count":
        print(len(found()))
    elif args.what == "dump":
        for r in found():
            print(json.dumps(r, sort_keys=True))
    else:
        want = int(args.min or 1)
        deadline = time.monotonic() + _timeout(args)
        while len(found()) < want:
            if time.monotonic() > deadline:
                desc = " ".join([signal] + ([name] if name else [])
                                + [f"{k}={v}" for k, v in attrs.items()])
                req = os.path.join(need("OTEL_SINK_DIR"), "requests.log")
                try:
                    last = "".join(open(req).readlines()[-10:]) or "(none)\n"
                except OSError:
                    last = "(none)\n"
                die(f"sink wait {desc}: {len(found())} of {want} after {_timeout(args):g}s. "
                    f"Last sink requests (status path records):\n{last}"
                    f"Collector log: {os.environ.get('OTEL_COLLECTOR_LOG', '?')}")
            time.sleep(0.1)


def control(path):
    status, text = _post(need("OTEL_CONTROL_URL") + path, b"", "text/plain")
    if status != 200:
        die(f"{path}: {status}: {text.strip()}")


# ---- the collector's own metrics -------------------------------------------------

_LINE = re.compile(r"^([A-Za-z_:][\w:]*)(\{(.*)\})?\s+(\S+)")
_LABEL = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')


def selfmetric_value(name, attrs):
    url = need("OTEL_COLLECTOR_METRICS_URL")
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            text = r.read().decode()
    except OSError as e:
        return None, str(e)
    total, seen = 0.0, False
    for line in text.splitlines():
        m = _LINE.match(line)
        if not m or m.group(1) != name:
            continue
        labels = dict(_LABEL.findall(m.group(3) or ""))
        if all(labels.get(k) == v for k, v in attrs.items()):
            total += float(m.group(4))
            seen = True
    return (total if seen else None), None


def selfmetric(args):
    plain, attrs = split_rest(args.rest)
    name = one_name(plain, "selfmetric")
    if name is None:
        die("selfmetric: missing the metric name")
    if args.min is None:
        v, err = selfmetric_value(name, attrs)
        if err:
            die(f"selfmetric: {err}")
        print(0 if v is None else (int(v) if v.is_integer() else v))
        return
    deadline = time.monotonic() + _timeout(args)
    while True:
        v, err = selfmetric_value(name, attrs)
        if v is not None and v >= args.min:
            print(int(v) if v.is_integer() else v)
            return
        if time.monotonic() > deadline:
            die(f"selfmetric {name}: {v if v is not None else 'no series'} "
                f"(want >= {args.min:g}) after {_timeout(args):g}s" + (f"; {err}" if err else ""))
        time.sleep(0.2)


def logwait(args):
    if len(args.rest) != 1:
        die("logwait: expected one REGEX")
    pat = re.compile(args.rest[0])
    path = need("OTEL_COLLECTOR_LOG")
    deadline = time.monotonic() + _timeout(args)
    while True:
        try:
            for line in open(path, errors="replace"):
                if pat.search(line):
                    print(line.rstrip("\n"))
                    return
        except FileNotFoundError:
            pass
        if time.monotonic() > deadline:
            tail = "".join(open(path, errors="replace").readlines()[-20:]) if os.path.exists(path) else ""
            die(f"logwait: no line matching {args.rest[0]!r} after {_timeout(args):g}s. "
                f"Log tail:\n{tail}")
        time.sleep(0.1)


_OPTIONS = {"--severity": str, "--min": float, "--timeout": float}


def parse(argv):
    """-> Namespace(cmd, what, rest, severity, min, timeout). Options may
    come anywhere (argparse can't intermix them with subcommands)."""
    opts = {"severity": "INFO", "min": None, "timeout": None}
    rest, it = [], iter(argv)
    for a in it:
        name, sep, val = a.partition("=")
        if name in _OPTIONS:
            if not sep:
                val = next(it, None)
                if val is None:
                    die(f"{name} needs a value")
            try:
                opts[name[2:]] = _OPTIONS[name](val)
            except ValueError:
                die(f"{name} {val!r}: not a number")
        else:
            rest.append(a)
    commands = {"send": ("metric", "sum", "span", "log"),
                "sink": ("count", "wait", "dump", "mode"),
                "collector": ("stop", "start"),
                "selfmetric": None, "logwait": None}
    if not rest or rest[0] not in commands:
        die("usage: otel_tool {" + ",".join(commands) + "} ...  (see otel_tool.py)")
    cmd, rest = rest[0], rest[1:]
    what = None
    if commands[cmd]:
        if not rest or rest[0] not in commands[cmd]:
            die(f"usage: otel_tool {cmd} {{{','.join(commands[cmd])}}} ...")
        what, rest = rest[0], rest[1:]
    return argparse.Namespace(cmd=cmd, what=what, rest=rest, **opts)


def main(argv):
    args = parse(argv)
    if args.cmd == "send":
        send(args)
    elif args.cmd == "sink":
        sink(args)
    elif args.cmd == "collector":
        control("/collector/" + args.what)
    elif args.cmd == "selfmetric":
        selfmetric(args)
    else:
        logwait(args)


if __name__ == "__main__":
    main(sys.argv[1:])
