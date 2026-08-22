-- swarm телеметрія — схема `swarm` у БД mandrock_kb (контейнер mandrock-kb-postgres).
-- Ідемпотентний: безпечно прогнати повторно.
CREATE SCHEMA IF NOT EXISTS swarm;

CREATE TABLE IF NOT EXISTS swarm.runs (
  run_id         TEXT PRIMARY KEY,
  kind           TEXT NOT NULL CHECK (kind IN ('run','chain','swarm','lane','fanin')),
  parent_run_id  TEXT REFERENCES swarm.runs(run_id),
  node           TEXT,
  repo           TEXT,
  branch         TEXT,
  base_sha       TEXT,
  model          TEXT,
  style          TEXT,
  started_at     TIMESTAMPTZ,
  finished_at    TIMESTAMPTZ,
  duration_s     INTEGER,
  exit_code      INTEGER,
  status         TEXT CHECK (status IN ('ok','fail','limit','timeout')),
  tokens_in      BIGINT DEFAULT 0,
  tokens_out     BIGINT DEFAULT 0,
  cache_read     BIGINT DEFAULT 0,
  cache_write    BIGINT DEFAULT 0,
  cost_usd       NUMERIC(10,4),
  notes          TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- run_id у verifications/estimates/routes НЕ FK навмисно: estimates й routes
-- пишуться ДО того, як існує рядок swarm.runs (пре-фліт оцінка/рішення
-- роутера випереджають сам ран) — жорсткий FK зробив би цей порядок
-- неможливим. Зв'язок — по значенню, не по constraint.
CREATE TABLE IF NOT EXISTS swarm.verifications (
  id           BIGSERIAL PRIMARY KEY,
  run_id       TEXT NOT NULL,
  verify_cmd   TEXT,
  exit_code    INTEGER,
  duration_s   INTEGER,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS swarm.estimates (
  id                   BIGSERIAL PRIMARY KEY,
  run_id               TEXT NOT NULL,
  predicted_tokens     BIGINT,
  predicted_minutes    NUMERIC(10,2),
  predicted_pct_5h     NUMERIC(6,2),
  predicted_pct_week   NUMERIC(6,2),
  actual_tokens        BIGINT,
  actual_minutes       NUMERIC(10,2),
  error_pct            NUMERIC(10,2) GENERATED ALWAYS AS (
    CASE WHEN actual_tokens IS NOT NULL AND actual_tokens != 0 AND predicted_tokens IS NOT NULL
      THEN ROUND((100.0 * (actual_tokens - predicted_tokens) / actual_tokens)::numeric, 2)
      ELSE NULL
    END
  ) STORED,
  estimator_version    TEXT,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS swarm.routes (
  id                BIGSERIAL PRIMARY KEY,
  run_id            TEXT,
  n_units           INTEGER,
  has_verify        BOOLEAN,
  has_deps          BOOLEAN,
  shared_target     BOOLEAN,
  needs_judgement   BOOLEAN,
  unit_size         TEXT,
  route             TEXT CHECK (route IN ('swarm','chain','hybrid')),
  tier              TEXT,
  rule_fired        TEXT,
  human_override    BOOLEAN NOT NULL DEFAULT false,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_swarm_runs_kind_started  ON swarm.runs (kind, started_at);
CREATE INDEX IF NOT EXISTS idx_swarm_runs_model_started ON swarm.runs (model, started_at);
