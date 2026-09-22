# HANDOFF nightshift-skills 20260923

## Стан
- Pickup E2 виконано: канон перевірено живим (14 симлінків /root/ops/cc-runs → nightshift/bin, compat /root/projects/cc-swarm → nightshift), verify-ран e1b-cutover-verify-20260922-231836 exit 0, обидві нотифікації Марк підтвердив.
- Виявлено: скіл cc-remote-agent 1.2.0 (23.09) мав у scripts/ фічі, яких не було в каноні (Sync-only автододавання, мітка BG-WAIT, CC_RUN_TIMEOUT_S у cc-run.sh). Перенесено ран e2-port-120-20260922-233611 (sonnet, worktree /root/projects/nightshift-wt/e2-port-120, гілка cc/e2-port-120) → коміт 74fece4. Перевірено руками: tests/run-all.sh зелені, E2E під systemd-run ok.
- Також у 74fece4: ops/waiter-e1b.sh note() тепер пише rc/stderr у $BK/notify-debug.log (раніше ковтав).
- cc-cost / cc-opus-gate / cc-seq: скіл-копії не мають функціональних фіч понад канон — лише старі LOG-дефолти ($(dirname "$0")/telemetry.log). Канон правий.
- main ff → 74fece4 (прод), smoke e2-post-merge-noop-20260922-234615 під systemd: exit 0, Sync-only дописано, RESULT: ok, Telegram 200.
- Приватний remote: github.com/0mandrock1/nightshift (PRIVATE), origin/main = 74fece4. Push по HTTPS через gh auth setup-git (SSH-ключа на VPS для GitHub нема).

## Рішення Марка (23.09)
- (1) Прибрати scripts/ зі скіла cc-remote-agent; скіл посилається на репо nightshift. Правило: драйвери правляться ТІЛЬКИ в репо, ніколи в скілі.
- (2) Desktop WSL отримує канон через приватний remote + git pull.
- (3) compat-симлінк /root/projects/cc-swarm прибрати одразу після того, як Марк встановить виправлені .skill.

## Гілка / ран
- nightshift: main = 74fece4, чисте дерево, tracking origin/main. Worktree /root/projects/nightshift-wt/e2-port-120 (гілка cc/e2-port-120 == main) — можна прибрати (git worktree remove) при нагоді.
- Активних ранів нема. Verify з task.md R1: /root/ops/cc-runs/e2-port-120-20260922-233611/task.md (секція Verify є).
- Staging /root/ops/_staging/e2-port-120/ (skill-копії, e2e-runs) — тимчасове, можна прибрати.

## Наступне (в новому чаті)
1. Прочитати skill-creator-framework (обов'язково перед будь-якою правкою SKILL.md).
2. cc-remote-agent → 1.3.0: прибрати scripts/ і всі посилання на `scripts/cc-*.sh` (рядки ~220, 273, 289-292, 483-503); замінити на «драйвери — репо nightshift, bin/; на вузлі — {RUNS}/cc-*.sh симлінками; відсутні на вузлі → git clone/pull github.com/0mandrock1/nightshift (private), не копіювати з скіла». Changelog 1.3.0.
3. swarm: /root/projects/cc-swarm → /root/projects/nightshift (рядки 19, 30, 84, 98, 216, 303, 312); прибрати «MIT» (репо приватне, опенсорс не зараз). Перевірити, чи існують bin/cc-gc.sh і tests/run-all.sh у nightshift.
4. model-router-runfile (рядок 86): «покласти її (cc-remote-agent scripts/cc-run.sh)» → посилання на репо nightshift.
5. vps-structure-audit (рядки 120, 187): прибрати scripts/cc-seq.sh, посилатись на nightshift/bin/cc-seq.sh.
6. Перевірити cc-remote-agent-vps/-desktop/-mandflok/-daybot на згадки scripts/ чи cc-swarm.
7. Пакувати через skill-creator-pack, видати .skill. Після того як Марк встановить: rm /root/projects/cc-swarm (попередньо pgrep 'claude'' -p' порожній, cc-defer ≥60 хв), skills-sync (у /root/claude-config/skills/user/swarm/SKILL.md ще старий шлях).
8. Desktop (окремо): read-only deploy key у WSL, clone → ~/src/nightshift, симлінки ~/ops/cc-runs/* → bin, CC_EXTRA_PATH для ~/.local/bin.

## Відкрито поза кодом
- Desktop: deploy key (read-only, тільки цей репо) чи fine-grained PAT? Рекомендація — deploy key.
- Worktree і staging e2-port-120 — прибрати зараз чи тримати до завершення скілів.

## Обмеження
- Правки коду драйверів — тільки у git worktree nightshift; жива копія = прод через симлінки.
- Перед зміною шляхів / rm симлінка — pgrep 'claude'' -p' / cc-*.sh порожні, cc-defer не ближче 60 хв (найближчий: cc-defer-post-transformer-explainer, 24.09 11:00 UTC).
- Скіли — правка в чаті, видача .skill; не редагувати живі скіли раном.
- Файли на/з VPS — тільки WebDAV.
- Опенсорс / публічний remote — не зараз (захардкоджені /root/... дефолти в CC_USAGE_CLI, CC_CAP_ENV). Не міняти visibility репо.
- Теки ранів і .lock не чіпати.

## Уроки цієї сесії
- Скіл-копія драйвера, відредагована в чаті ПІСЛЯ cutover, мовчки розійшлась з каноном і тримала фікс, якого в проді не було. Перед видаленням будь-якої копії — функціональна матриця фіч (grep по маркерах) в обидва боки, не лише md5.
- `cmd | tail` у `set -e`-ланцюгу маскує провал cmd (pipefail в sh нема) — фолбек `||` не спрацював на git push. Для перевірних кроків не пайпити у tail, або перевіряти ефект окремо (git ls-remote).
- `timeout` у cc-run/cc-chain вбиває лише процес claude, не дочірні Bash-процеси — потенційні сироти після TIMEOUT (не регресія, кандидат для infra-anomaly-triage).
