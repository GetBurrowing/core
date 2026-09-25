#!/usr/bin/env bash
# preload.sh: load a render's images and host files into the guest, then start
# the stack. For `images.source = "preloaded"` renders, whose suite-stack.service
# waits on /opt/suite/.images-loaded and whose compose services never pull.
#
#   preload.sh --workdir <dir> --render <dir> [--file <host-path>=<install-rel-path>]...
#              [--pull-missing-public] [--dry-run]
#
# Each image ref named in <render>/compose.yaml is streamed from THIS host's
# local podman store (`podman save | docker load`, read-only on the host store;
# nothing is written to the workdir; layer diff ids compared). A ref the host
# store does not hold is an error, unless --pull-missing-public is given: then the GUEST pulls it
# anonymously. No registry credential is used or copied by this script.
# --file copies a host file (read-only source) to /opt/suite/<install-rel-path>.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

workdir="" render="" pull_missing=0 dry_run=0
files=()
while (($#)); do
  case "$1" in
  --workdir) workdir=$2; shift 2 ;;
  --render) render=$2; shift 2 ;;
  --file) files+=("$2"); shift 2 ;;
  --pull-missing-public) pull_missing=1; shift ;;
  --dry-run) dry_run=1; shift ;;
  -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
  *) die "unknown argument '$1'" ;;
  esac
done
[[ -n "$workdir" && -n "$render" ]] || die "--workdir and --render are required"
[[ -s "$render/compose.yaml" ]] || die "no compose.yaml in $render"

vx() { "$here/vm-exec.sh" --workdir "$workdir" -- "$@"; }

mapfile -t refs < <(sed -n 's/^    image: "\(.*\)"$/\1/p' "$render/compose.yaml" | sort -u)
((${#refs[@]})) || die "no image refs found in $render/compose.yaml"

local_refs=() missing=()
for ref in "${refs[@]}"; do
  if podman image exists "$ref"; then local_refs+=("$ref"); else missing+=("$ref"); fi
done
echo "== images named by the render: ${#refs[@]} (host store: ${#local_refs[@]}, missing: ${#missing[@]})"
for ref in "${missing[@]}"; do echo "missing from host store: $ref"; done
if ((${#missing[@]})) && ! ((pull_missing)); then
  die "images missing from the host store; load them first or pass --pull-missing-public"
fi

for spec in "${files[@]}"; do
  [[ "$spec" == *=* ]] || die "--file wants <host-path>=<install-rel-path>: '$spec'"
  src=${spec%%=*} dst=${spec#*=}
  [[ -r "$src" ]] || die "cannot read $src"
  [[ "$dst" != /* && "$dst" != *..* ]] || die "install path must be relative, without '..': $dst"
done

if ((dry_run)); then
  for ref in "${local_refs[@]}"; do show podman save --format docker-archive "$ref" "|" vm-exec sudo docker load; done
  for ref in "${missing[@]}"; do show vm-exec sudo docker pull "$ref"; done
  for spec in "${files[@]}"; do show cat "${spec%%=*}" "|" vm-exec "> /opt/suite/${spec#*=}"; done
  exit 0
fi

load_state "$workdir"
echo "== wait for cloud-init in the guest"
vx "cloud-init status --wait >/dev/null; command -v docker >/dev/null" || die "guest has no docker yet"

layers_fmt='{{range .RootFS.Layers}}{{.}} {{end}}'
for ref in "${local_refs[@]}"; do
  echo "== load $ref (host store -> guest)"
  podman save --format docker-archive "$ref" | vx "sudo docker load -q"
  # Compare the layer diff ids, not the image id: docker's containerd image
  # store (the default since docker 29) ids an image by its manifest digest,
  # which `docker load` recomputes, while podman ids it by its config digest.
  host_layers=$(podman image inspect -f "$layers_fmt" "$ref" | sha256sum | cut -d' ' -f1)
  guest_layers=$(vx "sudo docker image inspect -f '$layers_fmt' '$ref' | sha256sum" | cut -d' ' -f1)
  [[ "$guest_layers" == "$host_layers" ]] || die "$ref: guest layers differ from the host store"
  echo "$ref layers sha256 ${host_layers:0:12} match host"
done
for ref in "${missing[@]}"; do
  echo "== pull $ref in the guest (anonymous, public)"
  vx "sudo docker pull -q '$ref'"
done

for spec in "${files[@]}"; do
  src=${spec%%=*} dst=/opt/suite/${spec#*=}
  echo "== copy $(basename "$src") -> $dst"
  vx "sudo install -d -m 0755 '$(dirname "$dst")' && sudo sh -c 'cat > \"$dst.tmp\" && mv \"$dst.tmp\" \"$dst\"'" <"$src"
  want=$(sha256sum "$src" | cut -d' ' -f1)
  got=$(vx "sudo sha256sum '$dst'" | cut -d' ' -f1)
  [[ "$got" == "$want" ]] || die "$dst sha256 mismatch after copy"
  echo "$dst sha256 ${want:0:12} matches host"
done

echo "== start suite-stack.service"
vx "sudo touch /opt/suite/.images-loaded && sudo systemctl start suite-stack.service"
vx "systemctl is-active suite-stack.service"
vx "cd /opt/suite && sudo docker compose ps --format '{{.Service}} {{.State}}'"
