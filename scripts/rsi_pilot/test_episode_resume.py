"""Exercise host crash boundaries without using an external model account."""

import tempfile
import unittest
from copy import deepcopy
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import benchmark
import run_episode


class HostRecoveryTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.out = Path(self.scratch.name)
        self.arm = self.out / "sheet" / "C"
        self.arm.mkdir(parents=True)
        self.task = {"task_id": "task", "step": 0, "decisions": []}
        self.state = {
            "arm": "C",
            "paper": "sheet",
            "home": str(self.arm),
            "draft_id": "draft",
            "revision": 2,
            "size": [100, 200],
            "task": deepcopy(self.task),
            "decisions": [],
            "runtime": {},
            "snapshots": {"2": [{"review_id": "review-2"}]},
        }
        benchmark.write(self.out / "runtime.json", {})
        benchmark.write(self.arm / "state.json", self.state)
        self.calls = []
        self.interrupt = None
        parent = self

        class Server:
            def __init__(self, *args, **kwargs):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return None

            def call(self, name, **args):
                parent.calls.append((name, args))
                if name == "read_rsi_task":
                    content = deepcopy(parent.task)
                elif name == "advance_rsi_task":
                    parent.task["step"] += 1
                    parent.task["decisions"].append(
                        args
                        | {
                            "decision_id": "task/" + str(parent.task["step"]),
                            "result_revision": None,
                        }
                    )
                    content = deepcopy(parent.task)
                elif name == "tune_handwriting":
                    parent.task["decisions"][-1]["result_revision"] = 3
                    content = {"revision": 3}
                elif name == "export_handwriting":
                    file = parent.arm / "sample.pdf"
                    file.write_bytes(b"sample")
                    content = {
                        "revision": args["revision"],
                        "pages": 1,
                        "draft_id": "draft",
                        "path": str(file),
                    }
                elif name == "preview_handwriting":
                    return {
                        "structuredContent": {"evidence_id": "preview-2"},
                        "content": [],
                    }
                else:
                    raise AssertionError(name)
                if parent.interrupt == name:
                    parent.interrupt = None
                    raise ConnectionError("lost response")
                return {"structuredContent": content}

        self.server = Server
        self.addCleanup(patch.stopall)
        patch.object(benchmark, "Server", Server).start()

    def decide(self, n, action, **args):
        path = self.arm / f"turn-{n}" / "decision.json"
        benchmark.write(path, {"action": action, "reason": "readable lines", **args})
        return SimpleNamespace(out=self.out, paper="sheet", arm="C", decision=path)

    def test_edit_commit_response_lost_then_inspect_older_version(self):
        def freeze(cfg, arm, state):
            state["snapshots"]["3"] = [{"review_id": "review-3"}]
            benchmark.write(arm / "state.json", state)

        with patch.object(benchmark, "snapshot", freeze):
            args = self.decide(
                1,
                "revise",
                tool="tune_handwriting",
                arguments={"changes": {"font_size": 30}},
            )
            self.interrupt = "tune_handwriting"
            with self.assertRaises(ConnectionError):
                benchmark.advance(args)
            benchmark.advance(args)
        self.assertEqual(sum(t == "tune_handwriting" for t, _ in self.calls), 1)
        self.assertEqual(sum(t == "advance_rsi_task" for t, _ in self.calls), 1)
        state = benchmark.read(self.arm / "state.json")
        self.assertEqual((len(state["decisions"]), state["revision"]), (1, 3))
        benchmark.advance(
            self.decide(
                2,
                "request_evidence",
                revision=2,
                tool="native_crop",
                arguments={"section": 1, "box": [0, 0, 0.5, 0.5]},
            )
        )
        self.assertEqual(self.calls[-1][1]["revision"], 2)
        self.assertEqual(benchmark.read(self.arm / "state.json")["revision"], 3)

    def test_native_commit_before_ack_and_selected_delivery_recovery(self):
        args = self.decide(1, "select", revision=2)
        self.interrupt = "advance_rsi_task"
        with self.assertRaises(ConnectionError):
            benchmark.advance(args)
        self.interrupt = "export_handwriting"
        with self.assertRaises(ConnectionError):
            benchmark.advance(args)
        run_episode.solve(self.out, "sheet", "C", "gpt-6.1-terra")
        self.assertEqual(sum(t == "advance_rsi_task" for t, _ in self.calls), 1)
        self.assertEqual(sum(t == "export_handwriting" for t, _ in self.calls), 2)
        self.assertTrue(
            benchmark.has_delivery(benchmark.read(self.arm / "state.json"), self.arm)
        )
        count = len(self.calls)
        run_episode.solve(self.out, "sheet", "C", "gpt-6.1-terra")
        self.assertEqual(len(self.calls), count)

    def test_native_refusal_can_be_followed_by_a_different_model_decision(self):
        original = self.server.call

        def reject(server, name, **args):
            if name == "advance_rsi_task" and args["action"] == "revise":
                raise benchmark.ToolError("Pinned policy does not allow the edit tool")
            return original(server, name, **args)

        with patch.object(self.server, "call", reject):
            benchmark.advance(
                self.decide(
                    1, "revise", tool="save_section", arguments={"markdown": "text"}
                )
            )
        self.assertFalse((self.arm / "pending-dispatch.json").exists())
        self.assertTrue(
            benchmark.read(self.arm / "state.json")["decisions"][0]["native_rejected"]
        )
        args = self.decide(2, "stop")
        self.interrupt = "advance_rsi_task"
        with self.assertRaises(ConnectionError):
            benchmark.advance(args)
        benchmark.advance(args)
        self.assertEqual(benchmark.read(self.arm / "state.json")["disposition"], "stop")
        self.assertEqual(self.task["step"], 1)

    def test_partial_provider_attempt_is_preserved_and_retried(self):
        base = self.arm / "turn-1"
        base.mkdir()
        (base / "receipt.json").write_text("{", encoding="utf8")
        (base / "stderr.log").write_text("interrupted", encoding="utf8")

        def provider(prompt, images, model, turn):
            self.assertFalse(turn.exists())
            benchmark.write(
                turn / "decision.json", {"action": "stop", "reason": "not ready"}
            )
            benchmark.write(
                turn / "receipt.json",
                {
                    "model": model,
                    "prompt_sha256": benchmark.digest(prompt.read_bytes()),
                    "image_sha256": [],
                },
            )

        with (
            patch.object(run_episode, "context", return_value=("inspect", [])),
            patch.object(run_episode, "run", provider),
        ):
            run_episode.solve(self.out, "sheet", "C", "gpt-6.1-terra")
        self.assertEqual(benchmark.read(self.arm / "state.json")["disposition"], "stop")
        archived = list(self.arm.glob("turn-1.incomplete-*/stderr.log"))
        self.assertEqual(len(archived), 1)
        self.assertEqual(archived[0].read_text(), "interrupted")
