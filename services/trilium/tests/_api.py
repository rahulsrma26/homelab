# Shared by seed and check: Trilium's ETAPI (run from the service folder).
import json, os, time, urllib.request, urllib.parse

def env():
    e = {}
    for line in open('.env'):
        if '=' in line and not line.lstrip().startswith('#'):
            k, v = line.rstrip('\n').split('=', 1); e[k] = v.strip().strip("'\"")
    return e

E = env()
BASE = f"http://localhost:{E.get('PORT', '8085')}"
TOKEN_FILE = '.labber-test-token'   # written by seed on a test instance only

def req(path, data=None, headers=None, method=None):
    r = urllib.request.Request(BASE + path, data=data, headers=headers or {}, method=method)
    with urllib.request.urlopen(r, timeout=30) as resp:
        body = resp.read(); return json.loads(body) if body[:1] in (b'{', b'[') else body

def token():
    # a token you created in Trilium (Options → ETAPI) for a real instance, else seed's
    if E.get('TRILIUM_ETAPI_TOKEN'): return E['TRILIUM_ETAPI_TOKEN']
    return open(TOKEN_FILE).read().strip() if os.path.exists(TOKEN_FILE) else None

def etapi(path, body=None, method=None):
    h = {'Authorization': token(), 'Content-Type': 'application/json'}
    return req('/etapi' + path, json.dumps(body).encode() if body is not None else None, h, method)

def wait_ready(timeout=180):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if req('/api/health-check').get('status') == 'ok': return
        except Exception: pass
        time.sleep(3)
    raise SystemExit('trilium not ready')
