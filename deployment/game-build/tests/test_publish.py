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
                    z.writestr('game.pck', b'packaged resources')
            else:
                with tarfile.open(path, 'w:gz') as t:
                    info = tarfile.TarInfo('game')
                    info.size, info.mode = 17, 0o755
                    t.addfile(info, io.BytesIO(b'native executable'))
                    resources = tarfile.TarInfo('game.pck')
                    resources.size, resources.mode = 18, 0o644
                    t.addfile(resources, io.BytesIO(b'packaged resources'))
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
        with self.assertRaises(ValueError):
            publish.validate(self.manifest, self.directory)

    def test_checksum_mismatch_cannot_publish(self):
        self.manifest['artifacts'][0]['sha256'] = '0'*64
        with self.assertRaises(ValueError):
            publish.validate(self.manifest, self.directory)

    def test_missing_executable_cannot_publish(self):
        self.manifest['artifacts'][0]['executable'] = 'missing'
        with self.assertRaises((ValueError, KeyError)):
            publish.validate(self.manifest, self.directory)

    def test_path_traversal_and_duplicate_platform_rejected(self):
        for value in ('../escape', '/absolute', 'C:\\escape'):
            manifest = copy.deepcopy(self.manifest)
            manifest['artifacts'][0]['executable'] = value
            with self.assertRaises(ValueError):
                publish.validate(manifest, self.directory)
        self.manifest['artifacts'].append(self.manifest['artifacts'][0])
        with self.assertRaises(ValueError):
            publish.validate(self.manifest, self.directory)

    def test_resource_free_archive_rejected_even_when_digest_matches(self):
        artifact = next(a for a in self.manifest['artifacts'] if a['os'] == 'windows')
        path = self.directory / artifact['filename']
        with zipfile.ZipFile(path, 'w') as z:
            z.writestr('game', b'native executable')
        artifact['size'] = path.stat().st_size
        artifact['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, 'missing game resources'):
            publish.validate(self.manifest, self.directory)

    def test_symlink_zip_rejected_even_when_digest_matches(self):
        artifact = next(a for a in self.manifest['artifacts'] if a['os'] == 'windows')
        path = self.directory / artifact['filename']
        with zipfile.ZipFile(path, 'a') as z:
            link = zipfile.ZipInfo('link')
            link.create_system = 3
            link.external_attr = 0o120777 << 16
            z.writestr(link, '/outside')
        artifact['size'] = path.stat().st_size
        artifact['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, 'symlink'):
            publish.validate(self.manifest, self.directory)

    def test_empty_publication_destination_fails_before_requesting_identity(self):
        for endpoint in ('', 'http://example.invalid', 'https://token@example.invalid', 'https://example.invalid/?secret=x'):
            with self.assertRaises(ValueError):
                publish.register(self.manifest, endpoint, 'project')

    def test_no_engine_build_or_unreal_pipeline(self):
        self.assertNotIn('RunUAT', Path(publish.__file__).read_text())
        self.assertFalse((Path(publish.__file__).parent / 'unreal.sh').exists())


if __name__ == '__main__':
    unittest.main()
