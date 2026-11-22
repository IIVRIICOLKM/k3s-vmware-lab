"""Tests for datasets.py: the synthetic source's determinism (what makes resume exact) and the .npz loader's checks."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
import torch

# apps/train is not a package and these tests live outside it (tests/train/), so put it on the import path.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "apps" / "train"))

import datasets  # noqa: E402 - needs the path set above


def write_npz(directory: str, name: str = "t.npz", **arrays) -> str:
    path = Path(directory) / name
    np.savez(path, **arrays)
    return str(path)


class OpenDatasetTest(unittest.TestCase):
    def test_synthetic(self):
        data = datasets.open_dataset("synthetic")
        self.assertEqual((data.name, data.input_dim, data.num_classes), ("synthetic", 64, 10))

    def test_unknown_spec(self):
        for spec in ("", "csv:/x", "synthetic2", "npz"):
            with self.subTest(spec=spec), self.assertRaises(ValueError):
                datasets.open_dataset(spec)

    def test_missing_file(self):
        with self.assertRaises(FileNotFoundError):
            datasets.open_dataset("npz:/definitely/not/here.npz")


class SyntheticBlobsTest(unittest.TestCase):
    def setUp(self):
        self.data = datasets.SyntheticBlobs()
        self.cpu = torch.device("cpu")

    def test_batch_shape_dtype_and_label_range(self):
        x, y = self.data.batch(torch.Generator().manual_seed(0), 32, self.cpu)
        self.assertEqual((x.shape, x.dtype), ((32, 64), torch.float32))
        self.assertEqual((y.shape, y.dtype), ((32,), torch.int64))
        self.assertTrue(0 <= int(y.min()) and int(y.max()) < 10)

    def test_same_seed_same_batch_other_seed_other_batch(self):
        a = self.data.batch(torch.Generator().manual_seed(7), 16, self.cpu)
        b = self.data.batch(torch.Generator().manual_seed(7), 16, self.cpu)
        c = self.data.batch(torch.Generator().manual_seed(8), 16, self.cpu)
        self.assertTrue(torch.equal(a[0], b[0]) and torch.equal(a[1], b[1]))
        self.assertFalse(torch.equal(a[0], c[0]))

    def test_class_centers_do_not_depend_on_the_run(self):
        self.assertTrue(torch.equal(self.data.centers, datasets.SyntheticBlobs().centers))

    def test_restored_generator_state_repeats_the_next_batch(self):
        """The resume contract: a checkpointed generator state gives exactly the batches the uninterrupted run draws."""
        gen = torch.Generator().manual_seed(3)
        self.data.batch(gen, 8, self.cpu)
        saved = gen.get_state()
        expected = self.data.batch(gen, 8, self.cpu)
        resumed = torch.Generator()
        resumed.set_state(saved)
        again = self.data.batch(resumed, 8, self.cpu)
        self.assertTrue(torch.equal(expected[0], again[0]) and torch.equal(expected[1], again[1]))


class NpzDatasetTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        rng = np.random.default_rng(0)
        self.x = rng.normal(size=(20, 4)).astype("float32")
        self.y = (np.arange(20) % 3).astype("int64")

    def test_valid_file(self):
        data = datasets.open_dataset("npz:" + write_npz(self.dir.name, x=self.x, y=self.y))
        self.assertEqual((data.input_dim, data.num_classes), (4, 3))
        self.assertTrue(data.name.startswith("npz:"))
        gen = torch.Generator().manual_seed(1)
        x, y = data.batch(gen, 6, torch.device("cpu"))
        self.assertEqual((x.shape, x.dtype, y.shape, y.dtype), ((6, 4), torch.float32, (6,), torch.int64))
        # every sampled row really is a row of the file
        rows = {tuple(r) for r in self.x.tolist()}
        self.assertTrue(all(tuple(r) in rows for r in x.tolist()))

    def test_num_classes_in_file_wins_and_casts_types(self):
        path = write_npz(self.dir.name, x=self.x.astype("float64"), y=self.y.astype("int32"), num_classes=np.array(7))
        data = datasets.open_dataset("npz:" + path)
        self.assertEqual(data.num_classes, 7)
        self.assertEqual((data.x.dtype, data.y.dtype), (torch.float32, torch.int64))

    def test_same_generator_state_same_rows(self):
        data = datasets.open_dataset("npz:" + write_npz(self.dir.name, x=self.x, y=self.y))
        a = data.batch(torch.Generator().manual_seed(5), 10, torch.device("cpu"))
        b = data.batch(torch.Generator().manual_seed(5), 10, torch.device("cpu"))
        self.assertTrue(torch.equal(a[0], b[0]) and torch.equal(a[1], b[1]))

    def test_rejects_malformed_files(self):
        cases = {
            "no_y": dict(x=self.x),
            "no_x": dict(y=self.y),
            "x_not_2d": dict(x=self.x.ravel(), y=self.y),
            "length_mismatch": dict(x=self.x, y=self.y[:5]),
            "label_too_big": dict(x=self.x, y=self.y, num_classes=np.array(2)),
            "negative_label": dict(x=self.x, y=self.y - 1),
            "empty": dict(x=np.zeros((0, 4), "float32"), y=np.zeros(0, "int64")),
        }
        for label, arrays in cases.items():
            with self.subTest(case=label), self.assertRaises(ValueError):
                datasets.open_dataset("npz:" + write_npz(self.dir.name, f"{label}.npz", **arrays))

    def test_pickled_objects_are_refused(self):
        path = write_npz(self.dir.name, x=self.x, y=np.array([{"a": 1}] * 20, dtype=object))
        with self.assertRaises(ValueError):
            datasets.open_dataset("npz:" + path)


if __name__ == "__main__":
    unittest.main()
