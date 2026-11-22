"""Tests for jobdb.py with a fake database connection (no MySQL, no network).

What must hold: without DB_HOST the store is off; a write that cannot reach the database during training is kept and sent
with the next update (training goes on); the final DONE/FAILED write insists and raises when the database stays away.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

# apps/train is not a package and these tests live outside it (tests/train/), so put it on the import path.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "apps" / "train"))

import jobdb  # noqa: E402 - needs the path set above


class FakeCursor:
    def __init__(self, conn: "FakeConn") -> None:
        self.conn = conn

    def __enter__(self) -> "FakeCursor":
        return self

    def __exit__(self, *exc) -> None:
        return None

    def execute(self, sql: str, params: tuple = ()) -> None:
        self.conn.statements.append((" ".join(sql.split()), params))

    def fetchone(self):
        return self.conn.row


class FakeConn:
    def __init__(self, row: tuple | None = None) -> None:
        self.statements: list[tuple[str, tuple]] = []
        self.row = row
        self.commits = 0
        self.rollbacks = 0
        self.closed = False

    def cursor(self) -> FakeCursor:
        return FakeCursor(self)

    def commit(self) -> None:
        self.commits += 1

    def rollback(self) -> None:
        self.rollbacks += 1

    def close(self) -> None:
        self.closed = True


class FakeClock:
    """Replaces jobdb.time so that retry waits cost no real time."""

    def __init__(self) -> None:
        self.now = 0.0

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


def record(status: str, **extra) -> dict:
    return {"job_id": "j1", "job_type": "train", "model_version": "v1", "status": status,
            "checkpoint_path": None, "result_path": None, "updated_at": "2026-11-20T00:00:00+00:00", **extra}


class StatusStoreTest(unittest.TestCase):
    def make_store(self, host: str = "db", wait_s: float = 120.0) -> jobdb.StatusStore:
        with mock.patch.dict(os.environ, {"DB_HOST": host} if host else {}, clear=False):
            if not host:
                os.environ.pop("DB_HOST", None)
            return jobdb.StatusStore(wait_s=wait_s)

    def setUp(self):
        clock = FakeClock()
        patcher = mock.patch.object(jobdb, "time", clock)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.clock = clock
        stderr = contextlib.redirect_stderr(io.StringIO())
        stderr.__enter__()
        self.addCleanup(stderr.__exit__, None, None, None)

    def test_disabled_without_db_host(self):
        store = self.make_store(host="")
        self.assertFalse(store.enabled)
        store.put(record("RUNNING"))
        store.put(record("DONE"), final=True)
        self.assertEqual(store.pending, [])

    def test_put_writes_one_row_and_one_event(self):
        store = self.make_store()
        conn = FakeConn()
        store._connect = lambda: conn
        store.put(record("RUNNING", epoch=2), new_attempt=True)
        self.assertEqual(len(conn.statements), 2)
        upsert, params = conn.statements[0]
        self.assertTrue(upsert.startswith("INSERT INTO jobs"))
        self.assertEqual(params[:6], ("j1", "train", "v1", "RUNNING", None, None))
        self.assertEqual(json.loads(params[6]), {"epoch": 2})  # everything outside the table columns goes to `detail`
        self.assertEqual(params[7:], (1, 1))  # a new attempt counts once
        self.assertTrue(conn.statements[1][0].startswith("INSERT INTO job_events"))
        self.assertEqual((conn.commits, store.pending), (1, []))

    def test_later_updates_do_not_count_as_new_attempts(self):
        store = self.make_store()
        conn = FakeConn()
        store._connect = lambda: conn
        store.put(record("RUNNING"))
        self.assertEqual(conn.statements[0][1][7:], (0, 0))

    def test_database_down_keeps_records_and_training_goes_on(self):
        store = self.make_store()
        up = FakeConn()
        down = {"flag": True}

        def connect():
            if down["flag"]:
                raise OSError("connection refused")
            return up

        store._connect = connect
        store.put(record("RUNNING", epoch=1))  # must not raise
        store.put(record("RUNNING", epoch=2))
        self.assertEqual(len(store.pending), 2)
        self.assertEqual(up.statements, [])

        down["flag"] = False
        store.put(record("RUNNING", epoch=3))
        self.assertEqual(store.pending, [])
        epochs = [json.loads(p[6])["epoch"] for s, p in up.statements if s.startswith("INSERT INTO jobs")]
        self.assertEqual(epochs, [1, 2, 3], "records are written in the order they were made")

    def test_final_write_raises_when_the_database_stays_away(self):
        store = self.make_store(wait_s=3.0)

        def connect():
            raise OSError("connection refused")

        store._connect = connect
        with self.assertRaises(RuntimeError) as ctx:
            store.put(record("DONE"), final=True)
        self.assertIn("write failed", str(ctx.exception))
        self.assertLessEqual(self.clock.now, 3.0, "gave up at the deadline instead of waiting on")

    def test_failed_write_is_rolled_back_and_retried(self):
        store = self.make_store()

        class FlakyConn(FakeConn):
            def cursor(self):
                if not self.statements:
                    self.statements.append(("boom", ()))
                    raise OSError("lost connection")
                return super().cursor()

        conn = FlakyConn()
        store._connect = lambda: conn
        store.put(record("RUNNING"))
        self.assertEqual(conn.rollbacks, 1)
        self.assertEqual(store.pending, [])  # the retry succeeded
        self.assertTrue(any(s.startswith("INSERT INTO jobs") for s, _ in conn.statements))

    def test_get_merges_columns_and_detail(self):
        store = self.make_store()
        row = ("j1", "train", "v1", "DONE", "/c/ckpt", "/r/model.pt", json.dumps({"epoch": 10}), 2, "2026-11-20T01:02:03.000000Z")
        store._connect = lambda: FakeConn(row)
        rec = store.get("j1")
        self.assertEqual(rec["status"], "DONE")
        self.assertEqual((rec["epoch"], rec["attempts"], rec["updated_at"]), (10, 2, "2026-11-20T01:02:03.000000Z"))

    def test_get_unknown_job_is_none(self):
        store = self.make_store()
        store._connect = lambda: FakeConn(None)
        self.assertIsNone(store.get("nope"))


if __name__ == "__main__":
    unittest.main()
