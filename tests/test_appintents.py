"""Merging preserves host actions/version while repairing missing version metadata."""
import json
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = 'Payload/Spotify.app/'
MEMBER = APP + 'Metadata.appintents/'


class AppIntentsTests(unittest.TestCase):
    def test_missing_and_existing_host_metadata(self):
        for has_actions, has_version in ((False, False), (True, False), (True, True), (False, True)):
            with self.subTest(actions=has_actions, version=has_version), tempfile.TemporaryDirectory() as folder:
                folder = Path(folder)
                ipa, ours = folder / 'input.ipa', folder / 'ours'
                ours.mkdir()
                added = {'actions': {'ModIntent': {'value': 1}}}
                added_version = {'version': '3.0', 'toolsVersion': 'new'}
                host_version = {'version': '3.0', 'toolsVersion': 'existing'}
                (ours / 'extract.actionsdata').write_text(json.dumps(added))
                (ours / 'version.json').write_text(json.dumps(added_version))
                with zipfile.ZipFile(ipa, 'w') as archive:
                    archive.writestr('unchanged', b'keep')
                    if has_actions:
                        archive.writestr(MEMBER + 'extract.actionsdata', json.dumps({'actions': {'HostIntent': {}}, 'other': 5}))
                    if has_version:
                        archive.writestr(MEMBER + 'version.json', json.dumps(host_version))
                args = ['python3', str(ROOT / 'scripts/merge-appintents.py'), str(ipa), APP, str(ours)]
                subprocess.run(args, check=True, capture_output=True)
                subprocess.run(args, check=True, capture_output=True)
                with zipfile.ZipFile(ipa) as archive:
                    self.assertEqual(archive.read('unchanged'), b'keep')
                    self.assertEqual(len(archive.namelist()), len(set(archive.namelist())))
                    self.assertEqual(json.loads(archive.read(MEMBER + 'version.json')), host_version if has_version else added_version)
                    merged = json.loads(archive.read(MEMBER + 'extract.actionsdata'))
                    self.assertEqual(merged['actions']['ModIntent'], added['actions']['ModIntent'])
                    self.assertEqual(len(merged['actions']), 2 if has_actions else 1)
                    if has_actions:
                        self.assertEqual(merged['other'], 5)
                        self.assertIn('HostIntent', merged['actions'])


if __name__ == '__main__':
    unittest.main()
