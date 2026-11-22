"""Training data sources for train.py: the seam where a real dataset replaces the synthetic one.

The lab's research topic is not fixed yet, so train.py never touches data directly. It asks a Dataset for batches,
drawing all randomness from the generator it passes in. That generator's state is saved in every checkpoint, so a
resumed run draws exactly the batches the uninterrupted run would have drawn, whatever the dataset is.

A new dataset only has to provide `input_dim`, `num_classes` and `batch(gen, size, device)`, and a name in open().

    --dataset synthetic              seeded Gaussian blobs (default; no files, no network)
    --dataset npz:/data/<file>.npz   arrays x (float32, [N, D]) and y (int64, [N]); optional num_classes
                                     (/data is gpu-host /var/lib/k3slab/datasets, filled by `scripts/job.sh upload`)
"""

from __future__ import annotations

from pathlib import Path
from typing import Protocol

import torch


class Dataset(Protocol):
    name: str
    input_dim: int
    num_classes: int

    def batch(self, gen: torch.Generator, size: int, device: torch.device) -> tuple[torch.Tensor, torch.Tensor]:
        """Returns (x float32 [size, input_dim], y int64 [size]) on `device`, using only `gen` for randomness."""
        ...


class SyntheticBlobs:
    """Separable 10-class data: class k is a Gaussian blob around a fixed random center (same for every run).

    Kept identical to the generator train.py used before the Dataset interface, so old checkpoints resume unchanged.
    """

    name = "synthetic"
    input_dim = 64
    num_classes = 10

    def __init__(self) -> None:
        self.centers = torch.randn(self.num_classes, self.input_dim, generator=torch.Generator().manual_seed(1234))

    def batch(self, gen: torch.Generator, size: int, device: torch.device) -> tuple[torch.Tensor, torch.Tensor]:
        y = torch.randint(0, self.num_classes, (size,), generator=gen)
        x = self.centers[y] + 0.8 * torch.randn(size, self.input_dim, generator=gen)
        return x.to(device), y.to(device)


class NpzDataset:
    """A labelled table from an .npz file, sampled with replacement (uniform random rows per batch)."""

    def __init__(self, path: str) -> None:
        import numpy as np  # shipped with the PyTorch image

        p = Path(path)
        if not p.is_file():
            raise FileNotFoundError(f"dataset file {p} not found (upload it with scripts/job.sh upload)")
        with np.load(p, allow_pickle=False) as data:
            if "x" not in data or "y" not in data:
                raise ValueError(f"{p} must contain arrays 'x' and 'y'")
            x, y = data["x"], data["y"]
            classes = int(data["num_classes"]) if "num_classes" in data else int(y.max()) + 1
        if x.ndim != 2 or y.ndim != 1 or len(x) != len(y) or len(x) == 0:
            raise ValueError(f"{p}: x must be [N, D] and y [N] with the same N > 0 (got {x.shape} and {y.shape})")
        if y.min() < 0 or y.max() >= classes:
            raise ValueError(f"{p}: labels must be in 0..{classes - 1}")
        self.name = f"npz:{p}"
        self.x = torch.from_numpy(x.astype("float32"))
        self.y = torch.from_numpy(y.astype("int64"))
        self.input_dim = self.x.shape[1]
        self.num_classes = classes

    def batch(self, gen: torch.Generator, size: int, device: torch.device) -> tuple[torch.Tensor, torch.Tensor]:
        idx = torch.randint(0, len(self.y), (size,), generator=gen)
        return self.x[idx].to(device), self.y[idx].to(device)


def open_dataset(spec: str) -> Dataset:
    """Turns a --dataset value into a Dataset."""
    if spec == "synthetic":
        return SyntheticBlobs()
    if spec.startswith("npz:"):
        return NpzDataset(spec[len("npz:"):])
    raise ValueError(f"unknown dataset {spec!r} (synthetic or npz:<path>)")
