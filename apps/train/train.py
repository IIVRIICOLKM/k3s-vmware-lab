"""Training job for the k3s-vmware-lab platform (proposal slides 5 and 11).

Model-agnostic on purpose: the lab's research topic is not fixed yet, so this trains a small classifier on a
seeded synthetic dataset and focuses on the platform contract every future model must follow:

* one job id per request; a finished job id is not trained again (the proposal's duplicate-request rule),
* a checkpoint after every epoch (atomic write) and on SIGTERM, so a deleted or preempted pod resumes where it stopped,
* status records whose fields match the planned MySQL `jobs` table (job_id, job_type, model_version, status,
  checkpoint_path, result_path, updated_at), written to <checkpoint-dir>/<job-id>/status.json and stdout.

Usage: python train.py --job-id J --model-version V [--epochs N] [--checkpoint-dir DIR] ...
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import signal
import struct
import sys
import time
from pathlib import Path

import torch
from torch import nn

STOP_REQUESTED = False


def on_sigterm(signum, frame):  # noqa: ARG001 - signal handler signature
    """Kubernetes sends SIGTERM when it deletes the pod; finish the current step and checkpoint."""
    global STOP_REQUESTED
    STOP_REQUESTED = True


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--job-id", required=True)
    p.add_argument("--model-version", required=True)
    p.add_argument("--epochs", type=int, default=10)
    p.add_argument("--steps-per-epoch", type=int, default=200)
    p.add_argument("--batch-size", type=int, default=256)
    p.add_argument("--lr", type=float, default=1e-3)
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--checkpoint-dir", default=os.environ.get("CHECKPOINT_DIR", "/checkpoints"))
    p.add_argument("--keep", type=int, default=3, help="number of epoch checkpoints to keep")
    p.add_argument("--epoch-sleep", type=float, default=0.0, help="pause after each epoch (to make interruption tests easy)")
    return p.parse_args()


class Job:
    """Paths and status bookkeeping for one job id."""

    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.dir = Path(args.checkpoint_dir) / args.job_id
        self.dir.mkdir(parents=True, exist_ok=True)
        self.status_file = self.dir / "status.json"
        self.latest_file = self.dir / "latest.json"

    def status(self, status: str, **extra) -> dict:
        record = {
            "job_id": self.args.job_id,
            "job_type": "train",
            "model_version": self.args.model_version,
            "status": status,
            "checkpoint_path": extra.pop("checkpoint_path", self.latest_checkpoint()),
            "result_path": extra.pop("result_path", None),
            "updated_at": now(),
            **extra,
        }
        atomic_write_text(self.status_file, json.dumps(record, indent=2) + "\n")
        print(json.dumps(record), flush=True)
        return record

    def previous_status(self) -> dict | None:
        if self.status_file.exists():
            return json.loads(self.status_file.read_text())
        return None

    def latest_checkpoint(self) -> str | None:
        if self.latest_file.exists():
            return json.loads(self.latest_file.read_text())["path"]
        return None

    def save(self, state: dict, epoch: int, step: int) -> str:
        path = self.dir / f"ckpt-e{epoch:04d}-s{step:05d}.pt"
        tmp = path.with_suffix(".pt.tmp")
        torch.save(state, tmp)
        os.replace(tmp, path)  # atomic: a crash never leaves a half-written checkpoint under the final name
        atomic_write_text(self.latest_file, json.dumps({"path": str(path), "epoch": epoch, "step": step}) + "\n")
        for old in sorted(self.dir.glob("ckpt-*.pt"))[: -self.args.keep]:
            old.unlink()
        return str(path)


def atomic_write_text(path: Path, text: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def export_raw(model: nn.Sequential, path: Path) -> None:
    """Write the weights for the C++ inference worker (apps/infer), which has no PyTorch dependency.

    Format (little-endian): b"K3SM", u32 version=1, u32 linear-layer count, then per Linear layer
    u32 out, u32 in, float32 weight[out*in] (row-major), float32 bias[out]. ReLU follows every Linear except the last.
    """
    linears = [m for m in model if isinstance(m, nn.Linear)]
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "wb") as f:
        f.write(b"K3SM" + struct.pack("<II", 1, len(linears)))
        for layer in linears:
            w = layer.weight.detach().cpu().float().contiguous().flatten().tolist()
            b = layer.bias.detach().cpu().float().contiguous().tolist()
            f.write(struct.pack("<II", layer.out_features, layer.in_features))
            f.write(struct.pack(f"<{len(w)}f", *w))
            f.write(struct.pack(f"<{len(b)}f", *b))
    os.replace(tmp, path)


def synthetic_batch(gen: torch.Generator, batch: int, device: torch.device) -> tuple[torch.Tensor, torch.Tensor]:
    """Separable 10-class data: class k is a Gaussian blob around a fixed random center (same for every run)."""
    centers = torch.randn(10, 64, generator=torch.Generator().manual_seed(1234))
    y = torch.randint(0, 10, (batch,), generator=gen)
    x = centers[y] + 0.8 * torch.randn(batch, 64, generator=gen)
    return x.to(device), y.to(device)


def main() -> int:
    args = parse_args()
    signal.signal(signal.SIGTERM, on_sigterm)
    job = Job(args)

    prev = job.previous_status()
    if prev and prev.get("status") == "DONE" and prev.get("epochs") == args.epochs:
        print(json.dumps({**prev, "note": "already DONE; not training again"}), flush=True)
        return 0

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    torch.manual_seed(args.seed)
    model = nn.Sequential(nn.Linear(64, 128), nn.ReLU(), nn.Linear(128, 10)).to(device)
    optim = torch.optim.Adam(model.parameters(), lr=args.lr)
    gen = torch.Generator().manual_seed(args.seed)
    start_epoch, start_step = 1, 0

    ckpt_path = job.latest_checkpoint()
    if ckpt_path and Path(ckpt_path).exists():
        # Load on the CPU: the data generator's RNG state must stay a CPU ByteTensor (map_location=cuda moved it to the
        # GPU and set_state() failed on every retry). load_state_dict() moves model/optimizer tensors to `device`.
        state = torch.load(ckpt_path, map_location="cpu", weights_only=False)
        model.load_state_dict(state["model"])
        optim.load_state_dict(state["optim"])
        gen.set_state(state["gen"])
        start_epoch, start_step = state["epoch"], state["step"]
        if start_step >= args.steps_per_epoch:  # the checkpoint closed an epoch
            start_epoch, start_step = start_epoch + 1, 0
        job.status("RUNNING", checkpoint_path=ckpt_path, resumed_from=ckpt_path, epoch=start_epoch, epochs=args.epochs,
                   device=str(device))
    else:
        job.status("RUNNING", epoch=start_epoch, epochs=args.epochs, device=str(device))

    loss_fn = nn.CrossEntropyLoss()
    epoch = start_epoch
    try:
        for epoch in range(start_epoch, args.epochs + 1):
            first = start_step if epoch == start_epoch else 0
            correct = total = 0
            loss = torch.tensor(0.0)
            for step in range(first, args.steps_per_epoch):
                x, y = synthetic_batch(gen, args.batch_size, device)
                optim.zero_grad(set_to_none=True)
                logits = model(x)
                loss = loss_fn(logits, y)
                loss.backward()
                optim.step()
                correct += (logits.argmax(1) == y).sum().item()
                total += y.numel()
                if STOP_REQUESTED:
                    path = job.save({"model": model.state_dict(), "optim": optim.state_dict(), "gen": gen.get_state(),
                                     "epoch": epoch, "step": step + 1}, epoch, step + 1)
                    job.status("INTERRUPTED", checkpoint_path=path, epoch=epoch, step=step + 1, epochs=args.epochs)
                    return 143  # 128 + SIGTERM: Kubernetes treats it as a failed attempt and the Job retries
            path = job.save({"model": model.state_dict(), "optim": optim.state_dict(), "gen": gen.get_state(),
                             "epoch": epoch, "step": args.steps_per_epoch}, epoch, args.steps_per_epoch)
            job.status("RUNNING", checkpoint_path=path, epoch=epoch, epochs=args.epochs, loss=round(loss.item(), 4),
                       accuracy=round(correct / max(total, 1), 4))
            if args.epoch_sleep:
                time.sleep(args.epoch_sleep)
    except Exception as exc:  # record the failure for the status table, then fail the pod
        job.status("FAILED", epoch=epoch, epochs=args.epochs, error=repr(exc))
        raise

    result = job.dir / "model.pt"
    torch.save(model.state_dict(), result)
    export = job.dir / "model.k3sm"
    export_raw(model, export)
    job.status("DONE", epoch=args.epochs, epochs=args.epochs, result_path=str(result), export_path=str(export))
    return 0


if __name__ == "__main__":
    sys.exit(main())
