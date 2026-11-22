-- Job status tables (proposal slide 11). Applied by scripts/mysql-deploy.sh on every run; every statement is
-- idempotent (IF NOT EXISTS), so re-running it never touches existing rows.
--
-- jobs        one row per job id: the current state. The PRIMARY KEY on job_id is what stops a second run of the
--             same job id (scripts/job.sh inserts PENDING; a duplicate insert fails and the existing row is returned).
-- job_events  every status change, in order, so an interruption and its resume stay visible after the fact.

CREATE TABLE IF NOT EXISTS jobs (
  job_id          VARCHAR(64)  NOT NULL,
  job_type        ENUM('train', 'infer') NOT NULL,
  model_version   VARCHAR(128) NOT NULL,
  status          ENUM('PENDING', 'RUNNING', 'INTERRUPTED', 'DONE', 'FAILED') NOT NULL,
  checkpoint_path VARCHAR(512) NULL,
  result_path     VARCHAR(512) NULL,
  detail          JSON         NULL COMMENT 'epoch, loss, accuracy, resumed_from, dataset, error, ...',
  attempts        INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'pods that started this job (Job retries add one each)',
  created_at      TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at      TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (job_id),
  KEY jobs_status (status)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE IF NOT EXISTS job_events (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  job_id          VARCHAR(64)  NOT NULL,
  status          ENUM('PENDING', 'RUNNING', 'INTERRUPTED', 'DONE', 'FAILED') NOT NULL,
  checkpoint_path VARCHAR(512) NULL,
  detail          JSON         NULL,
  at              TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  KEY job_events_job (job_id, id),
  CONSTRAINT job_events_job_fk FOREIGN KEY (job_id) REFERENCES jobs (job_id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
