"""Pure preparation/safety tests; never start a daemon, UI helper or payload transfer."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('soak', Path(__file__).parents[1] / 'soak.py')
soak = importlib.util.module_from_spec(spec); spec.loader.exec_module(soak)


def torrent(name=b'fixture', size=1):
    return b'd4:infod6:lengthi'+str(size).encode()+b'e4:name'+str(len(name)).encode()+b':'+name+b'12:piece lengthi16384e6:pieces20:'+b'a'*20+b'ee'


class SoakSafetyTests(unittest.TestCase):
    def test_metadata_size_and_hash(self):
        value = soak.metainfo(torrent())
        self.assertEqual(value['bytes'], 1)
        self.assertEqual(value['name'], 'fixture')
        self.assertEqual(len(value['hash']), 40)

    def test_unsafe_paths_rejected(self):
        for name in (b'..', b'/tmp/file', b'a\\b', b'a\0b'):
            with self.subTest(name=name), self.assertRaises(ValueError): soak.metainfo(torrent(name))

    def test_truncation_duplicate_info_and_bad_piece_count(self):
        for raw in (torrent()[:-1], torrent()+b'e', b'd4:infod4:name1:aee',
                    torrent().replace(b'6:pieces20:', b'6:pieces19:')):
            with self.subTest(raw=raw), self.assertRaises((ValueError, KeyError)): soak.metainfo(raw)

    def test_guards_distinguish_network_pause_from_safety_stop(self):
        plan = {'min_free_bytes': 100, 'rss_limit': 30, 'download_budget': 12, 'upload_budget': 4}
        self.assertIsNone(soak.budget_reason(plan, 101, 29, 11, 3))
        self.assertEqual(soak.budget_reason(plan, 99, 29, 11, 3), 'disk-reserve')
        self.assertEqual(soak.budget_reason(plan, 101, 31, 11, 3), 'rss-limit')
        self.assertEqual(soak.budget_reason(plan, 101, 29, 12, 3), 'network-budget')
        self.assertEqual(soak.budget_reason(plan, 101, 29, 11, 4), 'network-budget')

    def test_run_without_confirmation_never_launches(self):
        with patch.object(soak.subprocess, 'Popen') as popen:
            with self.assertRaisesRegex(ValueError, 'confirm-start'): soak.run(Path('/nonexistent'), False)
            popen.assert_not_called()

    def test_prepare_pins_artifacts_without_starting(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            app = base/'input.app'; engine = app/'Contents/Helpers/transmission-daemon'
            engine.parent.mkdir(parents=True); engine.write_bytes(b'engine')
            bundle = base/'input.xctest'; executable = bundle/'Contents/MacOS/HarborPackageTests'
            executable.parent.mkdir(parents=True); executable.write_bytes(b'fixture')
            helper = base/'helper'; helper.write_bytes(b'helper')
            metadata = base/'fixture.torrent'; metadata.write_bytes(torrent())
            root = base/'run'
            with patch.object(soak.subprocess, 'Popen') as popen:
                plan = soak.prepare(root, app, bundle, helper, [metadata])
                self.assertEqual(plan['status'], 'prepared-not-started')
                self.assertFalse((root/'state.json').exists())
                self.assertFalse((root/'profile').exists())
                self.assertFalse((root/'Downloads').exists())
                popen.assert_not_called()
            with patch.object(soak.shutil, 'disk_usage') as disk:
                disk.return_value.free = 200 * soak.GIB
                soak.verify(plan, root)
                Path(plan['torrents'][0]['metainfo']).write_bytes(b'tamper')
                with self.assertRaisesRegex(ValueError, 'metadata changed'): soak.verify(plan, root)

    def test_rotating_child_log_is_bounded(self):
        import io
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'child.log'
            soak.bounded_pipe(io.BytesIO(b'x' * (27 * 1024 ** 2)), path)
            self.assertLessEqual(sum(p.stat().st_size for p in Path(folder).iterdir()), 24 * 1024 ** 2)


if __name__ == '__main__': unittest.main()
