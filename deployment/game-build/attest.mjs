// GitHub's keyless attestation library; private bundles stay with private artifacts.
// skipWrite avoids the unsupported attestation-index API on user-owned private repos.
import { attestProvenance } from '@actions/attest';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join, basename } from 'node:path';
const directory = process.argv[2];
const subjects = readdirSync(directory).filter(n => n.endsWith('.zip') || n.endsWith('.tar.gz'))
  .map(name => ({ name: basename(name), digest: { sha256: createHash('sha256').update(readFileSync(join(directory, name))).digest('hex') } }));
if (subjects.length !== 4) throw new Error('Incomplete native archive set');
const attestation = await attestProvenance({ subjects, token: process.env.GH_TOKEN, sigstore: 'github', skipWrite: true });
writeFileSync(join(directory, 'provenance.json'), JSON.stringify(attestation.bundle) + '\n', { mode: 0o600 });
console.log('Created GitHub keyless provenance bundle for all four native archives.');
