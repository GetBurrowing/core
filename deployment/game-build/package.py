#!/usr/bin/env python3
"""Generate metadata after validated packages have immutable GitHub release assets."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--repository', required=True)
p.add_argument('--sha', required=True)
p.add_argument('--number', type=int, required=True)
p.add_argument('--image', required=True)
p.add_argument('--workflow', required=True)
p.add_argument('--directory', required=True)
a = p.parse_args()
directory = Path(a.directory)
tag = 'native-' + a.sha
assets = json.loads(subprocess.check_output(['gh', 'api', 'repos/' + a.repository + '/releases/tags/' + tag]))['assets']
ids = {x['name']: x['id'] for x in assets}
artifacts = []
for os_name, arch, role, filename, executable in [
    ('windows', 'x86_64', 'client', 'windows-x86_64.zip', 'voltron.exe'),
    ('linux', 'x86_64', 'client', 'linux-x86_64.tar.gz', 'voltron.x86_64'),
    ('macos', 'universal', 'client', 'macos-universal.zip', 'Voltron.app/Contents/MacOS/Voltron'),
    ('linux', 'x86_64', 'server', 'linux-server-x86_64.tar.gz', 'voltron-server.x86_64')]:
    data = (directory / filename).read_bytes()
    artifacts.append(dict(os=os_name, arch=arch, role=role, filename=filename, executable=executable,
                          size=len(data), sha256=hashlib.sha256(data).hexdigest(), asset_id=ids[filename]))
manifest = dict(schema_version=1, id=tag, repository=a.repository, repo_url='https://github.com/' + a.repository,
                source_sha=a.sha, build_number=a.number, engine='godot', engine_version='4.7.2',
                protocol_version=1, capacity=4, server_image=a.image,
                publisher_workflow=a.workflow, artifacts=artifacts)
(directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
