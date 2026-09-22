# HANDOFF nightshift-e1b 20260922

## Стан
- Мета: винести cc-драйвери в один git-репо з єдиним джерелом правди, згодом opensource (друга хвиля, ПІСЛЯ skill-governance-oss).
- Рішення Марка (22.09): НЕ новий репо — вирощуємо існуючий `/root/projects/cc-swarm` у `nightshift` (перейменування + занесення CORE з /root/ops/cc-runs). Причина: 3 CORE-скрипти вже симлінки в cc-swarm/bin — новий репо дав би перехресні симлінки двох репо.
- E0 (зроблено, чексуми): три копії драйверів (VPS /root/ops/cc-runs, skill cc-remote-agent/scripts, desktop WSL ~/ops/cc-runs) — жоден спільний файл не збігається. /root/ops/cc-runs без git. На VPS є claude 2.1.207 і codex-cli 0.151.0.
- E1a (зроблено, read-only ран sonnet): звіт `/root/ops/cc-runs/e1a-drivers-diff/REPORT.md` — hunk-класифікація, канон, межа симлінків, список санітизації. Вхідні копії лежать у `e1a-drivers-diff/src/{vps,skill,desktop}/`.
- Канон із звіту:
  - cc-run.sh → база VPS (ambiguous exit 4, BG_WAIT_CEILING, HTML-escape, BACKEND=codex гілка вже є). З desktop лише PATH-хак як NODE-опція (CC_CLAUDE_BIN / CC_EXTRA_PATH).
  - cc-chain.sh → база SKILL (pid self-healing lock, CC_RUNS env); домерджити з VPS: RISK-оцінку старту + ambiguous-гілку в do_run(). Дефолт CC_RUNS має резолвитись по вузлу (desktop-баг: дефолт /root/ops/cc-runs).
  - cc-cost.sh → skill-варіант (LOG відносно dirname $0).
  - cc-opus-gate / cc-notify → див. звіт, рядки 62–104 (у чаті не звірено).
- Unreal-agent ідеї, погоджені на крадіжку (E3, не E1b): idempotent RUN_ID (RESULT уже є → no-op), versioned run.json manifest, record-what-was-truncated, proxy operation manager (E4).

## Гілка / ран
- cc-swarm: гілку й чистоту дерева перевірити живому (при записі: див. вивід команди в чаті — не зафіксовано тут).
- Ран e1a-drivers-diff (sonnet/none) — завершено, RESULT: ok. Фактичний cost.log рядок не знайдено.
Verify з task.md цього рану: нема — task.md без Verify-секції (read-only аналіз).

## Відкрито поза кодом
- Остаточна назва: `nightshift`? (робоча, з пам'яті) — підтвердити.
- Перейменовувати тільки теку/remote чи й історію/ідентифікатори `cc-swarm` у коді й скілах (swarm SKILL.md посилається на cc-swarm)?
- LAUNCHER-скрипти (28 шт, 0 referrers): архівувати в `examples/` після санітизації, у `_archive/` поза репо чи лишити як є? `tv-deploy-prod/staging.sh` — підтвердити руками, що мертві.
- Чи правити живий VPS cc-chain.sh pid-lock ДО E1b як гарячий фікс, чи тільки через репо.

## Обмеження
- /root/ops/cc-runs/{cc-run,cc-chain,cc-seq,cc-notify,cc-opus-gate,cc-cost,cc-telemetry,cc-week-guard,cc-notify-swarm,cc-swarm,run-usage}.sh МУСЯТЬ лишитись робочими шляхами (симлінки на репо). Жорстко зашиті в: crontab (cc-week-guard кожні 15 хв), cc-defer units `cc-defer-ar-block2/3.service` → cc-chain.sh, /usr/local/bin/cc-runs (CC_RUNS_DIR), bootstrap-логіка скіла cc-remote-agent.
- Перед будь-якою мутацією шляхів — перевірити, чи armed cc-defer таймери (`systemctl list-timers --all | grep cc-defer`) і чи нема активних ранів (`pgrep -af 'claude -p'`). Не міняти шлях під живим раном.
- Мердж канону робити раном (cc-remote-agent-vps / cc-chain), не в чаті. Model: sonnet для механіки; opus лише якщо ран ухвалює рішення (CC_OPUS_REASON).
- Теки ранів (743 шт) і .lock-файли НЕ переносити і НЕ чистити.
- Opensource/публічний remote — не зараз.
- Файловий трансфер на/з VPS — тільки WebDAV, ніколи ssh_upload/ssh_download.

## Уроки цієї сесії
- Скіл-копія драйверів може бути НОВІША за живий вузол (pid-lock) — «VPS = канон» наосліп хибно; для CORE завжди hunk-diff, не вибір за розміром.
- Живий VPS cc-chain.sh має голий mkdir-лок без pid-перевірки — клас бага 09.09 досі не закритий на проді.
- Reverse-tunnel :19459 не пускає ssh з VPS на desktop; desktop→VPS файли — curl -T на WebDAV прямо з WSL.
- desktop: claude у ~/.local/bin, не в PATH неінтерактивного шелу — «мовчазні» фейли desktop-ранів.
