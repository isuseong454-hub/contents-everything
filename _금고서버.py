#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
컨텐츠의 모든것 — 금고 서버 (맥북 로컬)

  지금까지: 런처가 `python3 -m http.server` 로 «읽기만» 하는 서버를 띄웠다.
  이제부터: 그 자리에 이 서버가 선다. 화면을 띄우는 일은 그대로 하고,
           거기에 «맥북에 진짜 파일로 저장하는» 창구 하나를 더 연다.

  금고 자리 :  ~/컨모금고/
      items.json        담은 것 전부 (한 줄짜리 JSON 배열)
      images/<id>.jpg   사진 원본 — base64가 아니라 진짜 파일
      백업/items-YYMMDD.json   하루 첫 저장 때 그날치 사본

  ⚠️ 이 서버는 «맥북 안에서만» 듣는다(127.0.0.1). 밖에서는 못 들어온다.
"""

import json
import os
import re
import base64
import shutil
import datetime
import posixpath
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

PORT = 5260
APP_DIR = os.path.dirname(os.path.abspath(__file__))
VAULT = os.path.expanduser('~/컨모금고')
IMG_DIR = os.path.join(VAULT, 'images')
BAK_DIR = os.path.join(VAULT, '백업')
ITEMS = os.path.join(VAULT, 'items.json')

UUID_RE = re.compile(r'^[0-9a-fA-F-]{8,64}$')   # 파일 이름에 쓸 수 있는 id인지


# ────────────────────────────────────────────────── 금고 바닥 깔기
def ensure_vault():
    for d in (VAULT, IMG_DIR, BAK_DIR):
        if not os.path.isdir(d):
            os.makedirs(d)
    if not os.path.exists(ITEMS):
        write_json(ITEMS, [])


def read_items():
    try:
        with open(ITEMS, 'r', encoding='utf-8') as f:
            rows = json.load(f)
        return rows if isinstance(rows, list) else []
    except Exception:
        return []


def write_json(path, obj):
    """원자적 쓰기 — 쓰다 만 파일이 남지 않게 임시로 썼다가 갈아끼운다."""
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, path)


def backup_once_a_day():
    """그날 첫 저장 때만 사본을 남긴다 — 저장할 때마다 남기면 폴더가 터진다."""
    name = 'items-' + datetime.date.today().strftime('%y%m%d') + '.json'
    dst = os.path.join(BAK_DIR, name)
    if not os.path.exists(dst) and os.path.exists(ITEMS):
        try:
            shutil.copy2(ITEMS, dst)
        except Exception:
            pass


def prune_backups(keep=30):
    try:
        files = sorted(f for f in os.listdir(BAK_DIR) if f.startswith('items-'))
        # '서버이사-*' 는 지우지 않는다 — 이사 원본은 한 번뿐이라 값이 다르다
        for f in files[:-keep]:
            os.remove(os.path.join(BAK_DIR, f))
    except Exception:
        pass


# ────────────────────────────────────────────────── 사진: base64 → 진짜 파일
def stash_image(row):
    """
    row.img_path 가 base64 데이터URL이면 images/<id>.jpg 로 떼어내고
    자리에는 'local:<id>.jpg' 만 남긴다. 이게 «용량이 서버에서 빠지는» 지점.
    """
    v = row.get('img_path') or ''
    if not isinstance(v, str) or not v.startswith('data:image'):
        return row
    rid = str(row.get('id') or '')
    if not UUID_RE.match(rid):
        return row                      # 이름을 못 믿으면 건드리지 않는다
    try:
        head, b64 = v.split(',', 1)
        ext = 'png' if 'png' in head else 'jpg'
        name = rid + '.' + ext
        with open(os.path.join(IMG_DIR, name), 'wb') as f:
            f.write(base64.b64decode(b64))
        row['img_path'] = 'local:' + name
    except Exception:
        pass                            # 실패하면 base64인 채로 둔다 — 잃는 것보단 낫다
    return row


def drop_image(rid):
    if not UUID_RE.match(str(rid or '')):
        return
    for ext in ('jpg', 'png'):
        p = os.path.join(IMG_DIR, str(rid) + '.' + ext)
        if os.path.exists(p):
            try:
                os.remove(p)
            except Exception:
                pass


# ────────────────────────────────────────────────── 창구
def vault_get():
    return {'ok': True, 'rows': read_items()}


def vault_save(rows):
    if not isinstance(rows, list):
        rows = [rows]
    backup_once_a_day()
    cur = read_items()
    index = {r.get('id'): i for i, r in enumerate(cur) if isinstance(r, dict)}
    for r in rows:
        if not isinstance(r, dict) or not r.get('id'):
            continue
        r = stash_image(dict(r))
        if r['id'] in index:
            cur[index[r['id']]] = r
        else:
            index[r['id']] = len(cur)
            cur.append(r)
    write_json(ITEMS, cur)
    prune_backups()
    return {'ok': True, 'n': len(cur)}


def vault_del(ids):
    if not isinstance(ids, list):
        ids = [ids]
    backup_once_a_day()
    cur = read_items()
    gone = set(str(i) for i in ids)
    kept = [r for r in cur if isinstance(r, dict) and str(r.get('id')) not in gone]
    write_json(ITEMS, kept)
    for i in ids:
        drop_image(i)
    return {'ok': True, 'n': len(kept)}


def vault_import(rows):
    """
    서버에서 처음 내려온 짐 — 금고에 넣기 «전에» 받은 그대로 한 벌 따로 떠둔다.
    이사 중에 무슨 일이 나도 이 파일만 있으면 되돌린다.
    """
    if not isinstance(rows, list):
        rows = []
    stamp = datetime.datetime.now().strftime('%y%m%d-%H%M%S')
    dst = os.path.join(BAK_DIR, '서버이사-' + stamp + '.json')
    try:
        write_json(dst, rows)
    except Exception:
        pass
    r = vault_save(rows)
    r['backup'] = os.path.basename(dst)
    return r


def vault_inflate(ids):
    """
    회색지대로 내보낼 때만 부른다 — 'local:xxx.jpg' 를 다시 base64로 되돌려
    폰과 수강생도 볼 수 있게 «짐을 실어» 준다. 일이 끝나 회수되면 이 짐은 서버에서 사라진다.
    (사장님 말씀대로 «그때만 서버에 용량이 실리는» 자리가 정확히 여기다)
    """
    if not isinstance(ids, list):
        ids = [ids]
    want = set(str(i) for i in ids)
    out = []
    for r in read_items():
        if not isinstance(r, dict) or str(r.get('id')) not in want:
            continue
        r = dict(r)
        v = r.get('img_path') or ''
        if isinstance(v, str) and v.startswith('local:'):
            name = posixpath.basename(v[6:])
            p = os.path.join(IMG_DIR, name)
            try:
                with open(p, 'rb') as f:
                    b64 = base64.b64encode(f.read()).decode('ascii')
                mime = 'image/png' if name.endswith('.png') else 'image/jpeg'
                r['img_path'] = 'data:' + mime + ';base64,' + b64
            except Exception:
                r['img_path'] = ''      # 원본을 못 찾으면 그림 없이 보낸다
        for k in list(r.keys()):
            if k.startswith('_'):       # 금고 안에서만 쓰는 메모는 서버로 안 나간다
                del r[k]
        out.append(r)
    return {'ok': True, 'rows': out}


def bot_alive():
    import urllib.request
    try:
        urllib.request.urlopen(BOT_URL + '/', timeout=2)
        return True
    except Exception:
        return False


def vault_ping():
    rows = read_items()
    try:
        imgs = len([f for f in os.listdir(IMG_DIR) if not f.startswith('.')])
    except Exception:
        imgs = 0
    return {'ok': True, 'vault': VAULT, 'items': len(rows), 'images': imgs, 'port': PORT,
            'bot': bot_alive()}


# ────────────────────────────────────────────────── 링크 → 원고
YTDLP_PY = os.path.expanduser('~/Desktop/클로드앱/원고분해AI/_engine/.venv/bin/python')
BOT_URL = 'http://127.0.0.1:8765'
ORDERS = os.path.join(VAULT, '_분해대기.json')
_jobs = {}          # {id: {'state':'run|done|fail', 'msg':..., 'script':...}}


def _vtt_to_text(path):
    """자막 파일에서 «말한 것»만 남긴다 — 시간줄·태그·중복 제거."""
    try:
        with open(path, 'r', encoding='utf-8') as f:
            raw = f.read()
    except Exception:
        return ''
    out = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or '-->' in line:
            continue
        if line.startswith(('WEBVTT', 'Kind:', 'Language:', 'NOTE')):
            continue
        line = re.sub(r'<[^>]+>', '', line).strip()
        if line and (not out or out[-1] != line):
            out.append(line)
    return ' '.join(out).strip()


def _yt_script(url, workdir):
    """
    유튜브: 자막이 있으면 그걸 쓴다(몇 초). 없으면 빈 문자열을 돌려
    부르는 쪽이 받아쓰기로 넘어가게 한다.
    ⚠️ 자막을 연달아 받으면 유튜브가 429(요청 과다)를 준다 — 한 번에 한 편씩.
    """
    import subprocess
    meta = {}
    try:
        r = subprocess.run([YTDLP_PY, '-m', 'yt_dlp', '-J', '--skip-download', url],
                           capture_output=True, timeout=90)
        meta = json.loads(r.stdout.decode('utf-8', 'replace') or '{}')
    except Exception:
        meta = {}
    info = {
        'title': meta.get('title') or '',
        'views': meta.get('view_count') or '',
        'duration': meta.get('duration') or '',
        'thumb': meta.get('thumbnail') or '',
    }
    langs = list((meta.get('subtitles') or {}).keys()) + \
            list((meta.get('automatic_captions') or {}).keys())
    pick = ''
    for want in ('ko', 'ko-orig', 'en', 'en-orig'):
        if want in langs:
            pick = want
            break
    if not pick:
        return '', info
    try:
        subprocess.run([YTDLP_PY, '-m', 'yt_dlp', '--skip-download',
                        '--write-sub', '--write-auto-sub', '--sub-lang', pick,
                        '--sub-format', 'vtt', '-o', os.path.join(workdir, 'cap.%(ext)s'), url],
                       capture_output=True, timeout=120)
    except Exception:
        return '', info
    for f in sorted(os.listdir(workdir)):
        if f.endswith('.vtt'):
            t = _vtt_to_text(os.path.join(workdir, f))
            if t:
                return t, info
    return '', info


def _ig_script(url, job_id):
    """
    인스타 릴스 — 분해봇(8765)에 넘긴다. 오디오를 받아 받아쓰기까지 하므로 «분»이 걸린다.
    ⚠️ 분해봇이 꺼져 있으면 켜라고 말해준다(조용히 실패하지 않는다).
    """
    import urllib.request, urllib.error, time
    def post(path, body):
        req = urllib.request.Request(BOT_URL + path, data=json.dumps(body).encode(),
                                     headers={'Content-Type': 'application/json'})
        return json.loads(urllib.request.urlopen(req, timeout=20).read().decode())
    def get(path):
        return json.loads(urllib.request.urlopen(BOT_URL + path, timeout=20).read().decode())

    try:
        job = post('/analyze', {'url': url}).get('job_id')
    except urllib.error.URLError:
        _jobs[job_id] = {'state': 'fail',
                         'msg': '분해봇이 꺼져 있어요 — 바탕화면 «▶ 원고 분해 AI»를 켜주세요'}
        return '', {}
    except Exception as e:
        _jobs[job_id] = {'state': 'fail', 'msg': '분해봇이 거절했어요: ' + str(e)[:80]}
        return '', {}

    for _ in range(200):                    # 최대 10분 — 받아쓰기는 오래 걸린다
        time.sleep(3)
        try:
            st = get('/status/' + job)
        except Exception:
            continue
        stage = st.get('stage')
        _jobs[job_id] = {'state': 'run', 'msg': '분해봇: ' + str(stage or '작업 중')}
        if stage == 'done':
            r = st.get('result') or {}
            sc = (r.get('script') or '').strip()
            if not sc:
                _jobs[job_id] = {'state': 'fail', 'msg': '말소리가 없는 영상이에요 — 원고를 못 만듭니다'}
                return '', {}
            return sc, {'title': (r.get('caption') or '')[:90],
                        'views': r.get('manual_views') or '',
                        'thumb': r.get('thumb') or ''}
        if stage == 'error':
            _jobs[job_id] = {'state': 'fail', 'msg': '분해봇: ' + str(st.get('error') or '실패')[:90]}
            return '', {}
    _jobs[job_id] = {'state': 'fail', 'msg': '분해봇이 10분 안에 못 끝냈어요'}
    return '', {}


def _run_script_job(job_id, item_id, url):
    import tempfile, shutil as sh
    work = tempfile.mkdtemp(prefix='cme-')
    try:
        low = (url or '').lower()
        script, info = '', {}
        if 'youtu' in low:
            script, info = _yt_script(url, work)
            if not script:
                _jobs[job_id] = {'state': 'fail',
                                 'msg': '자막이 없는 영상이에요 — 받아쓰기가 필요합니다(분해봇)'}
                return
        else:
            script, info = _ig_script(url, job_id)
            if not script:
                return                      # 실패 사유는 _ig_script 가 이미 적었다
        rows = read_items()
        hit = None
        for r in rows:
            if isinstance(r, dict) and str(r.get('id')) == str(item_id):
                hit = r
                break
        if hit is None:
            _jobs[job_id] = {'state': 'fail', 'msg': '금고에서 그 항목을 못 찾았어요'}
            return
        # ⚠️ 원고는 최상위가 아니라 memo 안의 JSON에 들어간다(앱의 vmeta 규칙).
        #    memo가 JSON이 아닌 종류(음악=ytid)는 건드리지 않는다.
        meta = {}
        raw = hit.get('memo') or ''
        if raw:
            try:
                meta = json.loads(raw)
            except Exception:
                meta = {}
        if not isinstance(meta, dict):
            meta = {}
        if str(hit.get('type')) == 'video' or raw in ('', '{}') or meta:
            meta['script'] = script
            hit['memo'] = json.dumps(meta, ensure_ascii=False)
        else:
            hit['script'] = script      # 규칙을 모르는 종류는 최상위에 둔다
        if info.get('title') and not hit.get('title'):
            hit['title'] = info['title'][:90]
        if info.get('views') and not hit.get('views'):
            hit['views'] = info['views']
        vault_save([hit])
        _jobs[job_id] = {'state': 'done', 'msg': '원고 %d자' % len(script),
                         'chars': len(script), 'id': item_id}
    except Exception as e:
        _jobs[job_id] = {'state': 'fail', 'msg': str(e)}
    finally:
        try:
            sh.rmtree(work, ignore_errors=True)
        except Exception:
            pass


def script_start(item_id, url):
    import threading
    job_id = str(item_id) + '-' + datetime.datetime.now().strftime('%H%M%S')
    _jobs[job_id] = {'state': 'run', 'msg': '원고를 가져오는 중…'}
    threading.Thread(target=_run_script_job, args=(job_id, item_id, url), daemon=True).start()
    return {'ok': True, 'job': job_id}


# ────────────────────────────────────────────────── 📺 유튜브 창구
#   열쇠는 여기(서버)에만 있다. 앱·브라우저로는 절대 나가지 않는다.
#   손님은 «검색해주세요» 라고 부탁만 하고, 꺼내오는 건 이 창구가 한다.
#     · 장부  — 누가 몇 번 썼나 (하루 단위)
#     · 한도  — 한 사람 하루 N번 (관리자는 무제한)
#     · 미리 꺼내두기 — 같은 검색어는 다시 안 들어간다(점수도 한도도 안 깎임)
KEYS_FILE = os.path.expanduser('~/.컨모열쇠.json')
YT_CACHE = os.path.join(VAULT, '_유튜브캐시')
YT_LEDGER = os.path.join(VAULT, '_유튜브장부.json')
YT_CACHE_HOURS = 24
YT_COST = {'search': 100, 'videos': 1, 'channels': 1, 'commentThreads': 1, 'playlistItems': 1}


def keys_load():
    try:
        with open(KEYS_FILE, 'r', encoding='utf-8') as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def _today():
    return datetime.date.today().strftime('%y%m%d')


def ledger_load():
    try:
        with open(YT_LEDGER, 'r', encoding='utf-8') as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def ledger_bump(code, kind, units, cached=False):
    d = ledger_load()
    day = d.setdefault(_today(), {})
    row = day.setdefault(str(code or '?').upper(),
                         {'search': 0, 'calls': 0, 'units': 0, 'cached': 0})
    if cached:
        row['cached'] = row.get('cached', 0) + 1
    else:
        row['calls'] = row.get('calls', 0) + 1
        row['units'] = row.get('units', 0) + units
        if kind == 'search':
            row['search'] = row.get('search', 0) + 1
    for k in list(d.keys()):          # 30일 넘은 장부는 버린다
        if len(d) > 30 and k < _today():
            del d[k]
            break
    write_json(YT_LEDGER, d)
    return row


def is_admin(code):
    k = keys_load()
    return str(code or '').upper() in [str(x).upper() for x in (k.get('admin_codes') or [])]


def quota_left(code):
    if is_admin(code):
        return {'admin': True, 'used': ledger_load().get(_today(), {})
                .get(str(code or '?').upper(), {}).get('search', 0), 'left': None}
    lim = int(keys_load().get('daily_search_limit') or 10)
    used = ledger_load().get(_today(), {}).get(str(code or '?').upper(), {}).get('search', 0)
    return {'admin': False, 'used': used, 'left': max(0, lim - used), 'limit': lim}


def _cache_path(kind, params):
    import hashlib
    raw = kind + '|' + json.dumps(params, sort_keys=True, ensure_ascii=False)
    return os.path.join(YT_CACHE, hashlib.sha1(raw.encode('utf-8')).hexdigest() + '.json')


def _cache_get(kind, params):
    p = _cache_path(kind, params)
    try:
        age = (datetime.datetime.now() -
               datetime.datetime.fromtimestamp(os.path.getmtime(p))).total_seconds()
        if age > YT_CACHE_HOURS * 3600:
            return None
        with open(p, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return None


def _cache_put(kind, params, data):
    try:
        if not os.path.isdir(YT_CACHE):
            os.makedirs(YT_CACHE)
        write_json(_cache_path(kind, params), data)
    except Exception:
        pass


def yt_call(kind, params, code):
    """유튜브에 실제로 물어보는 유일한 자리."""
    import urllib.request, urllib.parse, urllib.error
    k = keys_load()
    key = k.get('youtube')
    if not key:
        return {'ok': False, 'msg': '열쇠가 없어요 — ~/.컨모열쇠.json 을 확인해주세요'}

    hit = _cache_get(kind, params)
    if hit is not None:
        ledger_bump(code, kind, 0, cached=True)
        return {'ok': True, 'cached': True, 'data': hit}

    if kind == 'search' and not is_admin(code):
        q = quota_left(code)
        if q['left'] <= 0:
            return {'ok': False, 'quota': True,
                    'msg': '오늘 검색을 %d번 다 쓰셨어요 — 내일 다시 채워집니다' % q['limit']}

    qs = dict(params)
    qs['key'] = key
    url = 'https://www.googleapis.com/youtube/v3/' + kind + '?' + urllib.parse.urlencode(qs)
    req = urllib.request.Request(url)
    # ⚠️ 열쇠에 «주소 제한»이 걸려 있어 어디서 왔는지를 밝혀야 통과된다
    ref = k.get('youtube_referer')
    if ref:
        req.add_header('Referer', ref)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            data = json.loads(r.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read().decode('utf-8'))
            msg = (body.get('error') or {}).get('message') or str(e)
        except Exception:
            msg = str(e)
        return {'ok': False, 'msg': msg, 'code': e.code}
    except Exception as e:
        return {'ok': False, 'msg': str(e)}

    _cache_put(kind, params, data)
    row = ledger_bump(code, kind, YT_COST.get(kind, 1))
    return {'ok': True, 'cached': False, 'data': data, 'today': row}


def yt_search(b):
    q = str(b.get('q') or '').strip()
    if not q:
        return {'ok': False, 'msg': '검색어를 넣어주세요'}
    order = b.get('order') or 'relevance'
    if order not in ('relevance', 'viewCount', 'date', 'rating'):
        order = 'relevance'
    return yt_call('search', {
        'part': 'snippet', 'type': 'video', 'regionCode': 'KR',
        'relevanceLanguage': 'ko', 'maxResults': 25, 'order': order, 'q': q,
    }, b.get('code'))


def yt_videos(b):
    ids = b.get('ids') or []
    if isinstance(ids, str):
        ids = [ids]
    ids = [str(i) for i in ids if re.match(r'^[A-Za-z0-9_-]{6,20}$', str(i))][:50]
    if not ids:
        return {'ok': False, 'msg': '영상 번호가 없어요'}
    return yt_call('videos', {
        'part': 'snippet,contentDetails,statistics', 'id': ','.join(ids),
    }, b.get('code'))


# ────────────────────────────────────────────────── 분해 주문서 → 클로드 부르기
def orders_read():
    try:
        with open(ORDERS, 'r', encoding='utf-8') as f:
            d = json.load(f)
        return d if isinstance(d, list) else []
    except Exception:
        return []


def order_add(ids, call=True):
    """
    «분해해줘» 버튼. 주문서를 금고에 적어두고, 클로드 앱을 띄우고,
    붙여넣을 한 줄을 클립보드에 담아둔다. 실제 분해는 클로드가 한다.
    ⚠️ 여기서 실행하는 명령은 «정해진 두 개»뿐이다 — 임의 명령은 절대 받지 않는다.
    """
    import subprocess
    if not isinstance(ids, list):
        ids = [ids]
    cur = orders_read()
    known = set(str(o.get('id')) for o in cur if isinstance(o, dict))
    stamp = datetime.datetime.now().isoformat(timespec='seconds')
    added = 0
    for i in ids:
        if str(i) in known:
            continue
        cur.append({'id': str(i), 'at': stamp, 'done': False})
        added += 1
    write_json(ORDERS, cur)
    waiting = len([o for o in cur if not o.get('done')])
    line = '컨모 금고에 분해 주문 %d건 밀렸어. ~/컨모금고/_분해대기.json 보고 전부 분해해줘' % waiting
    opened = False
    if call:
        try:
            subprocess.run(['pbcopy'], input=line.encode('utf-8'), timeout=5)
        except Exception:
            pass
        try:
            subprocess.run(['open', '-a', 'Claude'], timeout=10)
            opened = True
        except Exception:
            opened = False
    return {'ok': True, 'added': added, 'waiting': waiting,
            'opened': opened, 'line': line}


def order_clear(ids):
    if not isinstance(ids, list):
        ids = [ids]
    gone = set(str(i) for i in ids)
    cur = orders_read()
    for o in cur:
        if isinstance(o, dict) and str(o.get('id')) in gone:
            o['done'] = True
    write_json(ORDERS, cur)
    return {'ok': True, 'waiting': len([o for o in cur if not o.get('done')])}


# ────────────────────────────────────────────────── HTTP
class Handler(SimpleHTTPRequestHandler):

    # ⚠️ HTTP/1.0으로 답하면 서비스워커(sw.js) 등록이 거부된다 — 앱이 오프라인에서 안 열린다
    protocol_version = 'HTTP/1.1'

    def __init__(self, *a, **kw):
        SimpleHTTPRequestHandler.__init__(self, *a, directory=APP_DIR, **kw)

    def log_message(self, *a):
        pass                            # 터미널을 조용히 — 런처가 백그라운드로 띄운다

    # -- 도우미
    def _send_json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        try:
            n = int(self.headers.get('Content-Length') or 0)
            return json.loads(self.rfile.read(n).decode('utf-8')) if n else {}
        except Exception:
            return {}

    # -- 금고에 든 사진 내주기: /vault/img/<이름>
    def _serve_image(self, name):
        name = posixpath.basename(name)
        if not re.match(r'^[0-9a-fA-F-]{8,64}\.(jpg|png)$', name):
            return self.send_error(404)
        p = os.path.join(IMG_DIR, name)
        if not os.path.exists(p):
            return self.send_error(404)
        try:
            with open(p, 'rb') as f:
                data = f.read()
        except Exception:
            return self.send_error(404)
        self.send_response(200)
        self.send_header('Content-Type', 'image/png' if name.endswith('.png') else 'image/jpeg')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'max-age=31536000')
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith('/vault/img/'):
            return self._serve_image(self.path[len('/vault/img/'):].split('?')[0])
        if self.path.split('?')[0] == '/vault/ping':
            return self._send_json(vault_ping())
        if self.path.split('?')[0] == '/vault/get':
            return self._send_json(vault_get())
        if self.path.startswith('/vault/job/'):
            jid = self.path[len('/vault/job/'):].split('?')[0]
            return self._send_json(_jobs.get(jid) or {'state': 'fail', 'msg': '없는 작업'})
        if self.path.split('?')[0] == '/vault/yt/quota':
            import urllib.parse as _up
            qs = _up.parse_qs(self.path.split('?')[1] if '?' in self.path else '')
            return self._send_json(quota_left((qs.get('code') or [''])[0]))
        if self.path.split('?')[0] == '/vault/ledger':
            return self._send_json({'ok': True, 'today': _today(),
                                    'rows': ledger_load().get(_today(), {})})
        if self.path.split('?')[0] == '/vault/orders':
            cur = orders_read()
            return self._send_json({'ok': True, 'waiting': [o for o in cur if not o.get('done')]})
        return SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        path = self.path.split('?')[0]
        try:
            if path == '/vault/save':
                return self._send_json(vault_save(self._body().get('rows')))
            if path == '/vault/del':
                return self._send_json(vault_del(self._body().get('ids')))
            if path == '/vault/import':
                return self._send_json(vault_import(self._body().get('rows')))
            if path == '/vault/script':
                b = self._body()
                return self._send_json(script_start(b.get('id'), b.get('url')))
            if path == '/vault/yt/search':
                return self._send_json(yt_search(self._body()))
            if path == '/vault/yt/videos':
                return self._send_json(yt_videos(self._body()))
            if path == '/vault/order':
                b = self._body()
                return self._send_json(order_add(b.get('ids'), b.get('call', True)))
            if path == '/vault/order-clear':
                return self._send_json(order_clear(self._body().get('ids')))
            if path == '/vault/inflate':
                return self._send_json(vault_inflate(self._body().get('ids')))
        except Exception as e:
            return self._send_json({'ok': False, 'msg': str(e)}, 500)
        self.send_error(404)


if __name__ == '__main__':
    ensure_vault()
    print('🗄  금고: ' + VAULT)
    print('🌐 http://localhost:%d/index.html' % PORT)
    ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
