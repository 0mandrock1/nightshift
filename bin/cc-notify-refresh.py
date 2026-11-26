#!/usr/bin/env python3
"""Best-effort delayed quota correction for the exact delivered preflight.
The original preflight and admission evidence are immutable. Post-start
observations are explicitly separate and must not be used as run-start meters.
"""
import concurrent.futures
import datetime
import hashlib
import html
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request

BIN = Path(__file__).resolve().parent
CLAUDE_REFRESH = '/root/projects/tg_bots/mandrock0_cc_bot/quota-refresh.py'
WINDOWS = ('5h','7d')


def read(path):
    return json.loads(Path(path).read_text())


def missing(data):
    return {backend: [key for key in WINDOWS if not quota.get('windows',{}).get(key,{}).get('usable')]
            for backend,quota in data.get('quotas',{}).items()
            if backend in ('claude','codex') and any(not quota.get('windows',{}).get(key,{}).get('usable') for key in WINDOWS)}


def credentials(path, variant):
    values = dict(line.split('=',1) for line in Path(path).read_text().splitlines() if '=' in line)
    if variant == 'swarm':
        return values['SWARM_BOT_TOKEN'], values['SWARM_CHAT_ID']
    return values['BOT_TOKEN'], values['OWNER_CHAT_ID']


def identity(token, chat):
    return hashlib.sha256((token+'\0'+chat).encode()).hexdigest()


def schedule(preflight, response, delivery, env_file, variant, content):
    absent = missing(read(preflight))
    result = read(response)
    mid = result.get('result',{}).get('message_id')
    if not absent or result.get('ok') is not True or type(mid) is not int or mid <= 0:
        return None
    token,chat = credentials(env_file,variant)
    job = Path(str(preflight)+f'.quota-refresh-{variant}-{mid}.json')
    data = dict(schema=1,message_id=mid,delivery=delivery,variant=variant,
                env_file=env_file,identity=identity(token,chat),missing=absent,content=content,
                created_at=time.time())
    try:
        with os.fdopen(os.open(job,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as out:
            json.dump(data,out,ensure_ascii=False)
    except FileExistsError:
        return None
    with open(str(job)+'.log','a') as log:
        subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'run',str(job)],
                         stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True,close_fds=True)
    return job


def probe(backend):
    command = ([sys.executable,CLAUDE_REFRESH] if backend == 'claude'
               else ['sh',str(BIN/'cc-codex-usage.sh'),'--json'])
    try:
        out = subprocess.run(command,capture_output=True,text=True,timeout=140 if backend=='claude' else 20,check=True)
        raw = json.loads(out.stdout)
        now = time.time()
        ts = now if backend=='codex' and raw.get('source')=='codex-app-server' else raw.get('ts')
        if (raw.get('source') not in ('live','cache','oauth-cache','codex-app-server')
                or type(ts) not in (int,float) or not math.isfinite(ts) or not 0 <= now-ts <= 180):
            return {}
        values = {}
        for key in WINDOWS:
            used,reset = raw.get('util'+key),raw.get('reset'+key)
            if type(used) in (int,float) and math.isfinite(used) and 0<=used<=1 and type(reset) in (int,float) and math.isfinite(reset) and reset>now:
                values[key] = round(100*(1-used),2)
        return {'observed_at':ts,'windows':values,'source':raw['source']}
    except (OSError,ValueError,subprocess.SubprocessError):
        return {}


def update_lines(job, readings):
    lines = ['оновлення квоти після старту · не початковий відлік']
    for backend,keys in job['missing'].items():
        result = readings.get(backend,{})
        values = result.get('windows',{})
        if not any(key in values for key in keys):
            lines.append(f'{backend}: повторний запит не підтвердив відсутні дані')
            continue
        stamp = datetime.datetime.fromtimestamp(result['observed_at'],datetime.timezone.utc).strftime('%H:%M:%S UTC')
        parts = [f'{key}: {values[key]:g}% залишилось' if key in values else f'{key}: н/д' for key in WINDOWS]
        lines.append(f'{backend} · {stamp} · '+ ' · '.join(parts))
    return lines


def payload(job,lines,chat):
    result = {'chat_id':chat,'message_id':job['message_id']}
    body = job['content']
    if job['delivery']=='rich':
        rich=json.loads(body)
        rich['html']=rich['html'].replace('поточна квота недоступна','квота на старті не підтверджена')
        rich['html'] += ''.join('<p>'+html.escape(line)+'</p>' for line in lines)
        result['rich_message']=rich
    else:
        body=body.replace('поточна квота недоступна','квота на старті не підтверджена')
        if job['delivery']=='html':
            body += '\n\n'+'\n'.join(html.escape(line) for line in lines)
            result['parse_mode']='HTML'
        else:
            body += '\n\n'+'\n'.join(lines)
        result['text']=body
    return result


def edit(token,data):
    request=urllib.request.Request('https://api.telegram.org/bot'+token+'/editMessageText',
        data=json.dumps(data,ensure_ascii=False).encode(),headers={'Content-Type':'application/json'},method='POST')
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request,timeout=12) as response:
                value=json.load(response)
                if value.get('ok') is True and value.get('result',{}).get('message_id')==data['message_id']:
                    return True
                return False
        except urllib.error.HTTPError as e:
            if e.code==400:
                try:
                    return 'message is not modified' in json.load(e).get('description','').lower()
                except (ValueError,OSError):
                    return False
            if e.code not in (429,500,502,503,504):
                return False
        except (OSError,ValueError):
            pass
        if attempt<2:
            time.sleep(3*(attempt+1))
    return False


def run(path):
    job=read(path)
    token,chat=credentials(job['env_file'],job['variant'])
    if identity(token,chat)!=job['identity'] or time.time()-job['created_at']>600:
        return False
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        readings=dict(zip(job['missing'],pool.map(probe,job['missing'])))
    ok=edit(token,payload(job,update_lines(job,readings),chat))
    print(json.dumps({'event':'quota_refresh_edit','message_id':job['message_id'],'ok':ok,
                      'providers':list(job['missing']),'confirmed':{k:list(v.get('windows',{})) for k,v in readings.items()}}),flush=True)
    return ok


if __name__=='__main__':
    try:
        if sys.argv[1]=='schedule':
            schedule(*sys.argv[2:],sys.stdin.read())
        elif sys.argv[1]=='run':
            sys.exit(0 if run(sys.argv[2]) else 1)
        else:
            sys.exit(2)
    except Exception as e:
        # Exceptions from Telegram may contain the bot token in their URL.
        print('quota_refresh_error: '+type(e).__name__,file=sys.stderr)
        sys.exit(1)
