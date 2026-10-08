#!/usr/bin/env python3
"""Serve an editor and its agent API on one network origin.

The shared isonim-review daemon chooses the optional workspace Harbor backend.
Consumers only provide their static directory, project root, and listen port.
"""
from __future__ import annotations

import argparse
import json
import functools
import http.client
import http.server
import os
from pathlib import Path
import shutil
import queue
import re
import select
import socket
import signal
import secrets
import threading
import sys
from contextlib import contextmanager
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

REPO = Path(__file__).resolve().parent.parent


def public_source_manifest(manifest: dict) -> dict:
    """Expose catalog identity capabilities without private source locations."""
    public = {name: manifest.get(name, []) for name in ("workspace", "title", "fixtures")}
    if "editableStyleSources" in manifest:
        public["editableStyleSources"] = []
    return public

# Two sequential native HTTP deadlines (creation/delivery and stop), then
# owned Harbor TERM/KILL/reap and scheduling margin. Session stops run concurrently.
SHUTDOWN_POLICY = json.loads((REPO / "tools/editor_shutdown.json").read_text())
DAEMON_SHUTDOWN_SECONDS = (2 * SHUTDOWN_POLICY["http_request_seconds"] +
    SHUTDOWN_POLICY["harbor_teardown_seconds"] + SHUTDOWN_POLICY["supervisor_margin_seconds"])


def install_vendor_assets(destination: Path) -> None:
    source = os.environ.get("ISONIM_EDITOR_VENDOR")
    if not source:
        source = subprocess.check_output(
            ["nix", "build", ".#editor-vendor", "--no-link", "--print-out-paths"],
            cwd=REPO, text=True,
        ).strip().splitlines()[-1]
    destination.mkdir(parents=True, exist_ok=True)
    for name in ("tiptap.umd.js", "xterm.umd.js", "xterm.css"):
        # Replace old Nix copies even when their source permissions were read-only.
        with tempfile.NamedTemporaryFile(dir=destination, delete=False) as tmp:
            temporary = Path(tmp.name)
        try:
            shutil.copyfile(Path(source) / name, temporary)
            temporary.replace(destination / name)
        finally:
            temporary.unlink(missing_ok=True)


class Shutdown(SystemExit):
    """Signal-driven shutdown unwinds every owned process scope."""


@contextmanager
def shutdown_signals():
    previous = {}
    stopping = False
    def stop(signum, frame):
        nonlocal stopping
        if stopping:
            return
        stopping = True
        raise Shutdown(128 + signum)
    if threading.current_thread() is threading.main_thread():
        for signum in (signal.SIGTERM, signal.SIGINT):
            previous[signum] = signal.signal(signum, stop)
    try:
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def owned_session_groups(session_id, ps_executable=None, known_groups=None):
    # Enumerate only numeric PIDs; kernel session identities cover child PGs
    # created by Repro while excluding other editors and detached services.
    groups = set()
    identities = known_groups if known_groups is not None else {}
    for group, members in list(identities.items()):
        for pid in list(members):
            try:
                if os.getsid(pid) == session_id and os.getpgid(pid) == group:
                    groups.add(group)
            except ProcessLookupError:
                pass
    try:
        if os.getsid(session_id) == session_id:
            groups.add(session_id)
            identities.setdefault(session_id, set()).add(session_id)
    except ProcessLookupError:
        pass
    try:
        pids = subprocess.check_output([ps_executable or "ps", "-e", "-o", "pid="], text=True, timeout=SHUTDOWN_POLICY["enumeration_seconds"])
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"Owned session {session_id}: process enumeration failed; signalling known groups: {error}", file=sys.stderr)
        return groups
    for item in pids.split():
        try:
            pid = int(item)
            if os.getsid(pid) == session_id:
                group = os.getpgid(pid)
                groups.add(group)
                identities.setdefault(group, set()).add(pid)
        except ValueError:
            print(f"Owned session {session_id}: invalid PID in process enumeration", file=sys.stderr)
        except OSError as error:
            if isinstance(error, ProcessLookupError):
                continue
            print(f"Owned session {session_id}: cannot inspect PID {item}: {error}", file=sys.stderr)
    return groups


def signal_owned_session(session_id, signum, ps_executable=None, known_groups=None):
    groups = owned_session_groups(session_id, ps_executable, known_groups)
    for group in groups:
        try:
            os.killpg(group, signum)
        except ProcessLookupError:
            pass


@contextmanager
def owned_process(args, require_clean_exit=False, **kwargs):
    ps_executable = shutil.which("ps")
    if not ps_executable:
        raise RuntimeError("Owned editor processes require the POSIX ps executable")
    try:
        subprocess.run([ps_executable, "-e", "-o", "pid="], check=True, stdout=subprocess.DEVNULL, timeout=SHUTDOWN_POLICY["enumeration_seconds"])
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError(f"POSIX ps preflight failed: {error}") from error
    known_groups = {}
    process = subprocess.Popen(args, start_new_session=True, **kwargs)
    try:
        yield process
    finally:
        # A graceful daemon shutdown also closes the independently owned Harbor
        # group. Kill the wrapper group only if graceful shutdown cannot finish.
        signal_owned_session(process.pid, signal.SIGTERM, ps_executable, known_groups)
        try:
            process.wait(timeout=DAEMON_SHUTDOWN_SECONDS)
        except subprocess.TimeoutExpired:
            print("Owned editor process exceeded shutdown budget; provider closure is unconfirmed", file=sys.stderr)
            signal_owned_session(process.pid, signal.SIGKILL, ps_executable, known_groups)
            process.wait()
        finally:
            # Command wrappers may exit before descendants; reclaim their group.
            signal_owned_session(process.pid, signal.SIGKILL, ps_executable, known_groups)
        if require_clean_exit and process.returncode != 0:
            raise RuntimeError(f"Owned editor daemon did not exit cleanly: {process.returncode}")


def await_daemon(process, lines, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"Editor daemon exited with {process.returncode}; see startup output")
        try:
            line = lines.get(timeout=min(0.2, max(0, deadline - time.monotonic())))
        except queue.Empty:
            continue
        if line.startswith("READY "):
            port = int(line.split()[1])
            endpoint = f"http://127.0.0.1:{port}"
            req = urllib.request.Request(endpoint + "/api/agent/sessions", method="OPTIONS")
            with urllib.request.urlopen(req, timeout=5) as response:
                if response.status != 204:
                    raise RuntimeError("Editor daemon readiness check failed")
            return endpoint
    raise TimeoutError("Editor daemon did not become ready; see startup output")


def inject_origin_meta(html, browser_bootstrap=""):
    meta = ('<script>const apiMeta=document.createElement("meta");'
            'apiMeta.name="isonim-review-api";apiMeta.content=location.origin;'
            'document.head.appendChild(apiMeta);</script>')
    if browser_bootstrap:
        meta += ('<script>const controlMeta=document.createElement("meta");'
                 'controlMeta.name="isonim-editor-bootstrap";controlMeta.content='
                 + json.dumps(browser_bootstrap) + ';document.head.appendChild(controlMeta);</script>')
    html = re.sub(r'<meta\b[^>]*\bname=["\']isonim-review-api["\'][^>]*>',
                  '', html, flags=re.IGNORECASE)
    return re.sub(r'</head>', meta + '</head>', html, count=1, flags=re.IGNORECASE).encode()


class EditorHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, *args, **kwargs):
        self.source_jobs = set()
        self.source_jobs_lock = threading.Lock()
        self.source_recovery = None
        self.source_closing = False
        super().__init__(*args, **kwargs)

    def server_close(self):
        # Source producers belong to this editor service, including jobs whose
        # browser disconnected. Reclaim their process groups before recovery.
        with self.source_jobs_lock:
            self.source_closing = True
            jobs = list(self.source_jobs)
        for process in jobs:
            if process.poll() is None:
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
            process.wait(timeout=5)
        if jobs and self.source_recovery:
            root, binary = self.source_recovery
            recovered = subprocess.run([str(binary), "source-project", str(root), "--recover"],
                capture_output=True, text=True, timeout=5)
            if recovered.returncode:
                print("Interrupted source transaction recovery failed: " + recovered.stdout, file=sys.stderr)
        super().server_close()


class EditorHandler(http.server.SimpleHTTPRequestHandler):
    daemon_url: str
    frontend_url: str = ""
    browser_bootstrap: str = ""
    source_root: Path | None = None
    source_binary: Path | None = None
    source_lock = threading.Lock()
    source_results: dict = {}

    def api_request(self, target_url=None, inject_meta=False) -> None:
        endpoint = urllib.parse.urlsplit(target_url or self.daemon_url)
        conn = http.client.HTTPConnection(endpoint.hostname, endpoint.port, timeout=1800)
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        headers = {"Content-Type": self.headers.get("Content-Type", "application/json")}
        # Forward only the editor control credential, never backend credentials.
        if self.headers.get("X-IsoNim-Control"):
            headers["X-IsoNim-Control"] = self.headers["X-IsoNim-Control"]
        headers_sent = False
        try:
            conn.request(self.command, self.path, body, headers)
            response = conn.getresponse()
            page = None
            if inject_meta and response.status == 200 and 'text/html' in response.getheader('Content-Type', ''):
                page = inject_origin_meta(response.read().decode(), self.browser_bootstrap)
            self.send_response(response.status)
            self.send_header("Content-Type", response.getheader("Content-Type", "application/json"))
            for name in ("Content-Length", "Allow", "Retry-After"):
                value = str(len(page)) if name == "Content-Length" and page is not None else response.getheader(name)
                if value is not None:
                    self.send_header(name, value)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            headers_sent = True
            if page is not None:
                self.wfile.write(page)
                self.wfile.flush()
                return
            while chunk := response.read1(65536):
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except (OSError, http.client.HTTPException) as error:
            self.log_error("daemon proxy failed: %s", error)
            if not headers_sent:
                self.send_error(502, "Editor agent service unavailable")
        finally:
            self.close_connection = True
            conn.close()

    def do_GET(self) -> None:
        path = urllib.parse.urlsplit(self.path).path
        if path == "/api/editor/source/catalog" and self.source_root:
            manifest_path = self.source_root / ".isonim/source-project.json"
            if not manifest_path.exists() and not manifest_path.is_symlink():
                return self.send_error(404, "Project source bridge unavailable")
            # Protect the complete manifest/catalog/capability snapshot, not
            # only the later describe call. Native snapshot also owns the OS
            # project lock, so another native worker cannot publish mid-read.
            with self.source_lock:
                try:
                    if self.source_binary:
                        described = subprocess.run([str(self.source_binary), "source-project", str(self.source_root), "--snapshot"],
                            cwd=self.source_root, capture_output=True, text=True, timeout=5)
                        snapshot = json.loads(described.stdout)
                        if described.returncode or not snapshot.get("ok"):
                            raise ValueError(snapshot.get("diagnostic", "Invalid editable source metadata"))
                        manifest = snapshot["manifest"]
                        output = {"catalog": snapshot["catalog"], "manifest": public_source_manifest(manifest)}
                        if "editableStyles" in manifest or "editableStyleSources" in manifest:
                            output["editableStyles"] = snapshot["editableStyles"]
                    else:
                        # Catalog-only consumers expose no native writer. Keep
                        # their existing read contract; editable projects require
                        # the native transaction/snapshot boundary.
                        manifest = json.loads(manifest_path.read_text())
                        if "editableStyles" in manifest or "editableStyleSources" in manifest:
                            raise ValueError("Native editable source worker unavailable")
                        catalog_path = (self.source_root / manifest["catalog"]).resolve()
                        if not catalog_path.is_relative_to(self.source_root):
                            raise ValueError("Catalog path escapes workspace")
                        output = {"catalog": json.loads(catalog_path.read_text()), "manifest": public_source_manifest(manifest)}
                    status = 200
                except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
                    output = {"ok": False, "diagnostic": "Source project contract is invalid: " + str(error)}
                    status = 400
                data = json.dumps(output).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)
            return
        if path.startswith("/api/"):
            return self.api_request()
        if self.frontend_url:
            if self.headers.get("Upgrade", "").lower() == "websocket":
                return self.upgrade_frontend()
            return self.api_request(self.frontend_url, inject_meta=path in ("/", "/index.html"))
        if path in ("/", "/index.html"):
            data = (Path(self.directory) / "index.html").read_text()
            data = inject_origin_meta(data, self.browser_bootstrap)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)
            return
        super().do_GET()

    def source_operation(self) -> None:
        # Only the registered browser's ACK credential authorizes source work.
        # Resolve the command from the registry rather than trust posted edits,
        # paths, templates, compiler arguments or a caller's claimed permissions.
        timing_start = time.monotonic()
        timings = {}
        def checkpoint(name):
            timings[name] = round((time.monotonic() - timing_start) * 1000, 3)
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 1 or length > 65536: raise ValueError("Invalid source request size")
            params = json.loads(self.rfile.read(length))
            if not isinstance(params, dict): raise ValueError("Object required")
            def authorize(admit=False):
                admission = dict(params)
                admission["admit"] = admit
                request = urllib.request.Request(self.daemon_url + "/api/editor/rpc",
                    data=json.dumps({"jsonrpc": "2.0", "id": "source", "method": "editor.source-authorize", "params": admission}).encode(),
                    headers={"Content-Type": "application/json", "X-IsoNim-Control": self.headers.get("X-IsoNim-Control", "")})
                with urllib.request.urlopen(request, timeout=3) as response:
                    authorization = json.load(response)
                if "error" in authorization: raise ValueError(authorization["error"]["message"])
                return authorization["result"]
            authorize()
            checkpoint("authorized")
            key = (params["instance"], params["epoch"], params["operationId"])
            # Serialize real project transactions and cache successful or failed
            # results so a lost response cannot create/build the same operation twice.
            with self.source_lock:
                if key in self.source_results:
                    output = self.source_results[key]
                else:
                    # Waiting is not admission. Re-check terminal revocation and
                    # current permissions only after acquiring the project lock.
                    command = authorize(admit=True)
                    checkpoint("admitted")
                    with tempfile.TemporaryDirectory(prefix="isonim-source-") as temporary:
                        payload = Path(temporary) / "request.json"
                        payload.write_text(json.dumps(command))
                        with self.server.source_jobs_lock:
                            if self.server.source_closing: raise ValueError("Editor source service is shutting down")
                            process = subprocess.Popen([str(self.source_binary), "source-project", str(self.source_root), str(payload)],
                                cwd=self.source_root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
                            self.server.source_jobs.add(process)
                            self.server.source_recovery = (self.source_root, self.source_binary)
                        try:
                            stdout, stderr = process.communicate(timeout=120)
                        except subprocess.TimeoutExpired:
                            try: os.killpg(process.pid, signal.SIGKILL)
                            except ProcessLookupError: pass
                            stdout, stderr = process.communicate()
                            recovered = subprocess.run([str(self.source_binary), "source-project", str(self.source_root), "--recover"],
                                capture_output=True, text=True, timeout=5)
                            output = {"ok": False, "diagnostic": "Project compiler exceeded 120 seconds" +
                                ("; recovery failed: " + recovered.stdout if recovered.returncode else "")}
                        else:
                            try: output = json.loads(stdout)
                            except json.JSONDecodeError: output = {"ok": False, "diagnostic": "Source worker failed: " + stderr[-16000:]}
                        finally:
                            # Reclaim build descendants even if their wrapper exited.
                            try: os.killpg(process.pid, signal.SIGKILL)
                            except ProcessLookupError: pass
                            with self.server.source_jobs_lock: self.server.source_jobs.discard(process)
                    checkpoint("native_exited")
                    if output.get("manifest"):
                        output["manifest"] = public_source_manifest(output["manifest"])
                    self.source_results[key] = output
            data = json.dumps(output).encode()
            checkpoint("encoded")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            checkpoint("sent")
            if os.environ.get("ISONIM_SOURCE_DIAGNOSTICS") == "timing":
                # Private developer diagnostics: no credentials/source payload.
                self.log_message("inspector-source-timing %s", json.dumps({**timings, "bytes": len(data)}))
        except (KeyError, ValueError, OSError, urllib.error.URLError, subprocess.SubprocessError) as error:
            data = json.dumps({"ok": False, "diagnostic": str(error)}).encode()
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    def do_POST(self) -> None:
        if self.path == "/api/editor/source/operation" and self.source_root and self.source_binary:
            return self.source_operation()
        if self.path.startswith("/api/"):
            return self.api_request()
        if self.frontend_url:
            return self.api_request(self.frontend_url)
        self.send_error(404)

    def upgrade_frontend(self):
        endpoint = urllib.parse.urlsplit(self.frontend_url)
        upstream = None
        try:
            upstream = socket.create_connection((endpoint.hostname, endpoint.port), timeout=5)
            headers = dict(self.headers)
            headers['Host'] = endpoint.netloc
            head = f'{self.command} {self.path} HTTP/1.1\r\n' + ''.join(f'{k}: {v}\r\n' for k, v in headers.items()) + '\r\n'
            upstream.sendall(head.encode())
            while True:
                readable, _, _ = select.select([self.connection, upstream], [], [], 1)
                for source in readable:
                    data = source.recv(65536)
                    if not data: return
                    destination = upstream if source is self.connection else self.connection
                    destination.sendall(data)
        except OSError as error:
            self.log_error('frontend upgrade failed: %s', error)
            if upstream is None: self.send_error(502, 'Editor frontend unavailable')
        finally:
            self.close_connection = True
            if upstream: upstream.close()

    def do_OPTIONS(self) -> None:
        if self.path.startswith("/api/"):
            return self.api_request()
        self.send_error(404)


def serve(directory: Path, project_root: Path, port: int, bind: str = "0.0.0.0",
          daemon_url: str = "", command: list[str] | None = None,
          config: Path | None = None, daemon_binary: Path | None = None,
          startup_timeout: float = 1800, frontend_command: list[str] | None = None) -> None:
    directory, project_root = directory.resolve(), project_root.resolve()
    if not (directory / "index.html").is_file():
        raise ValueError(f"Editor index missing: {directory / 'index.html'}")
    if not project_root.is_dir():
        raise ValueError(f"Editor project root missing: {project_root}")
    if daemon_url:
        endpoint = urllib.parse.urlsplit(daemon_url)
        if endpoint.scheme != "http" or not endpoint.hostname or not endpoint.port:
            raise ValueError("--daemon-url must be an http://host:port endpoint")
    with shutdown_signals():
        if not daemon_url:
            if daemon_binary is None:
                with owned_process(["repro", "exec", "--", "just", "isonim-review-build"],
                                   cwd=REPO) as build:
                    code = build.wait()
                    if code:
                        raise RuntimeError(f"Editor daemon build failed with {code}")
                daemon_binary = REPO / "build" / "bin" / "isonim-review"
            args = [str(daemon_binary.resolve()), "serve", "--agent-routes-only",
                    "--bind", "127.0.0.1", "--port", "0", "--workspace", str(project_root),
                    "--default-assistant-prompt", str(REPO / "prompts" / "ai-assistant.md")]
            if config:
                args += ["--config", str(config.resolve())]
            env = dict(os.environ)
            browser_bootstrap = secrets.token_hex(32)
            env["ISONIM_EDITOR_BROWSER_BOOTSTRAP"] = browser_bootstrap
            with owned_process(args, require_clean_exit=True, cwd=project_root, env=env, stderr=subprocess.PIPE,
                               text=True, bufsize=1) as daemon:
                lines = queue.Queue()
                def relay():
                    for line in daemon.stderr:
                        sys.stderr.write(line)
                        sys.stderr.flush()
                        if line.startswith("READY "):
                            lines.put(line)
                threading.Thread(target=relay, daemon=True).start()
                ready_url = await_daemon(daemon, lines, startup_timeout)
                serve_frontend(directory, project_root, port, bind, ready_url, command, daemon, frontend_command, browser_bootstrap, daemon_binary)
        else:
            serve_frontend(directory, project_root, port, bind, daemon_url, command, frontend_command=frontend_command, browser_bootstrap=os.environ.get("ISONIM_EDITOR_BROWSER_BOOTSTRAP", ""), source_binary=daemon_binary)


def serve_frontend(directory, project_root, port, bind, daemon_url, command, daemon=None, frontend_command=None, browser_bootstrap="", source_binary=None):
    if frontend_command:
        # An existing write/live-reload frontend remains private behind the
        # common origin. A bind collision is a startup error, never a fallback.
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            frontend_port = probe.getsockname()[1]
        env = {**os.environ, 'PORT': str(frontend_port), 'ISONIM_EDITOR_BIND': '127.0.0.1'}
        with owned_process(frontend_command, cwd=project_root, env=env) as frontend:
            frontend_url = f'http://127.0.0.1:{frontend_port}'
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if frontend.poll() is not None:
                    raise RuntimeError(f'Editor frontend exited with {frontend.returncode}')
                try:
                    with urllib.request.urlopen(frontend_url, timeout=1) as response:
                        if response.status == 200: break
                except OSError: time.sleep(.1)
            else: raise TimeoutError('Editor frontend did not become ready')
            return serve_proxy(directory, port, bind, daemon_url, daemon, frontend_url, frontend, browser_bootstrap, project_root, source_binary)

    if command:
        endpoint = urllib.parse.urlsplit(daemon_url)
        env = {**os.environ, "ISONIM_DAEMON_HOST": endpoint.hostname,
               "ISONIM_DAEMON_PORT": str(endpoint.port), "PORT": str(port),
               "ISONIM_EDITOR_BIND": bind, "EDITOR_STATIC_ROOT": str(directory)}
        with owned_process(command, cwd=project_root, env=env) as frontend:
            while frontend.poll() is None:
                if daemon and daemon.poll() is not None:
                    raise RuntimeError(f"Editor daemon exited with {daemon.returncode}")
                time.sleep(0.1)
            if frontend.returncode:
                raise RuntimeError(f"Editor frontend exited with {frontend.returncode}")
        return
    return serve_proxy(directory, port, bind, daemon_url, daemon, browser_bootstrap=browser_bootstrap, source_root=project_root, source_binary=source_binary)


def serve_proxy(directory, port, bind, daemon_url, daemon=None, frontend_url='', frontend=None, browser_bootstrap='', source_root=None, source_binary=None):
    handler = type("InstanceHandler", (EditorHandler,), {"daemon_url": daemon_url, "frontend_url": frontend_url, "browser_bootstrap": browser_bootstrap, "source_root": source_root, "source_binary": source_binary or REPO / "build/bin/isonim-review", "source_lock": threading.Lock(), "source_results": {}})
    with EditorHTTPServer(
            (bind, port), functools.partial(handler, directory=str(directory))) as server:
        print(f"Editor listening on http://{bind}:{server.server_port}/", flush=True)
        server.timeout = 0.2
        while True:
            if daemon and daemon.poll() is not None:
                raise RuntimeError(f"Editor daemon exited with {daemon.returncode}")
            if frontend and frontend.poll() is not None:
                raise RuntimeError(f"Editor frontend exited with {frontend.returncode}")
            server.handle_request()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--project-root", required=True, type=Path)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--daemon-url", default="")
    parser.add_argument("--config", type=Path)
    parser.add_argument("--daemon-binary", type=Path, help="Use an already built editor daemon")
    parser.add_argument("--startup-timeout", type=float, default=1800)
    commands = parser.add_mutually_exclusive_group()
    commands.add_argument("--command", nargs=argparse.REMAINDER)
    commands.add_argument("--frontend-command", nargs=argparse.REMAINDER,
                          help="Keep an existing frontend behind the common proxy")
    args = parser.parse_args()
    try:
        serve(args.directory, args.project_root, args.port, args.bind, args.daemon_url,
              args.command, args.config, args.daemon_binary, args.startup_timeout, args.frontend_command)
    except (OSError, ValueError, RuntimeError, TimeoutError) as error:
        parser.exit(1, f"editor_server: {error}\n")
