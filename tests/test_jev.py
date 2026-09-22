"""Exercise Jev's local written-script test helper without a Jev API key."""

import os
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(__file__).resolve().parents[1]
LEGIBLE = os.environ.get("LEGIBLE_BIN") or shutil.which("legible")


@unittest.skipUnless(LEGIBLE, "Legible interpreter is required")
class JevScriptTest(unittest.TestCase):
    def test_written_script_check_distinguishes_valid_and_invalid_sources(self):
        with tempfile.TemporaryDirectory(prefix="legible-jev-test-") as directory:
            target = Path(directory)
            for module in ("coder.lbl", "kv_cache.lbl", "turn_budget.lbl"):
                shutil.copy(ROOT / module, target / module)

            source = (ROOT / "coder.lbl").read_text()
            marker = "function main(): nothing"
            position = source.rfind(marker)
            source = source[:position] + "function coder_main(): nothing" + source[position + len(marker):]
            source += r'''
function main(): nothing
  intent: test the Jev written script checker on valid and invalid sources
  write_file("good.lbl", "print(\"ok\")")
  write_file("bad.lbl", "print(\"broken\"\n")
  write_file("bad_run.lbl", "function main(): nothing\n  intent: fail the runtime test\n  exit_process(7)\nend\n")
  let good: JevTestResult = jev_test_written_source("good.lbl")
  let bad: JevTestResult = jev_test_written_source("bad.lbl")
  let bad_run: JevTestResult = jev_test_written_source("bad_run.lbl")
  print("GOOD=" ++ to_text(good.passed))
  print("BAD=" ++ to_text(bad.passed))
  print("BAD_RUN=" ++ to_text(bad_run.passed))
end
'''
            script = target / "probe.lbl"
            script.write_text(source)
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith("LEGIBLE_CODER_JEV_")}
            result = subprocess.run([LEGIBLE, "run", str(script)], cwd=target,
                                    env=env, text=True, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("GOOD=true", result.stdout)
            self.assertIn("BAD=false", result.stdout)
            self.assertIn("BAD_RUN=false", result.stdout)


INITIAL_GRAPH = {
    "start": "n1",
    "nodes": {
        "n1": {
            "kind": "tool",
            "tool": "write_file",
            "args": {"path": "hello.lbl", "content": "print(\"hi\")"},
            "next": "n2",
        },
        "n2": {
            "kind": "tool",
            "tool": "test_script",
            "args": {"path": "hello.lbl"},
            "next": "n3",
        },
        "n3": {
            "kind": "choice",
            "question": "Did the test pass?",
            "options": {
                "<pass>": {"desc": "the test passed", "goto": ""},
                "<fix>": {"desc": "the test failed", "goto": "replan"},
            },
        },
    },
}

REPLANNED_GRAPH = {
    "start": "m1",
    "nodes": {
        "m1": {
            "kind": "tool",
            "tool": "write_file",
            "args": {"path": "fixed.lbl", "content": "print(\"fixed\")"},
            "next": "",
        },
    },
}


@unittest.skipUnless(LEGIBLE, "Legible interpreter is required")
class JevGraphTraversalTest(unittest.TestCase):
    def test_jev_replan_choice_triggers_a_second_planner_call(self):
        planner_requests = []
        jev_requests = []

        class PlannerHandler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                planner_requests.append(payload)
                graph = INITIAL_GRAPH if len(planner_requests) == 1 else REPLANNED_GRAPH
                content = json.dumps(graph)
                body = json.dumps({
                    "choices": [{"message": {"content": content}, "finish_reason": "stop"}]
                }).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        class JevHandler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                jev_requests.append(payload)
                # Always pick the reserved <replan> branch, even though the
                # graph only authored <pass>/<fix>, to exercise Jev calling
                # the planner again mid-turn on its own initiative.
                body = json.dumps({"answers": {"choice": {"choice": "<replan>"}}}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        planner_server = ThreadingHTTPServer(("127.0.0.1", 0), PlannerHandler)
        jev_server = ThreadingHTTPServer(("127.0.0.1", 0), JevHandler)
        threading.Thread(target=planner_server.serve_forever, daemon=True).start()
        threading.Thread(target=jev_server.serve_forever, daemon=True).start()
        try:
            with tempfile.TemporaryDirectory(prefix="legible-jev-graph-") as directory:
                target = Path(directory)
                for module in ("coder.lbl", "kv_cache.lbl", "turn_budget.lbl"):
                    shutil.copy(ROOT / module, target / module)
                source = (ROOT / "coder.lbl").read_text()
                marker = "function main(): nothing"
                position = source.rfind(marker)
                source = source[:position] + "function coder_main(): nothing" + source[position + len(marker):]
                source += r'''
function main(): nothing
  intent: test that Jev choosing the reserved replan branch calls the planner again and finishes the new graph
  let settings: TurnSettings = TurnSettings {key: "test-jev-key", base_url: jev_base_url(), model: "jev-latest", max_tools: 10, include_tools: true, include_dir_tools: false, max_output_tokens: 128, context_budget: 5000, preserve_recent_messages: 4, compact_after: 0, include_vision: false, track_usage: false, turn_quality: 1.0}
  let result: InnerLoopResult = run_jev_graph_turn([], "write hello.lbl", settings)
  print("USED_MODEL=" ++ to_text(result.used_model))
end
'''
                script = target / "probe.lbl"
                script.write_text(source)
                env = {key: value for key, value in os.environ.items()
                       if not key.startswith("LEGIBLE_CODER_JEV_")}
                env.update(
                    LEGIBLE_CODER_JEV_URL=f"http://127.0.0.1:{jev_server.server_port}",
                    LEGIBLE_CODER_JEV_PLANNER_URL=f"http://127.0.0.1:{planner_server.server_port}",
                )
                result = subprocess.run([LEGIBLE, "run", str(script)], cwd=target,
                                        env=env, text=True, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("USED_MODEL=true", result.stdout)
                self.assertEqual(len(planner_requests), 2, result.stdout + result.stderr)
                self.assertEqual(len(jev_requests), 1, result.stdout + result.stderr)
                self.assertTrue((target / "hello.lbl").exists())
                self.assertTrue((target / "fixed.lbl").exists())
                self.assertIn("fixed", (target / "fixed.lbl").read_text())
        finally:
            planner_server.shutdown()
            planner_server.server_close()
            jev_server.shutdown()
            jev_server.server_close()
