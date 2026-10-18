#!/usr/bin/env bash
# Tests for scripts/release.sh (task 01a10d8e stage 5). Runs ON THE RIG HOST,
# from the rig's copy (rig.sh push first):
#
#   RIG_HOST=<user@rig-host> RIG_ROOT=<rig work root> \
#     <rig work root>/01a10d8e/clients/android/scripts/test_release.sh
#
# RIG_HOST and RIG_ROOT are required (no default), as for release.sh.
# Uses only THROWAWAY keys made here with openssl, in a mktemp dir removed on
# exit. It never reads the real upload key, and it uses its own versionCode
# counter so the real one never moves.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
android_dir="$(cd "${here}/.." && pwd)"
for v in RIG_HOST RIG_ROOT; do
  [ -n "${!v:-}" ] || { echo "test_release: ${v} is required (no default)" >&2; exit 2; }
done
T="$(mktemp -d -p "${RIG_ROOT}" release-test.XXXXXXXX)"
trap 'rm -rf "${T}"' EXIT
export BURROW_VERSIONCODE_FILE="${T}/versioncode"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   - $*"; }
bad() { fail=$((fail + 1)); echo "FAIL - $*"; }

secrets_dirs() { find "${RIG_ROOT}" -maxdepth 1 -name 'release-secrets.*' | sort; }

# A throwaway PKCS12 "upload" key and its certificate, plus a second,
# unrelated certificate for the mismatch case. openssl, never the JDK's
# key-generation command (the repo grep below forbids it).
make_keys() {
  local dir="$1" pw="$2"
  mkdir -p "${dir}"
  printf '%s\n' "${pw}" > "${dir}/keystore-password.txt"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=throwaway-upload" \
    -keyout "${dir}/key.pem" -out "${dir}/upload.crt" 2>/dev/null
  openssl pkcs12 -export -name upload -inkey "${dir}/key.pem" -in "${dir}/upload.crt" \
    -passout "file:${dir}/keystore-password.txt" -out "${dir}/upload-keystore.p12"
  rm -f "${dir}/key.pem"
  # A fake Firebase config shaped enough for the google-services plugin.
  cat > "${dir}/google-services.json" <<'JSON'
{"project_info":{"project_number":"1","project_id":"throwaway-test","storage_bucket":"throwaway-test.appspot.com"},
 "client":[{"client_info":{"mobilesdk_app_id":"1:1:android:0000000000000000","android_client_info":{"package_name":"com.koboai.burrow"}},
  "oauth_client":[],"api_key":[{"current_key":"not-a-real-key"}],
  "services":{"appinvite_service":{"other_platform_oauth_client":[]}}}],
 "configuration_version":"1"}
JSON
}

PW="throwaway-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
make_keys "${T}/keys" "${PW}"
mkdir -p "${T}/other"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=someone-else" \
  -keyout "${T}/other/key.pem" -out "${T}/other/upload.crt" 2>/dev/null
rm -f "${T}/other/key.pem"

before="$(secrets_dirs)"

# 1. --upload with no Play inputs exits 3 and names each missing path.
mkdir -p "${T}/empty"
set +e
out="$(BURROW_KEYS_DIR="${T}/empty" BURROW_PLAY_KEY="${T}/empty/play.json" "${here}/release.sh" --upload 2>&1)"
rc=$?
set -e
if [ "${rc}" = 3 ] && grep -q "missing: ${T}/empty/upload-keystore.p12" <<<"${out}" \
  && grep -q "missing: ${T}/empty/play.json" <<<"${out}" && grep -q "missing: ${T}/empty/google-services.json" <<<"${out}"; then
  ok "--upload without inputs exits 3 and names the missing paths"
else
  bad "--upload without inputs (rc=${rc}): ${out}"
fi

# 2. --local builds an AAB whose applicationId is com.koboai.burrow.
set +e
out="$("${here}/release.sh" --local 2>&1)"
rc=$?
set -e
if [ "${rc}" = 0 ] && grep -q "manifest ok: com.koboai.burrow 1.0" <<<"${out}"; then
  ok "--local AAB: applicationId com.koboai.burrow, versionName 1.0, SDK floors, no debug component"
else
  bad "--local (rc=${rc}): $(tail -5 <<<"${out}")"
fi
all_output="${out}"

# 3. --signed with the throwaway key signs with THAT key.
set +e
out="$(BURROW_KEYS_DIR="${T}/keys" "${here}/release.sh" --signed 2>&1)"
rc=$?
set -e
if [ "${rc}" = 0 ] && grep -q "signed with the upload key" <<<"${out}"; then
  ok "--signed signs with the given PKCS12 and its certificate matches"
else
  bad "--signed (rc=${rc}): $(tail -5 <<<"${out}")"
fi
all_output="${all_output}${out}"

# 4. A certificate that is not the keystore's: refused with exit 4.
cp "${T}/keys/upload-keystore.p12" "${T}/keys/keystore-password.txt" "${T}/keys/google-services.json" "${T}/other/"
set +e
out="$(BURROW_KEYS_DIR="${T}/other" "${here}/release.sh" --signed 2>&1)"
rc=$?
set -e
if [ "${rc}" = 4 ] && grep -q "SIGNATURE MISMATCH" <<<"${out}"; then
  ok "a fingerprint mismatch against another certificate refuses (exit 4)"
else
  bad "mismatch (rc=${rc}): $(tail -3 <<<"${out}")"
fi
all_output="${all_output}${out}"

# 5. The secrets dir is gone after success, the mismatch failure, and a forced failure.
set +e
out="$(BURROW_KEYS_DIR="${T}/keys" BURROW_RELEASE_FORCE_FAIL=after-secrets "${here}/release.sh" --signed 2>&1)"
rc=$?
set -e
after="$(secrets_dirs)"
if [ "${rc}" != 0 ] && grep -q "forced failure" <<<"${out}" && [ "${before}" = "${after}" ] \
  && [ ! -e "${android_dir}/android/app/google-services.json" ]; then
  ok "no release-secrets dir and no copied google-services.json left after success and failures"
else
  bad "secrets left behind (rc=${rc}): before='${before}' after='${after}'"
fi
all_output="${all_output}${out}"

# 6. No secret-looking string in any output or the build logs.
leaks=0
for needle in "-----BEGIN" '"private_key"' "storePassword=" "${PW}"; do
  if grep -qF -- "${needle}" <<<"${all_output}"; then leaks=$((leaks + 1)); echo "  leaked: ${needle:0:12}..."; fi
done
if find "${RIG_ROOT}/${RIG_PREFIX:-01a10d8e}" -maxdepth 1 -name 'release-build.*.log' -exec grep -lF -- "${PW}" {} + 2>/dev/null | grep -q .; then
  leaks=$((leaks + 1))
fi
if [ "${leaks}" = 0 ]; then ok "no secret-looking string in the output or build logs"; else bad "${leaks} secret(s) in output"; fi

# 7. The repository never generates a key and never tracks key material.
cd "${android_dir}"
needle="genkey""pair"
if ! grep -rIl --exclude-dir=node_modules --exclude-dir=build --exclude-dir=.gradle -- "${needle}" . | grep -q .; then
  ok "no key-generation command anywhere in clients/android"
else
  bad "a key-generation command is in clients/android"
fi
if git -C "${android_dir}" rev-parse --git-dir >/dev/null 2>&1; then
  tracked="$(git -C "${android_dir}" ls-files | grep -E '\.p12$|\.jks$|google-services\.json$|service-account.*\.json$' || true)"
else
  # The rig copy has no .git: check that nothing of the kind is present at all.
  tracked="$(find . -path ./node_modules -prune -o \( -name '*.p12' -o -name '*.jks' -o -name 'google-services.json' -o -name '*service-account*.json' \) -print)"
fi
if [ -z "${tracked}" ]; then ok "no .p12, .jks, google-services.json or service-account JSON in clients/android"; else bad "key material: ${tracked}"; fi

echo "${pass} passed, ${fail} failed"
[ "${fail}" = 0 ]
