#!/bin/sh
# Install the agent host's pinned tools, system-wide, as root
# (core task 01a10322 stage 3). Used by BOTH capability profiles:
#   contained     the Dockerfile, at image build time;
#   full_machine  suite-agent-host-setup.service, on the host, at first boot.
#
# Usage: install-tools.sh <versions.env>
#
# Installs node (nodejs.org tarball, sha256-checked), bun, Claude Code and the
# Codex CLI (npm, global), and suite-cli at a pinned commit. Everything lands
# under /usr/local so every agent user can run it and none can modify it.
# Idempotent: a tool already at its pinned version is left alone.
set -eu

versions="${1:?usage: install-tools.sh <versions.env>}"
# shellcheck disable=SC1090
. "$versions"
for name in NODE_VERSION BUN_VERSION CLAUDE_CODE_VERSION CODEX_VERSION; do
	eval "value=\${$name:-}"
	[ -n "$value" ] || { echo "install-tools: $name is not set in $versions" >&2; exit 1; }
done
# suite-cli's pin: BURROW_CLI_REF, else the legacy SUITE_CLI_REF. Blank is unset.
cli_ref="$(printf '%s' "${BURROW_CLI_REF:-}" | tr -d '[:space:]')"
if [ -z "$cli_ref" ]; then
	cli_ref="$(printf '%s' "${SUITE_CLI_REF:-}" | tr -d '[:space:]')"
	[ -n "$cli_ref" ] || { echo "install-tools: BURROW_CLI_REF (or legacy SUITE_CLI_REF) is not set in $versions" >&2; exit 1; }
	echo "deprecated: SUITE_CLI_REF is set; rename it to BURROW_CLI_REF" >&2
fi

case "$(uname -m)" in
x86_64) node_arch=x64 ;;
aarch64 | arm64) node_arch=arm64 ;;
*) echo "install-tools: unsupported machine $(uname -m)" >&2; exit 1 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

# node
if [ "$(/usr/local/bin/node --version 2>/dev/null || true)" != "v$NODE_VERSION" ]; then
	tarball="node-v$NODE_VERSION-linux-$node_arch.tar.xz"
	curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/$tarball" -o "$tmp/$tarball"
	curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt"
	want="$(grep "  $tarball\$" "$tmp/SHASUMS256.txt" | cut -d' ' -f1)"
	have="$(sha256sum "$tmp/$tarball" | cut -d' ' -f1)"
	if [ -z "$want" ] || [ "$want" != "$have" ]; then
		echo "install-tools: $tarball does not match nodejs.org's SHASUMS256.txt" >&2
		exit 1
	fi
	tar -xJf "$tmp/$tarball" -C /usr/local --strip-components=1 \
		--exclude=CHANGELOG.md --exclude=LICENSE --exclude=README.md
fi

# bun
if [ "$(/usr/local/bin/bun --version 2>/dev/null || true)" != "$BUN_VERSION" ]; then
	curl -fsSL https://bun.sh/install -o "$tmp/bun-install.sh"
	BUN_INSTALL=/usr/local bash "$tmp/bun-install.sh" "bun-v$BUN_VERSION" >/dev/null
	chmod 0755 /usr/local/bin/bun
fi

# Claude Code and Codex. Agents never update them: suite-agent@.service sets
# DISABLE_AUTOUPDATER=1, and /usr/local is not theirs to write.
npm install --global --no-fund --no-audit --loglevel=error \
	"@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION" "@openai/codex@$CODEX_VERSION"

# suite-cli, from the pinned commit. Its installer asks before replacing an
# existing install, so remove the old entrypoint first; stdin is /dev/null so
# no prompt can ever block a boot.
curl -fsSL "https://raw.githubusercontent.com/Startup-Suite/suite-cli/$cli_ref/install.sh" \
	-o "$tmp/suite-install.sh"
rm -f /usr/local/bin/suite
# suite-cli 969c6f7 reads only SUITE_CLI_REF, so pass both names.
PATH="/usr/local/bin:$PATH" BURROW_CLI_REF="$cli_ref" SUITE_CLI_REF="$cli_ref" XDG_BIN_HOME=/usr/local/bin \
	XDG_DATA_HOME=/usr/local/share sh "$tmp/suite-install.sh" </dev/null >/dev/null
chmod -R a+rX /usr/local/share/suite

echo "install-tools: node $(/usr/local/bin/node --version) bun $(/usr/local/bin/bun --version)" \
	"claude $CLAUDE_CODE_VERSION codex $CODEX_VERSION suite $(/usr/local/bin/suite --version)"
