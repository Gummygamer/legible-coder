"""Exercise the real web server and worker against a local model stub.

Run with: python3 -m unittest discover -s tests -v
Requires Node.js and the Legible interpreter on PATH (or set LEGIBLE_BIN).
"""

import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
LEGIBLE = os.environ.get("LEGIBLE_BIN") or shutil.which("legible")


@unittest.skipUnless(LEGIBLE, "Legible interpreter is required")
class WebTurnTest(unittest.TestCase):
    def exercise_turn(self, script_dir, relative_interpreter=False, launch_failure=False, crash_worker=False):
        requests = []
        release_final = threading.Event()

        class ModelHandler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def reply(self, payload):
                body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                self.reply({"data": []})

            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append(payload)
                if len(requests) == 1:
                    message = {"role": "assistant", "content": None, "tool_calls": [{
                        "id": "call_test", "type": "function", "function": {
                            "name": "shell_exec",
                            "arguments": json.dumps({"command": "sleep 1; pwd"}),
                        },
                    }]}
                else:
                    release_final.wait(15)
                    message = {"role": "assistant", "content": "Backend received the message."}
                self.reply({"choices": [{"message": message, "finish_reason": "stop"}],
                            "usage": {"prompt_tokens": 100, "completion_tokens": 20}})

        with tempfile.TemporaryDirectory(prefix="legible-web-test-") as temporary:
            base = Path(temporary)
            source_dir = base / script_dir
            source_dir.mkdir()
            state_dir = base / "state"
            workspace = base / "workspace"
            workspace.mkdir()
            # Redirect only the fixture's state path; never touch the user's registry.
            source = (ROOT / "coder.lbl").read_text().replace(
                'unwrap_or(env_get("HOME"), "/tmp") ++ "/.legible-coder"',
                json.dumps(str(state_dir)),
            )
            for module in sorted(ROOT.glob("*.lbl")):
                shutil.copy(module, source_dir / module.name)
            (source_dir / "coder.lbl").write_text(source)
            interpreter = str(Path(LEGIBLE).resolve())
            if relative_interpreter:
                (base / "legible").symlink_to(interpreter)
                interpreter = "./legible"
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            model = ThreadingHTTPServer(("127.0.0.1", 0), ModelHandler)
            threading.Thread(target=model.serve_forever, daemon=True).start()
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith("LEGIBLE_CODER_")}
            env.update(LEGIBLE_CODER_BASE_URL=f"http://127.0.0.1:{model.server_port}/v1",
                       LEGIBLE_CODER_MODEL="test-model", LEGIBLE_CODER_API_KEY="test",
                       LEGIBLE_CODER_LOCAL_TOOLS="1", LEGIBLE_CODER_WEB_PORT=str(port))
            log_path = base / "server.log"

            def api(path, body=None):
                data = None if body is None else json.dumps(body).encode()
                req = Request(f"http://127.0.0.1:{port}{path}", data=data,
                              headers={"Content-Type": "application/json"})
                try:
                    with urlopen(req, timeout=3) as response:
                        return response.status, json.load(response)
                except HTTPError as error:
                    with error:
                        return error.code, json.load(error)

            def wait_for(predicate, timeout=12):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    try:
                        result = predicate()
                        if result:
                            return result
                    except (URLError, ConnectionError):
                        pass
                    time.sleep(0.1)
                logs = log_path.read_text()
                for log in state_dir.glob("worker-*.log"):
                    logs += "\n" + log.read_text()
                self.fail("Timed out waiting for web turn. Logs:\n" + logs)

            with log_path.open("w") as log:
                server = subprocess.Popen(
                    [interpreter, "run", f"{script_dir}/coder.lbl", "--web"],
                    cwd=base, env=env, stdout=log, stderr=log, start_new_session=True,
                )
                try:
                    wait_for(lambda: api("/api/state")[0] == 200)
                    if script_dir == "source" and not (relative_interpreter or launch_failure or crash_worker):
                        if not shutil.which("node"):
                            self.fail("Node.js is required for the generated frontend regression check")
                        with urlopen(f"http://127.0.0.1:{port}/", timeout=3) as response:
                            frontend = subprocess.run(
                                ["node", str(ROOT / "tests/check_web_frontend.js")],
                                input=response.read(), capture_output=True, timeout=10,
                            )
                        self.assertEqual(frontend.returncode, 0, frontend.stderr.decode())
                    status, _ = api("/api/workspaces", {"name": "Test", "root_dir": str(workspace)})
                    self.assertEqual(status, 200)
                    prompt = "Please inspect this workspace. Quotes: ' \" and $literal.\nSecond line."
                    if launch_failure:
                        launch_path = state_dir / "server-launch.json"
                        launch = launch_path.read_text()
                        launch_path.write_text(json.dumps({"interpreter": "/missing/legible", "script": ""}))
                        status, failed = api("/api/send", {"text": prompt})
                        self.assertEqual(status, 500, failed)
                        self.assertEqual(api("/api/messages")[1]["messages"], [])
                        self.assertEqual(list(state_dir.glob("locks/*.lock")), [])
                        launch_path.write_text(launch)
                    status, sent = api("/api/send", {"text": prompt})
                    self.assertEqual(status, 200, sent)
                    self.assertIs(sent["ok"], True)
                    self.assertIs(sent["started"], True)
                    events_url = f'/api/events?ws={sent["ws"]}&conv={sent["conv"]}'
                    running = wait_for(lambda: (p if any(e["type"] == "tool_start" for e in p["events"]) else None)
                                       if (p := api(events_url)[1]) else None)
                    self.assertIs(running["running"], True)
                    self.assertNotIn("done", [e["type"] for e in running["events"]])
                    status, _ = api("/api/send", {"text": "duplicate"})
                    self.assertEqual(status, 409)
                    if crash_worker:
                        lock = next(state_dir.glob("locks/*.lock"))
                        supervisor_pid = int(lock.read_text())
                        children = Path(f"/proc/{supervisor_pid}/task/{supervisor_pid}/children").read_text().split()
                        self.assertEqual(len(children), 1)
                        os.kill(int(children[0]), signal.SIGKILL)
                    release_final.set()
                    completed = wait_for(lambda: (p if any(e["type"] == "done" for e in p["events"]) else None)
                                         if (p := api(events_url)[1]) else None)
                    wait_for(lambda: api(events_url)[1]["running"] is False)
                    if crash_worker:
                        self.assertIn("error", [e["type"] for e in completed["events"]])
                        self.assertEqual(list(state_dir.glob("locks/*.lock")), [])
                        status, retried = api("/api/send", {"text": "Try again"})
                        self.assertEqual(status, 200, retried)
                        wait_for(lambda: any(e["type"] == "done" for e in api(events_url)[1]["events"]))
                        self.assertEqual(api("/api/messages")[1]["messages"][-1]["content"],
                                         "Backend received the message.")
                        return
                    self.assertIn("tool_end", [e["type"] for e in completed["events"]])
                    self.assertEqual(api(events_url + f'&since={completed["next"]}')[1]["events"], [])
                    messages = api("/api/messages")[1]["messages"]
                    self.assertEqual([m["content"] for m in messages if m["role"] == "user"], [prompt])
                    self.assertEqual(messages[-1]["content"], "Backend received the message.")
                    self.assertEqual(len(requests), 2)
                    self.assertEqual([m["content"] for m in requests[0]["messages"] if m["role"] == "user"], [prompt])
                    result = next(m for m in requests[1]["messages"] if m["role"] == "tool")
                    self.assertIn(str(workspace), result["content"])
                finally:
                    release_final.set()
                    for lock in state_dir.glob("locks/*.lock"):
                        pid = lock.read_text().strip()
                        if pid.isdigit():
                            try:
                                os.kill(int(pid), signal.SIGTERM)
                            except ProcessLookupError:
                                pass
                    server.terminate()
                    server.wait(timeout=5)
                    model.shutdown()
                    model.server_close()

    def test_send_and_live_tool_events(self):
        self.exercise_turn("source")

    def test_script_path_with_spaces(self):
        self.exercise_turn("source with spaces and 'quotes'")

    def test_relative_interpreter_after_workspace_change(self):
        self.exercise_turn("source", relative_interpreter=True)

    def test_failed_launch_rolls_back_message_and_allows_retry(self):
        self.exercise_turn("source", launch_failure=True)

    def test_worker_crash_reports_error_and_allows_retry(self):
        self.exercise_turn("source", crash_worker=True)


if __name__ == "__main__":
    unittest.main()
