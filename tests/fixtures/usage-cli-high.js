#!/usr/bin/env node
// Тестовий CC_USAGE_CLI: тиждень Claude майже вичерпано (лишилось 3 %).
if (process.argv.includes('--ratelimit-json')) {
  process.stdout.write(JSON.stringify({ util5h: 0.1, util7d: 0.97, source: 'stub-high' }) + '\n');
}
