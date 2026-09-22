# cc-swarm

Оркестратор паралельного рою `claude -p` лейнів: worktree-ізоляція, стеля
паралельності, машинний verify-cmd на кожен лейн, fan-in через Sonnet,
телеметрія в Postgres, пре-фліт оцінка вартості до запуску.

Незалежний продукт (власний git, MIT), придатний до відчуження від
конкретного VPS — усі шляхи стану (теки ранів, worktree, креденшли БД)
перевизначаються через ENV, дефолти вказують на поточний вузол Марка.

## Чому рій, а не ланцюг

Ланцюг (`cc-chain.sh`, не входить у цей продукт) — послідовність залежних
кроків в одній робочій копії. Рій — N незалежних лейнів у власних
worktree, що йдуть паралельно і зводяться (fan-in) в кінці. Рій виграє,
коли одиниць роботи ≥6, кожна має машинну умову успіху (verify-cmd), і
вони не ділять спільний ресурс. Роутер цього рішення — скіл `swarm` у
колекції скілів Марка (в цьому репо його нема).

## Запуск

```sh
sh bin/cc-swarm.sh <repo> <swarm-plan> <swarm-id>
```

Формат plan-файлу (`|`-розділений, по рядку на лейн):

```
lane-slug|task.md|verify-cmd|model|style
```

- `lane-slug` — унікальний, ім'я гілки/worktree.
- `task.md` — шлях до промпту лейна.
- `verify-cmd` — shell-команда в worktree лейна після рану, exit 0 = ok.
  **Обов'язкова** — порожня валить драйвер на старті.
- `model` — дефолт `haiku`. `local:<tag>` -> `cc-lane-local.sh` (Tier 0,
  зараз стаб, фаза 2).
- `style` — дефолт `none`.

Fan-in (опційно): `<swarm-plan>.fanin` — task.md для зведення, виконується
після лейнів на гілці `cc/<swarm-id>/fanin`, завжди `sonnet`.

## Пре-фліт оцінка

```sh
sh bin/cc-estimate.sh --task task.md --model sonnet [--lanes N] [--maxpar K] [--run-id ID]
```

Друкує один `PREFLIGHT:`-блок з прогнозом токенів/часу/% кепів на основі
медіани історії `swarm.runs` (сідові значення, якщо історія <3 ранів).
`cc-swarm.sh` викликає це сам перед спавном лейнів і друкує в `swarm.log`
+ стартову нотифікацію.

## ENV-змінні

| Змінна | Дефолт | Що |
|---|---|---|
| `MAXPAR` | 4 | стеля паралельних лейнів |
| `LANE_TIMEOUT` | 1800 | секунд на лейн (`timeout`), статус `timeout` при вбивстві |
| `DRYRUN` | 0 | 1 = валідація/worktree/маніфест без реального спавну |
| `CC_RUNS_DIR` | `/root/ops/cc-runs` | тека логів ранів |
| `CC_SWARMS_DIR` | `/root/ops/cc-swarms` | тека worktree/маніфестів |
| `CC_RUN_SH` | `$CC_RUNS_DIR/cc-run.sh` | раннер одиночного лейна (перевизначається в тестах) |
| `CC_LANE_LOCAL_SH` | `$CC_RUNS_DIR/cc-lane-local.sh` | раннер `local:*` лейнів |
| `CC_ESTIMATE_SH` | `$CC_RUNS_DIR/cc-estimate.sh` | пре-фліт оцінювач |
| `CC_NOTIFY` | `$CC_RUNS_DIR/cc-notify-swarm.sh` | Telegram-нотифікація (best-effort) |
| `CC_PG_CREDS` | `/root/ops/cc-runs/creds-pg.env` | файл з `POSTGRES_PASSWORD=` (chmod 600, поза git) |
| `CC_PG_CONTAINER`/`CC_PG_DB`/`CC_PG_USER`/`CC_PG_HOST`/`CC_PG_PORT` | mandrock-kb-postgres/mandrock_kb/mandrock/127.0.0.1/5432 | підключення до Postgres |

Креденшли БД **ніколи** не хардкодяться в скрипти чи git — тільки в
`CC_PG_CREDS`-файлі поза репозиторієм. `.env.example` тут — лише формат.

## Схема БД

`sql/001_swarm_schema.sql`, ідемпотентний, схема `swarm` у БД `mandrock_kb`:

- `swarm.runs` — один рядок на будь-яку одиницю виконання (`run`/`chain`/
  `swarm`/`lane`/`fanin`), токени/час/статус/parent_run_id.
- `swarm.verifications` — лог verify-cmd по лейнах.
- `swarm.estimates` — прогноз ДО запуску (`cc-estimate.sh`) + факт ПІСЛЯ
  (`cc-telemetry.sh` дописує `actual_*`) -> `error_pct` — калібрування
  оцінювача на власній історії.
- `swarm.routes` — рішення роутера скіла (рій/ланцюг/гібрид) для аудиту.

`run_id` у `estimates`/`routes`/`verifications` **не** FK на `runs` —
оцінка й рішення роутера пишуться ДО того, як існує сам ран.

Застосувати схему:

```sh
docker exec -i -e PGPASSWORD="$(cut -d= -f2- < /root/ops/cc-runs/creds-pg.env)" \
  mandrock-kb-postgres psql -h 127.0.0.1 -U mandrock -d mandrock_kb < sql/001_swarm_schema.sql
```

## Тести

```sh
sh tests/run-all.sh
```

- `test-maxpar.sh` — доводить реальну стелю MAXPAR (регрес `wait -n` на dash).
- `test-limit-stop.sh` — доводить зупинку спавну по session limit (сентинел-файл).
- `test-timeout.sh` — доводить, що завислий лейн вбивається по `LANE_TIMEOUT`.
- `test-smoke.sh` — старі шляхи (`/root/ops/cc-runs/cc-swarm.sh` тощо)
  лишаються робочими симлінками, `DRYRUN=1` проходить валідацію.

Усі тести — ізольовані (`mktemp -d`, підставні `CC_RUN_SH`, окрема
`CC_PG_CREDS=/tmp/.../no-creds`), не чіпають прод-стан і прод-БД.

## Ретеншен worktree/гілок

```sh
sh bin/cc-gc.sh <repo> [--older-than-days N] [--dry-run]
```

Прибирає `cc/*/*`-гілки й worktree старші за поріг (дефолт 14д), крім тих,
що ще не змержені в жодну fanin-гілку чи в main (§9 SKILL.md).

## Ліцензія

MIT.
