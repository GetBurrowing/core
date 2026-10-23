#!/bin/sh
# Fetch the binaries Mix deps download from GitHub release URLs with curl,
# into the exact paths those deps look in first, so their own Erlang
# `:httpc` download never runs.
#
# Why: since 2026-10-23 a GitHub release download answers with a 302 whose
# header block is ~10.7 KB (a ~9.2 KB content-security-policy plus a ~0.9 KB
# signed Location). OTP 28's httpc (inets 9.6) caps the TOTAL response header
# block at its 10240-byte `max_header_size` default and fails with
# {:error, {:header_too_long, {:max, 10240}}}. tailwind, rustler_precompiled
# and elixir_make all call `:httpc.request/4` without that option, and none of
# their current releases (tailwind 0.5.1, rustler_precompiled 0.10.0,
# elixir_make 0.10.0) sets it. curl has no such cap.
#
# Usage (from anywhere; paths may be relative to the current directory):
#
#   fetch-github-release-binaries.sh tailwind <project_dir> [<config.exs>]
#       Puts tailwindcss at <project_dir>/_build/tailwind-<target>, which is
#       Tailwind.bin_path/0 for a project that sets no `config :tailwind,
#       path:`. The version is `config :tailwind, version:` in <config.exs>
#       (default <project_dir>/config/config.exs). `mix tailwind.install
#       --if-missing` then finds that version installed and downloads nothing.
#
#   fetch-github-release-binaries.sh nifs <project_dir>
#       For every dep in <project_dir>/deps that ships a precompiled-NIF
#       checksum file, downloads this host's artefacts into the cache that
#       rustler_precompiled / elixir_make read before downloading, and checks
#       each against the dep's own checksum file. Run after `mix deps.get`
#       and before the deps compile. The cache is per-user, so one run covers
#       every project on the host that locks the same versions.
#
# Versions are never written here: they come from config.exs (tailwind) and
# <project_dir>/mix.lock (NIF deps); file names and sha256s come from the
# deps' checksum files. A dep that ships a checksum file and is not in the
# table below FAILS this script, so a new precompiled dep cannot fall back
# to httpc unnoticed.
set -eu

die() {
  echo "::error::fetch-github-release-binaries: $*" >&2
  exit 1
}

fetch() { # url dest
  tmp="$2.part.$$"
  curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "$1" || {
    rm -f "$tmp"
    die "curl could not fetch $1"
  }
  mv "$tmp" "$2"
}

is_musl() {
  ldd --version 2>&1 | grep -qi musl
}

cmd_tailwind() {
  project=$1
  config=${2:-$project/config/config.exs}
  [ -f "$config" ] || die "no config file at $config"

  version=$(awk '
    /^config :tailwind,/ { in_block = 1; next }
    /^config / { in_block = 0 }
    in_block && /version:/ {
      if (match($0, /"[^"]+"/)) { print substr($0, RSTART + 1, RLENGTH - 2); exit }
    }' "$config")
  [ -n "$version" ] || die "no 'config :tailwind, version:' in $config"

  # Tailwind.target/0 for the Linux targets these images and runners use.
  case $(uname -m) in
    x86_64 | amd64) target=linux-x64 ;;
    aarch64 | arm64) target=linux-arm64 ;;
    *) die "no tailwind target for $(uname -m)" ;;
  esac
  case $version in 4.*) is_musl && target="$target-musl" ;; esac

  # NO_COLOR as Tailwind.bin_version/0 sets it: under CI the banner is
  # coloured, with an escape code between "tailwindcss" and the version.
  dest="$project/_build/tailwind-$target"
  if [ -x "$dest" ] && NO_COLOR=1 "$dest" --help 2>&1 | grep -q "tailwindcss v$version"; then
    echo "tailwind v$version already at $dest"
    return
  fi
  mkdir -p "$project/_build"
  fetch "https://github.com/tailwindlabs/tailwindcss/releases/download/v$version/tailwindcss-$target" "$dest"
  chmod +x "$dest"
  NO_COLOR=1 "$dest" --help 2>&1 | grep -q "tailwindcss v$version" ||
    die "$dest does not report tailwindcss v$version"
  echo "tailwind v$version -> $dest"
}

cmd_nifs() {
  project=$1
  lock="$project/mix.lock"
  [ -f "$lock" ] || die "no mix.lock at $lock"
  [ -d "$project/deps" ] || die "no deps in $project (run mix deps.get first)"

  cache=${XDG_CACHE_HOME:-$HOME/.cache}
  rustler_cache=${RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH:-$cache/rustler_precompiled/precompiled_nifs}
  make_cache=${ELIXIR_MAKE_CACHE_DIR:-$cache/elixir_make}
  case $(uname -m) in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) die "no NIF target for $(uname -m)" ;;
  esac
  libc=gnu
  is_musl && libc=musl

  found=0
  for checksum in "$project"/deps/*/checksum*.exs; do
    [ -f "$checksum" ] || continue
    dep=$(basename "$(dirname "$checksum")")
    # dep | GitHub repo | which cache | that library's target triple
    case $dep in
      wasmex) repo=tessi/wasmex dir=$rustler_cache triple=$arch-unknown-linux-$libc ;;
      vix) repo=akash-akya/vix dir=$make_cache triple=$arch-linux-$libc ;;
      lazy_html) repo=dashbitco/lazy_html dir=$make_cache triple=$arch-linux-$libc ;;
      *) die "deps/$dep ships $(basename "$checksum") but is not in this script's table; add its GitHub repo" ;;
    esac
    version=$(sed -n "s/.*\"$dep\": {:hex, :$dep, \"\([^\"]*\)\".*/\1/p" "$lock")
    [ -n "$version" ] || die "$dep is not a hex dep in $lock"

    mkdir -p "$dir"
    # Lines look like:  "<file>" => "sha256:<hex>",
    entries=$(grep -o "\"[^\"]*-$triple[-.][^\"]*\" => \"sha256:[0-9a-f]*\"" "$checksum" |
      sed 's/^"\([^"]*\)" => "sha256:\([0-9a-f]*\)"$/\1 \2/')
    [ -n "$entries" ] || die "$checksum lists no artefact for $triple"

    echo "$entries" | while read -r file sha; do
      dest="$dir/$file"
      if [ -f "$dest" ] && echo "$sha  $dest" | sha256sum -c - >/dev/null 2>&1; then
        echo "$dep $version: $file already cached"
        continue
      fi
      fetch "https://github.com/$repo/releases/download/v$version/$file" "$dest"
      echo "$sha  $dest" | sha256sum -c - >/dev/null 2>&1 || {
        rm -f "$dest"
        die "$file does not match the sha256 in $checksum"
      }
      echo "$dep $version: $file -> $dir"
    done
    found=$((found + 1))
  done
  echo "precompiled NIF deps handled in $project: $found"
}

case ${1:-} in
  tailwind) [ $# -ge 2 ] || die "usage: $0 tailwind <project_dir> [<config.exs>]"; shift; cmd_tailwind "$@" ;;
  nifs) [ $# -eq 2 ] || die "usage: $0 nifs <project_dir>"; cmd_nifs "$2" ;;
  *) die "usage: $0 tailwind <project_dir> [<config.exs>] | nifs <project_dir>" ;;
esac
