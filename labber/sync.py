#!/usr/bin/env python3
"""labber sync: follow a release on an enrolled guest (homelab-private: plans/labber-design.md).

Run by `labber sync …` as root. Standard library only. The order of every run:
  1. fetch the release record for this guest's stage and check the gatekeeper's signature,
     the stage, and that its sequence never goes back
  2. fetch both repos and check that every new first-parent commit carries Forgejo's
     signature and that both move only forward from what this guest has
  3. take the guest's lock, then act per service: auto ones in the night window (labber
     update with rollback on failure), prepared ones only marked ready (images pulled),
     per-guest files (the fast lane) at once; byhand and unlisted ones never
  4. write metrics for Alloy
Nothing here creates commits, touches .env, SSH, the firewall or its own settings.
"""
import argparse, datetime, fcntl, grp, json, os, re, shutil, subprocess, sys, tempfile, time

CONF = os.environ.get('LABBER_SYNC_CONF', '/etc/labber/sync.conf')
SIGNERS = os.environ.get('LABBER_SYNC_SIGNERS', '/etc/labber/allowed_signers')          # Forgejo: commits
RELEASE_SIGNERS = os.environ.get('LABBER_SYNC_RELEASE_SIGNERS', '/etc/labber/release_signers')  # gatekeeper: records
STATE = os.environ.get('LABBER_SYNC_STATE', '/var/lib/labber/sync')
METRICS = os.environ.get('LABBER_SYNC_METRICS', '/var/lib/labber/metrics/labber_sync.prom')
LOCK = os.environ.get('LABBER_SYNC_LOCK', '/run/lock/labber-sync')
LABBER = os.environ.get('LABBER_BIN', '/usr/local/bin/labber')
SERVICE_BASE = os.environ.get('LABBER_SERVICE_BASE', '/opt/homelab/services')
RECORD_NAMESPACE = 'labber-release'
RELEASES_BRANCH = 'releases'
FLEET_WIDE = {'base-utils'}          # with labber itself: reach wave 1 (apps) first
SHA_RE = re.compile(r'^[0-9a-f]{40}$')


class SyncError(Exception):
    """A refusal: something didn't verify. Critical; nothing is applied."""


# ── small helpers ──────────────────────────────────────────────────────────────

def run(cmd, cwd=None, check=True, env=None, input=None, timeout=None):
    try: p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env, input=input, timeout=timeout)
    except subprocess.TimeoutExpired: raise RuntimeError(f"{' '.join(cmd)}: no answer for {timeout}s")
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)}: {(p.stderr or p.stdout).strip()[-300:]}")
    return p

GIT_TIMEOUT = 600     # a hanging Forgejo (accepts, never answers) must not stall sync for good
def git(repo, *args, check=True):
    return run(['git', '-c', f'safe.directory={repo}', '-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=60',
                '-C', repo, *args], check=check, timeout=GIT_TIMEOUT)

def read_kv(path):
    out = {}
    if os.path.exists(path):
        for line in rtext(path).splitlines():
            line = line.split('#', 1)[0].strip()
            if '=' in line:
                k, v = line.split('=', 1); out[k.strip()] = v.strip()
    return out

def load_json(name, default):
    p = os.path.join(STATE, name)
    try:
        with open(p) as f: return json.load(f)
    except (OSError, ValueError): return default

def save_json(name, data):
    os.makedirs(STATE, exist_ok=True)
    p = os.path.join(STATE, name); tmp = p + '.tmp'
    with open(tmp, 'w') as f: json.dump(data, f, indent=1, sort_keys=True)
    os.replace(tmp, p)

def ylists(text):
    """The YAML subset homelab-config uses: 'key: [a, b]' lines (comments allowed)."""
    out = {}
    for line in text.splitlines():
        line = line.split('#', 1)[0].rstrip()
        m = re.match(r'^([A-Za-z0-9_.-]+):\s*\[(.*)\]\s*$', line)
        if m: out[m.group(1)] = [x.strip().strip('"\'') for x in m.group(2).split(',') if x.strip()]
    return out

def log(msg): print(msg, flush=True)

def wtext(path, text):
    with open(path, 'w') as f: f.write(text)

def rtext(path):
    with open(path) as f: return f.read()


# ── the release record ─────────────────────────────────────────────────────────

def parse_record(text):
    rec = {}
    for line in text.splitlines():
        if '=' in line:
            k, v = line.split('=', 1); rec[k.strip()] = v.strip()
    for k in ('stage', 'seq', 'homelab', 'config', 'wave'):
        if k not in rec: raise SyncError(f'release record without {k}')
    if not rec['seq'].isdigit() or not rec['wave'].isdigit(): raise SyncError('release record: seq/wave not numbers')
    if not SHA_RE.match(rec['homelab']) or not SHA_RE.match(rec['config']): raise SyncError('release record: bad commit id')
    rec['seq'] = int(rec['seq']); rec['wave'] = int(rec['wave'])
    return rec

def verify_record(text, sig, signers=None):
    """True only if the gatekeeper's key signed exactly this text, in our namespace."""
    signers = signers or RELEASE_SIGNERS
    with tempfile.TemporaryDirectory() as d:
        s = os.path.join(d, 'record.sig'); wtext(s, sig)
        p = run(['ssh-keygen', '-Y', 'verify', '-f', signers, '-I', 'gatekeeper', '-n', RECORD_NAMESPACE, '-s', s],
                check=False, input=text)
    return p.returncode == 0

def check_record(rec, stage, last_seq):
    if rec['stage'] != stage: raise SyncError(f"release record is for stage {rec['stage']}, this guest follows {stage}")
    if last_seq is not None and rec['seq'] < last_seq:
        raise SyncError(f"release record {rec['seq']} is older than the last one seen ({last_seq}): refused")


# ── commits: Forgejo's signature, forward only ─────────────────────────────────

def verify_commit(repo, sha, signers=None):
    signers = signers or SIGNERS
    p = git(repo, '-c', 'gpg.format=ssh', '-c', f'gpg.ssh.allowedSignersFile={signers}', 'verify-commit', sha, check=False)
    return p.returncode == 0

def verify_range(repo, old, new, signers=None):
    """Every first-parent commit after old up to new is signed; new descends from old."""
    if old:
        if git(repo, 'merge-base', '--is-ancestor', old, new, check=False).returncode != 0:
            raise SyncError(f'{os.path.basename(repo)}: {new[:12]} does not descend from {old[:12]} (a backwards or sideways move): refused')
        commits = git(repo, 'rev-list', '--first-parent', f'{old}..{new}').stdout.split()
    else:
        commits = [new]                       # first enrolment: the head itself
    for c in commits:
        if not verify_commit(repo, c, signers):
            raise SyncError(f'{os.path.basename(repo)}: commit {c[:12]} is not signed by Forgejo: refused')
    return len(commits)


# ── fetching ───────────────────────────────────────────────────────────────────

def ensure_clone(url, path):
    if not os.path.isdir(os.path.join(path, '.git')):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        run(['git', '-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=60', 'clone', '-q', '--no-checkout', url, path], timeout=GIT_TIMEOUT)
    else:
        git(path, 'remote', 'set-url', 'origin', url)

def fetch_commit(repo, sha, branches):
    for b in branches:
        git(repo, 'fetch', '-q', 'origin', f'+refs/heads/{b}:refs/remotes/origin/{b}', check=False)
        if git(repo, 'cat-file', '-e', f'{sha}^{{commit}}', check=False).returncode == 0: return
    raise SyncError(f'{os.path.basename(repo)}: commit {sha[:12]} not found on {", ".join(branches)}')

def fetch_record(config_repo, stage):
    git(config_repo, 'fetch', '-q', 'origin', f'+refs/heads/{RELEASES_BRANCH}:refs/remotes/origin/{RELEASES_BRANCH}')
    ref = f'refs/remotes/origin/{RELEASES_BRANCH}'
    text = git(config_repo, 'show', f'{ref}:{stage}.txt').stdout
    sig = git(config_repo, 'show', f'{ref}:{stage}.txt.sig').stdout
    return text, sig


# ── the release tree labber installs from ──────────────────────────────────────

def build_tree(homelab_repo, config_repo, rec):
    """Check out the pair; private templates from homelab-config join services/ (a name in only one)."""
    git(homelab_repo, 'checkout', '-q', '--force', '--detach', rec['homelab'])
    git(homelab_repo, 'clean', '-q', '-fdx')
    git(config_repo, 'checkout', '-q', '--force', '--detach', rec['config'])
    git(config_repo, 'clean', '-q', '-fdx')
    priv = os.path.join(config_repo, 'services')
    if os.path.isdir(priv):
        for name in sorted(os.listdir(priv)):
            src = os.path.join(priv, name)
            if not os.path.isdir(src): continue
            dst = os.path.join(homelab_repo, 'services', name)
            if os.path.exists(dst): raise SyncError(f'template {name} exists in both repos: refused')
            shutil.copytree(src, dst)

def tree_id(repo, sha, path):
    p = git(repo, 'rev-parse', f'{sha}:{path}', check=False)
    return p.stdout.strip() if p.returncode == 0 else None


# ── what this guest should do ──────────────────────────────────────────────────

def plan(host, config_repo, homelab_repo, rec, canary):
    guests = ylists(rtext(os.path.join(config_repo, 'guests.yml')))
    groups = ylists(rtext(os.path.join(config_repo, 'policy', 'groups.yml')))
    group_of = {s: g for g in ('auto', 'prepared', 'byhand') for s in groups.get(g, [])}
    svcs = list(guests.get(host, []))
    on_demand = set(guests.get('canary-on-demand', [])) if canary else set()
    out = []
    for s in svcs + sorted(on_demand - set(svcs)):
        tpl = tree_id(homelab_repo, rec['homelab'], f'services/{s}') or tree_id(config_repo, rec['config'], f'services/{s}')
        files = tree_id(config_repo, rec['config'], f'guests/{host}/{s}')
        g = 'auto' if canary and group_of.get(s) in ('auto', 'prepared') else group_of.get(s, 'byhand')
        out.append({'svc': s, 'group': g, 'template': tpl, 'files': files, 'on_demand': s in on_demand})
    return out

def in_wave(conf, rec):
    """The guest's wave has come (labber itself, fleet-wide services). The canary is always in:
    it runs every release first, whatever wave= its enrolment says."""
    if conf.get('canary') == 'yes': return True
    return int(conf.get('wave', '1')) <= rec['wave']

def in_window(conf, now=None):
    w = conf.get('window', '04:00-05:00')
    if w == 'always': return True
    now = now or datetime.datetime.now(datetime.timezone.utc)
    a, b = w.split('-')
    t = now.strftime('%H:%M')
    if a <= b: return a <= t < b
    return t >= a or t < b                    # across midnight, e.g. 23:00-01:00

def missing_settings(svc_dir, release_dir):
    """Keys the new .env.example needs an answer for ({{ name }} without a default) that
    the instance's .env doesn't have: sync never invents a value."""
    ex = os.path.join(release_dir, '.env.example'); env = os.path.join(svc_dir, '.env')
    if not os.path.exists(ex) or not os.path.exists(env): return []
    have = set(read_kv(env)); need = []
    for line in rtext(ex).splitlines():
        if '=' not in line or line.lstrip().startswith('#'): continue
        k, v = line.split('=', 1)
        if k.strip() in have: continue
        # every placeholder without a default needs you (a generated secret too: never invented here)
        if any('default(' not in m for m in re.findall(r'\{\{([^}]*)\}\}', v)): need.append(k.strip())
    return need


# ── actions (through labber, which owns the compose side) ───────────────────────

def labber(*args, source=None):
    env = dict(os.environ)
    if source: env['LABBER_SOURCE'] = source
    env['LABBER_SYNC_LOCKED'] = '1'          # this run holds the guest's lock
    env.pop('LABBER_REF', None)
    p = subprocess.run([LABBER, *args], capture_output=True, text=True, env=env, stdin=subprocess.DEVNULL)
    return p.returncode, (p.stdout + p.stderr)[-2000:]

def installed(svc): return os.path.isdir(os.path.join(SERVICE_BASE, svc))

def allowed_files(config_repo, svc):
    p = os.path.join(config_repo, 'policy', 'allow', f'{svc}.yml')
    return {l[2:].strip() for l in rtext(p).splitlines() if l.startswith('- ')} if os.path.exists(p) else set()

def instance_matches(svc, release_dir, skip=()):
    """Is the installed instance already this release's template? labber records the sha256 of
    every template file it installed (.labber-base), so your own edits don't count; per-guest
    files and .env aside. True after an update by hand too."""
    import hashlib
    inst = os.path.join(SERVICE_BASE, svc)
    rel_files = {}
    for root, dirs, files in os.walk(release_dir):
        dirs[:] = [d for d in dirs if d != '.git']
        for f in files:
            rel = os.path.relpath(os.path.join(root, f), release_dir)
            if rel in skip or rel in ('.env', '.labber-base'): continue
            with open(os.path.join(root, f), 'rb') as h: rel_files[rel] = hashlib.sha256(h.read()).hexdigest()
    base_file = os.path.join(inst, '.labber-base')
    if os.path.exists(base_file):
        base = {}
        for line in rtext(base_file).splitlines():
            if '  ' in line:
                digest, name = line.split('  ', 1); base[name] = digest
        base = {k: v for k, v in base.items() if k not in skip}
        return base == rel_files
    for rel, digest in rel_files.items():                     # no record: compare the files themselves
        mine = os.path.join(inst, rel)
        if not os.path.isfile(mine): return False
        with open(mine, 'rb') as h:
            if hashlib.sha256(h.read()).hexdigest() != digest: return False
    return True

def moved_dirs(inst):
    """A template's folder setting that defaults to ./<dir> ({{ x | default(./config) }}) but that
    this guest's .env points elsewhere (HOMEPAGE_CONFIG=/mnt/apps/homepage/config): <dir> → there,
    so per-guest files land where the service reads them."""
    ex = os.path.join(inst, '.env.example'); env = read_kv(os.path.join(inst, '.env'))
    out = {}
    if not os.path.exists(ex): return out
    for line in rtext(ex).splitlines():
        m = re.match(r'^\s*([A-Za-z0-9_]+)=\{\{[^}]*default\(\./([^)/]+)/?\)[^}]*\}\}\s*$', line)
        if not m: continue
        var, d = m.groups(); v = env.get(var, '').strip('"\'')
        if v and v.rstrip('/') not in (f'./{d}', d):
            out[d] = v if os.path.isabs(v) else os.path.normpath(os.path.join(inst, v))
    return out

def write_files(host, svc, config_repo):
    """Per-guest files over the instance (only those policy/allow lists); returns the backups."""
    allow = os.path.join(config_repo, 'policy', 'allow', f'{svc}.yml')
    allowed = [l[2:].strip() for l in rtext(allow).splitlines() if l.startswith('- ')] if os.path.exists(allow) else []
    src_root = os.path.join(config_repo, 'guests', host, svc)
    dst_root = os.path.join(SERVICE_BASE, svc)
    moved = moved_dirs(dst_root)
    backups = {}
    for root, _, files in os.walk(src_root):
        for f in files:
            rel = os.path.relpath(os.path.join(root, f), src_root)
            if rel not in allowed: raise SyncError(f'guests/{host}/{svc}/{rel} is not allowed by policy/allow/{svc}.yml: refused')
            top, _, rest = rel.partition('/')
            dst = os.path.join(moved[top], rest) if rest and top in moved else os.path.join(dst_root, rel)
            if os.path.exists(dst):
                with open(dst, 'rb') as h: backups[dst] = h.read()
            else: backups[dst] = None
            safe_copy(os.path.join(root, f), dst, moved.get(top) if rest and top in moved else dst_root)
    return backups

def safe_copy(src, dst, top):
    """Copy as root without following a link someone planted: the folder must resolve inside top,
    the temporary file is created fresh (O_EXCL, no-follow), and the rename replaces a link at dst."""
    d = os.path.dirname(dst)
    os.makedirs(d, exist_ok=True)
    real_top, real_d = os.path.realpath(top), os.path.realpath(d)
    if real_d != real_top and not real_d.startswith(real_top + os.sep):
        raise SyncError(f'{dst}: its folder leads outside {top} (a symlink): refused')
    tmp = dst + '.labber-new'
    if os.path.lexists(tmp): os.unlink(tmp)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, 'wb') as out, open(src, 'rb') as inp: shutil.copyfileobj(inp, out)
    shutil.copymode(src, tmp)
    os.replace(tmp, dst)

def restore_files(backups):
    for dst, data in backups.items():
        if data is None:
            try: os.remove(dst)
            except FileNotFoundError: pass
        else:
            with open(dst, 'wb') as h: h.write(data)


# ── one run ────────────────────────────────────────────────────────────────────

def sync_run(conf, apply_now=False):
    stage, host = conf['stage'], conf['host']
    canary = conf.get('canary') == 'yes'
    hl = os.path.join(STATE, 'repos', 'homelab'); cf = os.path.join(STATE, 'repos', 'homelab-config')
    ensure_clone(conf['homelab'], hl); ensure_clone(conf['config'], cf)
    cur = load_json('current.json', {})

    text, sig = fetch_record(cf, stage)
    if not verify_record(text, sig): raise SyncError('release record: the gatekeeper signature does not verify: refused')
    rec = parse_record(text)
    check_record(rec, stage, cur.get('seq'))
    new_pair = (rec['homelab'], rec['config']) != (cur.get('homelab'), cur.get('config'))
    if new_pair:
        fetch_commit(hl, rec['homelab'], [stage, 'dev', 'canary', 'main'])
        fetch_commit(cf, rec['config'], [stage, 'dev', 'canary', 'main'])
        verify_range(hl, cur.get('homelab'), rec['homelab'])
        verify_range(cf, cur.get('config'), rec['config'])
    build_tree(hl, cf, rec)
    save_json('current.json', {'seq': rec['seq'], 'homelab': rec['homelab'], 'config': rec['config'], 'wave': rec['wave'],
                               'verified': int(time.time())})

    hold = load_json('hold.json', {})
    applied = load_json('applied.json', {}); failed = load_json('failed.json', {}); ready = load_json('ready.json', {})
    waiting = {}; results = []
    window = canary or apply_now or in_window(conf)
    wave_ok = in_wave(conf, rec)
    if hold.get('*'):
        log('sync: the whole guest is on hold — nothing applied'); return results

    # labber itself first (in the window, in its wave, after its self-test)
    if window and wave_ok:
        r = self_update(hl); results.append(('labber', r))
        if r == 'updated':          # the rest with the new labber, at the next run (this process is the old one)
            results.append(('sync', 'continues with the new labber at the next run')); return results

    for item in plan(host, cf, hl, rec, canary):
        s = item['svc']
        if hold.get(s): results.append((s, 'held')); continue
        if item['group'] == 'byhand' or not item['template']: continue
        if not installed(s):
            waiting[s] = 'not installed (sync never installs: a new service needs its settings from you)'
            continue
        want = {'template': item['template'], 'files': item['files']}
        have = applied.get(s, {})
        stale = not instance_matches(s, os.path.join(hl, 'services', s), allowed_files(cf, s))
        if not stale:
            if have.get('template') != want['template']:      # e.g. updated by hand (update --ready)
                have = applied[s] = {'template': want['template'], 'files': have.get('files')}
            ready.pop(s, None); failed.pop(s, None)           # it runs this release: an older failure is moot
        need = missing_settings(os.path.join(SERVICE_BASE, s), os.path.join(hl, 'services', s))
        if need and stale:
            waiting[s] = 'needs settings: ' + ', '.join(need); continue
        if item['group'] == 'prepared':
            if stale:
                if ready.get(s, {}).get('template') != want['template']:
                    rc, out = labber(s, 'pull-ready', source=hl)
                    ready[s] = {'template': want['template'], 'pulled': rc == 0, 'since': int(time.time())}
                results.append((s, 'ready'))
            # the fast-lane files don't wait for a prepared update: they fit the running version
            if want['files'] != have.get('files'):
                results.append((s, apply_files(host, s, cf, want, applied)))
            continue
        # auto
        if s in FLEET_WIDE and not wave_ok: continue
        if stale:
            prev = failed.get(s, {})
            if {k: prev.get(k) for k in want} == want or not window:
                if {k: prev.get(k) for k in want} == want: results.append((s, 'skipped: this version failed before'))
                # outside the window (or a version that failed) the template waits, the files don't
                if want['files'] and want['files'] != have.get('files'):
                    results.append((s, apply_files(host, s, cf, want, applied)))
                continue
            rc, out = labber(s, 'update', '--rollback-on-failure', source=hl)
            if item['on_demand']: labber(s, 'stop')     # the canary: started for its update, stopped after
            if rc == 0:
                applied[s] = {'template': want['template'], 'files': have.get('files')}
                failed.pop(s, None)                     # a fixed version clears the old failure
                r = apply_files(host, s, cf, want, applied) if want['files'] else 'updated'
                results.append((s, 'updated' if r in ('updated', 'files written') else r))
            elif rc == 3:
                failed[s] = dict(want, down=1); results.append((s, 'FAILED and the rollback failed too: the service is down'))
                log(f'{s}: update failed, rollback failed — service down\n{out}')
            else:
                failed[s] = want; results.append((s, 'failed, rolled back'))
                log(f'{s}: update failed and was rolled back\n{out}')
        elif want['files'] != have.get('files'):
            results.append((s, apply_files(host, s, cf, want, applied)))
    save_json('applied.json', applied); save_json('failed.json', failed); save_json('ready.json', ready)
    save_json('waiting.json', waiting)
    return results

def apply_files(host, s, cf, want, applied):
    """Per-guest files: write them and prove them at once. A file the service reloads by itself
    (policy/fast-lane.yml) only needs the health check; any other file is proven by a restart:
    otherwise a broken one would only show at the next restart, days later. On failure the
    previous files go back (and the service is restarted again)."""
    backups = write_files(host, s, cf)
    fast = set(ylists(rtext(os.path.join(cf, 'policy', 'fast-lane.yml'))).get(s, [])) \
        if os.path.exists(os.path.join(cf, 'policy', 'fast-lane.yml')) else set()
    src = os.path.join(cf, 'guests', host, s)
    written = [os.path.relpath(os.path.join(r, f), src) for r, _, fs in os.walk(src) for f in fs]
    restart = any(w not in fast for w in written)
    if restart: labber(s, 'restart')
    rc, out = labber(s, 'healthy')
    if rc != 0:
        restore_files(backups)
        if restart: labber(s, 'restart')
        labber(s, 'healthy')
        return 'files failed the health check' + (' after a restart' if restart else '') + ', previous files back'
    applied.setdefault(s, {})['files'] = want['files']
    if 'template' not in applied[s]: applied[s]['template'] = None
    return 'files written'

def labber_version(path):
    m = re.search(r'^VERSION="([0-9.]+)"', rtext(path), re.M)
    return tuple(int(x) for x in m.group(1).split('.')) if m else (0,)

def self_update(hl):
    new = os.path.join(hl, 'labber')
    lib = os.path.dirname(os.path.realpath(LABBER))
    have, offered = labber_version(os.path.join(lib, 'labber')), labber_version(os.path.join(new, 'labber'))
    if offered <= have: return 'current' if offered == have else 'current (the release has an older labber: never back)'
    p = subprocess.run(['bash', os.path.join(new, 'labber'), 'selftest'], capture_output=True, text=True,
                       stdin=subprocess.DEVNULL)
    if p.returncode != 0: return 'new labber failed its self-test: kept the old one'
    # the NEW labber installs itself: a bug in the old one's install path can't block a fix
    env = dict(os.environ, LABBER_SOURCE=hl, LABBER_SYNC_LOCKED='1'); env.pop('LABBER_REF', None)
    p = subprocess.run(['bash', os.path.join(new, 'labber'), 'update', '--labber-only'], capture_output=True, text=True,
                       env=env, stdin=subprocess.DEVNULL)
    if p.returncode != 0: log((p.stdout + p.stderr)[-1500:])
    return 'updated' if p.returncode == 0 else 'self-update failed: kept the old one'


# ── metrics ────────────────────────────────────────────────────────────────────

def service_health():
    """Per installed service: healthy (every container running, none unhealthy, none restarting)
    and the containers' restart count, for the canary's regression check and the digest."""
    out = []
    try: names = sorted(os.listdir(SERVICE_BASE))
    except OSError: return out
    for svc in names:
        d = os.path.join(SERVICE_BASE, svc)
        if not os.path.isfile(os.path.join(d, 'docker-compose.yml')): continue
        p = subprocess.run(['docker', 'ps', '-a', '--filter', f'label=com.docker.compose.project={svc}',
                            '--format', '{{.ID}}'], capture_output=True, text=True)
        ids = p.stdout.split()
        if not ids:
            out.append(f'labber_service_running{{service="{svc}"}} 0'); continue
        q = subprocess.run(['docker', 'inspect', '-f', '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}|{{.State.ExitCode}}|{{index .Config.Labels "com.docker.compose.oneoff"}}', *ids],
                           capture_output=True, text=True)
        healthy, restarts, running = 1, 0, 0
        for row in q.stdout.splitlines():
            st, health, rc, code, _ = (row.split('|') + ['', '', '0', '0', ''])[:5]
            restarts += int(rc or 0)
            if st == 'running': running += 1
            if health == 'unhealthy' or st in ('restarting', 'dead') or (st == 'exited' and code not in ('0', '')): healthy = 0
        out.append(f'labber_service_running{{service="{svc}"}} {1 if running else 0}')
        if running: out.append(f'labber_service_healthy{{service="{svc}"}} {healthy}')
        out.append(f'labber_service_restarts_total{{service="{svc}"}} {restarts}')
    return out

UNREACHABLE = ('unable to access', 'no answer for', 'Could not resolve host', 'Failed to connect', 'Connection refused',
               'Connection timed out', 'Operation timed out', 'returned error: 50')
def unreachable(err):
    """The run failed because Forgejo didn't answer (down, hanging, or the network): not this guest's own problem."""
    return not isinstance(err, SyncError) and any(m in str(err) for m in UNREACHABLE)

def write_metrics(ok, err=None, results=()):
    cur = load_json('current.json', {}); ready = load_json('ready.json', {}); waiting = load_json('waiting.json', {})
    failed = load_json('failed.json', {}); hold = load_json('hold.json', {})
    lines = ['# labber sync (see labber-design.md: metrics and alerts)',
             f'labber_sync_last_run_timestamp {int(time.time())}',
             f'labber_sync_seq {cur.get("seq", 0)}']
    stage = read_kv(CONF).get('stage', '') if os.path.exists(CONF) else ''
    if stage and re.match(r'^[A-Za-z0-9_-]+$', stage):   # with its stage: compared with the gatekeeper's record
        lines.append(f'labber_sync_record_seq{{stage="{stage}"}} {cur.get("seq", 0)}')
    if cur.get('homelab'):        # which release, not only its number: the gatekeeper's evidence needs the identity
        lines.append(f'labber_sync_current{{homelab="{cur["homelab"]}",config="{cur.get("config", "")}"}} {cur.get("seq", 0)}')
    prev = read_kv(METRICS + '.state')
    last_ok = int(time.time()) if ok else int(prev.get('last_ok', 0) or 0)
    lines.append(f'labber_sync_last_success_timestamp {last_ok}')
    lines.append(f'labber_sync_refused {1 if (err and isinstance(err, SyncError)) else 0}')
    lines.append(f'labber_sync_error {1 if err else 0}')
    lines.append(f'labber_sync_forgejo_unreachable {1 if err and unreachable(err) else 0}')
    for s, v in ready.items(): lines.append(f'labber_sync_ready{{service="{s}",since="{v.get("since", 0)}"}} 1')
    for s, v in failed.items():
        lines.append(f'labber_sync_failed{{service="{s}"}} 1')
        if v.get('down'): lines.append(f'labber_sync_rollback_failed{{service="{s}"}} 1')
    for s, why in waiting.items():
        why = re.sub(r'["\\\n]', ' ', str(why))
        lines.append(f'labber_sync_waiting{{service="{s}",why="{why}"}} 1')
    for s, v in hold.items():
        if v: lines.append(f'labber_sync_hold{{service="{s}"}} {v}')
    lines += service_health()
    os.makedirs(os.path.dirname(METRICS), exist_ok=True)
    tmp = METRICS + '.tmp'; wtext(tmp, '\n'.join(lines) + '\n'); os.replace(tmp, METRICS)
    wtext(METRICS + '.state', f'last_ok={last_ok}\n')


# ── commands ───────────────────────────────────────────────────────────────────

def need_conf():
    conf = read_kv(CONF)
    for k in ('host', 'stage', 'homelab', 'config'):
        if k not in conf: raise SystemExit(f'not enrolled ({CONF} lacks {k}): labber sync enroll')
    return conf

def cmd_run(args):
    conf = need_conf()
    os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    # group-writable (docker): an admin's by-hand labber takes the same lock (it fails closed)
    lock = os.fdopen(os.open(LOCK, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o664), 'w')
    try:
        if os.stat(LOCK).st_uid == os.geteuid():
            os.chmod(LOCK, 0o664)
            try: os.chown(LOCK, -1, grp.getgrnam('docker').gr_gid)
            except (KeyError, PermissionError): pass
    except OSError: pass
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: log('sync: another change is running on this guest — next run'); return 0
    try:
        refresh_unit()
        results = sync_run(conf, apply_now=getattr(args, 'apply', False))
        for s, r in results: log(f'{s}: {r}')
        write_metrics(True, None, results); return 0
    except SyncError as e:
        write_metrics(False, e); log(f'REFUSED: {e}'); return 2
    except Exception as e:
        write_metrics(False, e); log(f'error: {e}'); return 1

def cmd_status(args):
    conf = read_kv(CONF)
    if not conf: print('not enrolled'); return 0
    cur = load_json('current.json', {})
    print(f"host {conf.get('host')} · stage {conf.get('stage')} · wave {conf.get('wave', '1')} · window {conf.get('window', '04:00-05:00')}")
    print(f"release {cur.get('seq', '-')}: homelab {cur.get('homelab', '-')[:12]} · config {cur.get('config', '-')[:12]}")
    for name in ('hold', 'ready', 'waiting', 'failed', 'applied'):
        d = load_json(f'{name}.json', {})
        for s, v in sorted(d.items()):
            if v: print(f'  {name:8} {s}: {v if not isinstance(v, dict) else ", ".join(f"{k}={str(x)[:12]}" for k, x in v.items())}')
    return 0

def cmd_hold(args, value):
    h = load_json('hold.json', {})
    key = args.svc or '*'
    if value: h[key] = int(time.time())
    else: h.pop(key, None)
    save_json('hold.json', h); print(('hold' if value else 'released') + f': {key if key != "*" else "the whole guest"}')
    write_metrics(True); return 0

def cmd_retry(args):
    f = load_json('failed.json', {}); f.pop(args.svc, None); save_json('failed.json', f)
    print(f'{args.svc}: will be tried again at the next run'); return 0

def cmd_enroll(args):
    if os.path.exists(CONF) and not args.force: raise SystemExit(f'already enrolled ({CONF}); --force to redo')
    for k, v in (('forgejo-key', args.forgejo_key), ('gatekeeper-key', args.gatekeeper_key)):
        if not re.match(r'^ssh-(ed25519|rsa) [A-Za-z0-9+/=]+', v or ''): raise SystemExit(f'--{k}: an SSH public key')
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    # a (re-)enrolment starts the release chain afresh: another Forgejo, stage or key has its own
    # record numbers and commits. Per-service state (hold, applied, failed, ready) stays.
    cur = os.path.join(STATE, 'current.json'); repos = os.path.join(STATE, 'repos')
    if os.path.exists(cur) or os.path.isdir(repos):
        print('release state reset (re-enrolment): the next record is accepted as the start')
        if os.path.exists(cur): os.remove(cur)
        shutil.rmtree(repos, ignore_errors=True)
    wtext(SIGNERS, f'forgejo namespaces="git" {args.forgejo_key}\n')
    wtext(RELEASE_SIGNERS, f'gatekeeper namespaces="{RECORD_NAMESPACE}" {args.gatekeeper_key}\n')
    lines = [f'host={args.host}', f'stage={args.stage}', f'homelab={args.homelab}', f'config={args.config}',
             f'wave={args.wave}', f"window={'always' if args.canary else args.window}", f"canary={'yes' if args.canary else 'no'}"]
    wtext(CONF, '# labber sync enrolment (labber sync enroll); not changed by any release\n' + '\n'.join(lines) + '\n')
    install_timer()
    print(f'enrolled {args.host} on {args.stage} (labber-sync.timer: every 5 minutes); first run:')
    return cmd_run(argparse.Namespace(apply=False))

UNIT_DIR = os.environ.get('LABBER_SYNC_UNITS', '/etc/systemd/system')

SERVICE_UNIT = ('[Unit]\nDescription=labber sync: follow the release (labber-design.md)\nAfter=network-online.target docker.service\n'
                'Wants=network-online.target\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/labber sync run\nNice=5\n'
                '# a last resort: a run that never ends would stop every later one\nTimeoutStartSec=3h\n')

def refresh_unit():
    """An enrolled guest gets a newer unit with the labber that brings it (enroll writes it only once)."""
    p = os.path.join(UNIT_DIR, 'labber-sync.service')
    if os.path.exists(p) and rtext(p) != SERVICE_UNIT:
        wtext(p, SERVICE_UNIT); run(['systemctl', 'daemon-reload'], check=False)

def install_timer():
    wtext(os.path.join(UNIT_DIR, 'labber-sync.service'), SERVICE_UNIT)
    wtext(os.path.join(UNIT_DIR, 'labber-sync.timer'),
          '[Unit]\nDescription=labber sync every 5 minutes\n\n[Timer]\nOnBootSec=2min\nOnUnitActiveSec=5min\n'
          'RandomizedDelaySec=30\n\n[Install]\nWantedBy=timers.target\n')
    run(['systemctl', 'daemon-reload']); run(['systemctl', 'enable', '--now', 'labber-sync.timer'])

def cmd_unenroll(args):
    run(['systemctl', 'disable', '--now', 'labber-sync.timer'], check=False)
    for u in ('labber-sync.timer', 'labber-sync.service'):
        p = os.path.join(UNIT_DIR, u)
        if os.path.exists(p): os.remove(p)
    run(['systemctl', 'daemon-reload'], check=False)
    for p in (CONF, SIGNERS, RELEASE_SIGNERS):
        if os.path.exists(p): os.remove(p)
    print('unenrolled: the services stay as they are; labber works as before'); return 0

def main(argv=None):
    ap = argparse.ArgumentParser(prog='labber sync')
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('run'); r.add_argument('--apply', action='store_true')
    n = sub.add_parser('now'); n.add_argument('--apply', action='store_true', help='apply auto updates now, outside the window')
    sub.add_parser('status')
    for c in ('hold', 'release'): sub.add_parser(c).add_argument('svc', nargs='?')
    sub.add_parser('retry').add_argument('svc')
    e = sub.add_parser('enroll')
    e.add_argument('--host', required=True); e.add_argument('--stage', choices=['main', 'canary'], default='main')
    e.add_argument('--homelab', required=True, help='URL of homelab on Forgejo')
    e.add_argument('--config', required=True, help='URL of homelab-config on Forgejo')
    e.add_argument('--forgejo-key', required=True); e.add_argument('--gatekeeper-key', required=True)
    e.add_argument('--wave', choices=['1', '2'], default='2'); e.add_argument('--window', default='04:00-05:00')
    e.add_argument('--canary', action='store_true'); e.add_argument('--force', action='store_true')
    sub.add_parser('unenroll')
    a = ap.parse_args(argv)
    if a.cmd in ('run', 'now'): return cmd_run(a)
    if a.cmd == 'status': return cmd_status(a)
    if a.cmd == 'hold': return cmd_hold(a, True)
    if a.cmd == 'release': return cmd_hold(a, False)
    if a.cmd == 'retry': return cmd_retry(a)
    if a.cmd == 'enroll': return cmd_enroll(a)
    if a.cmd == 'unenroll': return cmd_unenroll(a)

if __name__ == '__main__':
    sys.exit(main())
