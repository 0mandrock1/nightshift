#!/usr/bin/env node
// Тестовий CC_USAGE_CLI: замість реального usage-cli.js (Telegram-бот,
// ~37 execve/прогін реального run-all.sh) віддає фіксований "ліміти вільні"
// JSON у форматі, який парсить bin/cc-estimate.sh і bin/cc-chain.sh
// (--ratelimit-json -> {util5h, util7d, source}) — гейти тижня/ризику
// в тестах ніколи не спрацьовують.
if (process.argv.includes('--ratelimit-json')) {
  process.stdout.write(JSON.stringify({ util5h: 0, util7d: 0, source: 'stub' }) + '\n');
}
