# Throwaway-VM proof for single-host renders

These scripts boot a render from `suite_install render` on a disposable KVM
virtual machine, so a rendered install can be checked end to end (TLS, sign-in
redirect, service set) without touching any real host. ADR 0053 records the
proof runs.

The guest is a real QEMU/KVM VM with its own kernel, its own cloud-init and its
own docker. QEMU runs as the main process of a ROOTLESS podman container that
is given `/dev/kvm`, so the host needs only podman and a world-accessible
`/dev/kvm`: no qemu package, no libvirt and no sudo. The stack runs inside the
guest, not in a container on the host.

| Script | Does |
| --- | --- |
| `vm-up.sh` | builds `localhost/vmhost-<id>` (ubuntu:24.04 + qemu-system-x86, qemu-utils, cloud-image-utils), downloads the Ubuntu 24.04 cloud image into the workdir and verifies it against Ubuntu's `SHA256SUMS`, creates a qcow2 overlay and a NoCloud seed (the render's `user-data`, plus its `meta-data` with a per-run ssh key), starts container `vm-<id>` with `--cpus` (default 4) and ports published on `127.0.0.1` only, then waits for ssh and cloud-init. `--dry-run` prints the command lines and creates nothing. |
| `preload.sh` | for `images.source = "preloaded"`: streams every image ref in the render's `compose.yaml` from the host's podman store into the guest's docker (`podman save \| docker load`, image ids compared), copies `--file` host files (sha256 compared), touches `/opt/suite/.images-loaded` and starts `suite-stack.service`. Refs the host store lacks are an error unless `--pull-missing-public`, which makes the guest pull them anonymously. No registry credential is used. |
| `vm-exec.sh` | ssh into the guest as `ubuntu`; stdin passes through. |
| `vm-down.sh` | prints the evidence checks (container, image tag, workdir, both ports, processes) while the VM is up, removes everything, prints them again and fails if any still hits. |

Every resource carries the `--name` id, and the workdir path must contain it.
`vm-down.sh` removes only what `vm-up.sh` created. A host image you pulled for a run (for
example a core build tagged with the id) is not removed, but the image check reports it, so
teardown fails until you `podman rmi` it.

## Example (the ADR 0053 proof on test-host)

```bash
id=01a0d69d
wd=~/$id-vm
src=~/$id-src            # a clone at the branch tip
export PYTHONPATH=$src/deployment/installer
python3 -m suite_install render $src/deployment/examples/single-host.install.toml --out $wd/render
$src/deployment/installer/proof/vm-up.sh --name $id --workdir $wd --render $wd/render \
  --https-port 18443 --ssh-port 18022
$src/deployment/installer/proof/preload.sh --workdir $wd --render $wd/render --pull-missing-public \
  --file ~/models/qwen3-embedding-0.6b-gguf/Qwen3-Embedding-0.6B-f16.gguf=models/Qwen3-Embedding-0.6B-f16.gguf

# The guest's PUBLIC root certificate; the key never leaves the guest.
$src/deployment/installer/proof/vm-exec.sh --workdir $wd -- sudo cat /opt/suite/tls/root.crt > $wd/root.crt
pin=(--cacert $wd/root.crt
     --connect-to suite-$id.test:443:127.0.0.1:18443
     --connect-to auth.suite-$id.test:443:127.0.0.1:18443)
curl -sS "${pin[@]}" -o /dev/null -w '%{http_code}\n' https://suite-$id.test/health
curl -sS "${pin[@]}" -o /dev/null -w '%{http_code} %{redirect_url}\n' https://suite-$id.test/auth/login

$src/deployment/installer/proof/vm-down.sh --name $id --workdir $wd
```

Never use `curl -k` for these checks: the point is that TLS verifies against the
install's own root. Never print `user-data` or `secrets.env`; both carry secrets.
Pick ports that `ss -ltn` shows free; `vm-up.sh` refuses busy ones.
