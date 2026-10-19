#!/bin/sh
# Exercise actual argv for both drivers/backends without calling a model.
set -eu
export NIGHTSHIFT_TEST_ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 - <<'PY'
import json, os, pathlib, subprocess, tempfile
root=pathlib.Path(os.environ['NIGHTSHIFT_TEST_ROOT'])
with tempfile.TemporaryDirectory() as tmp:
 p=pathlib.Path(tmp)
 stub=p/'model-stub'
 stub.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
Path(os.environ['ARGV_LOG']).write_text(json.dumps(sys.argv[1:]))
a=sys.argv[1:]
if '-o' in a: Path(a[a.index('-o')+1]).write_text('RESULT: fail\\n')
else: print('RESULT: fail')
''')
 stub.chmod(0o755)
 for driver in ['cc-run.sh','cc-chain.sh']:
  for backend in ['codex','claude']:
   for override in [False,True]:
    label=f'{driver}-{backend}-{override}'
    d=p/label; d.mkdir(); repo=d/'repo'; repo.mkdir()
    for args in [('init','-q'),('config','user.email','test@example.invalid'),('config','user.name','Test'),('commit','--allow-empty','-qm','init')]:
     subprocess.run(['git','-C',str(repo),*args],check=True,capture_output=True)
    task=d/'task.md'; task.write_text('Test permissions only.\n')
    run=d/'runs'/'single'; run.mkdir(parents=True); (run/'task.md').write_text(task.read_text())
    log=d/'argv.json'
    env=os.environ.copy()
    for key in ['CC_CODEX_SANDBOX','CC_CODEX_APPROVAL_POLICY','CC_CLAUDE_PERMISSION_MODE']:
     env.pop(key,None)
    env.update(CC_RUNS=str(d/'runs'),CC_CODEX_BIN=str(stub),CC_CLAUDE_BIN=str(stub),ARGV_LOG=str(log),CC_USAGE_CLI=str(root/'tests/fixtures/usage-cli-stub.js'),CC_NOTIFY=str(root/'tests/fixtures/notify-null.sh'),CC_WEEK_LOCK=str(d/'no-lock'),CC_PG_CREDS=str(d/'no-creds'),CC_RUN_TIMEOUT_S='20')
    if override: env.update(CC_CODEX_SANDBOX='workspace-write',CC_CODEX_APPROVAL_POLICY='on-request',CC_CLAUDE_PERMISSION_MODE='acceptEdits')
    if driver=='cc-run.sh': cmd=['sh',str(root/'bin'/driver),str(run),'none','sonnet',backend]
    else:
     plan=d/'plan.txt'; plan.write_text(f'step|none|{task}|sonnet|{backend}\n')
     cmd=['sh',str(root/'bin'/driver),str(repo),str(plan),label]
    result=subprocess.run(cmd,cwd=repo,env=env,capture_output=True,text=True,timeout=40)
    assert log.exists(), (label,result.returncode,result.stdout[-500:],result.stderr[-500:])
    argv=json.loads(log.read_text())
    if backend=='codex':
     assert argv[argv.index('-s')+1]==('workspace-write' if override else 'danger-full-access'), (label,argv)
     assert 'approval_policy='+('on-request' if override else 'never') in argv,(label,argv)
    else:
     assert argv[argv.index('--permission-mode')+1]==('acceptEdits' if override else 'bypassPermissions'),(label,argv)
    assert result.returncode==(2 if driver=='cc-run.sh' else 4),(label,result.returncode)
 print('OK: run/chain Codex+Claude permission defaults and explicit overrides (8 cases)')
PY
