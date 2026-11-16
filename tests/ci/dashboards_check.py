#!/usr/bin/env python3
"""Grafana dashboards: valid JSON, unique uids, and every Prometheus query parses (promtool, from the
monitoring template's own Prometheus image). Dashboard changes skip the canary, so this is their test.
Run from the repo root: python3 tests/ci/dashboards_check.py   (needs Docker)"""
import glob, json, os, re, subprocess, sys, tempfile

files = sorted(glob.glob('services/*/config/grafana/provisioning/dashboards/*.json'))
bad, uids, rules = [], {}, []

def panels(ps):
    for p in ps:
        yield p
        yield from panels(p.get('panels', []))

def is_loki(ds):
    ds = ds or {}
    if isinstance(ds, str): return 'loki' in ds.lower()
    return 'loki' in str(ds.get('type', '')).lower() or 'loki' in str(ds.get('uid', '')).lower()

for f in files:
    try: d = json.load(open(f))
    except ValueError as e: bad.append(f'{f}: not valid JSON: {e}'); continue
    uid = d.get('uid')
    if not uid: bad.append(f'{f}: no uid')
    elif uid in uids: bad.append(f'{f}: uid {uid} also in {uids[uid]}')
    else: uids[uid] = f
    for p in panels(d.get('panels', [])):
        for t in p.get('targets', []):
            expr = t.get('expr')
            if not expr or is_loki(t.get('datasource')) or (not t.get('datasource') and is_loki(p.get('datasource'))):
                continue
            # Grafana's variables: durations become 5m, the rest only sit inside label strings
            q = re.sub(r'\$__(rate_)?interval|\$__range|\$\{__(rate_)?interval\}|\$\{__range\}', '5m', expr)
            q = re.sub(r'\$\{?[A-Za-z_]\w*\}?', 'x', q)
            rules.append({'record': f'check:{len(rules)}', 'expr': q,
                          'labels': {'where': f'{os.path.basename(f)} #{p.get("id")} {t.get("refId", "")}'}})

compose = open('services/monitoring/docker-compose.yml').read()
m = re.search(r'image:\s*(prom/prometheus:)\$\{PROMETHEUS_VERSION:-([^}]+)\}', compose)
if not m: sys.exit('no prom/prometheus image in services/monitoring/docker-compose.yml')
image = m.group(1) + m.group(2)

with tempfile.TemporaryDirectory() as tmp:
    os.chmod(tmp, 0o755)
    path = os.path.join(tmp, 'rules.yml')     # YAML is a superset of JSON
    json.dump({'groups': [{'name': 'dashboards', 'rules': rules}]}, open(path, 'w'))
    os.chmod(path, 0o644)
    r = subprocess.run(['docker', 'run', '--rm', '-v', f'{tmp}:/r:ro', '--entrypoint', 'promtool', image,
                        'check', 'rules', '/r/rules.yml'], capture_output=True, text=True)
    if r.returncode != 0:
        out = r.stdout + r.stderr
        for n in sorted(set(int(x) for x in re.findall(r'check:(\d+)', out))) or []:
            bad.append(f'{rules[n]["labels"]["where"]}: {rules[n]["expr"][:200]}')
        bad.append('promtool: ' + out.strip()[-1500:])

print(f'{len(files)} dashboards, {len(rules)} Prometheus queries')
if bad:
    print('\n'.join(bad)); sys.exit(1)
print('ok')
