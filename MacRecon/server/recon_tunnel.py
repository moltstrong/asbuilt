#!/usr/bin/env python3
"""Public HTTPS for asbuilt-recon via a Cloudflare quick tunnel (trycloudflare.com), plus discovery.

Why a quick tunnel: Tailscale Funnel needs a one-time admin-console click, and no Cloudflare
account credentials are usable on this Mac (see MacRecon/README.md "Server"). Quick tunnels need no
account but get a NEW random hostname every time cloudflared starts, so on each new URL this script:
  1. waits until https://<new>/v1/health answers through the tunnel,
  2. writes it to ~/.config/asbuilt-recon/base_url,
  3. updates the discovery gist (~/.config/asbuilt-recon/discovery.json -> gist id) so installed
     apps can find the new URL, and
  4. sets the GitHub Actions secret RECON_BASE_URL (for the next app build).
Then it health-checks the public URL every 60 s and restarts cloudflared after 5 straight failures.
Runs under launchd as com.moltstrong.asbuilt-recon-tunnel (KeepAlive).
"""
import json
import logging
import logging.handlers
import os
import re
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
CONF = os.path.join(HOME, ".config", "asbuilt-recon")
LOG_DIR = os.path.join(HOME, "Library", "Logs", "asbuilt-recon")
PORT = int(os.environ.get("ASBUILT_RECON_PORT", "8765"))
CLOUDFLARED = os.environ.get("CLOUDFLARED", "/opt/homebrew/bin/cloudflared")
GH = os.environ.get("GH", "/opt/homebrew/bin/gh")
REPO = os.environ.get("RECON_REPO", "moltstrong/asbuilt")
GIST_FILE = "asbuilt-recon.json"
URL_RE = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com")

log = logging.getLogger("tunnel")


def setup_logging():
    os.makedirs(LOG_DIR, exist_ok=True)
    h = logging.handlers.RotatingFileHandler(os.path.join(LOG_DIR, "tunnel.log"), maxBytes=5 << 20, backupCount=3)
    h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(h)
    log.setLevel(logging.INFO)


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def public_ip(host):
    """Resolve via the system resolver, falling back to 1.1.1.1: home routers often cache the
    NXDOMAIN they got for a brand-new trycloudflare hostname for many minutes."""
    try:
        return socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
    except OSError:
        pass
    try:
        out = subprocess.run(["/usr/bin/dig", "+short", "+time=3", "+tries=2", host, "@1.1.1.1"],
                             capture_output=True, text=True, timeout=15).stdout.split()
        return next((x for x in out if re.match(r"^\d+\.\d+\.\d+\.\d+$", x)), None)
    except Exception:
        return None


def health(url, timeout=10):
    """GET <url>/v1/health over real HTTPS (SNI + certificate check against the hostname)."""
    host = urllib.parse.urlsplit(url).hostname
    ip = public_ip(host)
    if not ip:
        return False
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((ip, 443), timeout=timeout) as raw:
            with ctx.wrap_socket(raw, server_hostname=host) as s:
                s.sendall(("GET /v1/health HTTP/1.1\r\nHost: %s\r\nUser-Agent: asbuilt-recon-tunnel\r\n"
                           "Connection: close\r\n\r\n" % host).encode())
                data = b""
                while len(data) < 65536:
                    b = s.recv(4096)
                    if not b:
                        break
                    data += b
        head, _, body = data.partition(b"\r\n\r\n")
        return head.startswith(b"HTTP/1.1 200") and b'"ok": true' in body
    except Exception:
        return False


def write_private(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def gh(args, stdin=None):
    r = subprocess.run([GH] + args, input=stdin, capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError("gh %s failed: %s" % (args[0:2], r.stderr.strip()[:300]))
    return r.stdout


def publish(url):
    write_private(os.path.join(CONF, "base_url"), url + "\n")
    log.info("base_url -> %s", url)
    doc = json.dumps({"baseURL": url, "apiVersion": 1, "transport": "cloudflare-quick-tunnel", "updatedAt": now_iso()}, indent=1) + "\n"
    disc_path = os.path.join(CONF, "discovery.json")
    disc = {}
    try:
        with open(disc_path) as f:
            disc = json.load(f)
    except (OSError, ValueError):
        pass
    tmpfile = os.path.join(CONF, GIST_FILE)
    write_private(tmpfile, doc)
    try:
        if disc.get("gistID"):
            gh(["gist", "edit", disc["gistID"], "--filename", GIST_FILE, tmpfile])
        else:
            out = gh(["gist", "create", "--desc", "asbuilt-recon discovery (base URL of the Mac build server)", tmpfile])
            gid = out.strip().rstrip("/").split("/")[-1]
            owner = gh(["api", "user", "-q", ".login"]).strip()
            disc = {"gistID": gid, "apiURL": "https://api.github.com/gists/%s" % gid,
                    "rawURL": "https://gist.githubusercontent.com/%s/%s/raw/%s" % (owner, gid, GIST_FILE)}
            write_private(disc_path, json.dumps(disc, indent=1) + "\n")
            gh(["secret", "set", "RECON_DISCOVERY_URL", "-R", REPO], stdin=disc["apiURL"])
            log.info("created discovery gist %s", gid)
        log.info("discovery gist updated")
    except Exception as e:
        log.error("discovery gist update failed: %s", e)
    try:
        gh(["secret", "set", "RECON_BASE_URL", "-R", REPO], stdin=url)
        log.info("GitHub secret RECON_BASE_URL updated")
    except Exception as e:
        log.error("RECON_BASE_URL secret update failed: %s", e)


class Tunnel:
    def __init__(self):
        self.proc = None
        self.url = None
        self.stop = False

    def run_once(self):
        args = [CLOUDFLARED, "tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:%d" % PORT, "--protocol", "http2"]
        log.info("starting: %s", " ".join(args))
        self.url = None
        found = threading.Event()
        self.proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, text=True, bufsize=1)
        cf_log = open(os.path.join(LOG_DIR, "cloudflared.log"), "a")

        def pump():
            for line in self.proc.stdout:
                cf_log.write(line)
                cf_log.flush()
                if not self.url:
                    m = URL_RE.search(line)
                    if m:
                        self.url = m.group(0)
                        found.set()

        threading.Thread(target=pump, daemon=True).start()
        if not found.wait(60):
            log.error("no trycloudflare URL within 60 s; restarting")
            self.kill()
            return
        log.info("tunnel URL %s; waiting for it to answer", self.url)
        t0 = time.time()
        while not health(self.url):
            if self.proc.poll() is not None or time.time() - t0 > 180:
                log.error("tunnel never became healthy; restarting")
                self.kill()
                return
            time.sleep(3)
        log.info("tunnel healthy after %.0fs", time.time() - t0)
        publish(self.url)
        fails = 0
        while not self.stop and self.proc.poll() is None:
            time.sleep(60)
            if health(self.url, timeout=20):
                fails = 0
            else:
                fails += 1
                log.warning("public health check failed (%d/5)", fails)
                if fails >= 5:
                    log.error("tunnel unhealthy; restarting cloudflared")
                    self.kill()
                    return
        log.warning("cloudflared exited (%s)", self.proc.returncode)

    def kill(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def main():
    setup_logging()
    t = Tunnel()

    def on_term(sig, frame):
        t.stop = True
        t.kill()
        sys.exit(0)

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    while not t.stop:
        t.run_once()
        time.sleep(5)


if __name__ == "__main__":
    main()
