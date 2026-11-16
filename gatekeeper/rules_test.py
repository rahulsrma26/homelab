#!/usr/bin/env python3
"""Offline tests of the gatekeeper's rules. Run: python3 gatekeeper/rules_test.py"""
import os, sys, unittest
sys.path.insert(0, os.path.dirname(__file__))
import rules  # noqa: E402

D1 = 'sha256:' + '1' * 64; D2 = 'sha256:' + '2' * 64
def diff(path, old, new):
    return f'diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n@@ -3 +3 @@\n-{old}\n+{new}\n'
IMG = '    image: deluan/navidrome:${NAVIDROME_VERSION:-%s}'
GROUPS = {'auto': ['navidrome', 'homepage'], 'prepared': ['immich'], 'byhand': ['vaultwarden']}

class Rules(unittest.TestCase):
    def test_a_version_bump_is_recognised(self):
        c = rules.version_changes(diff('services/navidrome/docker-compose.yml', IMG % f'0.64.2@{D1}', IMG % f'0.64.3@{D2}'))
        self.assertEqual(c, [('navidrome', 'deluan/navidrome:{NAVIDROME_VERSION}', f'0.64.2@{D1}', f'0.64.3@{D2}')])
    def test_anything_else_is_not_version_only(self):
        bad = [
            diff('services/navidrome/docker-compose.yml', '    restart: unless-stopped', '    restart: always'),
            diff('services/navidrome/docker-compose.yml', IMG % f'0.64.2@{D1}', '    image: evil/navidrome:${NAVIDROME_VERSION:-0.64.3@%s}' % D2),
            diff('services/navidrome/docker-compose.yml', IMG % f'0.64.2@{D1}', IMG % '0.64.3'),          # no digest
            diff('services/navidrome/.env.example', 'A=1', 'A=2'),
            diff('labber/labber', 'VERSION="1"', 'VERSION="2"'),
            diff('.forgejo/workflows/ci.yml', 'a', 'b'),
            f'diff --git a/services/navidrome/docker-compose.yml b/services/navidrome/docker-compose.yml\n--- a/x\n+++ b/services/navidrome/docker-compose.yml\n@@ -3,0 +4 @@\n+    privileged: true\n',
            '',
        ]
        for d in bad:
            with self.assertRaises(ValueError, msg=d[:120]): rules.version_changes(d)
    def test_whole_image_in_a_variable_keeps_registry_and_repo(self):
        W = '    image: ${LLAMA_IMAGE:-%s}'
        old = f'ghcr.io/ggml-org/llama.cpp:server-cuda-b11870@{D1}'
        c = rules.version_changes(diff('services/assistant-agent/docker-compose.yml', W % old, W % f'ghcr.io/ggml-org/llama.cpp:server-cuda-b11900@{D2}'))
        self.assertEqual(c, [('assistant-agent', 'ghcr.io/ggml-org/llama.cpp:{LLAMA_IMAGE}', f'server-cuda-b11870@{D1}', f'server-cuda-b11900@{D2}')])
        for new in (f'evil.io/ggml-org/llama.cpp:server-cuda-b11900@{D2}',      # another registry
                    f'ghcr.io/evil/llama.cpp:server-cuda-b11900@{D2}',          # another repo
                    f'server-cuda-b11900@{D2}',                                 # a tag of nothing
                    f'localhost:5000/llama.cpp:x@{D2}'):
            with self.assertRaises(ValueError, msg=new):
                rules.version_changes(diff('services/assistant-agent/docker-compose.yml', W % old, W % new))
        # a prefixed image with a whole image in its default
        with self.assertRaises(ValueError):
            rules.version_changes(diff('services/navidrome/docker-compose.yml', IMG % f'0.64.2@{D1}', IMG % f'evil/x:1@{D2}'))
        self.assertEqual(rules.image_name(f'localhost:5000/a/b:1.2@{D1}'), ('localhost:5000/a/b', f'1.2@{D1}'))
        self.assertEqual(rules.image_name(f'1.2@{D1}'), ('', f'1.2@{D1}'))
    def test_steps(self):
        self.assertEqual(rules.step(f'0.64.2@{D1}', f'0.64.3@{D2}'), 'patch')
        self.assertEqual(rules.step(f'0.64.2@{D1}', f'0.65.0@{D2}'), 'minor')
        self.assertEqual(rules.step(f'v2.7.0@{D1}', f'v3.0.0@{D2}'), 'major')
        self.assertEqual(rules.step(f'v3@{D1}', f'v3@{D2}'), 'digest')
        self.assertEqual(rules.step(f'16-alpine@{D1}', f'16-bookworm@{D2}'), 'other')
    def test_low_risk_by_group(self):
        auto_patch = [('navidrome', 'x', f'0.64.2@{D1}', f'0.64.3@{D2}')]
        auto_major = [('navidrome', 'x', f'0.64.2@{D1}', f'1.0.0@{D2}')]
        prep_major = [('immich', 'x', f'v2.9.0@{D1}', f'v3.0.0@{D2}')]
        self.assertEqual(rules.low_risk(auto_patch, GROUPS), (True, ''))
        self.assertFalse(rules.low_risk(auto_major, GROUPS)[0])
        self.assertTrue(rules.low_risk(prep_major, GROUPS)[0])          # you deploy prepared ones yourself
        self.assertFalse(rules.low_risk([('vaultwarden', 'x', f'1@{D1}', f'2@{D2}')], GROUPS)[0])
        self.assertFalse(rules.low_risk([('unlisted', 'x', f'1.0@{D1}', f'1.1@{D2}')], GROUPS)[0])
    def test_fast_lane(self):
        fl = {'homepage': ['config/services.yaml'], 'traefik': ['dynamic/routes.yml']}
        self.assertTrue(rules.fast_lane_only(['guests/apps/homepage/config/services.yaml'], fl))
        self.assertFalse(rules.fast_lane_only(['guests/apps/homepage/config/services.yaml', 'policy/groups.yml'], fl))
        self.assertFalse(rules.fast_lane_only(['guests/apps/homepage/docker-compose.yml'], fl))
        self.assertFalse(rules.fast_lane_only([], fl))
    def test_record_text(self):
        t = rules.record_text('main', 7, 'a' * 40, 'b' * 40, 1, '2026-10-26T00:00:00Z')
        self.assertIn('seq=7\n', t)
        with self.assertRaises(ValueError): rules.record_text('main', 7, 'HEAD', 'b' * 40, 1, 'x')

    def test_byhand_only(self):
        g = {'auto': ['homepage'], 'prepared': ['immich'], 'byhand': ['assistant-agent']}
        self.assertTrue(rules.byhand_only(['services/assistant-agent/compose.embed-none.yml', 'services/assistant-agent/README.txt'], g))
        self.assertTrue(rules.byhand_only(['services/someday/docker-compose.yml'], g))          # unlisted = by hand
        self.assertFalse(rules.byhand_only(['services/assistant-agent/x.yml', 'services/homepage/x.yml'], g))
        self.assertFalse(rules.byhand_only(['services/immich/docker-compose.yml'], g))
        self.assertFalse(rules.byhand_only(['services/assistant-agent/x.yml', 'tests/ci/smoke.sh'], g))   # CI changes: the canary
        self.assertFalse(rules.byhand_only(['labber/labber'], g))
        self.assertFalse(rules.byhand_only([], g))

    def test_glob(self):
        m = lambda p, s: bool(rules.glob_re(p).match(s))
        self.assertTrue(m('**/*.md', 'README.md')); self.assertTrue(m('**/*.md', 'guides/a/b.md'))
        self.assertFalse(m('**/*.md', 'guides/a.md.sh'))
        self.assertTrue(m('config/*.json', 'config/a.json')); self.assertFalse(m('config/*.json', 'config/x/a.json'))
        self.assertTrue(m('a/**', 'a/b/c')); self.assertFalse(m('a.json', 'aXjson'))
    def test_quick_lane(self):
        g = {'auto': ['homepage'], 'prepared': ['monitoring'], 'byhand': ['assistant-agent']}
        disp = {'all': ['**/*.md'], 'monitoring': ['config/grafana/provisioning/dashboards/*.json']}
        dash = 'services/monitoring/config/grafana/provisioning/dashboards/disks.json'
        self.assertEqual(rules.quick_lane([dash], g, disp), 'display')
        self.assertEqual(rules.quick_lane([dash, 'guides/x.md', 'services/homepage/README.md'], g, disp), 'display')
        self.assertEqual(rules.quick_lane([dash, 'services/assistant-agent/x.yml'], g, disp), 'by-hand')
        self.assertEqual(rules.quick_lane(['services/assistant-agent/x.yml'], g, disp), 'by-hand')
        for other in ['services/monitoring/config/grafana/provisioning/dashboards/dashboards.yml',   # the provider: config
                      'services/monitoring/config/prometheus/alerts.yml', 'services/monitoring/config/prometheus.yml',
                      'services/monitoring/docker-compose.yml', 'services/homepage/config/grafana/provisioning/dashboards/x.json',
                      'labber/labber', 'tests/ci/smoke.sh', 'gatekeeper/gatekeeper.py', 'architecture/net.svg']:
            self.assertEqual(rules.quick_lane([dash, other], g, disp), '', other)
        self.assertEqual(rules.quick_lane([], g, disp), '')
        self.assertEqual(rules.quick_lane([dash], g, {}), '')                     # no policy: the canary
        self.assertNotEqual(rules.quick_lane(['services/all/x.md'], g, {'all': ['x.md']}), 'display')   # 'all' is no service

if __name__ == '__main__':
    unittest.main(verbosity=1)
