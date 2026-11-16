#!/usr/bin/env python3
"""Offline tests of the hold check's reading of release notes. Run: python3 tests/ci/hold_check_test.py"""
import importlib.util, os, unittest
spec = importlib.util.spec_from_file_location('hold', os.path.join(os.path.dirname(__file__), '..', '..', '.forgejo', 'hold-check.py'))
hold = importlib.util.module_from_spec(spec); spec.loader.exec_module(hold)

REL = [{'tag_name': 'sdk-v1.0.21', 'published_at': '2026-10-25', 'prerelease': False, 'body': 'security fix in the SDK'},
       {'tag_name': 'v26.10.5', 'published_at': '2026-10-24', 'prerelease': False, 'body': 'New: dark mode'},
       {'tag_name': 'v26.10.4', 'published_at': '2026-10-22', 'prerelease': False, 'body': 'Fixed a typo'},
       {'tag_name': 'v26.10.6-rc1', 'published_at': '2026-10-26', 'prerelease': True, 'body': 'regression'},
       {'tag_name': 'v26.10.3', 'published_at': '2026-10-20', 'prerelease': False, 'body': ''}]

class HoldCheck(unittest.TestCase):
    def test_later_releases_of_the_same_shape_only(self):
        hold.http_json = lambda url, headers=None: (REL, {})
        self.assertEqual([r['tag_name'] for r in hold.later_releases('x/y', '26.10.3')], ['v26.10.5', 'v26.10.4'])
        self.assertIsNone(hold.later_releases('x/y', '9.9.9'))
    def test_backports_to_older_lines_are_not_later(self):
        rels = [{'tag_name': 'v13.2.4', 'published_at': '2026-10-01', 'prerelease': False, 'body': ''},
                {'tag_name': 'v13.1.8', 'published_at': '2026-10-20', 'prerelease': False, 'body': 'Security: CVE-2026-1'},
                {'tag_name': 'v12.4.13', 'published_at': '2026-10-20', 'prerelease': False, 'body': 'Security'},
                {'tag_name': 'v13.2.5', 'published_at': '2026-10-21', 'prerelease': False, 'body': 'Fixed a typo'}]
        hold.http_json = lambda url, headers=None: (rels, {})
        self.assertEqual([r['tag_name'] for r in hold.later_releases('x/y', '13.2.4')], ['v13.2.5'])
        rels.append({'tag_name': 'v14.0.0', 'published_at': '2026-10-22', 'prerelease': False, 'body': 'Security'})
        self.assertEqual([r['tag_name'] for r in hold.later_releases('x/y', '13.2.4')], ['v13.2.5'])   # another major: not ours
    def test_a_prerelease_with_the_same_number_is_another_products(self):
        rels = [{'tag_name': 'v3.7.22', 'published_at': '2026-10-28', 'prerelease': False, 'body': 'Security'},
                {'tag_name': 'v3.7.4', 'published_at': '2026-06-24', 'prerelease': True, 'body': ''}]
        hold.http_json = lambda url, headers=None: (rels, {})
        self.assertIsNone(hold.later_releases('x/y', '3.7.4'))   # not checked, not held
    def test_serious_words(self):
        for t in ('Security: …', 'fixes CVE-2026-1234', 'Reverted the migration', 'a regression in 1.2', 'data loss on restart', 'crash at start', 'hotfix'):
            self.assertTrue(hold.SERIOUS.search(t), t)
        for t in ('Fixed a typo', 'New: dark mode', 'fix the button colour', 'improved performance'):
            self.assertFalse(hold.SERIOUS.search(t), t)

if __name__ == '__main__':
    unittest.main(verbosity=1)
