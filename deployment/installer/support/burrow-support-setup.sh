#!/bin/bash
# Vendor support host setup (core task 01a1b362 stage 3, ADR 0059). Rendered
# into an install as bin/burrow-support-setup; cloud-init runs it once on a new
# install and `burrow_install support enable-host` runs it on a running one.
# Idempotent: every run converges the host to the same state.
#
# It expects, already written by the renderer:
#   /etc/ssh/burrow-support-ca.pub                the vendor SSH user CA, PUBLIC key only
#   /opt/burrow/support/60-burrow-support.conf    the sshd drop-in, staged
#   /opt/burrow/bin/burrow-support-principals     sshd AuthorizedPrincipalsCommand
#   /opt/burrow/bin/burrow-support-shell          sshd ForceCommand
# and then:
#   * creates burrow-support (bash, NOPASSWD sudo via /etc/sudoers.d/60-burrow-support,
#     checked with visudo -c) and burrow-support-check (no login), if missing;
#   * creates /var/lib/burrow-support (core-platform's uid/gid 1000, 0755; core
#     writes state.json there, bind-mounted) with events.jsonl (root:1000 0640),
#     and /var/log/burrow-support (root 0700) for transcripts;
#   * installs the drop-in, runs `sshd -t`, and reloads ssh only if that passes.
#     If it fails, the drop-in is taken out again (the previous one, if any, is
#     put back) and the script exits 1 without reloading.
# It never touches root's or any other user's authorized_keys.
set -euo pipefail

install_root=/opt/burrow
staged="$install_root/support/60-burrow-support.conf"
dropin="/etc/ssh/sshd_config.d/60-burrow-support.conf"
sudoers="/etc/sudoers.d/60-burrow-support"
state_dir="/var/lib/burrow-support"
log_dir="/var/log/burrow-support"
core_uid=1000
core_gid=1000

for f in "/etc/ssh/burrow-support-ca.pub" "$staged" \
  "$install_root/bin/burrow-support-principals" "$install_root/bin/burrow-support-shell"; do
  [ -s "$f" ] || { echo "burrow-support-setup: missing $f" >&2; exit 1; }
done

# sshd refuses an AuthorizedPrincipalsCommand that is not root-owned or is
# group/world writable (and so is every directory above it).
chown root:root "$install_root/bin/burrow-support-principals" "$install_root/bin/burrow-support-shell"
chmod 0755 "$install_root/bin/burrow-support-principals" "$install_root/bin/burrow-support-shell"
chown root:root "/etc/ssh/burrow-support-ca.pub"
chmod 0644 "/etc/ssh/burrow-support-ca.pub"

if ! id -u burrow-support-check >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /nonexistent \
    --shell /usr/sbin/nologin burrow-support-check
fi
if ! id -u burrow-support >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash burrow-support
fi
usermod --shell /bin/bash burrow-support
# '*': no password can ever match, and sshd does not read it as "locked"
# (a '!' would refuse every login, certificates included, when UsePAM is no).
usermod --password '*' burrow-support

tmp=$(mktemp)
backup=
trap 'rm -f "$tmp" ${backup:+"$backup"}' EXIT
printf '%s\n' \
  '# Vendor support repair user (ADR 0059). Rendered by burrow_install; do not edit.' \
  'burrow-support ALL=(ALL) NOPASSWD: ALL' >"$tmp"
visudo -c -q -f "$tmp"
install -o root -g root -m 0440 "$tmp" "$sudoers"
visudo -c -q

install -d -o "$core_uid" -g "$core_gid" -m 0755 "$state_dir"
[ -e "$state_dir/events.jsonl" ] || install -o root -g "$core_gid" -m 0640 /dev/null "$state_dir/events.jsonl"
chown root:"$core_gid" "$state_dir/events.jsonl"
chmod 0640 "$state_dir/events.jsonl"
if [ -e "$state_dir/state.json" ]; then
  chmod 0644 "$state_dir/state.json"
fi
install -d -o root -g root -m 0700 "$log_dir"

if [ -e "$dropin" ]; then
  backup=$(mktemp)
  cp -p "$dropin" "$backup"
fi
install -o root -g root -m 0644 "$staged" "$dropin"
if ! /usr/sbin/sshd -t; then
  if [ -n "$backup" ]; then
    install -o root -g root -m 0644 "$backup" "$dropin"
  else
    rm -f "$dropin"
  fi
  echo "burrow-support-setup: sshd -t failed; drop-in left out, ssh not reloaded" >&2
  exit 1
fi
# Ubuntu 24.04 starts ssh.service from ssh.socket: reload it if it runs, and
# otherwise its next start reads the new drop-in anyway.
systemctl try-reload-or-restart ssh.service
echo "burrow-support-setup: ok"
