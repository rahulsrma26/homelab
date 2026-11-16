# n8n's REST API for the template's tests (standard library only): the instance in the current
# folder (its .env), a cookie session like the editor's.
import http.cookiejar, json, os, time, urllib.request, urllib.error

def env(key, default=''):
    try:
        for line in open('.env'):
            if line.startswith(key + '='): return line.split('=', 1)[1].strip().strip('"\'')
    except FileNotFoundError: pass
    return default

BASE = f"http://127.0.0.1:{env('PORT', '5678')}"
OWNER = {'email': 'labseed@example.test', 'firstName': 'Lab', 'lastName': 'Seed', 'password': 'Labseed-Test-1234'}
_jar = http.cookiejar.CookieJar()
_open = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_jar)).open

def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method, headers={'Content-Type': 'application/json'})
    try:
        with _open(r, timeout=30) as h:
            raw = h.read()
            return h.status, (json.loads(raw) if raw[:1] in (b'{', b'[') else raw.decode())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:300]

def wait_ready(seconds=180):
    end = time.time() + seconds
    while time.time() < end:
        try:
            if req('GET', '/healthz/readiness')[0] == 200: return     # /healthz answers while it still migrates
        except OSError: pass
        time.sleep(3)
    raise SystemExit('n8n did not get ready (/healthz/readiness)')

def login():
    st, out = req('POST', '/rest/login', {'emailOrLdapLoginId': OWNER['email'], 'password': OWNER['password']})
    if st != 200: raise SystemExit(f'login: {st} {out}')

def data(out): return out.get('data', out) if isinstance(out, dict) else out
