#!/usr/bin/env python3
"""Offline tests of labber sync's checks (labber/sync.py): throwaway Git repos and SSH keys
standing in for Forgejo, the gatekeeper and an attacker. Run: python3 tests/labber/sync_test.py"""
import datetime, os, subprocess, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'labber'))
import sync  # noqa: E402

def sh(*cmd, cwd=None, input=None):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, input=input)
    if p.returncode: raise RuntimeError(f'{cmd}: {p.stderr}')
    return p.stdout.strip()

class Keys:
    def __init__(self, d):
        self.d = d
        for k in ('forgejo', 'gatekeeper', 'attacker'):
            sh('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', k, '-f', os.path.join(d, k))
        self.signers = os.path.join(d, 'allowed_signers')
        open(self.signers, 'w').write(f'forgejo namespaces="git" {self.pub("forgejo")}\n')
        self.release_signers = os.path.join(d, 'release_signers')
        open(self.release_signers, 'w').write(f'gatekeeper namespaces="labber-release" {self.pub("gatekeeper")}\n')
    def pub(self, k): return open(os.path.join(self.d, k + '.pub')).read().strip()
    def sign_record(self, text, key='gatekeeper'):
        f = tempfile.mktemp(dir=self.d, suffix='.txt')        # a fresh name: ssh-keygen never overwrites a .sig
        with open(f, 'w') as h: h.write(text)
        sh('ssh-keygen', '-q', '-Y', 'sign', '-f', os.path.join(self.d, key), '-n', 'labber-release', f)
        with open(f + '.sig') as h: return h.read()

class Repo:
    def __init__(self, path, keys):
        self.path, self.keys = path, keys
        sh('git', 'init', '-q', '-b', 'main', path)
        for k, v in (('user.name', 't'), ('user.email', 't@example.org'), ('gpg.format', 'ssh')):
            sh('git', '-C', path, 'config', k, v)
    def commit(self, msg, key='forgejo'):
        with open(os.path.join(self.path, 'f'), 'a') as h: h.write(msg + '\n')
        sh('git', '-C', self.path, 'add', 'f')
        args = ['git', '-C', self.path, 'commit', '-q', '-m', msg]
        if key: args = ['git', '-C', self.path, '-c', f'user.signingkey={os.path.join(self.keys.d, key)}', 'commit', '-q', '-S', '-m', msg]
        sh(*args)
        return self.head()
    def head(self): return sh('git', '-C', self.path, 'rev-parse', 'HEAD')

class SyncChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(); cls.keys = Keys(cls.tmp.name)
    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()
    def repo(self, name):
        return Repo(os.path.join(self.tmp.name, name + str(id(self))), self.keys)
    def record(self, stage='main', seq=5, wave=1):
        return f'stage={stage}\nseq={seq}\nhomelab={"a"*40}\nconfig={"b"*40}\nwave={wave}\n'

    # ── the release record ──
    def test_record_signed_by_the_gatekeeper_verifies(self):
        t = self.record(); self.assertTrue(sync.verify_record(t, self.keys.sign_record(t), self.keys.release_signers))
    def test_record_signed_by_another_key_is_refused(self):
        t = self.record(); self.assertFalse(sync.verify_record(t, self.keys.sign_record(t, 'attacker'), self.keys.release_signers))
    def test_record_signed_by_forgejo_key_is_refused(self):
        t = self.record(); self.assertFalse(sync.verify_record(t, self.keys.sign_record(t, 'forgejo'), self.keys.release_signers))
    def test_record_signed_in_another_namespace_is_refused(self):
        t = self.record(); f = tempfile.mktemp(dir=self.keys.d)
        with open(f, 'w') as h: h.write(t)
        sh('ssh-keygen', '-q', '-Y', 'sign', '-f', os.path.join(self.keys.d, 'gatekeeper'), '-n', 'git', f)
        with open(f + '.sig') as h: self.assertFalse(sync.verify_record(t, h.read(), self.keys.release_signers))
    def test_a_garbage_signature_is_refused(self):
        self.assertFalse(sync.verify_record(self.record(), 'not a signature', self.keys.release_signers))
    def test_record_changed_after_signing_is_refused(self):
        t = self.record(); sig = self.keys.sign_record(t)
        self.assertFalse(sync.verify_record(t.replace('seq=5', 'seq=6'), sig, self.keys.release_signers))
    def test_a_dev_or_canary_pair_offered_as_main_is_refused(self):
        rec = sync.parse_record(self.record(stage='canary'))
        with self.assertRaises(sync.SyncError): sync.check_record(rec, 'main', None)
    def test_an_older_record_replayed_is_refused(self):
        rec = sync.parse_record(self.record(seq=4))
        with self.assertRaises(sync.SyncError): sync.check_record(rec, 'main', 5)
        sync.check_record(sync.parse_record(self.record(seq=5)), 'main', 5)   # the same one again: fine
    def test_a_malformed_record_is_refused(self):
        for bad in ('stage=main\nseq=1\n', self.record().replace('a' * 40, 'HEAD'), self.record().replace('seq=5', 'seq=x')):
            with self.assertRaises(sync.SyncError): sync.parse_record(bad)

    # ── commits ──
    def test_signed_commits_moving_forward_pass(self):
        r = self.repo('fwd'); a = r.commit('a'); r.commit('b'); c = r.commit('c')
        self.assertEqual(sync.verify_range(r.path, a, c, self.keys.signers), 2)
    def test_an_unsigned_commit_under_a_signed_head_is_refused(self):
        r = self.repo('mid'); a = r.commit('a'); r.commit('b', key=None); c = r.commit('c')
        with self.assertRaises(sync.SyncError): sync.verify_range(r.path, a, c, self.keys.signers)
    def test_a_commit_signed_by_the_wrong_key_is_refused(self):
        r = self.repo('wrong'); a = r.commit('a'); c = r.commit('c', key='attacker')
        with self.assertRaises(sync.SyncError): sync.verify_range(r.path, a, c, self.keys.signers)
    def test_the_gatekeeper_key_cannot_sign_commits(self):
        r = self.repo('gk'); a = r.commit('a'); c = r.commit('c', key='gatekeeper')
        with self.assertRaises(sync.SyncError): sync.verify_range(r.path, a, c, self.keys.signers)
    def test_a_backwards_move_is_refused(self):
        r = self.repo('back'); a = r.commit('a'); b = r.commit('b')
        with self.assertRaises(sync.SyncError): sync.verify_range(r.path, b, a, self.keys.signers)
    def test_a_sideways_move_is_refused(self):
        r = self.repo('side'); a = r.commit('a'); b = r.commit('b')
        sh('git', '-C', r.path, 'checkout', '-q', a); c = r.commit('c')
        with self.assertRaises(sync.SyncError): sync.verify_range(r.path, b, c, self.keys.signers)
    def test_first_enrolment_checks_the_head(self):
        r = self.repo('first'); r.commit('a', key=None); b = r.commit('b')
        self.assertEqual(sync.verify_range(r.path, None, b, self.keys.signers), 1)
        u = r.commit('u', key=None)
        with self.assertRaises(sync.SyncError): sync.verify_range(r.path, None, u, self.keys.signers)
    def test_a_signed_merge_of_unsigned_pr_commits_passes(self):
        r = self.repo('merge'); a = r.commit('a')
        sh('git', '-C', r.path, 'checkout', '-q', '-b', 'pr'); r.commit('pr work', key=None)
        sh('git', '-C', r.path, 'checkout', '-q', 'main')
        sh('git', '-C', r.path, '-c', f'user.signingkey={os.path.join(self.keys.d, "forgejo")}', 'merge', '-q', '--no-ff', '-S', '-m', 'merge pr', 'pr')
        self.assertEqual(sync.verify_range(r.path, a, r.head(), self.keys.signers), 1)

    # ── decisions ──
    def test_missing_settings(self):
        d = tempfile.mkdtemp(dir=self.tmp.name); rel = tempfile.mkdtemp(dir=self.tmp.name)
        open(os.path.join(d, '.env'), 'w').write("PORT='1'\nOLD='x'\n")
        open(os.path.join(rel, '.env.example'), 'w').write(
            "PORT={{ port | default(1) }}\nNEW_DEFAULT={{ a | default(2) }}\nNEW_TOKEN={{ token }}\n"
            "NEW_SECRET={{ s | generate(hex64) }}\nNEW_MODE={{ m | choice(a,b) }}\n# C={{ c }}\n")
        self.assertEqual(sync.missing_settings(d, rel), ['NEW_TOKEN', 'NEW_SECRET', 'NEW_MODE'])
    def test_instance_matches_uses_what_labber_installed(self):
        base = tempfile.mkdtemp(dir=self.tmp.name); rel = tempfile.mkdtemp(dir=self.tmp.name)
        import hashlib
        files = {'docker-compose.yml': b'services: {}\n', 'config/a.yml': b'x\n'}
        for n, c in files.items():
            os.makedirs(os.path.dirname(os.path.join(rel, n)), exist_ok=True)
            with open(os.path.join(rel, n), 'wb') as h: h.write(c)
        inst = os.path.join(base, 'svc'); os.makedirs(inst)
        def record(fs):
            with open(os.path.join(inst, '.labber-base'), 'w') as h:
                h.write(''.join(f'{hashlib.sha256(c).hexdigest()}  {n}\n' for n, c in fs.items()))
        old = sync.SERVICE_BASE; sync.SERVICE_BASE = base
        try:
            record(files); self.assertTrue(sync.instance_matches('svc', rel))
            with open(os.path.join(inst, 'docker-compose.yml'), 'w') as h: h.write('your edit\n')
            self.assertTrue(sync.instance_matches('svc', rel))            # your edit doesn't count
            record({'docker-compose.yml': b'services: {}\n'})            # an older template: a file missing
            self.assertFalse(sync.instance_matches('svc', rel))
            self.assertTrue(sync.instance_matches('svc', rel, skip={'config/a.yml'}))   # a per-guest file aside
        finally: sync.SERVICE_BASE = old

    def test_per_guest_files_written_only_when_allowed_and_put_back(self):
        root = tempfile.mkdtemp(dir=self.tmp.name); cfg = os.path.join(root, 'cfg'); base = os.path.join(root, 'svc')
        os.makedirs(os.path.join(cfg, 'policy', 'allow')); os.makedirs(os.path.join(cfg, 'guests', 'apps', 'homepage', 'config'))
        os.makedirs(os.path.join(base, 'homepage', 'config'))
        with open(os.path.join(cfg, 'policy', 'allow', 'homepage.yml'), 'w') as h: h.write('- config/services.yaml\n')
        with open(os.path.join(cfg, 'guests', 'apps', 'homepage', 'config', 'services.yaml'), 'w') as h: h.write('new\n')
        with open(os.path.join(base, 'homepage', 'config', 'services.yaml'), 'w') as h: h.write('old\n')
        old = sync.SERVICE_BASE; sync.SERVICE_BASE = base
        try:
            backups = sync.write_files('apps', 'homepage', cfg)
            with open(os.path.join(base, 'homepage', 'config', 'services.yaml')) as h: self.assertEqual(h.read(), 'new\n')
            sync.restore_files(backups)
            with open(os.path.join(base, 'homepage', 'config', 'services.yaml')) as h: self.assertEqual(h.read(), 'old\n')
            with open(os.path.join(cfg, 'guests', 'apps', 'homepage', 'docker-compose.yml'), 'w') as h: h.write('x\n')
            with self.assertRaises(sync.SyncError): sync.write_files('apps', 'homepage', cfg)   # not allowed
        finally: sync.SERVICE_BASE = old

    def test_per_guest_files_follow_a_folder_moved_in_env(self):
        root = tempfile.mkdtemp(dir=self.tmp.name); cfg = os.path.join(root, 'cfg'); base = os.path.join(root, 'svc')
        moved = os.path.join(root, 'mnt', 'homepage', 'config')
        os.makedirs(os.path.join(cfg, 'policy', 'allow')); os.makedirs(os.path.join(cfg, 'guests', 'apps', 'homepage', 'config'))
        os.makedirs(os.path.join(base, 'homepage')); os.makedirs(moved)
        with open(os.path.join(cfg, 'policy', 'allow', 'homepage.yml'), 'w') as h: h.write('- config/services.yaml\n')
        with open(os.path.join(cfg, 'guests', 'apps', 'homepage', 'config', 'services.yaml'), 'w') as h: h.write('new\n')
        with open(os.path.join(base, 'homepage', '.env.example'), 'w') as h:
            h.write('HOMEPAGE_CONFIG={{ homepage_config | default(./config) }}\nPORT={{ port | default(3000) }}\n')
        with open(os.path.join(base, 'homepage', '.env'), 'w') as h: h.write(f'HOMEPAGE_CONFIG={moved}\nPORT=3000\n')
        with open(os.path.join(moved, 'services.yaml'), 'w') as h: h.write('old\n')
        old = sync.SERVICE_BASE; sync.SERVICE_BASE = base
        try:
            backups = sync.write_files('apps', 'homepage', cfg)
            with open(os.path.join(moved, 'services.yaml')) as h: self.assertEqual(h.read(), 'new\n')   # where Homepage reads it
            self.assertFalse(os.path.exists(os.path.join(base, 'homepage', 'config', 'services.yaml')))
            sync.restore_files(backups)
            with open(os.path.join(moved, 'services.yaml')) as h: self.assertEqual(h.read(), 'old\n')
            with open(os.path.join(base, 'homepage', '.env'), 'w') as h: h.write('HOMEPAGE_CONFIG=./config\n')   # not moved
            self.assertEqual(sync.moved_dirs(os.path.join(base, 'homepage')), {})
        finally: sync.SERVICE_BASE = old

    def test_files_a_service_doesnt_reload_are_proven_by_a_restart(self):
        root = tempfile.mkdtemp(dir=self.tmp.name); cfg = os.path.join(root, 'cfg'); base = os.path.join(root, 'svc')
        os.makedirs(os.path.join(cfg, 'policy', 'allow')); os.makedirs(os.path.join(cfg, 'guests', 'g', 'web', 'config'))
        os.makedirs(os.path.join(base, 'web', 'config'))
        with open(os.path.join(cfg, 'policy', 'allow', 'web.yml'), 'w') as h: h.write('- config/routes.yml\n- config/app.ini\n')
        with open(os.path.join(cfg, 'policy', 'fast-lane.yml'), 'w') as h: h.write('web: [config/routes.yml]\n')
        def put(name, text):
            with open(os.path.join(cfg, 'guests', 'g', 'web', 'config', name), 'w') as h: h.write(text)
        calls = []; health = {'rc': 0}
        def fake(*a, source=None):
            calls.append(a[1]); return (health['rc'] if a[1] == 'healthy' else 0), ''
        old = (sync.SERVICE_BASE, sync.labber); sync.SERVICE_BASE = base; sync.labber = fake
        try:
            put('routes.yml', 'r1\n')                                     # reloaded by the service itself
            self.assertEqual(sync.apply_files('g', 'web', cfg, {'files': 'a'}, {}), 'files written')
            self.assertEqual(calls, ['healthy'])
            calls.clear(); put('app.ini', 'v1\n')                          # read only at start: a restart proves it
            self.assertEqual(sync.apply_files('g', 'web', cfg, {'files': 'b'}, {}), 'files written')
            self.assertEqual(calls, ['restart', 'healthy'])
            calls.clear(); health['rc'] = 1; put('app.ini', 'broken\n')   # fails: the previous file, restarted again
            self.assertIn('previous files back', sync.apply_files('g', 'web', cfg, {'files': 'c'}, {}))
            self.assertEqual(calls, ['restart', 'healthy', 'restart', 'healthy'])
            with open(os.path.join(base, 'web', 'config', 'app.ini')) as h: self.assertEqual(h.read(), 'v1\n')
        finally: sync.SERVICE_BASE, sync.labber = old

    def test_labber_never_goes_back(self):
        d = tempfile.mkdtemp(dir=self.tmp.name)
        for name, v in (('old', '4.5.0'), ('new', '4.5.1'), ('ten', '4.10.0')):
            with open(os.path.join(d, name), 'w') as h: h.write(f'#!/bin/bash\nVERSION="{v}"\n')
        self.assertLess(sync.labber_version(os.path.join(d, 'old')), sync.labber_version(os.path.join(d, 'new')))
        self.assertLess(sync.labber_version(os.path.join(d, 'new')), sync.labber_version(os.path.join(d, 'ten')))   # numbers, not text

    def test_wave(self):
        self.assertTrue(sync.in_wave({'wave': '1'}, {'wave': 1}))
        self.assertFalse(sync.in_wave({'wave': '2'}, {'wave': 1}))
        self.assertTrue(sync.in_wave({'wave': '2'}, {'wave': 2}))
        # the canary runs every release first, whatever its enrolment's wave says
        self.assertTrue(sync.in_wave({'wave': '2', 'canary': 'yes'}, {'wave': 1}))

    def test_window(self):
        at = lambda h, m: datetime.datetime(2026, 10, 26, h, m, tzinfo=datetime.timezone.utc)
        self.assertTrue(sync.in_window({'window': '04:00-05:00'}, at(4, 30)))
        self.assertFalse(sync.in_window({'window': '04:00-05:00'}, at(5, 0)))
        self.assertFalse(sync.in_window({}, at(14, 0)))
        self.assertTrue(sync.in_window({'window': 'always'}, at(14, 0)))
        # across midnight
        self.assertTrue(sync.in_window({'window': '23:00-01:00'}, at(23, 30)))
        self.assertTrue(sync.in_window({'window': '23:00-01:00'}, at(0, 30)))
        self.assertFalse(sync.in_window({'window': '23:00-01:00'}, at(1, 0)))
        self.assertFalse(sync.in_window({'window': '23:00-01:00'}, at(12, 0)))

    def test_safe_copy_never_follows_a_planted_link(self):
        top = tempfile.mkdtemp(dir=self.tmp.name); out = tempfile.mkdtemp(dir=self.tmp.name)
        src = os.path.join(top, 'src'); open(src, 'w').write('repo\n')
        inst = os.path.join(top, 'inst'); os.makedirs(inst)
        os.symlink(out, os.path.join(inst, 'conf'))                        # a folder leading out
        with self.assertRaises(sync.SyncError): sync.safe_copy(src, os.path.join(inst, 'conf', 'a'), inst)
        self.assertEqual(os.listdir(out), [])
        victim = os.path.join(out, 'victim'); open(victim, 'w').write('secret\n')
        os.symlink(victim, os.path.join(inst, 'b.labber-new'))             # a planted temp file
        os.symlink(victim, os.path.join(inst, 'b'))                         # and a planted target
        sync.safe_copy(src, os.path.join(inst, 'b'), inst)
        self.assertEqual(open(victim).read(), 'secret\n')
        self.assertFalse(os.path.islink(os.path.join(inst, 'b')))
        self.assertEqual(open(os.path.join(inst, 'b')).read(), 'repo\n')
    def test_ylists(self):
        y = sync.ylists('auto:     [a, b]   # comment\nprepared: ["c"]\n# x: [d]\nbyhand: []\n')
        self.assertEqual(y, {'auto': ['a', 'b'], 'prepared': ['c'], 'byhand': []})

if __name__ == '__main__':
    unittest.main(verbosity=2)
