"""The OTLP sink behind otel_collector_server: a small HTTP backend for the
collector's exporters, standard library only.

It accepts, under any path prefix (`{sink}/otlp` → /otlp/v1/metrics):
  POST .../v1/traces, .../v1/metrics, .../v1/logs
                                           OTLP/HTTP, protobuf or JSON,
                                           optionally gzip (otlphttp exporter)
  POST .../api/v1/push                     Prometheus remote write 1.0,
                                           snappy (prometheusremotewrite exporter)

and appends one JSON line per span / data point / log record to
<dir>/traces.jsonl, metrics.jsonl or logs.jsonl:

  traces:  {"name", "kind", "trace_id", "span_id", "parent_span_id",
            "attributes", "resource", "scope", "status"}
  metrics: {"name", "type", "value", "attributes", "resource", "scope",
            "time_unix_nano"}            (histograms / summaries: "count", "sum")
           sums also "monotonic" (bool) and "temporality" ("delta",
           "cumulative" or "unspecified"); histograms "temporality"
  logs:    {"body", "severity_text", "severity_number", "attributes",
            "resource", "scope", "trace_id", "span_id"}

Every request is also logged to <dir>/requests.log as
"<status> <path> <records>". The sink can be switched to answer every
request with an error status, or to stop listening ("down", so exporters
see connection refused) and come back on the same port.
"""

import gzip
import json
import os
import socket
import struct
import threading
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---- protobuf wire format -----------------------------------------------------


def _varint(buf, i):
    shift = result = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def _fields(buf):
    """Yields (field number, wire type, value) for one message."""
    i, n = 0, len(buf)
    while i < n:
        key, i = _varint(buf, i)
        num, wt = key >> 3, key & 7
        if wt == 0:
            v, i = _varint(buf, i)
        elif wt == 1:
            v, i = buf[i:i + 8], i + 8
        elif wt == 2:
            ln, i = _varint(buf, i)
            v, i = buf[i:i + ln], i + ln
        elif wt == 5:
            v, i = buf[i:i + 4], i + 4
        else:
            raise ValueError(f"unsupported wire type {wt}")
        yield num, wt, v


def _signed(v):
    return v - (1 << 64) if v >= 1 << 63 else v


def _double(b):
    return struct.unpack("<d", bytes(b))[0]


def _fixed64(b):
    return struct.unpack("<Q", bytes(b))[0]


def _sfixed64(b):
    return struct.unpack("<q", bytes(b))[0]


def _str(b):
    return bytes(b).decode("utf-8", "replace")


def _any_value(buf):
    for num, wt, v in _fields(buf):
        if num == 1:
            return _str(v)
        if num == 2:
            return bool(v)
        if num == 3:
            return _signed(v)
        if num == 4:
            return _double(v)
        if num == 5:  # ArrayValue{values=1}
            return [_any_value(x) for n, _, x in _fields(v) if n == 1]
        if num == 6:  # KeyValueList{values=1}
            return _attrs([x for n, _, x in _fields(v) if n == 1])
        if num == 7:
            return bytes(v).hex()
    return None


def _attrs(kvs):
    out = {}
    for kv in kvs:
        key, val = "", None
        for num, _, v in _fields(kv):
            if num == 1:
                key = _str(v)
            elif num == 2:
                val = _any_value(v)
        out[key] = val
    return out


def _resource(buf):  # Resource{attributes=1}
    return _attrs([v for n, _, v in _fields(buf) if n == 1])


def _scope(buf):  # InstrumentationScope{name=1, version=2}
    for num, _, v in _fields(buf):
        if num == 1:
            return _str(v)
    return ""


def _number_point(buf):  # NumberDataPoint
    p = {"attributes": {}, "value": None, "time_unix_nano": 0}
    attrs = []
    for num, _, v in _fields(buf):
        if num == 3:
            p["time_unix_nano"] = _fixed64(v)
        elif num == 4:
            p["value"] = _double(v)
        elif num == 6:
            p["value"] = _sfixed64(v)
        elif num == 7:
            attrs.append(v)
    p["attributes"] = _attrs(attrs)
    return p


def _count_point(buf):  # Histogram / ExponentialHistogram / Summary data points
    p = {"attributes": {}, "count": 0, "sum": None, "time_unix_nano": 0}
    attrs = []
    for num, wt, v in _fields(buf):
        if num == 3 and wt == 1:
            p["time_unix_nano"] = _fixed64(v)
        elif num == 4 and wt == 1:
            p["count"] = _fixed64(v)
        elif num == 5 and wt == 1:
            p["sum"] = _double(v)
        elif num in (1, 9) and wt == 2:
            attrs.append(v)
    p["attributes"] = _attrs(attrs)
    return p


_TEMPORALITY = {0: "unspecified", 1: "delta", 2: "cumulative"}


def _temporality(v):
    """AggregationTemporality from protobuf (int) or OTLP/JSON (int or
    "AGGREGATION_TEMPORALITY_DELTA")."""
    if isinstance(v, str) and not v.isdigit():
        return v.rsplit("_", 1)[-1].lower() if v.startswith("AGGREGATION_TEMPORALITY_") else "unspecified"
    return _TEMPORALITY.get(int(v or 0), "unspecified")


def _data_meta(kind, fields):
    """Sum: monotonic + temporality; (exponential) histogram: temporality.
    Sum{aggregation_temporality=2, is_monotonic=3};
    Histogram / ExponentialHistogram{aggregation_temporality=2}."""
    meta = {}
    if kind in ("sum", "histogram", "exponential_histogram"):
        meta["temporality"] = _temporality(next((v for n, wt, v in fields if n == 2 and wt == 0), 0))
    if kind == "sum":
        meta["monotonic"] = bool(next((v for n, wt, v in fields if n == 3 and wt == 0), 0))
    return meta


_METRIC_DATA = {5: ("gauge", _number_point), 7: ("sum", _number_point),
                9: ("histogram", _count_point), 10: ("exponential_histogram", _count_point),
                11: ("summary", _count_point)}


def _metrics_pb(body):
    out = []
    for n, _, rm in _fields(body):
        if n != 1:
            continue
        resource, scopes = {}, []
        for num, _, v in _fields(rm):
            if num == 1:
                resource = _resource(v)
            elif num == 2:
                scopes.append(v)
        for sm in scopes:
            scope, metrics = "", []
            for num, _, v in _fields(sm):
                if num == 1:
                    scope = _scope(v)
                elif num == 2:
                    metrics.append(v)
            for m in metrics:
                # Fields can come in any order: read the name first.
                fields = list(_fields(m))
                name = next((_str(v) for num, _, v in fields if num == 1), "")
                for num, _, v in fields:
                    if num in _METRIC_DATA:
                        kind, decode = _METRIC_DATA[num]
                        data = list(_fields(v))
                        meta = _data_meta(kind, data)
                        for dn, _, dp in data:
                            if dn == 1:
                                rec = {"name": name, "type": kind}
                                rec.update(meta)
                                rec.update(decode(dp))
                                rec.update(resource=resource, scope=scope)
                                out.append(rec)
    return out


def _traces_pb(body):
    out = []
    for n, _, rs in _fields(body):
        if n != 1:
            continue
        resource, scopes = {}, []
        for num, _, v in _fields(rs):
            if num == 1:
                resource = _resource(v)
            elif num == 2:
                scopes.append(v)
        for ss in scopes:
            scope, spans = "", []
            for num, _, v in _fields(ss):
                if num == 1:
                    scope = _scope(v)
                elif num == 2:
                    spans.append(v)
            for sp in spans:
                rec = {"name": "", "kind": 0, "trace_id": "", "span_id": "",
                       "parent_span_id": "", "attributes": {}, "status": 0}
                attrs = []
                for num, _, v in _fields(sp):
                    if num == 1:
                        rec["trace_id"] = bytes(v).hex()
                    elif num == 2:
                        rec["span_id"] = bytes(v).hex()
                    elif num == 4:
                        rec["parent_span_id"] = bytes(v).hex()
                    elif num == 5:
                        rec["name"] = _str(v)
                    elif num == 6:
                        rec["kind"] = v
                    elif num == 9:
                        attrs.append(v)
                    elif num == 15:  # Status{code=3}
                        rec["status"] = next((c for sn, _, c in _fields(v) if sn == 3), 0)
                rec["attributes"] = _attrs(attrs)
                rec.update(resource=resource, scope=scope)
                out.append(rec)
    return out


def _logs_pb(body):
    out = []
    for n, _, rl in _fields(body):
        if n != 1:
            continue
        resource, scopes = {}, []
        for num, _, v in _fields(rl):
            if num == 1:
                resource = _resource(v)
            elif num == 2:
                scopes.append(v)
        for sl in scopes:
            scope, records = "", []
            for num, _, v in _fields(sl):
                if num == 1:
                    scope = _scope(v)
                elif num == 2:
                    records.append(v)
            for lr in records:
                rec = {"body": None, "severity_text": "", "severity_number": 0,
                       "attributes": {}, "trace_id": "", "span_id": ""}
                attrs = []
                for num, _, v in _fields(lr):
                    if num == 2:
                        rec["severity_number"] = v
                    elif num == 3:
                        rec["severity_text"] = _str(v)
                    elif num == 5:
                        rec["body"] = _any_value(v)
                    elif num == 6:
                        attrs.append(v)
                    elif num == 9:
                        rec["trace_id"] = bytes(v).hex()
                    elif num == 10:
                        rec["span_id"] = bytes(v).hex()
                rec["attributes"] = _attrs(attrs)
                rec.update(resource=resource, scope=scope)
                out.append(rec)
    return out


# ---- OTLP/JSON ----------------------------------------------------------------


def _j_any(v):
    if not isinstance(v, dict):
        return v
    if "stringValue" in v:
        return v["stringValue"]
    if "boolValue" in v:
        return v["boolValue"]
    if "intValue" in v:
        return int(v["intValue"])
    if "doubleValue" in v:
        return float(v["doubleValue"])
    if "arrayValue" in v:
        return [_j_any(x) for x in v["arrayValue"].get("values", [])]
    if "kvlistValue" in v:
        return _j_attrs(v["kvlistValue"].get("values", []))
    if "bytesValue" in v:
        return v["bytesValue"]
    return None


def _j_attrs(kvs):
    return {kv.get("key", ""): _j_any(kv.get("value")) for kv in kvs or []}


def _j_res(r):
    return _j_attrs((r.get("resource") or {}).get("attributes"))


def _j_scope(s):
    return (s.get("scope") or {}).get("name", "")


def _metrics_json(doc):
    out = []
    for rm in doc.get("resourceMetrics", []):
        resource = _j_res(rm)
        for sm in rm.get("scopeMetrics", []):
            scope = _j_scope(sm)
            for m in sm.get("metrics", []):
                for key, kind in (("gauge", "gauge"), ("sum", "sum"), ("histogram", "histogram"),
                                  ("exponentialHistogram", "exponential_histogram"),
                                  ("summary", "summary")):
                    if key not in m:
                        continue
                    meta = {}
                    if kind in ("sum", "histogram", "exponential_histogram"):
                        meta["temporality"] = _temporality(m[key].get("aggregationTemporality", 0))
                    if kind == "sum":
                        meta["monotonic"] = bool(m[key].get("isMonotonic", False))
                    for dp in m[key].get("dataPoints", []):
                        rec = {"name": m.get("name", ""), "type": kind,
                               "attributes": _j_attrs(dp.get("attributes")),
                               "time_unix_nano": int(dp.get("timeUnixNano", 0))}
                        rec.update(meta)
                        if kind in ("gauge", "sum"):
                            if "asInt" in dp:
                                rec["value"] = int(dp["asInt"])
                            else:
                                rec["value"] = float(dp.get("asDouble", 0))
                        else:
                            rec["count"] = int(dp.get("count", 0))
                            rec["sum"] = dp.get("sum")
                        rec.update(resource=resource, scope=scope)
                        out.append(rec)
    return out


def _traces_json(doc):
    out = []
    for rs in doc.get("resourceSpans", []):
        resource = _j_res(rs)
        for ss in rs.get("scopeSpans", []):
            scope = _j_scope(ss)
            for sp in ss.get("spans", []):
                out.append({
                    "name": sp.get("name", ""), "kind": sp.get("kind", 0),
                    "trace_id": sp.get("traceId", ""), "span_id": sp.get("spanId", ""),
                    "parent_span_id": sp.get("parentSpanId", ""),
                    "attributes": _j_attrs(sp.get("attributes")),
                    "status": (sp.get("status") or {}).get("code", 0),
                    "resource": resource, "scope": scope,
                })
    return out


def _logs_json(doc):
    out = []
    for rl in doc.get("resourceLogs", []):
        resource = _j_res(rl)
        for sl in rl.get("scopeLogs", []):
            scope = _j_scope(sl)
            for lr in sl.get("logRecords", []):
                out.append({
                    "body": _j_any(lr.get("body")),
                    "severity_text": lr.get("severityText", ""),
                    "severity_number": lr.get("severityNumber", 0),
                    "attributes": _j_attrs(lr.get("attributes")),
                    "trace_id": lr.get("traceId", ""), "span_id": lr.get("spanId", ""),
                    "resource": resource, "scope": scope,
                })
    return out


# ---- Prometheus remote write 1.0 ----------------------------------------------


def snappy_decompress(buf):
    """Snappy block format (what remote write uses)."""
    length, i = _varint(buf, 0)
    out = bytearray()
    while i < len(buf):
        tag = buf[i]
        i += 1
        kind = tag & 3
        if kind == 0:  # literal
            ln = tag >> 2
            if ln >= 60:
                nb = ln - 59
                ln = int.from_bytes(buf[i:i + nb], "little")
                i += nb
            ln += 1
            out += buf[i:i + ln]
            i += ln
            continue
        if kind == 1:
            ln = ((tag >> 2) & 7) + 4
            off = ((tag >> 5) << 8) | buf[i]
            i += 1
        elif kind == 2:
            ln = (tag >> 2) + 1
            off = int.from_bytes(buf[i:i + 2], "little")
            i += 2
        else:
            ln = (tag >> 2) + 1
            off = int.from_bytes(buf[i:i + 4], "little")
            i += 4
        if off == 0 or off > len(out):
            raise ValueError("bad snappy offset")
        for _ in range(ln):  # may overlap
            out.append(out[-off])
    if len(out) != length:
        raise ValueError(f"snappy: got {len(out)} bytes, header says {length}")
    return bytes(out)


def _prw(body):
    out = []
    for n, _, ts in _fields(body):  # WriteRequest{timeseries=1}
        if n != 1:
            continue
        labels, samples = {}, []
        for num, _, v in _fields(ts):
            if num == 1:  # Label{name=1, value=2}
                kv = {ln: _str(lv) for ln, _, lv in _fields(v)}
                labels[kv.get(1, "")] = kv.get(2, "")
            elif num == 2:  # Sample{value=1 double, timestamp=2 int64}
                s = {"value": None, "timestamp_ms": 0}
                for sn, _, sv in _fields(v):
                    if sn == 1:
                        s["value"] = _double(sv)
                    elif sn == 2:
                        s["timestamp_ms"] = _signed(sv)
                samples.append(s)
        name = labels.pop("__name__", "")
        for s in samples:
            out.append({"name": name, "type": "prometheus", "value": s["value"],
                        "attributes": labels, "resource": {}, "scope": "",
                        "time_unix_nano": s["timestamp_ms"] * 1000000})
    return out


# ---- server -------------------------------------------------------------------

_OTLP = {
    "/v1/traces": ("traces", _traces_pb, _traces_json),
    "/v1/metrics": ("metrics", _metrics_pb, _metrics_json),
    "/v1/logs": ("logs", _logs_pb, _logs_json),
}


def route(path):
    """The endpoint a request path ends with, under any prefix (an exporter
    pointed at `{sink}/otlp` posts to /otlp/v1/metrics). None if none."""
    for suffix in ("/api/v1/push",) + tuple(_OTLP):
        if path == suffix or path.endswith(suffix):
            return suffix
    return None


def decode(path, content_type, encoding, body):
    """-> (signal, records). Raises ValueError on a body it can't read,
    LookupError on a path that isn't an OTLP / remote-write endpoint."""
    path = route(path) or path
    if encoding == "gzip":
        body = gzip.decompress(body)
    elif encoding == "deflate":
        body = zlib.decompress(body)
    elif encoding == "snappy" or path == "/api/v1/push":
        body = snappy_decompress(body)
    if path == "/api/v1/push":
        return "metrics", _prw(body)
    if path not in _OTLP:
        raise LookupError(path)
    signal, pb, js = _OTLP[path]
    if "json" in (content_type or ""):
        return signal, js(json.loads(body))
    return signal, pb(body)


class Sink:
    """The sink server. mode: "ok", "down", or an HTTP status code (int)."""

    def __init__(self, directory, log):
        self.dir = directory
        self.log = log
        self.mode = "ok"
        self.lock = threading.Lock()
        self.server = None
        self.port = None
        self.conns = set()
        os.makedirs(directory, exist_ok=True)
        for name in ("traces.jsonl", "metrics.jsonl", "logs.jsonl", "requests.log"):
            open(os.path.join(directory, name), "a").close()

    def _record(self, signal, records, status, path):
        with self.lock:
            if records:
                with open(os.path.join(self.dir, signal + ".jsonl"), "a") as f:
                    for r in records:
                        f.write(json.dumps(r, sort_keys=True) + "\n")
            with open(os.path.join(self.dir, "requests.log"), "a") as f:
                f.write(f"{status} {path} {len(records)}\n")

    def _handler(self):
        sink = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            # Tracked so "down" can drop kept-alive exporter connections too.
            def setup(self):
                super().setup()
                sink.conns.add(self.connection)

            def finish(self):
                sink.conns.discard(self.connection)
                super().finish()

            def _reply(self, status, body=b"", ctype="application/x-protobuf"):
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length)
                path = self.path.split("?")[0]
                mode = sink.mode
                if mode == "down":
                    self.close_connection = True
                    return
                if isinstance(mode, int):
                    sink._record("", [], mode, path)
                    self._reply(mode, b"rules_otel sink: failing on purpose\n", "text/plain")
                    return
                ctype = self.headers.get("Content-Type", "")
                try:
                    signal, records = decode(path, ctype, self.headers.get("Content-Encoding", ""), body)
                except LookupError:
                    sink._record("", [], 404, path)
                    self._reply(404, b"not an OTLP path\n", "text/plain")
                    return
                except Exception as e:  # noqa: BLE001 — answer 400 for anything unreadable
                    sink.log(f"sink: unreadable {path} body: {e}")
                    sink._record("", [], 400, path)
                    self._reply(400, f"unreadable body: {e}\n".encode(), "text/plain")
                    return
                sink._record(signal, records, 200, path)
                if "json" in ctype:
                    self._reply(200, b"{}", "application/json")
                else:
                    self._reply(200)

        return Handler

    def start(self, port=0):
        server = ThreadingHTTPServer(("127.0.0.1", port), self._handler())
        server.daemon_threads = True
        self.server = server
        self.port = server.server_address[1]
        t = threading.Thread(target=server.serve_forever, daemon=True)
        t.start()
        return self.port

    def _close(self):
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
            self.server = None
        for c in list(self.conns):
            try:
                c.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def set_mode(self, mode):
        """"ok", "down", or an HTTP status code as a string or int."""
        with self.lock:
            if mode == "down":
                self._close()
                self.mode = "down"
                return
            if mode == "ok":
                new = "ok"
            else:
                new = int(mode)
                if not 100 <= new <= 599:
                    raise ValueError(f"not an HTTP status: {mode}")
            if self.server is None:
                self._rebind()
            self.mode = new

    def _rebind(self):
        # Same port as before, so the collector's exporter endpoint stays
        # valid. Retry briefly: the old socket may still be closing.
        last = None
        for _ in range(50):
            try:
                self.start(self.port)
                return
            except OSError as e:
                last = e
                threading.Event().wait(0.1)
        raise OSError(f"sink: can't listen on port {self.port} again: {last}")

    def stop(self):
        with self.lock:
            self._close()

