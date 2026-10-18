#!/bin/bash
# proof.sh: data-plane proof of a Burrow install on this Mac (task 01a0d6ab
# stage 5). A thin door onto `suite-install proof`, which holds the logic
# (suite_install/proof_mac.py) and its tests. Run it ON the Mac.
#
#   proof.sh init --zone example.com --image-namespace NS   # install suite-01a0d6ab, meetings off
#   proof.sh ports                            # listening ports, 7881/7882, name clashes
#   proof.sh ram --label before|idle|after    # docker stats, VM memory, memory_pressure
#   proof.sh arch                             # image arch + uname -m in the services
#   proof.sh memory                           # pgvector width, canary/control ranks
#   proof.sh files                            # 1 MiB round trip over the public URL
#   proof.sh meetings --expect on|off         # livekit present? core LIVEKIT_ count
#   proof.sh livekit                          # two lk publishers, participants list
#   proof.sh --grep-transcript --transcript F --marker M [--key-file P ...]
#            [--human-turns [--expect-human-turns N]]   # list what a human typed
#
# Output is `key value` lines and one `RESULT PASS|FAIL|CHECK <command>` line:
# ids, digests, ranks, scores, counts and names only, never a secret value.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ "${1:-}" = "--grep-transcript" ]; then
  shift
  set -- grep-transcript "$@"
fi
exec "$here/suite-install" proof "$@"
