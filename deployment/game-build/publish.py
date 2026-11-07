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
REQUIRED = {('windows', 'x86_64', 'client'), ('linux', 'x86_64', 'client'), ('macos', 'universal', 'client'), ('linux', 'x86_64', 'server')}
SHA = re.compile('^[0-9a-f]{64}$')

def require(condition, message='invalid native package'):
    if not condition:
        raise ValueError(message)


def safe_path(value):
    p = PurePosixPath(value)
    return bool(value) and (not p.is_absolute()) and ('..' not in p.parts) and ('\\' not in value) and (':' not in value)

def validate(manifest, directory=None):
    require(manifest['schema_version'] == 1, 'invalid native package')
    require(isinstance(manifest['id'], str) and 1 <= len(manifest['id']) <= 128)
    require(re.fullmatch('[0-9a-f]{40}', manifest['source_sha']), 'invalid native package')
    require(re.fullmatch('[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', manifest['repository']), 'invalid native package')
    require(manifest['repo_url'] == 'https://github.com/' + manifest['repository'], 'invalid native package')
    require(isinstance(manifest['engine'], str) and manifest['engine'], 'invalid native package')
    require(isinstance(manifest['build_number'], int) and manifest['build_number'] > 0, 'invalid native package')
    require(isinstance(manifest['protocol_version'], int) and manifest['protocol_version'] > 0, 'invalid native package')
    require(1 <= manifest['capacity'] <= 8, 'invalid native package')
    require(re.fullmatch('[a-z0-9][a-z0-9./:_-]*@sha256:[0-9a-f]{64}', manifest['server_image']), 'invalid native package')
    seen = set()
    for a in manifest['artifacts']:
        key = (a['os'], a['arch'], a['role'])
        require(key not in seen, 'invalid native package')
        seen.add(key)
        require(safe_path(a['executable']) and safe_path(a['filename']), 'invalid native package')
        require(isinstance(a['asset_id'], int) and a['asset_id'] > 0, 'invalid native package')
        require('/' not in a['filename'] and SHA.fullmatch(a['sha256']), 'invalid native package')
        require(isinstance(a['size'], int) and a['size'] > 0, 'invalid native package')
        if directory is not None:
            path = Path(directory) / a['filename']
            require(path.stat().st_size == a['size'], 'invalid native package')
            require(hashlib.sha256(path.read_bytes()).hexdigest() == a['sha256'], 'invalid native package')
            if zipfile.is_zipfile(path):
                with zipfile.ZipFile(path) as z:
                    require(all((safe_path(i.filename.rstrip('/')) for i in z.infolist())), 'invalid native package')
                    require(a['executable'] in z.namelist(), 'invalid native package')
                    require(z.getinfo(a['executable']).file_size > 0, 'invalid native package')
                    require(all((i.external_attr >> 16) & 0o170000 != 0o120000 for i in z.infolist()), 'symlink in archive')
                    require(any((i.filename.endswith('.pck') and i.file_size > 0 for i in z.infolist())), 'missing game resources')
            else:
                with tarfile.open(path, 'r:gz') as t:
                    members = t.getmembers()
                    require(all((safe_path(i.name) and (not (i.issym() or i.islnk())) for i in members)), 'invalid native package')
                    executable = t.getmember(a['executable'])
                    require(executable.isfile() and executable.size > 0 and executable.mode & 73, 'invalid native package')
                    require(any((i.name.endswith('.pck') and i.size > 0 for i in members)), 'missing game resources')
    require(REQUIRED <= seen, 'incomplete platform matrix')
    return manifest

def oidc(audience):
    url = os.environ['ACTIONS_ID_TOKEN_REQUEST_URL'] + '&audience=' + urllib.parse.quote(audience, safe='')
    req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + os.environ['ACTIONS_ID_TOKEN_REQUEST_TOKEN']})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)['value']

def register(manifest, endpoint, project):
    origin = urllib.parse.urlsplit(endpoint)
    require(origin.scheme == 'https' and origin.hostname and not origin.username and not origin.password and not origin.query and not origin.fragment and origin.path in ('', '/'), 'an HTTPS publication origin is required')
    token = oidc('burrow-native-builds')
    req = urllib.request.Request(endpoint.rstrip('/') + '/api/ext/play/builds/' + project, data=json.dumps(manifest).encode(), method='POST', headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=60) as response:
        return json.load(response)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('manifest')
    parser.add_argument('--directory', required=True)
    parser.add_argument('--endpoint')
    parser.add_argument('--project')
    parser.add_argument('--verify-attestations', action='store_true')
    parser.add_argument('--bundle')
    args = parser.parse_args()
    manifest = validate(json.loads(Path(args.manifest).read_text()), args.directory)
    if args.verify_attestations:
        require(args.bundle, 'a retained keyless provenance bundle is required')
        workflow, signer_sha = manifest['publisher_workflow'].rsplit('@', 1)
        require(re.fullmatch('[0-9a-f]{40}', signer_sha), 'invalid native package')
        for a in manifest['artifacts']:
            subprocess.run(['gh', 'attestation', 'verify', str(Path(args.directory) / a['filename']), '--bundle', args.bundle, '--custom-trusted-root', str(Path(__file__).with_name('trusted_root.jsonl')), '--repo', manifest['repository'], '--signer-workflow', workflow, '--signer-digest', signer_sha, '--deny-self-hosted-runners', '--source-ref', 'refs/heads/main', '--source-digest', manifest['source_sha']], check=True, stdout=subprocess.DEVNULL)
    if args.endpoint is not None:
        require(args.verify_attestations, 'publication requires verified provenance')
        require(args.project, 'invalid native package')
        register(manifest, args.endpoint, args.project)
    print('Native packages validated: ' + manifest['id'])
if __name__ == '__main__':
    main()
