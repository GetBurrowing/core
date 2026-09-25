#!/usr/bin/env bash
# vm-up.sh: boot a rendered single-host install on a throwaway KVM guest.
#
# The guest is a real QEMU/KVM virtual machine (own kernel, own cloud-init, own
# docker), run as a process inside a ROOTLESS podman container that is given
# /dev/kvm. No host package, no sudo. See README.md.
#
#   vm-up.sh --name <id> --workdir <dir> --render <dir> --https-port <p> --ssh-port <p>
#            [--cpus 4] [--memory 16G] [--disk 80G] [--dry-run]
#
# Creates, all named with <id>: image localhost/vmhost-<id>, container vm-<id>
# (plus the short-lived vmprep-<id>), ssh key <workdir>/ssh-<id>, and <workdir>
# itself. Ports are published on 127.0.0.1 only. Remove everything with vm-down.sh.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

name="" workdir="" render="" https_port="" ssh_port=""
cpus=4 memory=16G disk=80G dry_run=0
base_image=docker.io/library/ubuntu:24.04
cloud_base=https://cloud-images.ubuntu.com/noble/current
cloud_file=noble-server-cloudimg-amd64.img
boot_timeout=900

while (($#)); do
  case "$1" in
  --name) name=$2; shift 2 ;;
  --workdir) workdir=$2; shift 2 ;;
  --render) render=$2; shift 2 ;;
  --https-port) https_port=$2; shift 2 ;;
  --ssh-port) ssh_port=$2; shift 2 ;;
  --cpus) cpus=$2; shift 2 ;;
  --memory) memory=$2; shift 2 ;;
  --disk) disk=$2; shift 2 ;;
  --dry-run) dry_run=1; shift ;;
  -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
  *) die "unknown argument '$1'" ;;
  esac
done

[[ -n "$name" && -n "$workdir" && -n "$render" && -n "$https_port" && -n "$ssh_port" ]] ||
  die "--name, --workdir, --render, --https-port and --ssh-port are required"
check_name "$name"
check_workdir "$name" "$workdir"
check_port "$https_port"
check_port "$ssh_port"
[[ "$https_port" != "$ssh_port" ]] || die "--https-port and --ssh-port must differ"
[[ "$cpus" =~ ^[0-9]+$ ]] || die "--cpus must be an integer"

tag="localhost/vmhost-$name"
container="vm-$name"
prep="vmprep-$name"
key="$workdir/ssh-$name"
overlay="disk-$name.qcow2"
seed="seed-$name.iso"

containerfile="FROM $base_image
RUN apt-get update \\
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
      qemu-system-x86 qemu-utils cloud-image-utils \\
 && rm -rf /var/lib/apt/lists/*"

build_cmd=(podman build --layers=false --pull=never -t "$tag" -f - "$workdir/build")
prep_cmd=(podman run --rm --name "$prep" -v "$workdir:/work:Z" -w /work "$tag"
  sh -c "qemu-img create -q -f qcow2 -F qcow2 -b $cloud_file $overlay $disk \
&& cloud-localds $seed seed/user-data seed/meta-data")
qemu_cmd=(qemu-system-x86_64 -accel kvm -cpu host -smp "$cpus" -m "$memory"
  -display none -monitor none -serial file:/work/console.log
  -drive "if=virtio,file=/work/$overlay,format=qcow2"
  -drive "if=virtio,file=/work/$seed,format=raw,readonly=on"
  -netdev "user,id=net0,hostfwd=tcp::$ssh_port-:22,hostfwd=tcp::$https_port-:443"
  -device "virtio-net-pci,netdev=net0")
run_cmd=(podman run -d --name "$container" --device /dev/kvm --cpus "$cpus"
  -p "127.0.0.1:$https_port:$https_port" -p "127.0.0.1:$ssh_port:$ssh_port"
  -v "$workdir:/work:Z" "$tag" "${qemu_cmd[@]}")

if ((dry_run)); then
  echo "# dry run: nothing is created"
  echo "# Containerfile for $tag:"
  while IFS= read -r line; do echo "#   $line"; done <<<"$containerfile"
  show "${build_cmd[@]}"
  show curl -fsSL -o "$workdir/$cloud_file" "$cloud_base/$cloud_file"
  show "${prep_cmd[@]}"
  show "${run_cmd[@]}"
  exit 0
fi

for tool in podman curl sha256sum ssh ssh-keygen ss; do
  command -v "$tool" >/dev/null || die "missing host tool: $tool"
done
[[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm is not read/writable by $(id -un)"
for f in user-data meta-data; do [[ -s "$render/$f" ]] || die "render has no $f: $render"; done
for p in "$https_port" "$ssh_port"; do
  [[ -z "$(ss -ltnH "sport = :$p")" ]] || die "port $p is already listening (pick free ones per ss -ltn)"
done
if podman container exists "$container"; then die "container $container already exists"; fi

mkdir -p "$workdir/build" "$workdir/seed"
chmod 0700 "$workdir"

echo "== cloud image (verified against Ubuntu SHA256SUMS)"
curl -fsSL -o "$workdir/SHA256SUMS" "$cloud_base/SHA256SUMS"
[[ -s "$workdir/$cloud_file" ]] || curl -fsSL -o "$workdir/$cloud_file" "$cloud_base/$cloud_file"
want=$(awk -v f="*$cloud_file" '$2 == f {print $1}' "$workdir/SHA256SUMS")
[[ "$(wc -w <<<"$want")" -eq 1 ]] || die "SHA256SUMS has no single entry for $cloud_file"
got=$(sha256sum "$workdir/$cloud_file" | cut -d' ' -f1)
[[ "$got" == "$want" ]] || die "$cloud_file sha256 $got != SHA256SUMS $want"
echo "$cloud_file sha256 $got OK"

echo "== ssh key and NoCloud seed"
[[ -s "$key" ]] || ssh-keygen -q -t ed25519 -N '' -C "$container" -f "$key"
# user-data carries secrets.env: copied mode 0600, never printed.
install -m 0600 "$render/user-data" "$workdir/seed/user-data"
{
  cat "$render/meta-data"
  echo "public-keys:"
  echo "  - $(cat "$key.pub")"
} >"$workdir/seed/meta-data"
chmod 0600 "$workdir/seed/meta-data"

echo "== vm host image $tag"
if ! podman image exists "$tag"; then
  "${build_cmd[@]}" <<<"$containerfile"
fi
"${prep_cmd[@]}"

echo "== start $container"
"${run_cmd[@]}"
{
  printf 'NAME=%q\n' "$name"
  printf 'CONTAINER=%q\n' "$container"
  printf 'IMAGE_TAG=%q\n' "$tag"
  printf 'HTTPS_PORT=%q\n' "$https_port"
  printf 'SSH_PORT=%q\n' "$ssh_port"
  printf 'SSH_KEY=%q\n' "$key"
} >"$(state_file "$workdir")"

echo "== wait for ssh (up to ${boot_timeout}s)"
deadline=$((SECONDS + boot_timeout))
until "$here/vm-exec.sh" --workdir "$workdir" -- true 2>/dev/null; do
  podman container exists "$container" && [[ "$(podman inspect -f '{{.State.Running}}' "$container")" == true ]] ||
    die "$container stopped; see podman logs $container and $workdir/console.log"
  ((SECONDS < deadline)) || die "no ssh after ${boot_timeout}s; see $workdir/console.log"
  sleep 5
done
"$here/vm-exec.sh" --workdir "$workdir" -- uname -srm

echo "== wait for cloud-init"
"$here/vm-exec.sh" --workdir "$workdir" -- "timeout $boot_timeout cloud-init status --wait --long" ||
  die "cloud-init did not finish cleanly; see $workdir/console.log"
echo "vm-up: $container running; https 127.0.0.1:$https_port, ssh 127.0.0.1:$ssh_port"
