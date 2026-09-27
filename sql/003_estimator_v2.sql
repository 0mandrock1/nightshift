-- Estimator v2: калібрування пре-фліт оцінки на реальному rate-limit (util5h/
-- util7d ДО/ПІСЛЯ рану, з заголовків Anthropic через usage-cli.js) замість
-- вигаданих P5H_TOKEN_CAP/P7D_TOKEN_CAP, плюс concurrency й категорія задачі
-- (task_kind) для group-by model×kind. Лише адитивні зміни. Ідемпотентний.
--
-- Названо task_kind, НЕ kind: swarm.runs.kind вже зайнятий (CHECK IN
-- run|chain|swarm|lane|fanin — тип запису телеметрії), а не категорія задачі
-- (skills/mf/gpsmap/...), яку хоче estimator v2. Колізія імені з
-- ТЗ вирішена перейменуванням нового поля.
ALTER TABLE swarm.runs ADD COLUMN IF NOT EXISTS util5h_before NUMERIC(6,4);
ALTER TABLE swarm.runs ADD COLUMN IF NOT EXISTS util5h_after  NUMERIC(6,4);
ALTER TABLE swarm.runs ADD COLUMN IF NOT EXISTS util7d_before NUMERIC(6,4);
ALTER TABLE swarm.runs ADD COLUMN IF NOT EXISTS util7d_after  NUMERIC(6,4);
ALTER TABLE swarm.runs ADD COLUMN IF NOT EXISTS concurrent    INTEGER;
ALTER TABLE swarm.runs ADD COLUMN IF NOT EXISTS task_kind     TEXT;

-- Бекфіл task_kind для історичних рядків: префікс run_id до ПЕРШОГО "-"
-- (напр. skills-surface-20260927-191809 -> skills, dt-skill-triggering-... ->
-- dt). Той самий алгоритм, що cc_task_kind() у bin/cc-util-lib.sh для нових
-- ранів (без явного CC_KIND). Груба евристика — інколи перше слово це
-- частина складеного слага (dt-*), не "тема" в людському сенсі, але
-- консистентна з тим, як group-by model×kind рахуватиме нові рани.
UPDATE swarm.runs SET task_kind = split_part(run_id, '-', 1)
  WHERE task_kind IS NULL;

CREATE INDEX IF NOT EXISTS idx_swarm_runs_model_kind_started
  ON swarm.runs (model, task_kind, started_at);

-- --- swarm.estimates: діапазон p25-p75 замість точки, з чесною міткою базису ---
ALTER TABLE swarm.estimates ADD COLUMN IF NOT EXISTS predicted_min_lo    NUMERIC(10,2);
ALTER TABLE swarm.estimates ADD COLUMN IF NOT EXISTS predicted_min_hi    NUMERIC(10,2);
ALTER TABLE swarm.estimates ADD COLUMN IF NOT EXISTS predicted_pct_5h_lo NUMERIC(6,2);
ALTER TABLE swarm.estimates ADD COLUMN IF NOT EXISTS predicted_pct_5h_hi NUMERIC(6,2);
ALTER TABLE swarm.estimates ADD COLUMN IF NOT EXISTS predicted_pct_7d_lo NUMERIC(6,2);
ALTER TABLE swarm.estimates ADD COLUMN IF NOT EXISTS predicted_pct_7d_hi NUMERIC(6,2);
ALTER TABLE swarm.estimates ADD COLUMN IF NOT EXISTS basis               TEXT;
