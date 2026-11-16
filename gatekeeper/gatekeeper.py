#!/usr/bin/env python3
"""The gatekeeper: one run (a timer calls it every 2 minutes) on the Forgejo LXC, as its own user.
homelab-private: plans/automation-design.md → Gatekeeper. Standard library only.

  1. Renovate's version-only PRs that meet the fixed rules (rules.py): approve them, after
     checking each new digest against its registry and Renovate's own age check
     PRs opened by a login in approve_authors (yours): approve them (you can't approve your own)
  2. approved PRs whose CI passed: merge them (Forgejo signs the merge)
  3. dev → canary (both repos together) once dev's CI passed; a signed canary record
  4. config lane: homelab-config merges go straight to main once their CI passed (not those
     labelled with-release, which ride with a release through the canary)
     by-hand lane: homelab changes only in by-hand templates (no guest applies them) likewise
     display lane: homelab changes only to display files (homelab-config policy/display.yml:
     dashboards, docs) likewise; with a release on the canary, after it, without restarting its clock
  5. canary → main on positive evidence from the canary's Prometheus (missing data blocks);
     a signed main record, wave 1; wave 2 once the first guest reports that release healthy
It never creates a commit on dev/canary/main, never moves a branch backwards, never runs code
from a repo. A file at `pause` stops everything but its metrics.
"""
import datetime, json, os, re, subprocess, sys, time, urllib.parse, urllib.request, urllib.error
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rules  # noqa: E402

CONF_FILE = os.environ.get('GATEKEEPER_CONF', '/etc/gatekeeper/gatekeeper.conf')
ADVISORY = []          # (container, metric, ratio) of the last promotion's regression check
STATUS = {'why': '', 'eta': 0, 'prs': {}}   # what this run saw, for the Pipeline dashboard


def read_kv(path):
    out = {}
    with open(path) as f:
        for line in f:
            line = line.split('#', 1)[0].strip()
            if '=' in line: k, v = line.split('=', 1); out[k.strip()] = v.strip()
    return out

C = read_kv(CONF_FILE) if os.path.exists(CONF_FILE) else {}
STATE = C.get('state', '/var/lib/gatekeeper')
def log(m): print(f'{datetime.datetime.now(datetime.timezone.utc):%H:%M:%S} {m}', flush=True)


# ── Forgejo ────────────────────────────────────────────────────────────────────

def token():
    with open(C['token_file']) as f: return f.read().strip()

def api(method, path, body=None, raw=False):
    req = urllib.request.Request(C['forgejo'] + '/api/v1' + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Authorization': 'token ' + token(), 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            t = r.read(); return r.status, (t.decode() if raw else (json.loads(t) if t else None))
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:300]

def repo_path(r): return f"/repos/{C['owner']}/{C[r]}"

def head(r, branch):
    st, b = api('GET', f'{repo_path(r)}/branches/{branch}')
    return b['commit']['id'] if st == 200 else None

def ci_ok(r, sha):
    if C.get('require_ci', 'yes') != 'yes': return True
    st, s = api('GET', f'{repo_path(r)}/commits/{sha}/status')
    return st == 200 and s.get('state') == 'success' and s.get('total_count', 0) > 0

def raw_file(r, branch, path):
    st, t = api('GET', f'{repo_path(r)}/raw/{urllib.parse.quote(path)}?ref={branch}', raw=True)
    return t if st == 200 else ''


# ── Git (pushes only existing commits, fast-forward) ───────────────────────────

def git(*args, check=True, text=True):
    """git with the token in the environment (never in a URL, an argument or an error message)."""
    env = dict(os.environ, GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0=f"http.{C['forgejo']}/.extraHeader",
               GIT_CONFIG_VALUE_0='Authorization: token ' + token(), GIT_TERMINAL_PROMPT='0')
    p = subprocess.run(['git', *args], capture_output=True, text=text, env=env)
    if check and p.returncode != 0:
        raise RuntimeError(f"git {args[0] if args[0] != '-C' else args[2]}: {(p.stderr or '').replace(token(), '***').strip()[-200:]}")
    return p

def repo_url(r): return f"{C['forgejo']}/{C['owner']}/{C[r]}.git"

def clone(r):
    path = os.path.join(STATE, 'git', C[r])
    if not os.path.isdir(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        git('clone', '-q', '--bare', repo_url(r), path)
    git('-C', path, 'remote', 'set-url', 'origin', repo_url(r))
    git('-C', path, 'fetch', '-q', 'origin', '+refs/heads/*:refs/heads/*')
    return path

def is_ancestor(path, a, b):
    return git('-C', path, 'merge-base', '--is-ancestor', a, b, check=False).returncode == 0

def move(r, branch, sha):
    """Fast-forward <branch> of repo r to the existing commit sha; never backwards."""
    path = clone(r); cur = head(r, branch)
    if cur == sha: return False
    if cur and not is_ancestor(path, cur, sha): raise RuntimeError(f'{C[r]}: {branch} {cur[:12]} → {sha[:12]} is not forward')
    git('-C', path, 'push', '-q', 'origin', f'{sha}:refs/heads/{branch}')
    log(f'{C[r]}: {branch} → {sha[:12]}'); return True

def changed_files(r, a, b):
    path = clone(r)
    return git('-C', path, 'diff', '--name-only', a, b).stdout.split()


# ── release records ────────────────────────────────────────────────────────────

def current_record(stage):
    text = raw_file('config', 'releases', f'{stage}.txt')
    rec = dict(l.split('=', 1) for l in text.splitlines() if '=' in l)
    try: t = int(datetime.datetime.strptime(rec.get('time', ''), '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp())
    except ValueError: t = 0
    return {'seq': int(rec.get('seq', 0)), 'homelab': rec.get('homelab'), 'config': rec.get('config'), 'wave': int(rec.get('wave', 0)), 'time': t}

def publish(stage, homelab, config, wave):
    seq = current_record(stage)['seq'] + 1
    when = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    text = rules.record_text(stage, seq, homelab, config, wave, when)
    sig = rules.sign(text, C['key'])
    work = os.path.join(STATE, 'releases'); url = repo_url('config')
    subprocess.run(['rm', '-rf', work])
    if git('ls-remote', '--exit-code', url, 'refs/heads/releases', check=False).returncode == 0:
        git('clone', '-q', '-b', 'releases', url, work)
    else:
        git('init', '-q', '-b', 'releases', work); git('-C', work, 'remote', 'add', 'origin', url)
    with open(os.path.join(work, f'{stage}.txt'), 'w') as f: f.write(text)
    with open(os.path.join(work, f'{stage}.txt.sig'), 'w') as f: f.write(sig)
    g = ['-C', work, '-c', 'user.name=gatekeeper', '-c', 'user.email=gatekeeper@localhost']
    git(*g, 'add', '-A'); git(*g, 'commit', '-q', '-m', f'{stage} {seq}')
    git('-C', work, 'push', '-q', 'origin', 'releases')
    log(f'record {stage} {seq}: homelab {homelab[:12]} config {config[:12]} wave {wave}')
    return seq


# ── evidence (Prometheus) ──────────────────────────────────────────────────────

def prom(base, q):
    try:
        with urllib.request.urlopen(base + '/api/v1/query?' + urllib.parse.urlencode({'query': q}), timeout=20) as r:
            d = json.load(r)
        return [(x['metric'], float(x['value'][1])) for x in d['data']['result']]
    except Exception as e:
        log(f'prometheus {base}: {e}'); return None

def healthy_since(base, host, rec, window, untested_blocks=False):
    """Positive evidence that <host> runs the release <rec> (its commits, not only its number:
    a guest following another Forgejo has numbers too) without a failure for the whole window.
    Missing data is no evidence. untested_blocks (the canary): an installed service waiting for a
    new setting hasn't run this release, so there is no evidence for it yet."""
    q = lambda e: prom(base, e)
    seq = rec['seq']
    have = q(f'min_over_time(labber_sync_seq{{instance="{host}"}}[{window}])')
    if not have: return False, 'no data'
    if have[0][1] < seq: return False, f'not on {seq} for the whole {window} yet'
    # on exactly these commits at every sample of the window (later releases count as not proven)
    ident = f'instance="{host}",homelab="{rec["homelab"]}",config="{rec["config"]}"'
    on = q(f'count_over_time(labber_sync_current{{{ident}}}[{window}])')
    all_ = q(f'count_over_time(labber_sync_seq{{instance="{host}"}}[{window}])')
    if on is None or all_ is None: return False, 'no data'
    if not on or not all_ or on[0][1] < all_[0][1]:
        return False, f'{host} has not run {rec["homelab"][:12]}/{rec["config"][:12]} for the whole {window}'
    for metric in ('labber_sync_failed', 'labber_sync_rollback_failed', 'labber_sync_error', 'labber_sync_refused'):
        r = q(f'max_over_time({metric}{{instance="{host}"}}[{window}])')
        if r is None: return False, 'no data'
        if any(v > 0 for _, v in r): return False, f'{metric} on {host}'
    if untested_blocks:
        r = q(f'labber_sync_waiting{{instance="{host}",why=~"needs settings.*"}}')
        if r is None: return False, 'no data'
        if r: return False, f'{host} waits for you (a new setting): ' + ', '.join(sorted(f'{m.get("service")} ({m.get("why", "")[16:]})' for m, _ in r))
    fresh = q(f'time() - max(labber_sync_last_success_timestamp{{instance="{host}"}})')
    if not fresh or fresh[0][1] > 900: return False, f'{host} has not synced successfully for 15 min'
    # the regression check's blocking part: healthy throughout, no restart, no OOM kill
    sel = f'instance="{host}"'
    checks = [
        (f'min_over_time(labber_service_healthy{{{sel}}}[{window}]) < 1', 'a service was unhealthy'),
        (f'max_over_time(labber_service_restarts_total{{{sel}}}[{window}]) - min_over_time(labber_service_restarts_total{{{sel}}}[{window}]) > 0', 'a service restarted'),
        # any container started after the window began (the release was applied before it: the seq check)
        (f'container_start_time_seconds{{{sel}}} > time() - {seconds(window)}', 'a container restarted'),
        (f'increase(container_oom_events_total{{{sel}}}[{window}]) > 0', 'a container ran out of memory'),
    ]
    for expr, why in checks:
        r = q(expr)
        if r is None: return False, 'no data'
        if r: return False, f'{why} on {host}: ' + ', '.join(sorted({m.get("service") or m.get("name", "?") for m, _ in r}))
    if not q(f'labber_service_healthy{{{sel}}}'): return False, f'no service health from {host}'
    return True, ''

def main_eta(rec):
    """When main moves if all stays healthy: the window starts when the canary first reported this
    release's commits (its Prometheus), not when the record was written (the canary applies it a
    few minutes later); + one gatekeeper run. Without that report yet: the record + 5 minutes."""
    window = seconds(C.get('evidence_window', '2h'))
    ident = f'instance="{C["canary_host"]}",homelab="{rec["homelab"]}",config="{rec["config"]}"'
    first = prom(C['canary_prometheus'], f'min_over_time(timestamp(labber_sync_current{{{ident}}})[{2 * window}s:1m])')
    start = int(float(first[0][1])) if first else (rec.get('time', 0) + 300 if rec.get('time') else 0)
    return start + window + 120 if start else 0

def seconds(window):
    """'2h', '5m', '90s', '1d' → seconds."""
    n, unit = int(window[:-1]), window[-1]
    return n * {'s': 1, 'm': 60, 'h': 3600, 'd': 86400}[unit]

def advisory(base, host, window):
    """The regression check's reported part: each container against the same-length window
    before (the previous release). Logged and exported, never blocking."""
    out = []
    sel = f'instance="{host}"'
    for metric, expr, limit in (
            ('memory', 'avg_over_time(container_memory_working_set_bytes{%s}[%s]%s)', 1.5),
            ('cpu', 'rate(container_cpu_usage_seconds_total{%s}[%s]%s)', 2.0),
            ('writes', 'rate(container_fs_writes_bytes_total{%s}[%s]%s)', 3.0)):
        now = prom(base, expr % (sel, window, '')) or []
        before = {m.get('name'): v for m, v in (prom(base, expr % (sel, window, f' offset {window}')) or [])}
        for m, v in now:
            b = before.get(m.get('name'))
            if b and b > 0:
                ratio = v / b
                out.append((m.get('name'), metric, ratio))
                if ratio > limit: log(f'advisory: {host} {m.get("name")}: {metric} {ratio:.1f}× the previous release')
    return out


# ── the run ────────────────────────────────────────────────────────────────────

def handle_prs(groups):
    for r in ('homelab', 'config'):
        st, prs = api('GET', f'{repo_path(r)}/pulls?state=open&limit=50')
        if st != 200: continue
        for pr in prs:
            if pr['base']['ref'] != 'dev' or pr.get('draft'): continue
            n, sha = pr['number'], pr['head']['sha']
            if not approved(r, n, sha) and pure_revert(r, n):
                api('POST', f'{repo_path(r)}/pulls/{n}/reviews', {'event': 'APPROVED', 'body': 'gatekeeper: a pure revert of a change that has not reached main'})
                log(f'{C[r]}#{n}: approved (pure revert of an unpromoted change)')
                summarise(r, n, sha, groups, 'a pure revert: merged by the gatekeeper after CI')
            elif pr['user']['login'] in authors() and not approved(r, n, sha):
                # your own PR: opening it is the decision (your login has 2FA); Forgejo won't
                # let you approve it yourself, and only an approved merge is signed
                api('POST', f'{repo_path(r)}/pulls/{n}/reviews', {'event': 'APPROVED', 'body': f"gatekeeper: opened by {pr['user']['login']} (approve_authors)"})
                log(f'{C[r]}#{n}: approved (opened by {pr["user"]["login"]})')
                summarise(r, n, sha, groups, 'your own PR: merged by the gatekeeper after CI, then the canary')
            elif pr['user']['login'] == C.get('renovate_user') and not approved(r, n, sha):
                ok, why = renovate_low_risk(r, n, sha, groups)
                if ok:
                    api('POST', f'{repo_path(r)}/pulls/{n}/reviews', {'event': 'APPROVED', 'body': 'gatekeeper: low-risk (version lines only; digests checked against their registries; Renovate\'s age check passed)'})
                    log(f'{C[r]}#{n}: approved (low-risk)')
                    summarise(r, n, sha, groups, 'low-risk: merged by the gatekeeper after CI, then the canary')
                elif why.startswith('AGE: '):
                    STATUS['prs']['low_risk_waiting'] = STATUS['prs'].get('low_risk_waiting', 0) + 1
                    log(f'{C[r]}#{n}: low-risk, waiting: {why[5:]}')
                    summarise(r, n, sha, groups, f'low-risk once quiet: {why[5:]}; then merged by the gatekeeper after CI')
                else:
                    STATUS['prs']['waiting_for_you'] = STATUS['prs'].get('waiting_for_you', 0) + 1
                    log(f'{C[r]}#{n}: waits for you: {why}')
                    summarise(r, n, sha, groups, f'waits for your approval: {why}')
            elif not approved(r, n, sha):
                STATUS['prs']['waiting_for_you'] = STATUS['prs'].get('waiting_for_you', 0) + 1
                summarise(r, n, sha, groups, 'waits for your approval')
            if approved(r, n, sha) and ci_ok(r, sha) and pr.get('mergeable', True):
                # head_commit_id: Forgejo refuses the merge if the branch moved after the CI and
                # approval this decision saw (a push in between can't ride along)
                st, out = api('POST', f'{repo_path(r)}/pulls/{n}/merge', {'Do': 'merge', 'head_commit_id': sha,
                                                                    'delete_branch_after_merge': True})
                log(f'{C[r]}#{n}: merged' if st == 200 else f'{C[r]}#{n}: merge refused ({st}): {str(out)[:120]}')

def authors():
    """approve_authors=: logins whose own PRs the gatekeeper approves (yours); empty: none."""
    return {a.strip() for a in C.get('approve_authors', '').split(',') if a.strip()}

def summarise(r, n, sha, groups, decision):
    """One plain comment per PR version: what changes, what you'd need to do, what happens next."""
    seen = os.path.join(STATE, 'summarised'); os.makedirs(seen, exist_ok=True)
    mark = os.path.join(seen, f'{C[r]}-{n}-{sha}')
    if os.path.exists(mark): return
    st, d = api('GET', f'{repo_path(r)}/pulls/{n}.diff', raw=True)
    if st != 200: return
    files = rules.parse_diff(d)
    group_of = {s: g for g in ('auto', 'prepared', 'byhand') for s in groups.get(g, [])}
    lines = ['**gatekeeper summary** (facts from the diff; the decision follows a fixed rule)', '']
    try:
        for svc, img, old, new in rules.version_changes(d):
            lines.append(f"- `{img.split('{')[0].rstrip(':')}` ({svc}, {group_of.get(svc, 'byhand')}): "
                         f"{old.split('@')[0]} → {new.split('@')[0]} · **{rules.step(old, new)}**")
    except ValueError:
        svcs = sorted({f.split('/')[1] for f in files if f.startswith('services/')})
        if svcs: lines.append('- templates changed: ' + ', '.join(f'{s} ({group_of.get(s, "byhand")})' for s in svcs))
    new_keys = sorted({l.split('=', 1)[0].strip() for f, (rem, add) in files.items() if f.endswith('.env.example')
                       for l in add if '=' in l and not l.lstrip().startswith('#')} -
                      {l.split('=', 1)[0].strip() for f, (rem, add) in files.items() if f.endswith('.env.example')
                       for l in rem if '=' in l})
    if new_keys: lines.append(f"- **new settings**: {', '.join(new_keys)} (a deploy waits until they're in .env)")
    risky = sorted(f for f in files if f.startswith(('.forgejo/', 'gatekeeper/', 'labber/', 'tests/')) or f == 'renovate.json')
    if risky: lines.append(f"- **changes CI, tests or the tooling**: {', '.join(risky[:8])}{' …' if len(risky) > 8 else ''}")
    lines += ['', f'**next:** {decision}']
    api('POST', f'{repo_path(r)}/issues/{n}/comments', {'body': '\n'.join(lines)})
    open(mark, 'w').close()

def approved(r, n, sha):
    st, revs = api('GET', f'{repo_path(r)}/pulls/{n}/reviews')
    return st == 200 and any(v['state'] == 'APPROVED' and v.get('official') and not v.get('stale') and not v.get('dismissed')
                             and v.get('commit_id') == sha for v in revs)

def patch_id(diff):
    p = subprocess.run(['git', 'patch-id', '--stable'], input=diff, capture_output=True, text=True)
    return p.stdout.split()[0] if p.stdout.strip() else None

def pure_revert(r, n):
    """Does the PR exactly undo one first-parent change on dev that main doesn't have yet?"""
    st, d = api('GET', f'{repo_path(r)}/pulls/{n}.diff', raw=True)
    if st != 200 or not d.strip(): return False
    mine = patch_id(d)
    if not mine: return False
    path = clone(r); dev, main = head(r, 'dev'), head(r, 'main')
    for c in git('-C', path, 'rev-list', '--first-parent', f'{main}..{dev}').stdout.split():
        undo = git('-C', path, 'diff', c, f'{c}^1').stdout
        if undo.strip() and patch_id(undo) == mine: return True
    return False

def renovate_low_risk(r, n, sha, groups):
    if r != 'homelab': return False, 'not a template change'
    st, d = api('GET', f'{repo_path(r)}/pulls/{n}.diff', raw=True)
    if st != 200: return False, 'no diff'
    try: changes = rules.version_changes(d)
    except ValueError as e: return False, str(e)
    ok, why = rules.low_risk(changes, groups)
    if not ok: return False, why
    st, s = api('GET', f'{repo_path(r)}/commits/{sha}/status')
    ctx = {x['context']: x['status'] for x in (s or {}).get('statuses', [])} if st == 200 else {}
    if C.get('require_age_check', 'yes') == 'yes' and ctx.get('renovate/stability-days') != 'success':
        return False, "AGE: Renovate's age check hasn't passed"
    # quiet for N days: Renovate rewrites the PR when a newer version comes out, so an unchanged
    # proposal for N days is a version nothing newer replaced (most registries give no dates)
    st, c = api('GET', f'{repo_path(r)}/git/commits/{sha}')
    days = float(C.get('min_age_days', '3'))
    if st != 200: return False, 'no commit date'
    when = datetime.datetime.fromisoformat(c['commit']['committer']['date'].replace('Z', '+00:00'))
    age = (datetime.datetime.now(datetime.timezone.utc) - when).total_seconds() / 86400
    if age < days: return False, f'AGE: proposed {age:.1f} days ago, quiet for {days:g} needed'
    for svc, img, old, new in changes:
        ref = img.split('{')[0] + new.split('@')[0]
        if registry_digest(ref) != new.split('@')[1]: return False, f'{ref}: the digest is not what the registry has for that tag'
    return True, ''

def registry_digest(ref):
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
    from registry import digest
    try: return digest(ref)
    except Exception as e: log(f'registry {ref}: {e}'); return None

def promote():
    hl = {b: head('homelab', b) for b in ('dev', 'canary', 'main')}
    cf = {b: head('config', b) for b in ('dev', 'canary', 'main')}
    # the config lane: config merges (CI passed, not tied to a release by the PR label
    # with-release) go to main one by one at once, whatever waits on the canary;
    # main keeps its tested homelab commit, the canary's record and evidence stay as they are
    cfp = clone('config')
    target = config_lane_target(cfp, cf['main'], cf['dev'])
    m = current_record('main')
    if target != cf['main'] or (m['config'] and m['config'] != cf['main'] and m['homelab'] == hl['main']
                                and is_ancestor(cfp, m['config'], cf['main'])):
        nothing_waits = hl['canary'] == hl['main'] and cf['canary'] == cf['main']
        move('config', 'main', target)
        publish('main', hl['main'], target, m['wave'] or 1)
        if nothing_waits:                     # keep the canary level with main when it has nothing of its own
            move('config', 'canary', target); publish('canary', hl['canary'], target, 1)
        log(f'config lane: {target[:12]} straight to main')
        cf['main'] = target
        if nothing_waits: cf['canary'] = target
    # quick lanes: nothing waits in homelab-config, and every homelab change since main is display
    # only (Grafana dashboards, docs) or in a by-hand template: the canary can't prove anything there
    lane = rules.quick_lane(changed_files('homelab', hl['main'], hl['dev']), groups_policy(), display_policy()) \
        if cf['dev'] == cf['main'] and hl['dev'] != hl['main'] and ci_ok('homelab', hl['dev']) else ''
    if lane:
        why = f'{lane} lane: ' + ('only dashboards or docs changed' if lane == 'display' else
                                  'only by-hand templates (or dashboards, docs) changed') + ', straight to main'
        log(why)
        move('homelab', 'canary', hl['dev']); move('homelab', 'main', hl['dev'])
        publish('canary', hl['dev'], cf['dev'], 1); publish('main', hl['dev'], cf['dev'], 1)
        STATUS['why'] = why
        return
    # dev → canary: a new homelab (versions, templates, labber), or config the lane didn't take (tied
    # to a release); config the lane already took to main doesn't move the canary (its clock stays)
    canary_due = hl['dev'] != hl['canary'] or (cf['dev'] != cf['canary'] and cf['dev'] != cf['main'])
    # a release under test, and dev adds only quick-lane changes on top: the canary keeps its clock;
    # they reach main by the quick lane once that release is promoted
    if canary_due and hl['canary'] != hl['main'] and cf['dev'] in (cf['canary'], cf['main']) \
            and rules.quick_lane(changed_files('homelab', hl['canary'], hl['dev']), groups_policy(), display_policy()):
        log('dev adds only dashboards/docs/by-hand templates: the canary keeps its release and clock')
        canary_due = False
    if canary_due and ci_ok('homelab', hl['dev']) and ci_ok('config', cf['dev']):
        move('homelab', 'canary', hl['dev']); move('config', 'canary', cf['dev'])
        publish('canary', hl['dev'], cf['dev'], 1)
        hl['canary'], cf['canary'] = hl['dev'], cf['dev']
    # a move whose record failed (e.g. the push of `releases` refused): the next run writes it;
    # only for what passed CI (canary moves only then), so a never-promoted canary gets none
    rec = current_record('canary')
    if (rec['homelab'], rec['config']) != (hl['canary'], cf['canary']) and ci_ok('homelab', hl['canary']) and ci_ok('config', cf['canary']):
        log('canary has no record for its commits (an earlier run failed after the move): writing it')
        publish('canary', hl['canary'], cf['canary'], 1)
        rec = current_record('canary')
    # canary → main, on positive evidence
    cf_canary_newer = cf['canary'] != cf['main'] and is_ancestor(cfp, cf['main'], cf['canary'])
    if (hl['canary'] != hl['main'] or cf_canary_newer) and (rec['homelab'], rec['config']) == (hl['canary'], cf['canary']):
        ok, why = healthy_since(C['canary_prometheus'], C['canary_host'], rec, C.get('evidence_window', '2h'),
                                untested_blocks=True)
        ADVISORY[:] = advisory(C['canary_prometheus'], C['canary_host'], C.get('evidence_window', '2h')) if ok else []
        if ok:
            new_cf = cf['canary'] if cf_canary_newer else cf['main']   # main's newer config (the lane) stays
            move('homelab', 'main', hl['canary']); move('config', 'main', new_cf)
            publish('main', hl['canary'], new_cf, 1)
            STATUS['why'] = 'promoted to main'
        else:
            log(f'canary → main waits: {why}')
            STATUS['why'] = why
            STATUS['eta'] = main_eta(rec)
    # the same for main: only when main holds exactly what the canary's record proved
    m = current_record('main')
    if (m['homelab'], m['config']) != (hl['main'], cf['main']) and (rec['homelab'], rec['config']) == (hl['main'], cf['main']):
        log('main has no record for its commits (an earlier run failed after the move): writing it')
        publish('main', hl['main'], cf['main'], 1)
        m = current_record('main')
    # wave 2, once the first guest runs main's record healthy
    if m['wave'] == 1 and m['homelab'] and C.get('wave1_host'):     # none yet (no guest enrolled): no wave 2
        ok, why = healthy_since(C['main_prometheus'], C['wave1_host'], m, C.get('wave_window', '10m'))
        if ok: publish('main', m['homelab'], m['config'], 2)
        else: log(f"wave 2 waits for {C['wave1_host']}: {why}")

def config_lane_target(path, main, dev):
    """How far main may move along dev's merges at once. homelab-config is configuration only:
    the canary can't prove anything about it that CI doesn't, so each merge goes once its CI
    passed, unless its PR is labelled with-release (config that must land with a new version).
    Stops at the first one that isn't (it, and everything after it, goes through the canary)."""
    target = main
    for c in git('-C', path, 'rev-list', '--first-parent', '--reverse', f'{main}..{dev}').stdout.split():
        if not ci_ok('config', c) or tied_to_release(path, c): break
        target = c
    return target

def tied_to_release(path, sha):
    """The merged PR carries the label with-release (or the merge says Release-with:)."""
    msg = git('-C', path, 'log', '-1', '--format=%B', sha).stdout
    if re.search(r'^Release-with:', msg, re.M): return True
    m = re.search(r'\(#(\d+)\)', msg)
    if not m: return False
    st, pr = api('GET', f"{repo_path('config')}/pulls/{m.group(1)}")
    return st == 200 and any(l.get('name') == 'with-release' for l in pr.get('labels') or [])

def rules_fast_lane():
    from_text = raw_file('config', 'main', 'policy/fast-lane.yml')
    out = {}
    for line in from_text.splitlines():
        line = line.split('#', 1)[0]
        mm = re.match(r'^([A-Za-z0-9_.-]+):\s*\[(.*)\]', line)
        if mm: out[mm.group(1)] = [x.strip() for x in mm.group(2).split(',') if x.strip()]
    return out

def display_policy():
    """homelab-config policy/display.yml on main: {'all' | <svc>: [path patterns]}; none: no display lane."""
    out = {}
    for line in raw_file('config', 'main', 'policy/display.yml').splitlines():
        line = line.split('#', 1)[0]
        mm = re.match(r'^([A-Za-z0-9_.-]+):\s*\[(.*)\]', line)
        if mm: out[mm.group(1)] = [x.strip().strip('\'"') for x in mm.group(2).split(',') if x.strip().strip('\'"')]
    return out

def groups_policy():
    out = {}
    for line in raw_file('config', 'main', 'policy/groups.yml').splitlines():
        line = line.split('#', 1)[0]
        mm = re.match(r'^(auto|prepared|byhand):\s*\[(.*)\]', line)
        if mm: out[mm.group(1)] = [x.strip() for x in mm.group(2).split(',') if x.strip()]
    return out

def write_metrics(ok):
    hl_c, hl_m = head('homelab', 'canary'), head('homelab', 'main')
    cf_c, cf_m = head('config', 'canary'), head('config', 'main')
    st = os.path.join(STATE, 'waiting_since'); now = int(time.time())
    if hl_c != hl_m or (cf_c != cf_m and is_ancestor(clone('config'), cf_m, cf_c)):
        if os.path.exists(st):
            with open(st) as f: since = int(f.read())
        else:
            since = now
            with open(st, 'w') as f: f.write(str(now))
    else:
        since = now
        if os.path.exists(st): os.remove(st)
    lines = [f'gatekeeper_last_run_timestamp {now}', f'gatekeeper_last_run_ok {1 if ok else 0}',
             f'gatekeeper_promotion_waiting_seconds {now - since}',
             f'gatekeeper_paused {1 if os.path.exists(C.get("pause_file", "/etc/gatekeeper/pause")) else 0}']
    lines += [f'gatekeeper_regression_ratio{{container="{c}",metric="{m}"}} {v:.3f}' for c, m, v in ADVISORY]
    try:
        for st in ('canary', 'main'):
            r = current_record(st)
            lines += [f'gatekeeper_record_seq{{stage="{st}"}} {r["seq"]}', f'gatekeeper_record_timestamp{{stage="{st}"}} {r["time"]}',
                      f'gatekeeper_record_wave{{stage="{st}"}} {r["wave"]}']
    except Exception: pass
    if hl_c == hl_m and not (cf_c != cf_m and is_ancestor(clone('config'), cf_m, cf_c)):
        STATUS['why'] = STATUS['why'] or 'nothing waits: main has what the canary has'
    why = re.sub(r'["\\\n]', ' ', STATUS['why'] or 'unknown')[:200]
    lines.append(f'gatekeeper_canary_status{{why="{why}"}} 1')
    lines.append(f'gatekeeper_main_eta_timestamp {STATUS["eta"]}')
    for k in ('waiting_for_you', 'low_risk_waiting'):
        lines.append(f'gatekeeper_prs{{state="{k}"}} {STATUS["prs"].get(k, 0)}')
    p = C.get('metrics', '/var/lib/labber/metrics/gatekeeper.prom')
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'w') as f: f.write('\n'.join(lines) + '\n')     # in place: its sandbox may write this file only

def main():
    if not C: raise SystemExit(f'no {CONF_FILE}')
    os.makedirs(STATE, exist_ok=True)
    if os.path.exists(C.get('pause_file', '/etc/gatekeeper/pause')):
        log('paused'); STATUS['why'] = 'paused (/etc/gatekeeper/pause)'; write_metrics(True); return 0
    ok = True
    try:
        handle_prs(groups_policy())
        promote()
    except Exception as e:
        ok = False; log('error: ' + str(e).replace(token(), '***')); STATUS['why'] = 'error: ' + str(e).replace(token(), '***')[:120]
    write_metrics(ok)
    return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main())
