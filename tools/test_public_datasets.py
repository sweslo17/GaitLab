import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from public_datasets import acquire, git_blob_sha, verify_bytes, TRIALS


class PublicDataTests(unittest.TestCase):
    def test_git_blob_hash_known_example(self):
        self.assertEqual(git_blob_sha(b'hello\n'),
                         'ce013625030ba8dba906f756967f9e9ca394464a')

    def test_modified_public_file_rejected(self):
        sha = git_blob_sha(b'good data')
        verify_bytes(b'good data', sha)
        with self.assertRaisesRegex(ValueError, 'Dataset changed'):
            verify_bytes(b'modified', sha)

    def test_offline_requires_explicit_data_files(self):
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaises(FileNotFoundError):
                acquire(Path(td), fetch=False)

    def test_three_trials_pinned(self):
        self.assertEqual(set(TRIALS), {'running_pants', 'sitting_pants', 'running_upper'})
        self.assertTrue(all(len(v['blob']) == 40 for v in TRIALS.values()))
        self.assertTrue(all('/' in v['path'] and v['path'].endswith('.csv') for v in TRIALS.values()))


if __name__ == '__main__':
    unittest.main()
