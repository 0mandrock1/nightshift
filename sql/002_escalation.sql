-- Лічильник ескалацій, що переживає рестарт (замінює лише in-memory рахунок).
-- run_id у swarm.runs — TEXT (не UUID), тож escalation_of теж TEXT, не UUID —
-- відхилення від початкового опису задачі заради консистентності з наявною
-- схемою (001_swarm_schema.sql). Ідемпотентний: безпечно прогнати повторно.
ALTER TABLE swarm.runs ADD COLUMN IF NOT EXISTS escalation_of TEXT REFERENCES swarm.runs(run_id);
ALTER TABLE swarm.runs ADD COLUMN IF NOT EXISTS attempt INT NOT NULL DEFAULT 1;

CREATE INDEX IF NOT EXISTS idx_swarm_runs_escalation_of ON swarm.runs (escalation_of);
