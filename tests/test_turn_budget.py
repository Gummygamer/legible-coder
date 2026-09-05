"""Run the real native-tool loop against a local stub, without provider credentials."""

import json
import os
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
class TurnBudgetTest(unittest.TestCase):
    def run_turn(self, *, minimum=None, maximum=30, batch_size=1,
                 finish_after=None, repeat=False, ignore_stop=False, quality=0.4):
        requests = []

        class ModelHandler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append(payload)
                index = len(requests)
                if ((payload["tool_choice"] == "none" and not ignore_stop)
                        or (finish_after is not None and index > finish_after)):
                    message = {"role": "assistant", "content": "Finished."}
                else:
                    message = {"role": "assistant", "content": None, "tool_calls": [
                        {"id": f"call_{index}_{i}", "type": "function", "function": {
                            "name": "shell_exec",
                            "arguments": json.dumps({"command": f"printf 'result {0 if repeat else index} {i}'"}),
                        }} for i in range(batch_size)
                    ]}
                body = json.dumps({"choices": [{"message": message, "finish_reason": "stop"}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        model = ThreadingHTTPServer(("127.0.0.1", 0), ModelHandler)
        threading.Thread(target=model.serve_forever, daemon=True).start()
        try:
            with tempfile.TemporaryDirectory(prefix="legible-budget-test-") as directory:
                target = Path(directory)
                for module in ("turn_budget.lbl", "kv_cache.lbl"):
                    shutil.copy(ROOT / module, target / module)
                source = (ROOT / "coder.lbl").read_text().replace(
                    "function main(): nothing", "function coder_main(): nothing")
                source += f'''
function main(): nothing
  intent: run_inner_loop against the test model and print whether the result ends with assistant text
  let messages: a list of a mapping from text to text = [{{"role": "system", "content": "Use tools as needed."}}, {{"role": "user", "content": "Complete the task."}}]
  let result: InnerLoopResult = run_inner_loop(messages, 2, "test", "http://127.0.0.1:{model.server_port}/v1", "test-model", {maximum}, true, true, 4096, 120000, 12, 0, false, false, {quality})
  print("TEST_FINAL=" ++ to_text(last_message_is_assistant_text(result.messages)))
end
'''
                script = target / "coder.lbl"
                script.write_text(source)
                env = {k: v for k, v in os.environ.items() if not k.startswith("LEGIBLE_CODER_")}
                if minimum is not None:
                    env["LEGIBLE_CODER_TURN_MIN_ROUNDS"] = str(minimum)
                result = subprocess.run([LEGIBLE, "run", str(script)], cwd=target,
                                        env=env, text=True, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("TEST_FINAL=true", result.stdout)
        finally:
            model.shutdown()
            model.server_close()
        return requests

    def test_budget_math_and_boundaries(self):
        result = subprocess.run([LEGIBLE, "run", str(ROOT / "test_turn_budget.lbl")],
                                cwd=ROOT, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Budget assertions passed.", result.stdout)

    def test_productive_turns_get_eight_rounds_across_difficulties(self):
        for quality in (0.4, 0.65, 0.9):
            with self.subTest(quality=quality):
                requests = self.run_turn(quality=quality)
                self.assertEqual([r["tool_choice"] for r in requests], ["auto"] * 8 + ["none"])
                self.assertEqual(sum(m["role"] == "tool" for m in requests[-1]["messages"]), 8)

    def test_minimum_override_is_honored(self):
        requests = self.run_turn(minimum=12)
        self.assertEqual([r["tool_choice"] for r in requests], ["auto"] * 12 + ["none"])

    def test_hard_limit_wins_and_still_allows_final_answer(self):
        for maximum in (1, 3):
            with self.subTest(maximum=maximum):
                requests = self.run_turn(minimum=12, maximum=maximum)
                self.assertEqual([r["tool_choice"] for r in requests], ["auto"] * maximum + ["none"])

    def test_batch_cannot_exceed_remaining_calls(self):
        requests = self.run_turn(maximum=3, batch_size=5)
        messages = requests[-1]["messages"]
        self.assertEqual(len(requests), 2)
        self.assertEqual(sum(m["role"] == "tool" for m in messages), 3)
        self.assertEqual(sum(len(m.get("tool_calls", [])) for m in messages), 3)

    def test_model_can_finish_before_minimum(self):
        requests = self.run_turn(finish_after=1)
        self.assertEqual([r["tool_choice"] for r in requests], ["auto", "auto"])

    def test_repeat_guard_still_forces_text(self):
        requests = self.run_turn(repeat=True)
        self.assertEqual([r["tool_choice"] for r in requests], ["auto", "auto", "none"])

    def test_forced_text_stays_forced_and_retries_are_bounded(self):
        requests = self.run_turn(maximum=3, ignore_stop=True)
        self.assertEqual([r["tool_choice"] for r in requests], ["auto"] * 3 + ["none"] * 2)


if __name__ == "__main__":
    unittest.main()
