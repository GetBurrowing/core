#!/usr/bin/env bash
# Burrow Android release: build the AAB on the rig host, sign it with the UPLOAD key,
# check the signature, and upload it to the Play internal track
# (task 01a10d8e stage 5; README "Release" and "Human inputs").
#
#   release.sh --local    a debug-signed release AAB. No secrets, no Firebase.
#                         Asserts the applicationId, versionName, SDK floors and
#                         that the release manifest has no debug receiver and no
#                         cleartext.
#   release.sh --signed   the upload-key-signed AAB (with google-services.json),
#                         its certificate checked against upload.crt. No upload.
#   release.sh --upload   --signed, then Play: play_upload.py to the internal
#                         track. Exits 3 naming every MISSING INPUT by path.
#
# Runs from a dev box (it ssh-es to RIG_HOST) or on the rig host itself (then
# it runs locally). REQUIRED, with no default: RIG_HOST (ssh target of the
# rig, user@host), RIG_ROOT (the rig's work root on that host) and
# BURROW_VERSIONCODE_FILE (the versionCode counter on that host).
# Inputs are read from BURROW_KEYS_DIR (default ~/private_keys/burrow-android):
#   upload-keystore.p12  keystore-password.txt  upload.crt
#   google-services.json (--signed/--upload)
#   BURROW_PLAY_KEY, default <keys>/burrow-e7850-6e4ab44521d9.json (--upload)
#
# Secrets: copied into a per-run `mktemp -d` dir on the rig (mode 700) that an
# EXIT/INT/TERM/HUP trap deletes whatever happens; the build reads them by
# PATH (rig.sh RIG_SECRETS). Nothing here prints a secret: no cat, no echo of
# a value, no secret in argv. This script never creates a key.
#
# Exit codes: 0 ok; 2 usage; 3 missing inputs; 4 signature mismatch;
# 5 a manifest/AAB assertion failed; other: the failing step's.
# The commands sent to the rig are built here on purpose (SC2029).
# shellcheck disable=SC2029
set -euo pipefail

MODE="${1:-}"
case "${MODE}" in --local|--signed|--upload) ;; *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;; esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${RIG_PREFIX:-01a10d8e}"
for v in RIG_HOST RIG_ROOT BURROW_VERSIONCODE_FILE; do
  [ -n "${!v:-}" ] || { echo "release: ${v} is required (no default); see the header" >&2; exit 2; }
done
RIG_SSH="${RIG_HOST}"
WORK="${RIG_ROOT}/${PREFIX}"
COUNTER="${BURROW_VERSIONCODE_FILE}"
KEYS="${BURROW_KEYS_DIR:-${HOME}/private_keys/burrow-android}"
PLAY_KEY="${BURROW_PLAY_KEY:-${KEYS}/burrow-e7850-6e4ab44521d9.json}"
PACKAGE="com.koboai.burrow"
VERSION_NAME="1.0"
# Play's floor for new apps and updates (Aug 2025: target API 35).
PLAY_MIN_TARGET_SDK=35
OUT_DIR="${BURROW_OUT_DIR:-${HOME}/Dev/build/burrow-android}"

log() { echo "release: $*" >&2; }
die() { local code="$1"; shift; log "$*"; exit "${code}"; }

# The short host name of RIG_HOST: running there means running locally.
rig_name="${RIG_HOST#*@}"
rig_name="${rig_name%%.*}"
if [ "$(hostname -s)" = "${rig_name}" ]; then
  ON_RIG=1
  on_rig() { bash -c "$1"; }
  to_rig() { cp -p "$1" "$2"; }
  from_rig() { cp -p "$1" "$2"; }
  RIG="${WORK}/clients/android/scripts/rig/rig.sh"
  # On the rig host the script runs from the rig's own copy; run it there.
  [ "$(cd "${here}/.." && pwd)" = "${WORK}/clients/android" ] || die 2 "on the rig host, run ${RIG%/rig/rig.sh}/release.sh"
else
  ON_RIG=0
  on_rig() { ssh "${RIG_SSH}" "$1"; }
  to_rig() { scp -q -p "$1" "${RIG_SSH}:$2"; }
  from_rig() { scp -q -p "${RIG_SSH}:$1" "$2"; }
  RIG="${WORK}/clients/android/scripts/rig/rig.sh"
fi

# ── Inputs ───────────────────────────────────────────────────────────────
need=()
if [ "${MODE}" != "--local" ]; then
  need+=("${KEYS}/upload-keystore.p12" "${KEYS}/keystore-password.txt" "${KEYS}/upload.crt" "${KEYS}/google-services.json")
fi
if [ "${MODE}" = "--upload" ]; then
  need+=("${PLAY_KEY}")
fi
missing=()
for f in "${need[@]}"; do [ -s "${f}" ] || missing+=("${f}"); done
if [ "${#missing[@]}" -gt 0 ]; then
  log "MISSING INPUT(S); nothing was built:"
  for f in "${missing[@]}"; do echo "  missing: ${f}" >&2; done
  exit 3
fi

# The expected signing certificate (public; printable).
EXPECTED=""
if [ "${MODE}" != "--local" ]; then
  EXPECTED="$(openssl x509 -in "${KEYS}/upload.crt" -noout -fingerprint -sha256 | sed 's/^.*=//' | tr -d ':' | tr 'a-f' 'A-F')"
  [ -n "${EXPECTED}" ] || die 3 "could not read the fingerprint of ${KEYS}/upload.crt"
fi

# ── Secrets dir on the rig, removed whatever happens ────────────────────
SECRETS=""
cleanup() {
  local rc=$?
  if [ -n "${SECRETS}" ]; then
    on_rig "rm -rf '${SECRETS}' '${WORK}/clients/android/android/app/google-services.json'" || true
  fi
  exit "${rc}"
}
trap cleanup EXIT INT TERM HUP

# ── Source on the rig ────────────────────────────────────────────────────
if [ "${ON_RIG}" = 0 ]; then
  "${here}/rig/rig.sh" push >/dev/null
fi

if [ "${MODE}" != "--local" ]; then
  SECRETS="$(on_rig "umask 077; mkdir -p '${RIG_ROOT}' && mktemp -d -p '${RIG_ROOT}' release-secrets.XXXXXXXX")"
  on_rig "chmod 700 '${SECRETS}'"
  to_rig "${KEYS}/upload-keystore.p12" "${SECRETS}/upload-keystore.p12"
  to_rig "${KEYS}/keystore-password.txt" "${SECRETS}/keystore-password.txt"
  to_rig "${KEYS}/google-services.json" "${SECRETS}/google-services.json"
  if [ "${MODE}" = "--upload" ]; then to_rig "${PLAY_KEY}" "${SECRETS}/play-service-account.json"; fi
  on_rig "chmod 600 '${SECRETS}'/*"
  # Firebase config for the shipped build; removed by the trap.
  on_rig "install -m 600 '${SECRETS}/google-services.json' '${WORK}/clients/android/android/app/google-services.json'"
fi
[ "${BURROW_RELEASE_FORCE_FAIL:-}" = "after-secrets" ] && die 1 "forced failure after the secrets were copied (test hook)"

# ── versionCode ──────────────────────────────────────────────────────────
current="$(on_rig "cat '${COUNTER}' 2>/dev/null || echo 0")"
case "${current}" in ''|*[!0-9]*) die 5 "versionCode counter ${COUNTER} is not a number" ;; esac
VERSION_CODE=$((current + 1))
log "mode ${MODE}, versionCode ${VERSION_CODE}"

# ── Build ────────────────────────────────────────────────────────────────
props="-PburrowVersionCode=${VERSION_CODE}"
[ "${MODE}" = "--local" ] && props="${props} -PburrowLocalDebugSigned=true"
build_log="$(on_rig "mktemp -p '${WORK}' release-build.XXXXXX.log")"
secrets_env=""
[ -n "${SECRETS}" ] && secrets_env="RIG_SECRETS='${SECRETS}'"
if ! on_rig "cd '${WORK}/clients/android' && ${secrets_env} RIG_GRADLE_PROPS='${props}' '${RIG}' gradle bundleRelease > '${build_log}' 2>&1"; then
  on_rig "grep -E 'FAILURE|What went wrong|error:' '${build_log}' | head -20" >&2 || true
  die 1 "bundleRelease failed (log on the rig: ${build_log})"
fi
on_rig "rm -f '${build_log}'"

AAB_REL="clients/android/android/app/build/outputs/bundle/release/app-release.aab"
on_rig "test -s '${WORK}/${AAB_REL}'" || die 5 "no AAB at ${AAB_REL}"

# ── Assertions on the AAB ────────────────────────────────────────────────
manifest="$(on_rig "'${RIG}' bundletool dump manifest --bundle '/work/${AAB_REL}'")"
attr() { awk -v k="$1" 'match($0, k "=\"[^\"]*\"") { v = substr($0, RSTART + length(k) + 2, RLENGTH - length(k) - 3); print v; exit }' <<<"${manifest}"; }
pkg="$(attr 'package')"
[ "${pkg}" = "${PACKAGE}" ] || die 5 "applicationId is '${pkg}', expected ${PACKAGE}"
vn="$(attr 'android:versionName')"
[ "${vn}" = "${VERSION_NAME}" ] || die 5 "versionName is '${vn}', expected ${VERSION_NAME}"
vc="$(attr 'android:versionCode')"
[ "${vc}" = "${VERSION_CODE}" ] || die 5 "versionCode is '${vc}', expected ${VERSION_CODE}"
target="$(attr 'android:targetSdkVersion')"
min="$(attr 'android:minSdkVersion')"
[ "${target:-0}" -ge "${PLAY_MIN_TARGET_SDK}" ] || die 5 "targetSdk ${target} is below Play's floor ${PLAY_MIN_TARGET_SDK}"
[ "${min:-0}" -ge 26 ] || die 5 "minSdk ${min} is below 26"
if printf '%s' "${manifest}" | grep -q 'DebugPushReceiver\|DebugWidgetReceiver\|DebugExplainer\|com.koboai.burrow.debug'; then
  die 5 "the release manifest contains a debug-only component"
fi
if printf '%s' "${manifest}" | grep -q 'usesCleartextTraffic="true"'; then
  die 5 "the release manifest allows cleartext traffic"
fi
log "manifest ok: ${pkg} ${vn} (${vc}), minSdk ${min}, targetSdk ${target}"

# ── Signature (the UPLOAD key, never another) ────────────────────────────
if [ "${MODE}" != "--local" ]; then
  # Captured whole, then parsed: a pipe into `grep -m1` would SIGPIPE keytool under pipefail.
  certs="$(on_rig "podman run --rm -v '${WORK}:/work:z' localhost/burrow-android-rig:latest keytool -printcert -jarfile '/work/${AAB_REL}'" || true)"
  actual="$(awk '/SHA256:/ { sub(/^.*SHA256: */, ""); gsub(/[: ]/, ""); print toupper($0); exit }' <<<"${certs}")"
  [ -n "${actual}" ] || die 4 "the AAB carries no signature"
  if [ "${actual}" != "${EXPECTED}" ]; then
    die 4 "SIGNATURE MISMATCH: the AAB is signed by ${actual:0:8}...${actual: -4}, upload.crt is ${EXPECTED:0:8}...${EXPECTED: -4}. Refusing."
  fi
  log "signed with the upload key (SHA-256 ${EXPECTED:0:8}...${EXPECTED: -4})"
fi

# ── Copy out ─────────────────────────────────────────────────────────────
name="burrow-${VERSION_NAME}-${VERSION_CODE}-${MODE#--}.aab"
on_rig "mkdir -p '${WORK}/out' && cp '${WORK}/${AAB_REL}' '${WORK}/out/${name}'"
if [ "${ON_RIG}" = 0 ]; then
  mkdir -p "${OUT_DIR}"
  from_rig "${WORK}/out/${name}" "${OUT_DIR}/${name}"
  log "AAB: ${OUT_DIR}/${name} (and ${WORK}/out/${name} on the rig)"
else
  log "AAB: ${WORK}/out/${name}"
fi

# ── Upload ───────────────────────────────────────────────────────────────
if [ "${MODE}" = "--upload" ]; then
  on_rig "cd '${WORK}/clients/android' && python3 scripts/play_upload.py \
    --key '${SECRETS}/play-service-account.json' --package '${PACKAGE}' \
    --aab '${WORK}/out/${name}' --track internal --notes WHATSNEW.md ${BURROW_PLAY_ARGS:-}" \
    || die 1 "play upload failed; versionCode counter NOT advanced"
  if [ "${BURROW_PLAY_ARGS:-}" != "--dry-run" ]; then
    on_rig "mkdir -p '$(dirname "${COUNTER}")' && echo ${VERSION_CODE} > '${COUNTER}.tmp' && mv '${COUNTER}.tmp' '${COUNTER}'"
    log "uploaded versionCode ${VERSION_CODE}; counter advanced"
  fi
fi
log "done"
