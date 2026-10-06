# Backlog — nightshift

## Відсічка ранів за usage Codex
- Зараз тижневий лок (`.week-locked`, крон `cc-week-guard.sh`) міряє лише usage Claude. Codex-бекенд його обходить (з 06.10: `cc-chain.sh` і `cc-run.sh` не перевіряють лок, а `cc-chain.sh` ще й гейт тижня <5 %, якщо всі кроки на codex), тож власної відсічки за бюджетом Codex немає: ран упирається в квоту й виходить з exit 3 уже посеред роботи.
- Зробити окремий гейт для codex-бекенда за зразком claude-гейта: `cc-codex-usage.sh` (є в `bin/`, у `/root/ops/cc-runs` не слінкований) → поріг залишку → окремий лок `.codex-locked` (крон, як `cc-week-guard.sh`), який перевіряють `cc-chain.sh` / `cc-run.sh` / `cc-swarm.sh` лише для кроків із backend=codex; змішаний план — по кроках, не за першим.
- Відкриті питання: поріг (як у claude-гейта, 5 %?), вікно (5h чи тиждень, чи обидва), що робити з преф-флайтом `cc-estimate.sh --backend codex`, чи зупиняти ланцюг між кроками при просіданні нижче порогу.
- Тест: аналог `tests/test-week-lock-codex.sh` — лок codex блокує codex-кроки й не чіпає claude-кроки.
- Статус: не почато
