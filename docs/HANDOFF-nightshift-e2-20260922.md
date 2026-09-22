# HANDOFF nightshift-e2 20260922

## Стан
- E1b ЗАВЕРШЕНО. /root/projects/cc-swarm → /root/projects/nightshift (старий шлях = compat-симлінк). main = 835d584 (ff з e1b-canon).
- 14 шляхів /root/ops/cc-runs (11 CORE + cc-estimate/cc-lane-local/cc-tg-format) — симлінки на nightshift/bin, перевірено readlink -f на момент запису.
- Канон: код через BIN=$(dirname "$(readlink -f "$0")"), стан через CC_RUNS=${CC_RUNS:-<passwd-home>/ops/cc-runs} (НЕ $HOME — під systemd його нема). LOG → $CC_RUNS/telemetry.log. NODE-опції CC_CLAUDE_BIN / CC_EXTRA_PATH.
- Креди поза git: bin/notify.env → mandrock0_cc_bot/.env, bin/notify-swarm.env → /root/ops/cc-runs/creds-swarm.env (обидва gitignored).
- 31 LAUNCHER (+tv-deploy-*) → /root/ops/_archive/launchers-20260922/.
- Бекапи: /root/ops/_archive/cutover-e1b-20260922-225950 (перша спроба, verify впав на HOME, авто-відкат), cutover-e1b-20260922-231835 (успішна). Відкат: sh ops/rollback-e1b.sh <бекап> (скрипт розрахований на стан одразу після cutover — після нових комітів у main звір BASE вручну).
- Скрипти cutover/rollback/waiter — ops/ у репо.

## Гілка / ран
- nightshift: main, дерево чисте на момент запису. Remote НЕМА (не було й у cc-swarm).
- Verify-ран e1b-cutover-verify-20260922-231836 (haiku noop через /root/ops/cc-runs/cc-run.sh під systemd): exit_code 0, RESULT: ok.
- Доставка Telegram-нотифікацій (cutover OK + noop) — машинно НЕ перевірено, лише Марк бачить бот.

## Відкрито поза кодом
- Скіл-копії драйверів (cc-remote-agent/scripts/{cc-run,cc-chain,cc-opus-gate,cc-cost}.sh) тепер третя розбіжна копія. Варіант: прибрати scripts/ зі скіла і посилатись на репо, чи генерувати їх з репо при пакуванні? Рішення Марка.
- Desktop-вузол (WSL ~/ops/cc-runs): як доставити канон — потрібен приватний remote (GitHub 0mandrock1/nightshift private?) чи WebDAV-снапшот? Рішення Марка.
- Коли прибрати compat-симлінк /root/projects/cc-swarm (після оновлення swarm SKILL.md і cc-remote-agent*-скілів на nightshift).
- Чи прийшли обидві нотифікації (підтвердити Марку).

## Обмеження
- Правки коду драйверів — ТІЛЬКИ у git worktree nightshift, не в живій копії: bin/ живий прод через симлінки, будь-який checkout/редагування в /root/projects/nightshift = миттєвий деплой.
- Перед будь-якою зміною шляхів — pgrep claude -p / cc-*.sh порожні, cc-defer таймер не ближче 60 хв.
- Скіли правити в чаті, віддавати .skill; не редагувати живі скіли раном.
- Файли на/з VPS — тільки WebDAV. Opensource/публічний remote — не зараз (захардкоджені дефолти /root/... у CC_USAGE_CLI, CC_CAP_ENV — блокер опенсорсу).
- Теки ранів і .lock не чіпати.

## Уроки цієї сесії
- Під systemd юнітами HOME не задано → дефолт через $HOME + set -u = краш. Дефолти стану брати з getent passwd. E2E драйверів ганяти під systemd-run, не з інтерактивного шелу.
- Ран, що змінює код, який живий через симлінки, мусить працювати у worktree: merge-ран у живій копії дав побічний деплой cc-estimate/lane-local/tg-format через checkout.
- Атомарна інфра-підміна (mv -T, симлінки) — детермінованим скриптом з авто-відкатом, не LLM-раном; LLM-ран під cc-run.sh ще й бачить себе в pgrep-передумові.
- Вейтер мусить відкочувати й при провалі ПІСЛЯ мутації — маркер бекапу пишеться одразу після бекапу, не в кінці.
- pgrep -f по рядку, який є у власному командному рядку (ssh -c з тим самим текстом), матчить сам себе — патерн розбивати ('claude'' -p').
