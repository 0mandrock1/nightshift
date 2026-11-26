#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 - <<'PY'
import importlib.util, pathlib, tempfile, json, os
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('refresh','bin/cc-notify-refresh.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as d:
    root=pathlib.Path(d); p=root/'preflight.json'; response=root/'response.json'; env=root/'env'
    original={'quotas':{'claude':{'windows':{'5h':{'usable':False},'7d':{'usable':False}}}}}
    p.write_text(json.dumps(original)); response.write_text(json.dumps({'ok':True,'result':{'message_id':42}}))
    env.write_text('BOT_TOKEN=fake\nOWNER_CHAT_ID=123\n')
    with patch.object(m.subprocess,'Popen') as proc:
        job=m.schedule(str(p),str(response),'html',str(env),'run','<b>start</b>')
        assert proc.call_count==1 and job.exists()
        assert m.schedule(str(p),str(response),'html',str(env),'run','<b>start</b>') is None
    data=m.read(job)
    assert data['message_id']==42 and 'fake' not in job.read_text()
    assert job.stat().st_mode & 0o777==0o600
    assert m.read(p)==original
    reading={'observed_at':1000,'windows':{'5h':76,'7d':65},'source':'live'}
    with patch.object(m,'probe',return_value=reading), patch.object(m,'edit',return_value=True) as edit:
        assert m.run(job)
        payload=edit.call_args.args[1]
        assert payload['message_id']==42 and '76%' in payload['text'] and '65%' in payload['text']
        assert payload['parse_mode']=='HTML'
    rich=data | {'delivery':'rich','content':json.dumps({'html':'<p>start</p>'})}
    payload=m.payload(rich,m.update_lines(rich,{'claude':reading}),'123')
    assert 'rich_message' in payload and '76%' in payload['rich_message']['html']
    assert 'не підтвердив' in m.payload(data,m.update_lines(data,{}),'123')['text']
    assert m.read(p)==original
print('notify refresh: OK')
PY
