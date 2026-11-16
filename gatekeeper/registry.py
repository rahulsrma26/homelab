"""What digest a registry has for an image tag: a HEAD on the manifest (registry v2 API), with an
anonymous token where the registry asks for one. A HEAD doesn't count against Docker Hub's pull
limit. Standard library only."""
import json, re, urllib.request, urllib.error

ACCEPT = ', '.join(['application/vnd.oci.image.index.v1+json', 'application/vnd.docker.distribution.manifest.list.v2+json',
                    'application/vnd.oci.image.manifest.v1+json', 'application/vnd.docker.distribution.manifest.v2+json'])

def split(ref):
    name, tag = ref.rsplit(':', 1)
    first = name.split('/')[0]
    if '.' in first or ':' in first or first == 'localhost': reg, repo = first, name.split('/', 1)[1]
    else: reg, repo = 'registry-1.docker.io', (name if '/' in name else 'library/' + name)
    if reg == 'docker.io': reg = 'registry-1.docker.io'
    return reg, repo, tag

def _head(url, tok=None):
    h = {'Accept': ACCEPT}
    if tok: h['Authorization'] = 'Bearer ' + tok
    return urllib.request.urlopen(urllib.request.Request(url, method='HEAD', headers=h), timeout=20)

def digest(ref):
    reg, repo, tag = split(ref)
    url = f'https://{reg}/v2/{repo}/manifests/{tag}'
    try: r = _head(url)
    except urllib.error.HTTPError as e:
        if e.code != 401: raise
        p = dict(re.findall(r'(\w+)="([^"]*)"', e.headers.get('WWW-Authenticate', '')))
        q = f"{p['realm']}?service={p.get('service', '')}&scope=repository:{repo}:pull"
        with urllib.request.urlopen(q, timeout=20) as t: tok = json.load(t)
        r = _head(url, tok.get('token') or tok.get('access_token'))
    d = r.headers.get('Docker-Content-Digest') or ''
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', d): raise ValueError(f'no digest in the reply for {ref}')
    return d
