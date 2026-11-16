"""The gatekeeper's fixed rules (homelab-private: plans/automation-design.md → Gatekeeper).

Pure functions, no network: what a diff changes, whether a change is low-risk or fast-lane
only, and the release record. The gatekeeper (gatekeeper.py) feeds them from Forgejo's API,
the registries and the canary's Prometheus. Standard library only.
"""
import re, subprocess, tempfile, os

COMPOSE_RE = re.compile(r'^services/([A-Za-z0-9_.-]+)/(docker-compose\.yml|compose\.[A-Za-z0-9_.-]+\.yml)$')
IMAGE_RE = re.compile(r'^(\s*image:\s*["\']?)([^\s"\'#]*?)\$\{([A-Z0-9_]+):-([^}]+)\}([^\s"\'#]*)(["\']?\s*(#.*)?)$')
DIGEST_RE = re.compile(r'^(?P<tag>[^@]+)@(?P<digest>sha256:[0-9a-f]{64})$')


def parse_diff(diff):
    """Unified diff (git diff -U0) → {file: [(removed lines), (added lines)]}."""
    files, cur = {}, None
    for line in diff.splitlines():
        if line.startswith('diff --git '):
            cur = None
        elif line.startswith('+++ '):
            path = line[4:]
            cur = path[2:] if path.startswith('b/') else path
            files.setdefault(cur, ([], []))
        elif line.startswith('--- '):
            path = line[4:]
            if path != '/dev/null' and cur is None:
                files.setdefault(path[2:] if path.startswith('a/') else path, ([], []))
        elif cur and line.startswith('-') and not line.startswith('---'):
            files[cur][0].append(line[1:])
        elif cur and line.startswith('+') and not line.startswith('+++'):
            files[cur][1].append(line[1:])
    return files


def version_changes(diff):
    """If the diff changes nothing but image version defaults (${X_VERSION:-tag@digest}) in
    compose files, return [(service, image, old, new)]; else raise ValueError(why)."""
    out = []
    files = parse_diff(diff)
    if not files: raise ValueError('an empty change')
    for path, (rem, add) in files.items():
        m = COMPOSE_RE.match(path)
        if not m: raise ValueError(f'{path}: not a compose file')
        if len(rem) != len(add): raise ValueError(f'{path}: lines added or removed, not only changed')
        for old, new in zip(rem, add):
            a, b = IMAGE_RE.match(old), IMAGE_RE.match(new)
            if not a or not b: raise ValueError(f'{path}: a change that is not an image version: {new.strip()[:80]}')
            if (a.group(1), a.group(2), a.group(3), a.group(5), a.group(6)) != (b.group(1), b.group(2), b.group(3), b.group(5), b.group(6)):
                raise ValueError(f'{path}: more than the version changed: {new.strip()[:80]}')
            if not DIGEST_RE.match(b.group(4)): raise ValueError(f'{path}: the new version has no digest: {b.group(4)}')
            (rn, ot), (rn2, nt) = image_name(a.group(4)), image_name(b.group(4))
            # the whole image in the variable (${X_IMAGE:-registry/repo:tag@digest}): a version
            # change keeps the registry and repo; with a prefix, the default is only a tag
            if rn != rn2: raise ValueError(f'{path}: the image itself changed ({rn or "a tag"} → {rn2 or "a tag"}), not only its version')
            if rn and b.group(2): raise ValueError(f'{path}: an image name both before and inside the variable')
            img = (rn + ':' if rn else b.group(2)) + '{' + b.group(3) + '}'
            out.append((m.group(1), img, ot, nt))
    return out


def image_name(v):
    """'registry/repo:tag@digest' → ('registry/repo', 'tag@digest'); a bare 'tag@digest' → ('', it)."""
    ref, at, dig = v.partition('@')
    if '/' not in ref and ':' not in ref: return '', v
    name, colon, tag = ref.rpartition(':')
    if not colon or '/' in tag: return ref, ''       # no tag (or a registry port only)
    return name, tag + at + dig


def step(old, new):
    """'major', 'minor', 'patch' or 'other' between two tags (digests aside); 'digest' when only
    the digest moved (e.g. a major-line tag like v3 or 16-alpine)."""
    to = lambda v: v.split('@', 1)[0]
    a, b = to(old), to(new)
    if a == b: return 'digest'
    na = [int(x) for x in re.findall(r'\d+', a)][:3]; nb = [int(x) for x in re.findall(r'\d+', b)][:3]
    if not na or not nb: return 'other'
    if re.sub(r'[\d.]', '', a) != re.sub(r'[\d.]', '', b): return 'other'   # e.g. -alpine → -bookworm
    if na[0] != nb[0]: return 'major'
    if na[1:2] != nb[1:2]: return 'minor'
    return 'patch'


def low_risk(changes, groups):
    """Renovate's version-only PR merged without you? auto services: patch or minor (or a digest
    of the same tag); prepared: any step (you deploy them); byhand or unlisted: never.
    Returns (True, '') or (False, why)."""
    group_of = {s: g for g in ('auto', 'prepared', 'byhand') for s in groups.get(g, [])}
    for svc, img, old, new in changes:
        g = group_of.get(svc, 'byhand')
        st = step(old, new)
        if g == 'byhand': return False, f'{svc} is by hand'
        if g == 'auto' and st not in ('patch', 'minor', 'digest'): return False, f'{svc}: a {st} step of an auto service needs you'
    return True, ''


def fast_lane_only(changed, fast_lane):
    """Do the changed homelab-config files all belong to the fast lane (guests/<g>/<svc>/<path>
    with <path> in policy/fast-lane.yml)? changed: paths; fast_lane: {svc: [paths]}."""
    if not changed: return False
    for p in changed:
        parts = p.split('/', 3)
        if len(parts) != 4 or parts[0] != 'guests' or parts[3] not in fast_lane.get(parts[2], []): return False
    return True


def byhand_only(changed, groups):
    """Do the changed homelab files all belong to by-hand templates (services/<svc>/… with <svc>
    in neither auto nor prepared: unlisted counts as by hand)? No guest applies those by itself,
    so the canary can't prove anything about them. changed: paths; groups: {group: [svc]}."""
    if not changed: return False
    synced = set(groups.get('auto', [])) | set(groups.get('prepared', []))
    for p in changed:
        parts = p.split('/', 2)
        if len(parts) < 3 or parts[0] != 'services' or not parts[1] or parts[1] in synced: return False
    return True


def glob_re(pat):
    """A path pattern: * and ? within one directory, ** across directories (**/ also none)."""
    out, i = '', 0
    while i < len(pat):
        if pat.startswith('**/', i): out += '(?:.*/)?'; i += 3
        elif pat.startswith('**', i): out += '.*'; i += 2
        elif pat[i] == '*': out += '[^/]*'; i += 1
        elif pat[i] == '?': out += '[^/]'; i += 1
        else: out += re.escape(pat[i]); i += 1
    return re.compile(out + '$')


def display_only(path, display):
    """Is this homelab file display only (homelab-config policy/display.yml: dashboards, docs)? A
    mistake there shows at once and breaks no service. display: {'all': [patterns on the repo path],
    <svc>: [patterns inside services/<svc>/]}."""
    if any(glob_re(p).match(path) for p in display.get('all', [])): return True
    parts = path.split('/', 2)
    return len(parts) == 3 and parts[0] == 'services' and \
        any(glob_re(p).match(parts[2]) for p in display.get(parts[1], []) if parts[1] != 'all')


def quick_lane(changed, groups, display):
    """Can the canary prove nothing about these homelab changes? Each is display only or in a by-hand
    template. Returns '' (no: the canary) or the lane's name. changed: paths; groups: {group: [svc]}."""
    if not changed: return ''
    if all(display_only(p, display) for p in changed): return 'display'
    if all(display_only(p, display) or byhand_only([p], groups) for p in changed): return 'by-hand'
    return ''


def record_text(stage, seq, homelab, config, wave, when):
    for sha in (homelab, config):
        if not re.match(r'^[0-9a-f]{40}$', sha): raise ValueError(f'not a commit id: {sha}')
    return f'stage={stage}\nseq={seq}\nhomelab={homelab}\nconfig={config}\nwave={wave}\ntime={when}\n'


def sign(text, key):
    """The gatekeeper's signature (ssh-keygen -Y sign, namespace labber-release)."""
    with tempfile.TemporaryDirectory() as d:
        f = os.path.join(d, 'record')
        with open(f, 'w') as h: h.write(text)
        subprocess.run(['ssh-keygen', '-q', '-Y', 'sign', '-f', key, '-n', 'labber-release', f], check=True, capture_output=True)
        with open(f + '.sig') as h: return h.read()
