# Codex CLI surface (Hetzner VPS)

Знято 2026-09-23 після апгрейду `npm i -g @openai/codex@latest`. Для кожного твердження — команда, якою отримано.

## Версія і логін

- Версія до апгрейду: `0.151.0` (`npm ls -g @openai/codex` → `/usr/lib/node_modules/@openai/codex@0.151.0`).
- Версія після апгрейду: **`0.156.1`** (`codex --version` → `codex-cli 0.156.1`). `npm i -g @openai/codex@latest` → "changed 2 packages in 13s".
- Логін: `codex login status` → `Logged in using ChatGPT` (сесія не зачеплена апгрейдом).

## `codex exec --help` (повний вивід)

```
Run Codex non-interactively

Usage: codex exec [OPTIONS] [PROMPT]
       codex exec [OPTIONS] <COMMAND> [ARGS]

Commands:
  resume  Resume a previous session by id or pick the most recent with --last
  fork    Fork a previous session by id into a new session
  review  Run a code review against the current repository
  help    Print this message or the help of the given subcommand(s)

Arguments:
  [PROMPT]
          Initial instructions for the agent. If not provided as an argument (or if `-` is used),
          instructions are read from stdin. If stdin is piped and a prompt is also provided, stdin
          is appended as a `<stdin>` block

Options:
  -c, --config <key=value>
          Override a configuration value that would otherwise be loaded from `~/.codex/config.toml`.
          Use a dotted path (`foo.bar.baz`) to override nested values. The `value` portion is parsed
          as TOML. If it fails to parse as TOML, the raw string is used as a literal.

          Examples: - `-c model="o3"` - `-c 'sandbox_permissions=["disk-full-read-access"]'` - `-c
          shell_environment_policy.inherit=all`

      --enable <FEATURE>
          Enable a feature (repeatable). Equivalent to `-c features.<name>=true`

      --disable <FEATURE>
          Disable a feature (repeatable). Equivalent to `-c features.<name>=false`

      --strict-config
          Error out when config.toml contains fields that are not recognized by this version of
          Codex

  -i, --image <FILE>...
          Optional image(s) to attach to the initial prompt

  -m, --model <MODEL>
          Model the agent should use

      --oss
          Use open-source provider

      --local-provider <OSS_PROVIDER>
          Specify which local provider to use (lmstudio or ollama). If not specified with --oss,
          will use config default or show selection

  -p, --profile <CONFIG_PROFILE_V2>
          Layer $CODEX_HOME/<name>.config.toml on top of the base user config

  -s, --sandbox <SANDBOX_MODE>
          Select the sandbox policy to use when executing model-generated shell commands

          [possible values: read-only, workspace-write, danger-full-access]

      --approve-for-me
          Route approval requests through automatic review using the workspace-write sandbox

      --dangerously-bypass-approvals-and-sandbox
          Skip all confirmation prompts and execute commands without sandboxing. EXTREMELY
          DANGEROUS. Intended solely for running in environments that are externally sandboxed

      --dangerously-bypass-hook-trust
          Run enabled hooks without requiring persisted hook trust for this invocation. DANGEROUS.
          Intended only for automation that already vets hook sources

  -C, --cd <DIR>
          Tell the agent to use the specified directory as its working root

      --worktree
          Run the session in a new managed Git worktree

      --add-dir <DIR>
          Additional directories that should be writable alongside the primary workspace

      --thread-source <SOURCE>
          Source classification for newly created or forked threads

      --skip-git-repo-check
          Allow running Codex outside a Git repository

      --ephemeral
          Run without persisting session files to disk

      --ignore-user-config
          Do not load `$CODEX_HOME/config.toml`; auth still uses `CODEX_HOME`

      --ignore-rules
          Do not load user or project execpolicy `.rules` files

      --output-schema <FILE>
          Path to a JSON Schema file describing the model's final response shape

      --color <COLOR>
          Specifies color settings for use in the output

          [default: auto]
          [possible values: always, never, auto]

      --json
          Print events to stdout as JSONL

  -o, --output-last-message <FILE>
          Specifies file where the last message from the agent should be written

  -h, --help
          Print help (see a summary with '-h')

  -V, --version
          Print version
```
(`codex exec --help > /tmp/codex_exec_help.txt`)

**`--add-dir <DIR>` існує** — "Additional directories that should be writable alongside the primary workspace". Це аналог дозволу запису поза CWD, без потреби в `danger-full-access`.

## Топлевел `codex --help`

Підкоманди (`codex --help`, скорочено до релевантного): `agents`, `exec` (аліас `e`), `review`, `login`, `logout`, `mcp`, `plugin`, `app-server`, `remote-control`, `completion`, `update`, `doctor`, `sandbox`, `debug`, `apply` (аліас `a`), `resume`, `queue`, `archive`, `delete`, `migrate-rollouts`, `unarchive`, `fork`, `cloud`, `exec-server`, `features`, `help`.

## Моделі, доступні акаунту

Джерело: `codex debug models` (Render the raw model catalog as JSON) → `/tmp/codex_models.json`, поле `.models` (9 записів). Кеш підтверджений файлом `~/.codex/models_cache.json` (не читав вміст напряму — той самий каталог, до нього не торкався; `auth.json` не чіпав).

`slug` / `display_name` / `description`:

| slug | display_name | description |
|---|---|---|
| `gpt-6-astra` | GPT-6-Astra | Frontier intelligence for the most demanding work. |
| `gpt-6-sol` | GPT-6-Sol | Workhorse model for coding and everyday work. |
| `gpt-6-luna` | GPT-6-Luna | Fast and affordable model for easier tasks. |
| `gpt-reserve` | GPT-Reserve | Fast and affordable agentic coding model. |
| `gpt-5.6-sol` | GPT-5.6-Sol | Older coding model for complex work. |
| `gpt-5.6-terra` | GPT-5.6-Terra | Older balanced model for straightforward work. |
| `gpt-5.6-luna` | GPT-5.6-Luna | Older fast and efficient model. |
| `gpt-5.5` | GPT-5.5 | Legacy coding model. |
| `codex-auto-review` | Codex Auto Review | Automatic approval review model for Codex. |

Підтверджує common.md: **`gpt-6-terra` не існує** — є `gpt-5.6-terra` (легасі-покоління), а GPT-6 має тільки `luna`/`sol`/`astra`. Поточний дефолт у `~/.codex/config.toml`: `model = "gpt-5.6-terra"`, `model_reasoning_effort = "medium"` (`grep -i model ~/.codex/config.toml`) — не мінявся цим раном.

## Живий пробний виклик

Робоча тека: `/tmp/codex-probe` (`git init`).

### Валідна модель

```
codex exec -m gpt-6-luna --sandbox read-only --json -o /tmp/codex-probe/last.txt "reply with the single word PONG"
```

- **exit code: 0**
- `last.txt`: `PONG`
- Типи подій JSONL (стрім `stdout`, у порядку появи): `thread.started`, `turn.started`, `item.completed`, `turn.completed`.
- `turn.completed.usage` (дослівна структура ключів, без значень токенів авторизації):
  ```json
  {
    "input_tokens": 15276,
    "cached_input_tokens": 11008,
    "cache_write_input_tokens": 0,
    "output_tokens": 6,
    "reasoning_output_tokens": 0
  }
  ```

### Неіснуюча модель

```
codex exec -m gpt-6-nope --sandbox read-only --json -o /tmp/codex-probe/last2.txt "reply with the single word PONG"
```

- **exit code: 1**
- `last2.txt` не створюється (агент не дійшов до відповіді).
- JSONL-подій: `thread.started` → `item.completed` (`item.type=error`, `message="Model metadata for \`gpt-6-nope\` not found. Defaulting to fallback metadata; this can degrade performance and cause issues."`) → `turn.started` → `error` (`message` містить вкладений JSON: `status 400`, `type invalid_request_error`, `"The 'gpt-6-nope' model is not supported when using Codex with a ChatGPT account."`) → `turn.failed` (той самий error-об'єкт).
- Для класифікації помилок: невідома модель = exit 1, з `turn.failed.error.message` — вкладений JSON-рядок з `status:400`/`type:invalid_request_error`, не окремі структуровані поля.

## Live smoke ns-codex-live-20260923-0312

Бойовий прогін cc-run.sh з `BACKEND=codex`, `MODEL=sonnet` (→ мапиться в `gpt-6-luna`) на реальному repo з навмисним багом.

Робоча тека `/tmp/codex-live-ns-codex-live-20260923-0312` (git init, поза `/root/ops/cc-runs`): `add.py` з `return a - b` (баг) + `test_add.py` (assert-скрипт). Run-dir вкладеного рану — `/tmp/codex-live-ns-codex-live-20260923-0312-run` (теж у `/tmp`, не в `/root/ops/cc-runs`).

Команда:
```
cd /tmp/codex-live-ns-codex-live-20260923-0312 && CC_TAG=codex-smoke sh /root/projects/nightshift/bin/cc-run.sh /tmp/codex-live-ns-codex-live-20260923-0312-run none sonnet codex
```

Перший прогін з `task.md`, що вимагав `git commit`, дав `RESULT: fail` (exit script 2, `exit_code`-файл 0 — сам codex exec відпрацював чисто, RC=0): `.git/index.lock` не можна записати, `.git` у sandbox `workspace-write` доступний лише на читання. Прибрано вимогу коміту з task.md, репо скинуто (`git reset --hard`) до багованого стану, run-dir перестворено — другий прогін пройшов.

Перевірено руками (не зі слів вкладеного рану):
- `sh cc-run.sh` exit code: **0**.
- `add.py` після рану: `return a + b` (баг виправлено); `python3 test_add.py` запущено самостійно з host-сесії → `all tests passed`, exit 0.
- Модель: **events.jsonl не містить поля `model`** (лише `thread.started`/`turn.started`/`item.*`/`turn.completed`, як і задокументовано вище для проби 22.09) — підтверджено через `~/.codex/sessions/2026/09/23/rollout-*-<thread_id>.jsonl` (thread_id з `events.jsonl`), там `"model":"gpt-6-luna"`.
- `telemetry.log`: `[2026-09-23T03:28:19Z] cost: codex-live-ns-codex-live-20260923-0312-run: 83154 токенів (cache_read 90%), n/a codex` — з `turn.completed.usage`: `input_tokens=82793, cached_input_tokens=75520, output_tokens=361, reasoning_output_tokens=0`.
- `notify-debug.log`: `notify_silent rc=0` (preflight) і `notify rc=0` (afterflight, `codex-smoke · ok`) — обидва `curl_rc=0 http=200`.

Гард дорогої моделі (крок 4): та сама команда з `MODEL=opus`, без `CC_OPUS_REASON` (унсет у сесії):
```
CC_TAG=codex-smoke sh /root/projects/nightshift/bin/cc-run.sh /tmp/codex-live-ns-codex-live-20260923-0312-run-opusgate none opus codex
```
exit **6**, повідомлення `ВІДМОВА opus-gate: ... просить opus без CC_OPUS_REASON`. Run-dir після відмови містить лише `cwd`/`session_id`/`task.md` — **нема `events.jsonl`/`last-message.txt`**, тобто `codex exec` не спавнився (гард спрацював до виклику бінарника, не після).
