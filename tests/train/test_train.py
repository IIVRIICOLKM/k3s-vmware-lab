"""Tests for train.py: argument parsing helpers, model export format, and the resume contract.

Run from the repository root:  python -m unittest discover -s tests/train -t tests/train -v
The tests need torch and numpy (the training image has both) but no GPU, no database and no network. They live outside
apps/train/ on purpose: scripts/image-build.sh refuses build folders that contain subfolders.

The export test reads model.k3sm back byte by byte, because the C++ worker (apps/infer/model.cpp) trusts that format.
The resume test stops a run after its first step, as SIGTERM would, and checks that the next run continues from the
checkpoint instead of starting over (proposal slide 11: interrupted work must not be lost).
"""

from __future__ import annotations

import contextlib
import datetime as dt
import io
import json
import os
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import torch
from torch import nn

# apps/train is not a package and these tests live outside it (tests/train/), so put it on the import path.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "apps" / "train"))

import train  # noqa: E402 - needs the path set above


class ParseHiddenTest(unittest.TestCase):
    def test_single_and_multiple_widths(self):
        self.assertEqual(train.parse_hidden("128"), [128])
        self.assertEqual(train.parse_hidden("1024,1024"), [1024, 1024])

    def test_spaces_and_empty_parts_are_ignored(self):
        self.assertEqual(train.parse_hidden(" 64 , 32 "), [64, 32])
        self.assertEqual(train.parse_hidden("64,,32,"), [64, 32])

    def test_limits(self):
        self.assertEqual(train.parse_hidden("1"), [1])
        self.assertEqual(train.parse_hidden("16384"), [16384])
        self.assertEqual(len(train.parse_hidden(",".join(["8"] * 8))), 8)

    def test_rejects_bad_values(self):
        for text in ("", " ", ",", "abc", "12,x", "0", "-5", "16385", "1.5", ",".join(["8"] * 9)):
            with self.subTest(text=text), self.assertRaises(ValueError):
                train.parse_hidden(text)


class SmallHelpersTest(unittest.TestCase):
    def test_now_is_utc_iso_seconds(self):
        stamp = dt.datetime.fromisoformat(train.now())
        self.assertEqual(stamp.utcoffset(), dt.timedelta(0))
        self.assertEqual(stamp.microsecond, 0)

    def test_atomic_write_text_leaves_no_temp_file(self):
        with tempfile.TemporaryDirectory() as d:
            target = Path(d) / "status.json"
            train.atomic_write_text(target, "one\n")
            train.atomic_write_text(target, "two\n")
            self.assertEqual(target.read_text(), "two\n")
            self.assertEqual(sorted(p.name for p in Path(d).iterdir()), ["status.json"])

    def test_build_model_layers(self):
        model = train.build_model(6, [8, 4], 3)
        kinds = [type(m) for m in model]
        self.assertEqual(kinds, [nn.Linear, nn.ReLU, nn.Linear, nn.ReLU, nn.Linear])
        self.assertEqual(model(torch.zeros(5, 6)).shape, (5, 3))
        # no hidden layer is not allowed by parse_hidden, but build_model itself still yields one Linear
        self.assertEqual(len(train.build_model(6, [], 3)), 1)


class ExportRawTest(unittest.TestCase):
    """model.k3sm: b"K3SM", u32 version=1, u32 layers, then per layer u32 out, u32 in, float32 weight[out*in], float32 bias[out]."""

    def test_format_matches_what_the_cpp_worker_reads(self):
        torch.manual_seed(0)
        model = train.build_model(4, [3], 2)
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "model.k3sm"
            train.export_raw(model, path)
            self.assertEqual(sorted(p.name for p in Path(d).iterdir()), ["model.k3sm"], "temp file must be renamed away")
            raw = path.read_bytes()

        self.assertEqual(raw[:4], b"K3SM")
        version, count = struct.unpack_from("<II", raw, 4)
        self.assertEqual((version, count), (1, 2))
        offset = 12
        linears = [m for m in model if isinstance(m, nn.Linear)]
        for layer in linears:
            out, inp = struct.unpack_from("<II", raw, offset)
            self.assertEqual((out, inp), (layer.out_features, layer.in_features))
            offset += 8
            weights = struct.unpack_from(f"<{out * inp}f", raw, offset)
            offset += 4 * out * inp
            bias = struct.unpack_from(f"<{out}f", raw, offset)
            offset += 4 * out
            self.assertEqual(list(weights), layer.weight.detach().flatten().tolist())
            self.assertEqual(list(bias), layer.bias.detach().tolist())
        self.assertEqual(offset, len(raw), "no trailing bytes (model.cpp rejects them)")


class JobStatusTest(unittest.TestCase):
    """Job keeps status.json and the last few checkpoints under <checkpoint-dir>/<job-id>/ (no database here)."""

    def make_job(self, root: str, keep: int = 2) -> train.Job:
        args = mock.Mock(job_id="unit", model_version="v-test", checkpoint_dir=root, keep=keep)
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("DB_HOST", None)
            return train.Job(args)

    def test_status_is_written_and_printed(self):
        with tempfile.TemporaryDirectory() as root:
            job = self.make_job(root)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                record = job.status("RUNNING", epoch=1)
            on_disk = json.loads((Path(root) / "unit" / "status.json").read_text())
            self.assertEqual(on_disk, record)
            self.assertEqual(record["status"], "RUNNING")
            self.assertEqual(record["job_id"], "unit")
            self.assertEqual(record["model_version"], "v-test")
            self.assertIsNone(record["checkpoint_path"])
            self.assertEqual(json.loads(out.getvalue())["epoch"], 1)
            self.assertFalse(job.db.enabled, "without DB_HOST the store must stay off")

    def test_save_keeps_only_the_newest_checkpoints(self):
        with tempfile.TemporaryDirectory() as root:
            job = self.make_job(root, keep=2)
            paths = [job.save({"n": n}, epoch=n, step=10) for n in (1, 2, 3)]
            left = sorted(p.name for p in (Path(root) / "unit").glob("ckpt-*.pt"))
            self.assertEqual(left, [Path(paths[1]).name, Path(paths[2]).name])
            self.assertEqual(job.latest_checkpoint(), paths[2])
            self.assertEqual(torch.load(paths[2], weights_only=False), {"n": 3})
            self.assertEqual(list((Path(root) / "unit").glob("*.tmp")), [])


class RunTest(unittest.TestCase):
    """main() end to end on a tiny model: finish, repeat request, bad request, and interrupt-then-resume."""

    def run_main(self, root: str, *extra: str, job_id: str = "unit", version: str = "v-test") -> tuple[int, list[dict]]:
        argv = ["train.py", "--job-id", job_id, "--model-version", version, "--checkpoint-dir", root,
                "--epochs", "2", "--steps-per-epoch", "3", "--batch-size", "16", "--hidden", "8", *extra]
        out = io.StringIO()
        env = {k: v for k, v in os.environ.items() if k != "DB_HOST"}
        with mock.patch.object(sys, "argv", argv), mock.patch.dict(os.environ, env, clear=True), \
                contextlib.redirect_stdout(out):
            code = train.main()
        lines = [json.loads(line) for line in out.getvalue().splitlines() if line.startswith("{")]
        return code, lines

    def setUp(self):
        train.STOP_REQUESTED = False
        self.addCleanup(setattr, train, "STOP_REQUESTED", False)

    def test_finishes_and_exports_a_model(self):
        with tempfile.TemporaryDirectory() as root:
            code, lines = self.run_main(root)
            self.assertEqual(code, 0)
            self.assertEqual([r["status"] for r in lines], ["RUNNING", "RUNNING", "RUNNING", "DONE"])
            done = lines[-1]
            self.assertEqual(done["dataset"], "synthetic")
            self.assertEqual(done["hidden"], [8])
            self.assertTrue(Path(done["result_path"]).is_file())
            self.assertEqual(Path(done["export_path"]).read_bytes()[:4], b"K3SM")

    def test_same_job_id_is_not_trained_again(self):
        with tempfile.TemporaryDirectory() as root:
            self.run_main(root)
            code, lines = self.run_main(root)
            self.assertEqual(code, 0)
            self.assertEqual(len(lines), 1)
            self.assertIn("already DONE", lines[0]["note"])

    def test_other_model_version_cannot_reuse_an_unfinished_job_id(self):
        with tempfile.TemporaryDirectory() as root:
            train.STOP_REQUESTED = True
            self.assertEqual(self.run_main(root, version="v1")[0], 143)  # leaves an INTERRUPTED record for v1
            train.STOP_REQUESTED = False
            code, lines = self.run_main(root, version="v2")
            self.assertEqual(code, 2)
            self.assertIn("already used", lines[-1]["error"])

    def test_finished_job_id_is_answered_before_the_version_is_compared(self):
        """Current behaviour, pinned on purpose: a DONE record short-circuits, even for another model_version."""
        with tempfile.TemporaryDirectory() as root:
            self.run_main(root, version="v1")
            code, lines = self.run_main(root, version="v2")
            self.assertEqual(code, 0)
            self.assertEqual(lines[-1]["model_version"], "v1")

    def test_bad_hidden_is_recorded_as_failed(self):
        with tempfile.TemporaryDirectory() as root:
            code, lines = self.run_main(root, "--hidden", "0")
            self.assertEqual(code, 2)
            self.assertEqual(lines[-1]["status"], "FAILED")
            self.assertIn("--hidden", lines[-1]["error"])

    def test_missing_dataset_file_is_recorded_as_failed(self):
        with tempfile.TemporaryDirectory() as root:
            code, lines = self.run_main(root, "--dataset", f"npz:{root}/nope.npz")
            self.assertEqual(code, 2)
            self.assertEqual(lines[-1]["status"], "FAILED")

    def test_interrupted_run_resumes_from_its_checkpoint(self):
        with tempfile.TemporaryDirectory() as root:
            train.STOP_REQUESTED = True  # what the SIGTERM handler sets; main() does not reset it
            code, lines = self.run_main(root)
            self.assertEqual(code, 143)
            self.assertEqual(lines[-1]["status"], "INTERRUPTED")
            self.assertEqual((lines[-1]["epoch"], lines[-1]["step"]), (1, 1))
            checkpoint = lines[-1]["checkpoint_path"]
            self.assertTrue(Path(checkpoint).is_file())

            train.STOP_REQUESTED = False
            code, lines = self.run_main(root)
            self.assertEqual(code, 0)
            self.assertEqual(lines[0]["status"], "RUNNING")
            self.assertEqual(lines[0]["resumed_from"], checkpoint)
            self.assertEqual(lines[-1]["status"], "DONE")


if __name__ == "__main__":
    unittest.main()
