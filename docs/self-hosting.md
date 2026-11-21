# Self-hosting Burrow

This guide runs Burrow on one Ubuntu 24.04 server that you control. You render the install
on your own machine, and the server sets itself up at first boot from that render, pulling
the public Burrow images from `ghcr.io/getburrowing`.

## 1. What you need

- An **Ubuntu 24.04 server** from any provider that accepts cloud-init user data when you
  create it. Size: **2 vCPU and 4 GB RAM**, with at least 25 GB of disk. This is the
  installer's `small` tier, which was measured on a 4 GB server with memory and local
  embeddings on. The minimal service set in the example uses less, and leaves room to turn
  those on later. Inbound ports 80 and 443 must be open, as well as ssh.
- A **domain** with two DNS A records pointing at the server's public IPv4 address: the
  primary name (`burrow.example.com`) and the auth name (`auth.burrow.example.com`).
- On your own machine: **git** and **Python 3.11 or newer**. Nothing needs to be installed
  with pip.

## 2. Get the installer

```bash
git clone https://github.com/GetBurrowing/core.git
cd core
export PYTHONPATH=deployment/installer
```

## 3. Write your manifest

```bash
cp deployment/examples/self-host.install.toml ~/my-burrow.install.toml
```

Edit three fields in `~/my-burrow.install.toml`:

- `install.name`: a short lowercase name, such as `my-burrow`.
- `domain.primary`: your primary name, such as `burrow.example.com`.
- `domain.acme_email`: the address Let's Encrypt can write to about your certificate.

## 4. Validate and render

```bash
python3 -m burrow_install validate ~/my-burrow.install.toml
python3 -m burrow_install render ~/my-burrow.install.toml --out ~/my-burrow-render
```

`validate` prints `ok`. `render` prints the files it wrote and the **names** of the secrets it
generated. The output directory must be new or empty, and it must sit outside any git checkout.

`~/my-burrow-render/user-data` and `secrets.env` hold your install's secrets. Keep them private
and do not commit them. Keep `secrets.env` safe: a later re-render with
`--reuse-secrets ~/my-burrow-render/secrets.env` keeps the same values.

## 5. Create the server

Create the Ubuntu 24.04 server and paste the whole of `~/my-burrow-render/user-data` into the
provider's **user data** (cloud-init) field. Add your ssh key in the provider's form, or set
`host.ssh_authorized_key` in the manifest before rendering.

At first boot the server installs Docker, writes the install under `/opt/burrow`, pulls the
images and starts the stack as `burrow-stack.service`. This takes a few minutes.

## 6. Check it is up

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://burrow.example.com/health
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://burrow.example.com/auth/login
curl -sS -o /dev/null -w '%{http_code}\n' https://auth.burrow.example.com/login
```

The first command prints `200`. The second prints a redirect to `https://auth.burrow.example.com/`.
The third prints `200`: it is the sign-in page.

If `/health` does not answer yet, wait a few minutes. On the server,
`sudo systemctl status burrow-stack` and `sudo cloud-init status --long` show progress.

## 7. Create the owner account and sign in

Sign-in runs through the bundled pocket-id on the auth name. A fresh install has no users, and
pocket-id does not know Burrow yet. One command on the server creates both, using two keys that
already sit in `/opt/burrow/secrets.env`. It copies them into owner-only files without printing
them.

First copy the installer onto the server (Ubuntu 24.04 already has Python 3.12):

```bash
tar -C deployment/installer -cf - burrow_install \
  | ssh ubuntu@burrow.example.com 'sudo mkdir -p /root/burrow-installer && sudo tar -C /root/burrow-installer -xf -'
```

Then create the owner. Use your own email address:

```bash
ssh ubuntu@burrow.example.com 'sudo sh -s' <<'EOF'
set -e
umask 077
mkdir -p /root/burrow-owner && cd /root/burrow-owner
sed -n 's/^STATIC_API_KEY=//p' /opt/burrow/secrets.env > api-key
sed -n 's/^OIDC_CLIENT_SECRET=//p' /opt/burrow/secrets.env > oidc-secret
PYTHONPATH=/root/burrow-installer python3 -m burrow_install bootstrap-admin \
  --base https://auth.burrow.example.com --primary burrow.example.com \
  --api-key-file api-key --oidc-secret-file oidc-secret \
  --email you@example.com --link-file sign-in-link
EOF
```

It prints one JSON line containing `"ok": true`, `"admin": "created"` and
`"oidc_client": "created"`. It never prints the key or the link. Some providers log you in as
`root` rather than `ubuntu`; use that user name in both commands.

Read the one-time sign-in link and open it in your browser within 30 minutes:

```bash
ssh ubuntu@burrow.example.com sudo cat /root/burrow-owner/sign-in-link
```

The link signs you in as the owner and lands you in Burrow. **Add a passkey when pocket-id
offers to**: until you configure outgoing mail, the passkey is how you sign in next time.
The link is a credential, so do not share it. Running the `bootstrap-admin` block again
finds the same owner and writes a fresh link.

## No domain yet? Try it on a throwaway VM

You can run the same install on a local VM, using a `.test` name and a private certificate
authority that the install generates at first boot. Nothing is public, and you check it with
`curl` pinned to the install's own root certificate.

You need a VM that takes cloud-init user data and has 4 GB RAM. On a Linux machine with
`/dev/kvm` and podman, core's own scripts in `deployment/installer/proof/` start one (see its
`README.md`). The commands below use them. With another tool, set `addr` and `port` to the VM's
address and its port 443, and replace `guest` with ssh to the VM's `ubuntu` user.

From the core checkout:

```bash
export PYTHONPATH=deployment/installer
id=burrow-try                    # every resource the proof scripts create carries this id
wd=~/$id-vm                      # must contain the id, and sit outside any git checkout
addr=127.0.0.1 port=18443 ssh_port=18022    # pick ports that `ss -ltn` shows free
mkdir -p $wd

sed -e 's/^primary = .*/primary = "burrow-try.test"/' \
    -e 's/^tls = "acme"/tls = "internal"/' \
    -e '/^acme_email = /d' \
    deployment/examples/self-host.install.toml > $wd/try.install.toml
python3 -m burrow_install validate $wd/try.install.toml
python3 -m burrow_install render $wd/try.install.toml --out $wd/render

# Create the VM with $wd/render/user-data as its cloud-init user data.
deployment/installer/proof/vm-up.sh --name $id --workdir $wd --render $wd/render \
  --https-port $port --ssh-port $ssh_port
guest() { deployment/installer/proof/vm-exec.sh --workdir $wd -- "$@"; }
```

Wait for the stack, then fetch the install's **public** root certificate (its key never leaves
the VM) and check the same three URLs as step 6. Never use `curl -k`: the point is that TLS
verifies against the install's own root.

```bash
until guest 'sudo curl -sf -o /dev/null --cacert /opt/burrow/tls/root.crt --resolve burrow-try.test:443:127.0.0.1 https://burrow-try.test/health'; do sleep 10; done
guest sudo cat /opt/burrow/tls/root.crt > $wd/root.crt
pin=(--cacert $wd/root.crt
     --connect-to burrow-try.test:443:$addr:$port
     --connect-to auth.burrow-try.test:443:$addr:$port)
curl -sS "${pin[@]}" -o /dev/null -w '%{http_code}\n' https://burrow-try.test/health
curl -sS "${pin[@]}" -o /dev/null -w '%{http_code} %{redirect_url}\n' https://burrow-try.test/auth/login
curl -sS "${pin[@]}" -o /dev/null -w '%{http_code}\n' https://auth.burrow-try.test/login
```

Expect `200`, a redirect to `https://auth.burrow-try.test/`, and `200`.

To create the owner, do step 7 inside the VM. The VM does not resolve the `.test` names, and
Python must trust the install's root, so the block adds a hosts entry and `SSL_CERT_FILE`:

```bash
tar -C deployment/installer -cf - burrow_install \
  | guest 'sudo mkdir -p /root/burrow-installer && sudo tar -C /root/burrow-installer -xf -'
guest 'sudo sh -s' <<'EOF'
set -e
umask 077
grep -q 'auth.burrow-try.test' /etc/hosts || echo '127.0.0.1 burrow-try.test auth.burrow-try.test' >> /etc/hosts
mkdir -p /root/burrow-owner && cd /root/burrow-owner
sed -n 's/^STATIC_API_KEY=//p' /opt/burrow/secrets.env > api-key
sed -n 's/^OIDC_CLIENT_SECRET=//p' /opt/burrow/secrets.env > oidc-secret
SSL_CERT_FILE=/opt/burrow/tls/root.crt PYTHONPATH=/root/burrow-installer \
  python3 -m burrow_install bootstrap-admin \
  --base https://auth.burrow-try.test --primary burrow-try.test \
  --api-key-file api-key --oidc-secret-file oidc-secret \
  --email you@example.com --link-file sign-in-link
EOF
```

To open the sign-in link in a browser, that machine needs hosts entries sending both
`.test` names to the VM on port 443, and `root.crt` trusted. With the proof scripts' port
forward, the `curl` checks above are the test. When you are done, remove the VM and
everything the scripts created:

```bash
deployment/installer/proof/vm-down.sh --name $id --workdir $wd
```

## Next

- Updates and the host updater: [docs/burrow/installs.md](burrow/installs.md), "Updates".
- Every other manifest setting (memory, voice, meetings, backups, agents, mail):
  [deployment/schema/install-manifest.md](../deployment/schema/install-manifest.md).
