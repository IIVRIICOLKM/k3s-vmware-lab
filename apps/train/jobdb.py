"""Job status in MySQL (proposal slide 11): the one place job state is recorded and read back.

Table `jobs` (infra/k8s/mysql-schema.sql) holds one row per job id with the proposal's columns; `job_events` keeps
every status change, so an interrupted-and-resumed run shows up as RUNNING -> INTERRUPTED -> RUNNING -> DONE.

Connection settings come from the environment (the Helm chart fills them from the k3slab-db Secret):
DB_HOST, DB_PORT (3306), DB_NAME, DB_USER, DB_PASSWORD. Without DB_HOST the store is disabled and train.py falls back
to <checkpoint-dir>/<job-id>/status.json only (local runs and the old tests).

A database restart must not kill a training run that is hours in, so writes during training are retried and, if the
database stays away, kept in memory and sent with the next update (each row write is an upsert, so the last one
wins). Only the first read (is this job already DONE?) and the final DONE/FAILED write insist: they wait up to
`wait_s` seconds and then raise, which fails the pod so the Job retries it.
"""

from __future__ import annotations

import json
import os
import sys
import time

# Columns of `jobs` besides the JSON `detail`; everything else in a status record goes into `detail`.
COLUMNS = ("job_id", "job_type", "model_version", "status", "checkpoint_path", "result_path")


class StatusStore:
    def __init__(self, wait_s: float = 120.0) -> None:
        self.host = os.environ.get("DB_HOST", "")
        self.enabled = bool(self.host)
        self.wait_s = wait_s
        self.conn = None
        self.pending: list[dict] = []  # status records not yet written (database unreachable)

    # -- connection ------------------------------------------------------------------------------------------------
    def _connect(self):
        import pymysql  # only needed when the store is enabled

        if self.conn is None:
            self.conn = pymysql.connect(
                host=self.host,
                port=int(os.environ.get("DB_PORT", "3306")),
                user=os.environ["DB_USER"],
                password=os.environ["DB_PASSWORD"],
                database=os.environ["DB_NAME"],
                connect_timeout=5,
                read_timeout=10,
                write_timeout=10,
                autocommit=False,
                charset="utf8mb4",
            )
        return self.conn

    def _drop(self) -> None:
        try:
            if self.conn is not None:
                self.conn.close()
        except Exception:  # noqa: BLE001 - the connection is already broken
            pass
        self.conn = None

    def _retry(self, what: str, fn, wait_s: float):
        """Runs fn(conn) until it succeeds or wait_s passes (then re-raises the last error)."""
        deadline = time.monotonic() + wait_s
        delay = 1.0
        while True:
            try:
                return fn(self._connect())
            except Exception as exc:  # noqa: BLE001 - any driver/network error means "try again"
                self._drop()
                if time.monotonic() + delay > deadline:
                    raise RuntimeError(f"database {what} failed for {wait_s:.0f}s: {exc!r}") from exc
                print(json.dumps({"db": "retry", "what": what, "error": repr(exc)}), file=sys.stderr, flush=True)
                time.sleep(delay)
                delay = min(delay * 2, 10.0)

    # -- reads -----------------------------------------------------------------------------------------------------
    def get(self, job_id: str) -> dict | None:
        """The job's row (columns + detail merged), or None. Waits for the database up to wait_s."""

        def q(conn):
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT job_id, job_type, model_version, status, checkpoint_path, result_path, detail, attempts,"
                    " DATE_FORMAT(updated_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ') FROM jobs WHERE job_id = %s",
                    (job_id,),
                )
                row = cur.fetchone()
            conn.commit()
            return row

        row = self._retry("read", q, self.wait_s)
        if row is None:
            return None
        rec = dict(zip(COLUMNS, row[:6]))
        rec.update(json.loads(row[6]) if row[6] else {})
        rec["attempts"], rec["updated_at"] = row[7], row[8]
        return rec

    # -- writes ----------------------------------------------------------------------------------------------------
    def _write(self, conn, rec: dict, new_attempt: bool) -> None:
        detail = {k: v for k, v in rec.items() if k not in COLUMNS and k != "updated_at"}
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO jobs (job_id, job_type, model_version, status, checkpoint_path, result_path, detail, attempts)"
                " VALUES (%s, %s, %s, %s, %s, %s, %s, %s)"
                " ON DUPLICATE KEY UPDATE model_version = VALUES(model_version), status = VALUES(status),"
                " checkpoint_path = VALUES(checkpoint_path), result_path = VALUES(result_path), detail = VALUES(detail),"
                " attempts = attempts + %s",
                (*(rec.get(c) for c in COLUMNS), json.dumps(detail), 1 if new_attempt else 0, 1 if new_attempt else 0),
            )
            cur.execute(
                "INSERT INTO job_events (job_id, status, checkpoint_path, detail) VALUES (%s, %s, %s, %s)",
                (rec["job_id"], rec["status"], rec.get("checkpoint_path"), json.dumps(detail)),
            )
        conn.commit()

    def put(self, rec: dict, *, final: bool = False, new_attempt: bool = False) -> None:
        """Records a status change. final=True (DONE/FAILED) waits up to wait_s and raises if it cannot be written."""
        if not self.enabled:
            return
        self.pending.append({"rec": rec, "new_attempt": new_attempt})

        def flush(conn):
            while self.pending:
                item = self.pending[0]
                try:
                    self._write(conn, item["rec"], item["new_attempt"])
                except Exception:
                    conn.rollback()
                    raise
                self.pending.pop(0)

        try:
            self._retry("write", flush, self.wait_s if final else 5.0)
        except RuntimeError as exc:
            if final:
                raise
            print(json.dumps({"db": "deferred", "pending": len(self.pending), "error": str(exc)}), file=sys.stderr,
                  flush=True)
