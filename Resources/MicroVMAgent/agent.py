"""Studio's in-sandbox agent for AWS Lambda MicroVMs.

Lambda MicroVMs have no exec API, so this small server (stdlib only) runs inside the image and gives Studio:
  POST /studio/exec    {"command", "cwd"?, "timeout"?, "background"?} -> {"stdout","stderr","exitCode"} or {"pid","log"}
  POST /studio/upload?to=/home/user/<dir>   body: tar.gz  -> {"ok": true, "to": ...}
  GET  /studio/health  -> {"ok": true}
Requests only reach it through the MicroVM's proxy, which requires a Lambda auth token (X-aws-proxy-auth).
Lifecycle hooks (/aws/lambda-microvms/runtime/v1/*) are served on HOOK_PORT.
"""
import io, json, os, subprocess, tarfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

API_PORT = int(os.environ.get("STUDIO_AGENT_PORT", "8970"))
HOOK_PORT = 9000
HOME = os.environ.get("STUDIO_HOME", "/home/user")
os.makedirs(HOME, exist_ok=True)


def run(cmd, cwd, timeout, background):
    cwd = cwd if os.path.isabs(cwd or "") else os.path.join(HOME, cwd or "")
    os.makedirs(cwd, exist_ok=True)
    env = dict(os.environ, HOME=HOME)
    if background:
        log = os.path.join("/tmp", f"studio-{int(time.time() * 1000)}.log")
        p = subprocess.Popen(["bash", "-lc", cmd], cwd=cwd, env=env, stdout=open(log, "wb"),
                             stderr=subprocess.STDOUT, start_new_session=True)
        return {"pid": p.pid, "log": log}
    try:
        p = subprocess.run(["bash", "-lc", cmd], cwd=cwd, env=env, capture_output=True,
                           timeout=None if timeout == 0 else timeout)
        return {"stdout": p.stdout.decode(errors="replace")[-200_000:],
                "stderr": p.stderr.decode(errors="replace")[-50_000:], "exitCode": p.returncode}
    except subprocess.TimeoutExpired as e:
        return {"stdout": (e.stdout or b"").decode(errors="replace"), "stderr": "timed out", "exitCode": 124}


class Api(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def do_GET(self):
        if urlparse(self.path).path == "/studio/health":
            return self._send(200, {"ok": True})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        url = urlparse(self.path)
        try:
            if url.path == "/studio/exec":
                a = json.loads(self._body() or b"{}")
                return self._send(200, run(a["command"], a.get("cwd"), int(a.get("timeout", 120)), bool(a.get("background"))))
            if url.path == "/studio/upload":
                to = parse_qs(url.query).get("to", [HOME])[0]
                if not os.path.abspath(to).startswith(HOME):
                    return self._send(400, {"error": f"upload must stay under {HOME}"})
                os.makedirs(to, exist_ok=True)
                with tarfile.open(fileobj=io.BytesIO(self._body()), mode="r:gz") as t:
                    t.extractall(to, filter="data")
                return self._send(200, {"ok": True, "to": to})
        except Exception as e:  # report, never crash the agent
            return self._send(500, {"error": str(e)})
        self._send(404, {"error": "not found"})

    def log_message(self, *a):
        pass


class Hooks(BaseHTTPRequestHandler):
    # ready/validate/run/resume/suspend/terminate: nothing to prepare; the agent is up as soon as it listens
    def do_POST(self):
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    threading.Thread(target=ThreadingHTTPServer(("0.0.0.0", HOOK_PORT), Hooks).serve_forever, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", API_PORT), Api).serve_forever()
