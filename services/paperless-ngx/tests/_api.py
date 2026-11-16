# Shared by seed and check: Paperless's API with the admin account from .env (run from the service folder).
import base64, json, os, time, urllib.request, urllib.error

def env():
    e = {}
    for line in open('.env'):
        if '=' in line and not line.lstrip().startswith('#'):
            k, v = line.rstrip('\n').split('=', 1); e[k] = v.strip().strip("'\"")
    return e

E = env()
BASE = f"http://localhost:{E.get('PORT', '8075')}/api"
AUTH = 'Basic ' + base64.b64encode(f"{E['PAPERLESS_ADMIN_USER']}:{E['PAPERLESS_ADMIN_PASSWORD']}".encode()).decode()

def call(path, data=None, ctype=None, method=None):
    h = {'Authorization': AUTH, 'Accept': 'application/json'}
    if ctype: h['Content-Type'] = ctype
    req = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read()
        return json.loads(body) if body else None

def wait_ready(timeout=300):
    end = time.time() + timeout
    while time.time() < end:
        try: call('/documents/?page_size=1'); return
        except Exception: time.sleep(5)
    raise SystemExit('paperless API not ready')

def pdf(text):
    """A minimal one-page text PDF (test data)."""
    stream = f"BT /F1 18 Tf 72 720 Td ({text}) Tj ET".encode()
    objs = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    out, offs = b"%PDF-1.4\n", []
    for i, o in enumerate(objs, 1):
        offs.append(len(out)); out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    x = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1) + b"".join(b"%010d 00000 n \n" % o for o in offs)
    return out + b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
