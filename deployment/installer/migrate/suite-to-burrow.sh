#!/bin/sh
# burrow-migrate: move a single-host install rendered before the Burrow rename
# (task 01a14dd8) onto the Burrow names, in place, keeping its data.
#
#   burrow-migrate [--agent-host-image REF] [--adopt-wait SECONDS]
#
# Run as root on the install's host. Self-contained: the host needs no repo
# checkout. The repo copy is deployment/installer/migrate/suite-to-burrow.sh;
# every render also writes it into the install as bin/burrow-migrate.
#
# Steps, in order:
#   1. Preflight, which changes nothing: the legacy root is a real directory, the
#      legacy stack unit exists, and /opt/burrow is absent or an empty directory.
#      On a native-agent (full_machine) host it also checks that the agent-host
#      image carries the Burrow daemon, and that the renamed sudoers file passes
#      `visudo -c`.
#   2. Record a rollback dir, /var/lib/burrow-migrate/<UTC stamp>/, holding the
#      legacy unit files, the agent host's env, versions and sudoers files, the
#      old daemon, and the output of `docker compose ls`, `docker volume ls`
#      and the image of every running container.
#   3. Stop the legacy stack unit. Its ExecStop is `docker compose down`
#      without -v. Named volumes are keyed by the compose project `name:`
#      (install.name), which this script does not change, so the stack comes
#      back on the same volumes.
#   4. Move the legacy root to /opt/burrow, and leave a symlink at the old path
#      for anything that still names it.
#   5. Write burrow-stack.service (the same body, with the new root), disable
#      and remove the legacy stack unit, then enable and start burrow-stack.
#   6. Native agents only. Rename the agents group (gid kept). Rename the agent
#      host's env file, its versions dir and its sudoers file (checked with
#      visudo first). Copy the Burrow daemon out of the agent-host image, as the
#      setup unit does. Install the burrow-agent-host units, stop, disable and
#      remove the legacy ones, and start burrow-agent-host. The daemon then
#      adopts each legacy agent unit as burrow-agent@<id> (agent-host
#      src/legacy.ts). When no legacy agent unit is left, the legacy template
#      is removed.
#   7. Print the state of each new unit.
#
# A second run detects the finished state and exits 0 without changes. A run
# that stopped part way resumes from its rollback dir. Exit codes: 0 done,
# 1 refused or failed, 2 usage, 3 migrated but agent adoption is still pending
# (run it again).
#
# To undo it: burrow-to-suite-rollback.sh <stamp> (beside this script in the repo).
# See docs/runbooks/burrow-rename-deferred.md, "Installer and agent host (A2c)".
set -eu

# The legacy names, each defined once. Nothing else in this file spells them.
OLD_ROOT=/opt/suite                 # legacy name, kept by burrow-migrate
OLD_STACK=suite-stack.service       # legacy name, kept by burrow-migrate
OLD_HOST=suite-agent-host           # legacy name, kept by burrow-migrate
OLD_GROUP=suite-agents              # legacy name, kept by burrow-migrate
OLD_AGENT=suite-agent               # legacy name, kept by burrow-migrate

NEW_ROOT=/opt/burrow
NEW_STACK=burrow-stack.service
NEW_HOST=burrow-agent-host
NEW_GROUP=burrow-agents
NEW_AGENT=burrow-agent

UNITS=/etc/systemd/system
STATE_ROOT=/var/lib/burrow-migrate

agent_image=""
adopt_wait=180

log() { printf 'burrow-migrate: %s\n' "$*"; }
die() {
	printf 'burrow-migrate: error: %s\n' "$*" >&2
	exit 1
}
usage() {
	sed -n '2,9p' "$0"
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
	--agent-host-image)
		[ $# -ge 2 ] || usage
		agent_image=$2
		shift 2
		;;
	--adopt-wait)
		[ $# -ge 2 ] || usage
		adopt_wait=$2
		shift 2
		;;
	-h | --help) usage ;;
	*)
		printf 'burrow-migrate: unknown argument: %s\n' "$1" >&2
		exit 2
		;;
	esac
done
case "$adopt_wait" in '' | *[!0-9]*) die "--adopt-wait takes a number of seconds" ;; esac

# --- state --------------------------------------------------------------------

moved() {
	[ -L "$OLD_ROOT" ] && [ "$(readlink "$OLD_ROOT")" = "$NEW_ROOT" ] &&
		[ -d "$NEW_ROOT" ] && [ ! -L "$NEW_ROOT" ]
}

legacy_agents_left() {
	for d in "$UNITS/$OLD_AGENT"@*.service.d; do
		[ -f "$d/10-agent.conf" ] && return 0
	done
	return 1
}

finished() {
	moved || return 1
	[ -f "$UNITS/$NEW_STACK" ] || return 1
	[ ! -e "$UNITS/$OLD_STACK" ] || return 1
	[ ! -e "$UNITS/$OLD_HOST.service" ] || return 1
	[ ! -e "$UNITS/$OLD_HOST-setup.service" ] || return 1
	[ ! -e "$UNITS/$OLD_AGENT@.service" ] || return 1
	! legacy_agents_left
}

# The newest rollback dir whose run has not finished, if any.
unfinished_run() {
	[ -d "$STATE_ROOT" ] || return 0
	found=""
	for d in "$STATE_ROOT"/*/; do
		d=${d%/}
		if [ -f "$d/status" ] && [ "$(cat "$d/status")" = started ]; then found=$d; fi
	done
	printf '%s' "$found"
}

unit_state() {
	en=$(systemctl is-enabled "$1" 2>/dev/null) || en=${en:-not-found}
	ac=$(systemctl is-active "$1" 2>/dev/null) || ac=${ac:-inactive}
	printf '%s enabled=%s active=%s\n' "$1" "$en" "$ac"
}

print_state() {
	if [ -L "$OLD_ROOT" ]; then
		printf '%s -> %s\n' "$OLD_ROOT" "$(readlink "$OLD_ROOT")"
	fi
	for u in "$NEW_STACK" "$NEW_HOST-setup.service" "$NEW_HOST.service"; do
		if [ -f "$UNITS/$u" ]; then unit_state "$u"; fi
	done
	for d in "$UNITS/$NEW_AGENT"@*.service.d; do
		[ -f "$d/10-agent.conf" ] || continue
		u=${d##*/}
		unit_state "${u%.d}"
	done
	for u in "$OLD_STACK" "$OLD_HOST-setup.service" "$OLD_HOST.service" "$OLD_AGENT@.service"; do
		if [ -e "$UNITS/$u" ]; then unit_state "$u"; fi
	done
	return 0
}

# --- preflight (changes nothing) -----------------------------------------------

image_from_setup_script() {
	sed -n "s/^image='\\(.*\\)'\$/\\1/p" "$1" | head -n 1
}

check_daemon_image() {
	ctr=$(docker create --pull never "$1" 2>/dev/null) ||
		die "agent-host image $1 is not on this host: load the Burrow agent-host image first (see the runbook)"
	if docker cp "$ctr:$NEW_ROOT/agent-host/src/main.ts" - >/dev/null 2>&1; then
		docker rm -f "$ctr" >/dev/null 2>&1 || true
	else
		docker rm -f "$ctr" >/dev/null 2>&1 || true
		die "agent-host image $1 has no $NEW_ROOT/agent-host (it is a pre-rename build): load the Burrow agent-host image and pass it with --agent-host-image"
	fi
}

preflight() {
	[ -d "$OLD_ROOT" ] && [ ! -L "$OLD_ROOT" ] ||
		die "$OLD_ROOT is not a directory: there is no pre-rename install here to migrate"
	[ -f "$UNITS/$OLD_STACK" ] ||
		die "$UNITS/$OLD_STACK not found: $OLD_ROOT was not rendered by the installer"
	if [ -e "$NEW_ROOT" ] || [ -L "$NEW_ROOT" ]; then
		[ -d "$NEW_ROOT" ] && [ ! -L "$NEW_ROOT" ] && [ -z "$(ls -A "$NEW_ROOT")" ] ||
			die "$NEW_ROOT exists and is not an empty directory (was a new render applied before migrating? see the runbook)"
	fi
	command -v docker >/dev/null || die "docker not found"
	command -v systemctl >/dev/null || die "systemctl not found"
	if [ "$profile" = full_machine ]; then
		[ -f "$OLD_ROOT/bin/$OLD_HOST-setup" ] || die "$OLD_ROOT/bin/$OLD_HOST-setup not found"
		if [ -z "$agent_image" ]; then
			agent_image=$(image_from_setup_script "$OLD_ROOT/bin/$OLD_HOST-setup")
		fi
		[ -n "$agent_image" ] || die "no agent-host image: pass --agent-host-image"
		check_daemon_image "$agent_image"
		if [ -f "/etc/sudoers.d/$OLD_GROUP" ]; then
			command -v visudo >/dev/null || die "visudo not found"
			check=$(mktemp)
			sed "s/%$OLD_GROUP/%$NEW_GROUP/g" "/etc/sudoers.d/$OLD_GROUP" >"$check"
			if ! visudo -cf "$check" >/dev/null 2>&1; then
				rm -f "$check"
				die "the renamed sudoers file does not pass visudo -c; nothing was changed"
			fi
			rm -f "$check"
		fi
	fi
}

# --- step 2: rollback record ---------------------------------------------------

record() {
	stamp=$(date -u +%Y%m%dT%H%M%SZ)
	rb="$STATE_ROOT/$stamp"
	[ ! -e "$rb" ] || rb="$rb-$$"
	mkdir -p "$STATE_ROOT"
	chmod 0700 "$STATE_ROOT"
	mkdir -m 0700 "$rb" "$rb/units" "$rb/etc"
	printf '%s\n' "$profile" >"$rb/profile"
	printf '%s\n' "$agent_image" >"$rb/agent-host-image"
	for f in "$UNITS/$OLD_STACK" "$UNITS/$OLD_HOST"* "$UNITS/$OLD_AGENT"@*; do
		[ -e "$f" ] || continue
		cp -a "$f" "$rb/units/"
		u=${f##*/}
		case "$u" in *.service) unit_state "$u" >>"$rb/units.txt" ;; esac
	done
	systemctl list-units --plain --no-legend --all "$OLD_AGENT@*" >"$rb/agent-units.txt" 2>/dev/null || true
	for f in "/etc/$OLD_HOST.env" "/etc/$OLD_HOST" "/etc/sudoers.d/$OLD_GROUP"; do
		if [ -e "$f" ]; then cp -a "$f" "$rb/etc/"; fi
	done
	(cd "$OLD_ROOT" && docker compose ls --all) >"$rb/compose-ls.txt" 2>&1 || true
	docker volume ls >"$rb/volumes.txt" 2>&1 || true
	: >"$rb/images.txt"
	for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
		docker inspect -f '{{.Name}} {{.Config.Image}} {{.Image}}' "$c" >>"$rb/images.txt" 2>/dev/null || true
	done
	if [ "$profile" = full_machine ]; then
		old_id=$(docker image inspect -f '{{.Id}}' "$(image_from_setup_script "$OLD_ROOT/bin/$OLD_HOST-setup")" 2>/dev/null) || old_id=""
		printf '%s\n' "$old_id" >"$rb/old-agent-host-image-id"
		if [ -d "$OLD_ROOT/agent-host" ]; then cp -a "$OLD_ROOT/agent-host" "$rb/agent-host"; fi
	fi
	echo started >"$rb/status"
	log "rollback record: $rb"
}

# --- steps 3-4: stop and move ---------------------------------------------------

stop_and_move() {
	moved && return 0
	[ -d "$OLD_ROOT" ] && [ ! -L "$OLD_ROOT" ] || die "neither $OLD_ROOT nor $NEW_ROOT holds the install"
	if [ -f "$UNITS/$OLD_STACK" ]; then
		log "stopping $OLD_STACK (compose down, volumes kept)"
		systemctl stop "$OLD_STACK"
	fi
	if [ "$profile" = full_machine ] && [ -f "$UNITS/$OLD_HOST.service" ]; then
		# Agents keep running; only the daemon stops during the move.
		systemctl stop "$OLD_HOST.service" || true
	fi
	if [ -d "$NEW_ROOT" ]; then rmdir "$NEW_ROOT"; fi
	mv "$OLD_ROOT" "$NEW_ROOT"
	ln -s "$NEW_ROOT" "$OLD_ROOT"
	log "moved $OLD_ROOT to $NEW_ROOT (symlink left at $OLD_ROOT)"
}

# --- step 5: stack unit ----------------------------------------------------------

stack_unit() {
	if [ ! -f "$UNITS/$NEW_STACK" ]; then
		src="$rb/units/$OLD_STACK"
		[ -f "$src" ] || die "no copy of $OLD_STACK in $rb"
		tmp="$UNITS/.$NEW_STACK.tmp"
		{
			sed -n '1p' "$src"
			printf '# Migrated from %s by burrow-migrate (%s).\n' "$OLD_STACK" "${rb##*/}"
			sed -e '1d' -e "s#$OLD_ROOT#$NEW_ROOT#g" -e "s#$OLD_HOST\\.service#$NEW_HOST.service#g" "$src"
		} >"$tmp"
		chmod 0644 "$tmp"
		mv "$tmp" "$UNITS/$NEW_STACK"
	fi
	if [ -e "$UNITS/$OLD_STACK" ]; then
		systemctl disable "$OLD_STACK" >/dev/null 2>&1 || true
		rm -f "$UNITS/$OLD_STACK"
	fi
	systemctl daemon-reload
	systemctl enable "$NEW_STACK"
	log "starting $NEW_STACK"
	systemctl start "$NEW_STACK"
}

# --- step 6: native agents --------------------------------------------------------

copy_daemon() {
	dest="$NEW_ROOT/agent-host"
	ctr=$(docker create --pull never "$1")
	rm -rf "$dest.incoming"
	if ! docker cp "$ctr:$NEW_ROOT/agent-host" "$dest.incoming"; then
		docker rm -f "$ctr" >/dev/null 2>&1 || true
		die "could not copy $NEW_ROOT/agent-host out of $1"
	fi
	docker rm -f "$ctr" >/dev/null 2>&1 || true
	chown -R root:root "$dest.incoming"
	chmod -R go-w,a+rX "$dest.incoming"
	rm -rf "$dest"
	mv "$dest.incoming" "$dest"
}

# sed a legacy unit (or drop-in) onto the new names.
rename_unit_text() {
	sed -e "s#$OLD_ROOT#$NEW_ROOT#g" \
		-e "s#$OLD_HOST-setup#$NEW_HOST-setup#g" \
		-e "s#$OLD_HOST\\.service#$NEW_HOST.service#g" \
		-e "s#$OLD_STACK#$NEW_STACK#g" "$1"
}

install_text() { # <mode> <dest>, text on stdin
	tmp="$2.tmp.$$"
	cat >"$tmp"
	chmod "$1" "$tmp"
	mv "$tmp" "$2"
}

agents() {
	image=$(cat "$rb/agent-host-image")

	# Group first: the setup unit runs `groupadd burrow-agents` when that group
	# is missing, and the daemon renames the legacy group only while no
	# burrow-agents group exists. groupmod keeps the gid, so ownership holds.
	if getent group "$OLD_GROUP" >/dev/null && ! getent group "$NEW_GROUP" >/dev/null; then
		groupmod -n "$NEW_GROUP" "$OLD_GROUP"
		log "renamed group $OLD_GROUP to $NEW_GROUP (gid kept)"
	fi

	if [ -e "/etc/$OLD_HOST.env" ] && [ ! -e "/etc/$NEW_HOST.env" ]; then
		mv "/etc/$OLD_HOST.env" "/etc/$NEW_HOST.env"
	fi
	if [ -d "/etc/$OLD_HOST" ] && [ ! -e "/etc/$NEW_HOST" ]; then
		mv "/etc/$OLD_HOST" "/etc/$NEW_HOST"
	fi
	if [ -f "/etc/sudoers.d/$OLD_GROUP" ]; then
		# A name with a dot is ignored by sudo, so the candidate is inert until checked.
		tmp="/etc/sudoers.d/.$NEW_GROUP.tmp"
		sed "s/%$OLD_GROUP/%$NEW_GROUP/g" "/etc/sudoers.d/$OLD_GROUP" >"$tmp"
		chmod 0440 "$tmp"
		if ! visudo -cf "$tmp" >/dev/null; then
			rm -f "$tmp"
			die "the renamed sudoers file does not pass visudo -c"
		fi
		mv "$tmp" "/etc/sudoers.d/$NEW_GROUP"
		rm -f "/etc/sudoers.d/$OLD_GROUP"
	fi

	if [ ! -f "$NEW_ROOT/agent-host/packaging/$NEW_HOST.service" ]; then
		log "copying the Burrow agent host out of $image"
		copy_daemon "$image"
	fi
	if [ ! -f "$NEW_ROOT/bin/$NEW_HOST-setup" ]; then
		[ -f "$NEW_ROOT/bin/$OLD_HOST-setup" ] || die "$NEW_ROOT/bin/$OLD_HOST-setup not found"
		sed -e "s#$OLD_ROOT#$NEW_ROOT#g" \
			-e "s#/etc/$OLD_HOST/#/etc/$NEW_HOST/#g" \
			-e "s#$OLD_GROUP#$NEW_GROUP#g" \
			-e "s#$OLD_HOST-setup#$NEW_HOST-setup#g" \
			-e "s#$OLD_HOST\\.service#$NEW_HOST.service#g" \
			-e "s#^image=.*#image='$image'#" \
			"$NEW_ROOT/bin/$OLD_HOST-setup" | install_text 0755 "$NEW_ROOT/bin/$NEW_HOST-setup"
	fi

	if [ -f "$rb/units/$OLD_HOST-setup.service" ] && [ ! -f "$UNITS/$NEW_HOST-setup.service" ]; then
		rename_unit_text "$rb/units/$OLD_HOST-setup.service" | install_text 0644 "$UNITS/$NEW_HOST-setup.service"
	fi
	if [ -d "$rb/units/$OLD_HOST.service.d" ] && [ ! -d "$UNITS/$NEW_HOST.service.d" ]; then
		mkdir -p "$UNITS/$NEW_HOST.service.d.tmp"
		for f in "$rb/units/$OLD_HOST.service.d"/*; do
			[ -f "$f" ] || continue
			rename_unit_text "$f" | install_text 0644 "$UNITS/$NEW_HOST.service.d.tmp/${f##*/}"
		done
		mv "$UNITS/$NEW_HOST.service.d.tmp" "$UNITS/$NEW_HOST.service.d"
	fi
	install -m 0644 "$NEW_ROOT/agent-host/packaging/$NEW_HOST.service" "$UNITS/$NEW_HOST.service"
	install -m 0644 "$NEW_ROOT/agent-host/packaging/$NEW_AGENT@.service" "$UNITS/$NEW_AGENT@.service"

	for u in "$OLD_HOST.service" "$OLD_HOST-setup.service"; do
		[ -e "$UNITS/$u" ] || continue
		systemctl stop "$u" >/dev/null 2>&1 || true
		systemctl disable "$u" >/dev/null 2>&1 || true
		rm -f "$UNITS/$u"
	done
	rm -rf "$UNITS/$OLD_HOST.service.d"
	systemctl daemon-reload
	systemctl enable "$NEW_HOST-setup.service" "$NEW_HOST.service"
	log "starting $NEW_HOST.service (runs $NEW_HOST-setup.service first)"
	systemctl start "$NEW_HOST.service"

	waited=0
	while legacy_agents_left && [ "$waited" -lt "$adopt_wait" ]; do
		sleep 2
		waited=$((waited + 2))
	done
	if legacy_agents_left; then
		log "the agent host has not adopted every legacy agent unit yet (journalctl -u $NEW_HOST); run burrow-migrate again to finish"
		print_state
		exit 3
	fi
	if [ -e "$UNITS/$OLD_AGENT@.service" ]; then
		rm -f "$UNITS/$OLD_AGENT@.service"
		systemctl daemon-reload
	fi
	rmdir "/etc/$OLD_GROUP" 2>/dev/null || true
}

# --- main ----------------------------------------------------------------------

[ "$(id -u)" = 0 ] || die "run as root"

if finished; then
	log "already migrated; nothing to do"
	print_state
	exit 0
fi

rb=$(unfinished_run)
if [ -n "$rb" ]; then
	profile=$(cat "$rb/profile")
	log "resuming the run recorded in $rb"
else
	if [ -f "$UNITS/$OLD_HOST.service" ]; then profile=full_machine; else profile=none; fi
	preflight
	record
fi

stop_and_move
stack_unit
if [ "$profile" = full_machine ]; then agents; fi

printf 'done\n' >"$rb/status"
log "done; rollback with: burrow-to-suite-rollback.sh ${rb##*/}"
print_state
