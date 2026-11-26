#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENQUEUE = ROOT / "bin/cc-enqueue.sh"
STATE = ROOT / "bin/cc-queue-state.py"


class QueueContractTests(unittest.TestCase):
    def test_metadata_is_atomic_and_captures_live_worker_identity(self):
        with tempfile.TemporaryDirectory() as td:
            run = Path(td) / "fixture-20261126-204236"
            run.mkdir()
            subprocess.run(["python3", str(STATE), str(run), "QUEUED"], check=True)
            meta = json.loads((run / "queue.meta").read_text())
            self.assertEqual(meta["run_id"], run.name)
            self.assertEqual(meta["status"], "QUEUED")
            self.assertTrue(meta["queued_at"].endswith("Z"))
            self.assertEqual(int(meta["worker_pid"]), os.getpid())
            self.assertTrue(meta["worker_start_ticks"].isdigit())
            self.assertEqual(meta["worker_argv"][0], "python3")
            self.assertEqual((run / "queue.status").read_text(), "QUEUED\n")

    def test_worker_runs_once_only_after_successful_prerequisite(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            run = base / "job-20261126-204236"
            prereq = base / "prior-20261126-203000"
            run.mkdir(); prereq.mkdir()
            (run / "task.md").write_text("safe fixture\n")
            (prereq / "exit_code").write_text("0\n")
            (prereq / "out.log").write_text("RESULT: ok\n")
            fake = base / "cc-run.sh"
            counter = base / "invocations"
            fake.write_text("#!/bin/sh\nprintf '%s\\n' called >>\"$QUEUE_TEST_COUNTER\"\nexit 0\n")
            fake.chmod(0o755)
            env = dict(os.environ, CC_RUN_SH=str(fake), QUEUE_TEST_COUNTER=str(counter))
            result = subprocess.run(["sh", str(ENQUEUE), str(run), str(prereq), "10", "none", "sonnet", "codex"], env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(counter.read_text().splitlines(), ["called"])
            self.assertEqual((run / "queue.status").read_text(), "COMPLETE\n")
            meta = json.loads((run / "queue.meta").read_text())
            self.assertTrue(meta["started_at"].endswith("Z"))
            self.assertTrue(meta["ended_at"].endswith("Z"))
            again = subprocess.run(["sh", str(ENQUEUE), str(run), str(prereq)], text=True, capture_output=True, timeout=5)
            self.assertNotEqual(again.returncode, 0)
            self.assertEqual(counter.read_text().splitlines(), ["called"])

    def test_failure_prerequisite_blocks_without_invoking_runner(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            run = base / "job-20261126-204236"
            prereq = base / "prior-20261126-203000"
            run.mkdir(); prereq.mkdir()
            (run / "task.md").write_text("safe fixture\n")
            (prereq / "exit_code").write_text("0\n")
            (prereq / "out.log").write_text("RESULT: fail\n")
            result = subprocess.run(["sh", str(ENQUEUE), str(run), str(prereq), "10"], text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 10)
            self.assertEqual((run / "queue.status").read_text(), "BLOCKED\n")
            self.assertFalse((run / "out.log").exists())

    def test_wait_timeout_is_terminal_and_does_not_invoke_runner(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            run = base / "job-20261126-204236"
            prereq = base / "prior-20261126-203000"
            run.mkdir(); prereq.mkdir()
            (run / "task.md").write_text("safe fixture\n")
            fake = base / "cc-run.sh"
            fake.write_text("#!/bin/sh\necho called >>\"$QUEUE_TEST_COUNTER\"\n")
            fake.chmod(0o755)
            env = dict(os.environ, CC_RUN_SH=str(fake), CC_QUEUE_POLL_S="1", QUEUE_TEST_COUNTER=str(base / "invocations"))
            result = subprocess.run(["sh", str(ENQUEUE), str(run), str(prereq), "1"], env=env, text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 124)
            self.assertEqual((run / "queue.status").read_text(), "TIMEOUT\n")
            self.assertFalse((base / "invocations").exists())


if __name__ == "__main__":
    unittest.main()
