#!/usr/bin/env bash
# Build apps/platform/priv/code_mode/quickjs_cm.wasm (task 01a114a8 stage 2).
#
#   scripts/build-code-mode-wasm.sh [output.wasm]
#
# QuickJS-ng + the code_mode harness (apps/platform/native/code_mode/cm.c),
# compiled to wasm32-wasip1 with a pinned wasi-sdk inside a pinned container.
# Run it on the build host (podman), never on a developer's daily-driver
# machine. Nothing here is fetched unverified:
#
#   * the container base image is pinned by manifest-list digest;
#   * wasi-sdk is the upstream release tarball, checked against its sha256;
#   * quickjs-ng is cloned at a tag and checked against the tag's commit sha.
#
# The build is reproducible: the same inputs give a byte-identical .wasm (run it
# twice and compare; Platform.CodeMode's tests pin the vendored artifact's
# sha256, so a rebuild that changes a byte fails the suite until re-pinned).
set -euo pipefail

# ── pins ─────────────────────────────────────────────────────────────────
BASE_IMAGE="docker.io/library/debian@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587" # bookworm-slim, 2026-10-05
WASI_SDK_VERSION="34.0"
WASI_SDK_TAG="wasi-sdk-34"
WASI_SDK_SHA256_X86_64="b761e3a0721dbae9c09a0059e5fdb2bf917d1b4a8a7b430fb3b5aafb0984b2c4"
WASI_SDK_SHA256_ARM64="f7e243dff54d60bcc576e94d6166b69f410f2500ae4a9ceef34315be10e77971"
QUICKJS_NG_TAG="v0.16.2"
QUICKJS_NG_COMMIT="1ab8676f4b6d6d669baeb5f21790fb9734636a20"
QUICKJS_NG_REPO="https://github.com/quickjs-ng/quickjs.git"
# ─────────────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS_DIR="$REPO_ROOT/apps/platform/native/code_mode"
OUT="${1:-$REPO_ROOT/apps/platform/priv/code_mode/quickjs_cm.wasm}"
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

case "$(uname -m)" in
  x86_64) SDK_ARCH="x86_64"; SDK_SHA="$WASI_SDK_SHA256_X86_64" ;;
  aarch64 | arm64) SDK_ARCH="arm64"; SDK_SHA="$WASI_SDK_SHA256_ARM64" ;;
  *) echo "unsupported build host arch $(uname -m)" >&2; exit 1 ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/code-mode-wasm-01a114a8-XXXXXX")"
CONTAINER="code-mode-wasm-01a114a8-$$"
cleanup() {
  podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

SDK_TARBALL="wasi-sdk-${WASI_SDK_VERSION}-${SDK_ARCH}-linux.tar.gz"
echo "fetching $SDK_TARBALL"
curl -fsSL -o "$WORK/$SDK_TARBALL" \
  "https://github.com/WebAssembly/wasi-sdk/releases/download/${WASI_SDK_TAG}/${SDK_TARBALL}"
echo "${SDK_SHA}  $WORK/$SDK_TARBALL" | sha256sum -c -

echo "cloning quickjs-ng $QUICKJS_NG_TAG"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$QUICKJS_NG_TAG" \
  "$QUICKJS_NG_REPO" "$WORK/quickjs"
got="$(git -C "$WORK/quickjs" rev-parse HEAD)"
if [ "$got" != "$QUICKJS_NG_COMMIT" ]; then
  echo "quickjs-ng $QUICKJS_NG_TAG is $got, expected $QUICKJS_NG_COMMIT" >&2
  exit 1
fi

mkdir -p "$WORK/out"
cp "$HARNESS_DIR/cm.c" "$WORK/cm.c"

# Paths inside the container are fixed (/build), and -ffile-prefix-map strips
# them, so the host's temp dir name never reaches the artifact.
podman run --rm --name "$CONTAINER" --network=none \
  -v "$WORK:/build:z" -w /build "$BASE_IMAGE" bash -euo pipefail -c "
    mkdir -p /opt && tar -xzf /build/$SDK_TARBALL -C /opt
    SDK=/opt/wasi-sdk-${WASI_SDK_VERSION}-${SDK_ARCH}-linux
    \$SDK/bin/clang --version | head -1
    \$SDK/bin/clang --target=wasm32-wasip1 --sysroot=\$SDK/share/wasi-sysroot \
      -O2 -std=gnu11 -D_GNU_SOURCE -DNDEBUG \
      -ffile-prefix-map=/build=. -fno-ident \
      -Wno-unused-parameter -Wno-sign-compare \
      -I quickjs \
      cm.c quickjs/quickjs.c quickjs/libregexp.c quickjs/libunicode.c quickjs/dtoa.c \
      -mexec-model=reactor \
      -Wl,--stack-first -Wl,-z,stack-size=4194304 -Wl,--strip-all \
      -o out/quickjs_cm.wasm
  "

cp "$WORK/out/quickjs_cm.wasm" "$OUT"
echo "built $OUT"
echo "  bytes  $(wc -c < "$OUT")"
echo "  sha256 $(sha256sum "$OUT" | cut -d' ' -f1)"
echo "  wasi-sdk $WASI_SDK_TAG ($SDK_ARCH), quickjs-ng $QUICKJS_NG_TAG @ $QUICKJS_NG_COMMIT"
