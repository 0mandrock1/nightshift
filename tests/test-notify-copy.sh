#!/bin/sh
# Validate actual Bot API payloads without sending Telegram messages.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
python3 - "$HERE/../bin/cc-notify.sh" <<'PY'
import html
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

notify = sys.argv[1]
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    (root / "notify.env").write_text("BOT_TOKEN=fake\nOWNER_CHAT_ID=1\n")
    curl = root / "curl"
    curl.write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ["CAPTURE"], "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\\n")
print(os.environ.get("HTTP_CODE", "200"), end="")
""")
    curl.chmod(0o755)
    capture = root / "capture"
    env = dict(os.environ, PATH=f"{temp}:{os.environ['PATH']}",
               CC_NOTIFY_ENV=str(root / "notify.env"), CAPTURE=str(capture))

    def send(message, *args, http="200"):
        capture.write_text("")
        result = subprocess.run(["sh", notify, message, *args],
                                env=dict(env, HTTP_CODE=http),
                                capture_output=True, text=True, check=True)
        calls = [json.loads(line) for line in capture.read_text().splitlines()]
        assert len(calls) == (1 if http == "200" else 2), result.stderr
        return [next(a[5:] for a in call if a.startswith("text=")) for call in calls]

    for status in ["❌", "⏱️", "☠️", "⚠️"]:
        msg = f"{status} run · <code>test-42</code> · &lt;bad&gt; &amp; x\n<pre>Fact: 2 &gt; 1</pre>"
        plain = f"{status} run · test-42 · <bad> & x\nFact: 2 > 1"
        assert send(msg) == [msg + "\n\n<pre>" + html.escape(plain, quote=False) + "</pre>"]
    for msg in ["✅ run · ok", "⚠ РИЗИКОВИЙ СТАРТ", "⛔ run · session limit",
                "<b>run · старт</b>\n<pre>forecast</pre>"]:
        assert send(msg) == [msg]
    assert send("❌ run", "silent") == ["❌ run"]
    long = "❌ " + "🧪" * 1500
    assert send(long) == ["<pre>" + long + "</pre>"]
    oversized = "❌ " + "x" * 4100
    assert send(oversized) == [oversized]
    assert send("❌ <code>run</code>", http="400")[-1] == "❌ run"
print("test-notify-copy: OK (4 failure statuses, unchanged statuses, silent, limits, fallback)")
PY
