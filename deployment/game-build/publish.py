#!/usr/bin/env python3
"""Engine-neutral immutable package publisher. Never executes an engine or an archive."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import urllib.request
import urllib.parse
import zipfile

REQUIRED = {('windows', 'x86_64', 'client'), ('linux', 'x86_64', 'client'),
            ('macos', 'universal', 'client'), ('linux', 'x86_64', 'server')}
SHA = re.compile(r'^[0-9a-f]{64}$')


def safe_path(value):
    p = PurePosixPath(value)
    return bool(value) and not p.is_absolute() and '..' not in p.parts and '\\' not in value and ':' not in value


def validate(manifest, directory=None):
    assert manifest['schema_version'] == 1
    assert re.fullmatch(r'[0-9a-f]{40}', manifest['source_sha'])
    assert re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', manifest['repository'])
    assert manifest['repo_url'] == 'https://github.com/' + manifest['repository']
    assert isinstance(manifest['engine'], str) and manifest['engine']
    assert isinstance(manifest['build_number'], int) and manifest['build_number'] > 0
    assert isinstance(manifest['protocol_version'], int) and manifest['protocol_version'] > 0
    assert 1 <= manifest['capacity'] <= 8
    assert re.fullmatch(r'[a-z0-9][a-z0-9./:_-]*@sha256:[0-9a-f]{64}', manifest['server_image'])
    seen = set()
    for a in manifest['artifacts']:
        key = a['os'], a['arch'], a['role']
        assert key not in seen
        seen.add(key)
        assert safe_path(a['executable']) and safe_path(a['filename'])
        assert isinstance(a['asset_id'], int) and a['asset_id'] > 0
        assert '/' not in a['filename'] and SHA.fullmatch(a['sha256'])
        assert isinstance(a['size'], int) and a['size'] > 0
        if directory is not None:
            path = Path(directory) / a['filename']
            assert path.stat().st_size == a['size']
            assert hashlib.sha256(path.read_bytes()).hexdigest() == a['sha256']
            if zipfile.is_zipfile(path):
                with zipfile.ZipFile(path) as z:
                    assert all(safe_path(i.filename.rstrip('/')) for i in z.infolist())
                    assert a['executable'] in z.namelist()
                    assert z.getinfo(a['executable']).file_size > 0
                    assert any(i.filename.endswith('.pck') and i.file_size > 0 for i in z.infolist()), 'missing game resources'
            else:
                with tarfile.open(path, 'r:gz') as t:
                    members = t.getmembers()
                    assert all(safe_path(i.name) and not (i.issym() or i.islnk()) for i in members)
                    executable = t.getmember(a['executable'])
                    assert executable.isfile() and executable.size > 0 and executable.mode & 0o111
                    assert any(i.name.endswith('.pck') and i.size > 0 for i in members), 'missing game resources'
    assert REQUIRED <= seen, 'incomplete platform matrix'
    return manifest


def oidc(audience):
    url = os.environ['ACTIONS_ID_TOKEN_REQUEST_URL'] + '&audience=' + urllib.parse.quote(audience, safe='')
    req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + os.environ['ACTIONS_ID_TOKEN_REQUEST_TOKEN']})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)['value']


def register(manifest, endpoint, project):
    # Fixed HTTPS trust boundary. OIDC tokens are never command-line arguments or logged.
    assert endpoint.startswith('https://') and '?' not in endpoint
    token = oidc('burrow-native-builds')
    req = urllib.request.Request(endpoint.rstrip('/') + '/api/ext/play/builds/' + project,
                                 data=json.dumps(manifest).encode(), method='POST',
                                 headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=60) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('manifest')
    parser.add_argument('--directory', required=True)
    parser.add_argument('--endpoint')
    parser.add_argument('--project')
    parser.add_argument('--verify-attestations', action='store_true')
    args = parser.parse_args()
    manifest = validate(json.loads(Path(args.manifest).read_text()), args.directory)
    if args.verify_attestations:
        workflow, signer_sha = manifest['publisher_workflow'].rsplit('@', 1)
        assert re.fullmatch(r'[0-9a-f]{40}', signer_sha)
        for a in manifest['artifacts']:
            subprocess.run(['gh', 'attestation', 'verify', str(Path(args.directory) / a['filename']),
                            '--repo', manifest['repository'], '--signer-workflow', workflow, '--signer-digest', signer_sha,
                            '--deny-self-hosted-runners', '--source-ref', 'refs/heads/main',
                            '--source-digest', manifest['source_sha']], check=True, stdout=subprocess.DEVNULL)
    if args.endpoint:
        assert args.verify_attestations, 'publication requires verified provenance'
        assert args.project
        register(manifest, args.endpoint, args.project)
    print('Native packages validated: ' + manifest['id'])


if __name__ == '__main__':
    main()
