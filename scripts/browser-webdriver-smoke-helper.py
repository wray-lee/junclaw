#!/usr/bin/env python3
"""Loopback test double for scripts/browser-webdriver-smoke.sh.

Runs a tiny HTTPS site and a CONNECT-only proxy in one network namespace.
The proxy mirrors the documented contract for the smoke probes only:

  site.test       allowlisted host; private checks skipped, connects to
                  127.0.0.1 (the local test site)
  blocked.test    resolves to 10.0.0.1, denied
  popup.test      resolves to 192.168.1.10, denied
  form.test       resolves to 172.16.1.10, denied
  rebind.test     mixed public/private answer (203.0.113.10 + 127.0.0.1),
                  denied like junclaw's fail-closed mixed-answer rule
  anything else   denied

203.0.113.0/24 is RFC 5737 documentation space and stands in for a public
address here. junclaw's real proxy policy lives in Zig and is covered by its
unit tests; this helper only makes real Firefox reveal which traffic reaches a
proxy at all.
"""

import argparse
import ipaddress
import socket
import socketserver
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAGES = {
    "/ok": (
        '<html><head><title>smoke-ok</title></head>'
        '<body><h1 id="m">SMOKEOK4F2A</h1></body></html>'
    ),
    "/subresource": (
        '<html><head><title>subresource</title></head>'
        '<body><img src="https://blocked.test/a.png"></body></html>'
    ),
    "/popup": (
        '<html><head><title>popup</title></head>'
        '<body><a id="popup" target="_blank" href="https://popup.test/">open</a>'
        "</body></html>"
    ),
    "/form": (
        '<html><head><title>form</title></head><body>'
        '<form action="https://form.test/post" method="post">'
        '<button id="submit" type="submit">go</button></form>'
        "</body></html>"
    ),
}

RESOLVE = {
    "site.test": ["127.0.0.1"],
    "blocked.test": ["10.0.0.1"],
    "popup.test": ["192.168.1.10"],
    "form.test": ["172.16.1.10"],
    "rebind.test": ["203.0.113.10", "127.0.0.1"],
}
ALLOWLIST = ("site.test",)

LOG_LOCK = threading.Lock()
LOG_FILE = None


def log(line):
    with LOG_LOCK:
        LOG_FILE.write(line + "\n")
        LOG_FILE.flush()


class SiteHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGES.get(self.path.split("?", 1)[0])
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        pass


def reply(conn, code, reason, text):
    body = text.encode()
    head = "HTTP/1.1 %d %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % (
        code,
        reason,
        len(body),
    )
    conn.sendall(head.encode() + body)


def decide(host):
    """Return (connect_address_or_None, verdict)."""
    if host not in RESOLVE:
        return None, "deny unresolved-or-unlisted"
    if host in ALLOWLIST:
        return RESOLVE[host][0], "allow allowlisted"
    # A mixed answer fails closed, like the real proxy's mixed-answer rule.
    if len(RESOLVE[host]) > 1:
        return None, "deny mixed-public-private"
    addr = ipaddress.ip_address(RESOLVE[host][0])
    if addr.is_private or addr.is_loopback or addr.is_link_local:
        return None, "deny private-address"
    return None, "deny not-allowlisted"


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


class ProxyHandler(socketserver.BaseRequestHandler):
    def handle(self):
        conn = self.request
        conn.settimeout(10)
        head = b""
        while b"\r\n\r\n" not in head and len(head) < 8192:
            try:
                chunk = conn.recv(4096)
            except OSError:
                return
            if not chunk:
                return
            head += chunk

        line = head.split(b"\r\n", 1)[0].decode("latin-1")
        parts = line.split()
        if len(parts) != 3 or parts[0] != "CONNECT":
            log("REJECT non-CONNECT %r" % line)
            reply(conn, 403, "Forbidden", "Only HTTPS (CONNECT) is allowed\n")
            return

        authority = parts[1]
        host, sep, port_text = authority.rpartition(":")
        if not sep or not host or not port_text.isdigit():
            log("REJECT malformed-authority %r" % authority)
            reply(conn, 400, "Bad Request", "Malformed CONNECT request\n")
            return
        port = int(port_text)
        if port < 1 or port > 65535:
            log("REJECT malformed-port %r" % authority)
            reply(conn, 400, "Bad Request", "Malformed CONNECT request\n")
            return

        addr, verdict = decide(host)
        log("CONNECT %s:%d %s" % (host, port, verdict))
        if addr is None:
            reply(conn, 403, "Forbidden", "Blocked by the smoke test double\n")
            return

        try:
            upstream = socket.create_connection((addr, port), timeout=10)
        except OSError as err:
            log("FAIL connect %s:%d %s" % (host, port, err))
            reply(conn, 502, "Bad Gateway", "Upstream connect failed\n")
            return

        conn.settimeout(None)
        upstream.settimeout(None)
        conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        copier = threading.Thread(target=pipe, args=(conn, upstream), daemon=True)
        copier.start()
        pipe(upstream, conn)
        copier.join()
        upstream.close()


class ProxyServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    global LOG_FILE
    parser = argparse.ArgumentParser()
    parser.add_argument("--proxy-port", type=int, required=True)
    parser.add_argument("--https-port", type=int, required=True)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--ready", required=True)
    args = parser.parse_args()

    LOG_FILE = open(args.log, "a", buffering=1)

    site = ThreadingHTTPServer(("127.0.0.1", args.https_port), SiteHandler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    site.socket = context.wrap_socket(site.socket, server_side=True)
    threading.Thread(target=site.serve_forever, daemon=True).start()

    proxy = ProxyServer(("127.0.0.1", args.proxy_port), ProxyHandler)
    threading.Thread(target=proxy.serve_forever, daemon=True).start()

    log("READY proxy=%d https=%d" % (args.proxy_port, args.https_port))
    with open(args.ready, "w") as handle:
        handle.write("ready\n")
    threading.Event().wait()


if __name__ == "__main__":
    main()
