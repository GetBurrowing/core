import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('publish', Path(__file__).parents[1] / 'publish.py')
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)


class Packages(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        artifacts = []
        for os_name, arch, role in sorted(publish.REQUIRED):
            name = os_name + '-' + role + ('.zip' if os_name in ('windows', 'macos') else '.tar.gz')
            path = self.directory / name
            if name.endswith('.zip'):
                with zipfile.ZipFile(path, 'w') as z:
                    z.writestr('game', b'native executable')
            else:
                with tarfile.open(path, 'w:gz') as t:
                    info = tarfile.TarInfo('game')
                    info.size, info.mode = 17, 0o755
                    t.addfile(info, io.BytesIO(b'native executable'))
            data = path.read_bytes()
            artifacts.append(dict(os=os_name, arch=arch, role=role, filename=name, executable='game',
                                  sha256=hashlib.sha256(data).hexdigest(), size=len(data), asset_id=1))
        self.manifest = dict(schema_version=1, id='native-' + 'a'*40, repository='owner/game',
                             repo_url='https://github.com/owner/game', source_sha='a'*40, build_number=42,
                             engine='godot', protocol_version=1, capacity=4,
                             server_image='registry/game@sha256:' + 'b'*64, artifacts=artifacts)

    def test_complete_packages_and_open_engine_metadata(self):
        for engine in ('godot', 'future-engine'):
            self.manifest['engine'] = engine
            self.assertEqual(publish.validate(self.manifest, self.directory)['engine'], engine)

    def test_missing_platform_cannot_publish(self):
        self.manifest['artifacts'].pop()
        with self.assertRaises(AssertionError):
            publish.validate(self.manifest, self.directory)

    def test_checksum_mismatch_cannot_publish(self):
        self.manifest['artifacts'][0]['sha256'] = '0'*64
        with self.assertRaises(AssertionError):
            publish.validate(self.manifest, self.directory)

    def test_missing_executable_cannot_publish(self):
        self.manifest['artifacts'][0]['executable'] = 'missing'
        with self.assertRaises((AssertionError, KeyError)):
            publish.validate(self.manifest, self.directory)

    def test_path_traversal_and_duplicate_platform_rejected(self):
        for value in ('../escape', '/absolute', 'C:\\escape'):
            manifest = copy.deepcopy(self.manifest)
            manifest['artifacts'][0]['executable'] = value
            with self.assertRaises(AssertionError):
                publish.validate(manifest, self.directory)
        self.manifest['artifacts'].append(self.manifest['artifacts'][0])
        with self.assertRaises(AssertionError):
            publish.validate(self.manifest, self.directory)

    def test_no_engine_build_or_unreal_pipeline(self):
        self.assertNotIn('RunUAT', Path(publish.__file__).read_text())
        self.assertFalse((Path(publish.__file__).parent / 'unreal.sh').exists())


if __name__ == '__main__':
    unittest.main()
