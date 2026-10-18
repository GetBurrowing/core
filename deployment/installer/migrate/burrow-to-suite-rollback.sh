#!/bin/sh
# burrow-to-suite-rollback.sh: undo burrow-migrate (suite-to-burrow.sh) from
# the rollback dir it recorded.
#
#   burrow-to-suite-rollback.sh <stamp>
#
# <stamp> names /var/lib/burrow-migrate/<stamp>/ (burrow-migrate prints it).
# Run as root on the host. It stops the Burrow units, moves /opt/burrow back
# to the legacy root, restores the legacy unit files, env, versions and sudoers
# files and the old daemon from the record, hands each burrow-agent@<id> back
# to its legacy unit, renames the agents group back (gid kept), and starts the
# legacy units that were enabled before. The stack comes back on the same
# compose project, so on the same volumes. A second run exits 0 without
# changes.
set -eu

# The legacy names, each defined once (as in suite-to-burrow.sh).
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

log() { printf 'burrow-rollback: %s\n' "$*"; }
die() {
	printf 'burrow-rollback: error: %s\n' "$*" >&2
	exit 1
}

[ $# -eq 1 ] || {
	sed -n '2,6p' "$0"
	exit 2
}
case "$1" in */* | .* | '') die "a stamp is a directory name under $STATE_ROOT" ;; esac
rb="$STATE_ROOT/$1"
[ -d "$rb" ] && [ -f "$rb/status" ] || die "no rollback record at $rb"
[ "$(id -u)" = 0 ] || die "run as root"

if [ "$(cat "$rb/status")" = rolled-back ] && [ -d "$OLD_ROOT" ] && [ ! -L "$OLD_ROOT" ]; then
	log "already rolled back from $rb; nothing to do"
	exit 0
fi
profile=$(cat "$rb/profile")

if [ -L "$OLD_ROOT" ]; then
	[ "$(readlink "$OLD_ROOT")" = "$NEW_ROOT" ] && [ -d "$NEW_ROOT" ] ||
		die "$OLD_ROOT is a symlink that does not point at $NEW_ROOT"
elif [ -d "$OLD_ROOT" ]; then
	[ ! -e "$NEW_ROOT" ] || die "both $OLD_ROOT and $NEW_ROOT exist"
else
	die "no install at $OLD_ROOT or $NEW_ROOT"
fi

# --- native agents: hand every burrow-agent@<id> back -----------------------------
agent_ids=""
if [ "$profile" = full_machine ]; then
	for u in "$NEW_HOST.service" "$NEW_HOST-setup.service"; do
		systemctl stop "$u" >/dev/null 2>&1 || true
		systemctl disable "$u" >/dev/null 2>&1 || true
	done
	for d in "$UNITS/$NEW_AGENT"@*.service.d; do
		[ -f "$d/10-agent.conf" ] || continue
		u=${d##*/}
		u=${u%.d}
		id=${u#"$NEW_AGENT@"}
		id=${id%.service}
		systemctl stop "$u" >/dev/null 2>&1 || true
		systemctl disable "$u" >/dev/null 2>&1 || true
		legacy="$UNITS/$OLD_AGENT@$id.service.d"
		if [ -d "$rb/units/${legacy##*/}" ]; then
			rm -rf "$legacy"
			cp -a "$rb/units/${legacy##*/}" "$legacy"
		else
			# An agent created after the migration has no recorded legacy unit.
			mkdir -p "$legacy"
			sed -e "s#$NEW_GROUP#$OLD_GROUP#g" -e "s#/run/$NEW_GROUP/#/run/$OLD_GROUP/#g" \
				"$d/10-agent.conf" >"$legacy/10-agent.conf"
		fi
		if [ ! -d "/etc/$OLD_GROUP" ]; then mkdir -m 0711 "/etc/$OLD_GROUP"; fi
		for f in "$id.env" "$id.files.json"; do
			if [ -e "/etc/$NEW_GROUP/$f" ] && [ ! -e "/etc/$OLD_GROUP/$f" ]; then
				mv "/etc/$NEW_GROUP/$f" "/etc/$OLD_GROUP/$f"
			fi
		done
		rm -rf "$d"
		agent_ids="$agent_ids $id"
	done
	if getent group "$NEW_GROUP" >/dev/null && ! getent group "$OLD_GROUP" >/dev/null; then
		groupmod -n "$OLD_GROUP" "$NEW_GROUP"
		log "renamed group $NEW_GROUP back to $OLD_GROUP (gid kept)"
	fi
	rm -rf "$UNITS/$NEW_HOST.service" "$UNITS/$NEW_HOST.service.d" \
		"$UNITS/$NEW_HOST-setup.service" "$UNITS/$NEW_AGENT@.service"
	if [ -e "/etc/$NEW_HOST.env" ] && [ ! -e "/etc/$OLD_HOST.env" ]; then
		mv "/etc/$NEW_HOST.env" "/etc/$OLD_HOST.env"
	fi
	if [ -d "/etc/$NEW_HOST" ] && [ ! -e "/etc/$OLD_HOST" ]; then
		mv "/etc/$NEW_HOST" "/etc/$OLD_HOST"
	fi
	if [ -f "$rb/etc/$OLD_GROUP" ]; then
		visudo -cf "$rb/etc/$OLD_GROUP" >/dev/null || die "the recorded sudoers file does not pass visudo -c"
		cp -a "$rb/etc/$OLD_GROUP" "/etc/sudoers.d/$OLD_GROUP"
		rm -f "/etc/sudoers.d/$NEW_GROUP"
	fi
	if [ -d "$rb/agent-host" ]; then
		rm -rf "$NEW_ROOT/agent-host"
		cp -a "$rb/agent-host" "$NEW_ROOT/agent-host"
	fi
	rm -f "$NEW_ROOT/bin/$NEW_HOST-setup"
	rmdir "/etc/$NEW_GROUP" 2>/dev/null || true
	# The legacy setup unit copies the daemon from the image ref in its script;
	# if that ref now names the Burrow build, point it back at the old image.
	old_id=$(cat "$rb/old-agent-host-image-id" 2>/dev/null || true)
	ref=$(sed -n "s/^image='\\(.*\\)'\$/\\1/p" "$NEW_ROOT/bin/$OLD_HOST-setup" 2>/dev/null | head -n 1)
	if [ -n "$old_id" ] && [ -n "$ref" ]; then
		now_id=$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null || true)
		if [ "$now_id" != "$old_id" ]; then
			if docker tag "$old_id" "$ref" 2>/dev/null; then
				log "re-tagged $ref to the recorded pre-migration image"
			else
				log "warning: $ref no longer names the pre-migration image and that image is gone; load it before starting $OLD_HOST"
			fi
		fi
	fi
fi

# --- stack and directory -----------------------------------------------------------
if [ -f "$UNITS/$NEW_STACK" ]; then
	systemctl stop "$NEW_STACK"
	systemctl disable "$NEW_STACK" >/dev/null 2>&1 || true
	rm -f "$UNITS/$NEW_STACK"
fi
if [ -L "$OLD_ROOT" ]; then
	rm "$OLD_ROOT"
	mv "$NEW_ROOT" "$OLD_ROOT"
	log "moved $NEW_ROOT back to $OLD_ROOT"
fi

# --- legacy unit files, then start what was enabled --------------------------------
for f in "$rb/units"/*; do
	[ -e "$f" ] || continue
	[ -e "$UNITS/${f##*/}" ] || cp -a "$f" "$UNITS/"
done
systemctl daemon-reload
if [ -f "$rb/units.txt" ]; then
	while read -r unit enabled _active; do
		case "$unit" in *@.service) continue ;; esac
		if [ "$enabled" = enabled=enabled ]; then systemctl enable "$unit"; fi
	done <"$rb/units.txt"
fi
systemctl start "$OLD_STACK"
if [ "$profile" = full_machine ]; then
	systemctl start "$OLD_HOST.service"
	for id in $agent_ids; do
		systemctl enable --now "$OLD_AGENT@$id.service"
	done
fi

echo rolled-back >"$rb/status"
log "rolled back from $rb"
for u in "$OLD_STACK" "$OLD_HOST.service"; do
	[ -f "$UNITS/$u" ] || continue
	en=$(systemctl is-enabled "$u" 2>/dev/null) || en=${en:-not-found}
	ac=$(systemctl is-active "$u" 2>/dev/null) || ac=${ac:-inactive}
	printf '%s enabled=%s active=%s\n' "$u" "$en" "$ac"
done
