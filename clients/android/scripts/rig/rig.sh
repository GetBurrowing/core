#!/usr/bin/env bash
# Burrow Android rig: Gradle builds and a headless KVM emulator in podman on
# a Linux rig host with /dev/kvm (task 01a10d8e). A workstation without KVM
# or a JDK cannot be the rig. See clients/android/README.md, "Rig".
#
# REQUIRED, with no default: RIG_ROOT (the rig's work root on the rig host);
# RIG_HOST (ssh target of the rig, user@host) for `push`.
#
#   rig.sh push                  (dev box) rsync clients/android to RIG_HOST
#   rig.sh build-image           build the image, install the SDK packages
#   rig.sh gradle <args>         ./gradlew <args> in clients/android/android
#   rig.sh emulator-up <api>     boot a headless emulator (35 or 32)
#   rig.sh emulator-down         stop it
#   rig.sh adb <args>            adb inside the emulator container
#   rig.sh bundletool <args>     the pinned bundletool jar (fetched once,
#                                sha256-checked, cached on the Gradle volume)
#
# RIG_SECRETS=<dir on the rig> mounts that dir read-only at /secrets in the
# gradle container and sets BURROW_UPLOAD_KEYSTORE /
# BURROW_UPLOAD_PASSWORD_FILE to the files in it (PATHS, never values;
# scripts/release.sh). RIG_GRADLE_PROPS="-Pa=b ..." adds Gradle properties.
#
# Everything this script creates is named burrow-android-<prefix>-*, so it
# never touches another agent's containers. RIG_PREFIX defaults to the
# task's short id.
# Container scripts are single-quoted on purpose (they expand inside the
# container), and ssh arguments expand on the dev box on purpose.
# shellcheck disable=SC2016,SC2029
set -euo pipefail

PREFIX="${RIG_PREFIX:-01a10d8e}"
NAME="burrow-android-${PREFIX}"
IMAGE="localhost/burrow-android-rig:latest"
SDK_VOLUME="burrow-android-sdk"
GRADLE_VOLUME="burrow-android-gradle"
[ -n "${RIG_ROOT:-}" ] || { echo "rig: RIG_ROOT is required (no default); see the header" >&2; exit 2; }
WORK="${RIG_ROOT}/${PREFIX}"
EMU_CONTAINER="${NAME}-emu"
# Off the default 5554/5037 so a rig never collides with another adb/emulator;
# the console port stays inside 5554..5584, the range adb scans.
EMU_PORT="${RIG_EMU_PORT:-5580}"
# swiftshader_indirect segfaults (exit 139) during guest boot with emulator
# 37.2.12 in this container, measured 2026-10-05; swangle_indirect (ANGLE
# over SwiftShader, still software) boots API 35 in under 100 s.
EMU_GPU="${RIG_EMU_GPU:-swangle_indirect}"
ADB_PORT="${RIG_ADB_PORT:-5137}"
BUNDLETOOL_VERSION="1.18.3"
BUNDLETOOL_SHA256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "rig: $*" >&2; exit 1; }

require_rig() {
  [ -e /dev/kvm ] || die "no /dev/kvm here; run this on the rig host (ssh ${RIG_HOST:-<RIG_HOST>})"
  command -v podman >/dev/null || die "podman not found"
}

run_in_image() {
  # Short-lived container: unique name under the prefix, removed on exit.
  # The work dir is mounted :z (shared SELinux label), not :Z: the gradle
  # and emulator containers both read it, and :Z relabels it private to
  # whichever ran last ("adb install ... Permission denied").
  # ANDROID_USER_HOME on the Gradle volume keeps one debug.keystore across
  # runs, so a rebuilt debug APK still installs over the last one.
  local suffix="$1"; shift
  local secrets=()
  if [ -n "${RIG_SECRETS:-}" ]; then
    secrets=(-v "${RIG_SECRETS}:/secrets:ro,z"
      -e BURROW_UPLOAD_KEYSTORE=/secrets/upload-keystore.p12
      -e BURROW_UPLOAD_PASSWORD_FILE=/secrets/keystore-password.txt)
  fi
  podman run --rm -i \
    "${secrets[@]}" \
    -e RIG_GRADLE_PROPS="${RIG_GRADLE_PROPS:-}" \
    --name "${NAME}-${suffix}-$$" \
    --device /dev/kvm \
    --network host \
    -e ANDROID_ADB_SERVER_PORT="${ADB_PORT}" \
    -e ANDROID_USER_HOME=/root/.gradle/android-user \
    -v "${SDK_VOLUME}:/opt/android-sdk" \
    -v "${GRADLE_VOLUME}:/root/.gradle" \
    -v "${WORK}:/work:z" \
    -w /work \
    "${IMAGE}" "$@"
}

cmd_push() {
  # Runs on the dev box. Copies clients/android without build output
  # or node_modules; `gradle` installs node_modules inside the container.
  [ -n "${RIG_HOST:-}" ] || die "RIG_HOST is required for push (no default): the rig's ssh target, user@host"
  local src
  src="$(cd "${here}/../.." && pwd)"
  ssh "${RIG_HOST}" "mkdir -p '${WORK}/clients/android'"
  rsync -a --delete \
    --exclude node_modules/ --exclude '.gradle/' --exclude 'build/' \
    --exclude '.idea/' --exclude 'local.properties' --exclude '*.iml' \
    "${src}/" "${RIG_HOST}:${WORK}/clients/android/"
  echo "rig: pushed ${src} -> ${RIG_HOST}:${WORK}/clients/android"
}

cmd_build_image() {
  require_rig
  podman build -t "${IMAGE}" -f "${here}/Containerfile" "${here}"
  podman volume exists "${SDK_VOLUME}" || podman volume create "${SDK_VOLUME}" >/dev/null
  podman volume exists "${GRADLE_VOLUME}" || podman volume create "${GRADLE_VOLUME}" >/dev/null
  mkdir -p "${WORK}"
  run_in_image sdk bash -c '
    set -euo pipefail
    yes | sdkmanager --sdk_root="$ANDROID_HOME" --licenses >/dev/null || true
    mapfile -t pkgs < <(grep -v "^\s*$" /opt/sdk-packages.txt)
    sdkmanager --sdk_root="$ANDROID_HOME" --install "${pkgs[@]}" | grep -v "^\[=*" || true
    sdkmanager --sdk_root="$ANDROID_HOME" --list_installed
  '
}

cmd_gradle() {
  require_rig
  [ -d "${WORK}/clients/android/android" ] || die "nothing at ${WORK}/clients/android; run 'rig.sh push' from the dev box"
  run_in_image gradle bash -c '
    set -euo pipefail
    cd /work/clients/android
    if [ ! -d node_modules/@capacitor/android ]; then npm ci --no-fund --no-audit >/dev/null; fi
    # The Cordova shim project, the copied www and capacitor.config.json are
    # generated (gitignored): regenerate them on every build.
    npx cap sync android >/dev/null
    cd android
    printf "sdk.dir=%s\n" "$ANDROID_HOME" > local.properties
    # shellcheck disable=SC2086 # RIG_GRADLE_PROPS is a word list on purpose
    ./gradlew --no-daemon ${RIG_GRADLE_PROPS:-} "$@"
  ' gradle "$@"
}

cmd_bundletool() {
  require_rig
  mkdir -p "${WORK}"
  run_in_image bt bash -c '
    set -euo pipefail
    jar=/root/.gradle/bundletool-'"${BUNDLETOOL_VERSION}"'.jar
    if [ ! -f "$jar" ]; then
      curl -fsSL -o "$jar.part" "https://github.com/google/bundletool/releases/download/'"${BUNDLETOOL_VERSION}"'/bundletool-all-'"${BUNDLETOOL_VERSION}"'.jar"
      echo "'"${BUNDLETOOL_SHA256}"'  $jar.part" | sha256sum -c - >/dev/null
      mv "$jar.part" "$jar"
    fi
    exec java -jar "$jar" "$@"
  ' bundletool "$@"
}

# Per prefix, like every other name here: the AVD lives on the shared SDK
# volume, and two rigs booting one AVD fail with "Failed to get write lock"
# on its cache.img (measured 2026-10-09, task 01a120be, while two other
# prefixes held burrow_api35).
avd_name() { echo "burrow_${PREFIX}_api$1"; }

cmd_emulator_up() {
  require_rig
  local api="${1:-35}"
  case "${api}" in 35|32) ;; *) die "api must be 35 or 32" ;; esac
  local avd
  avd="$(avd_name "${api}")"
  if podman container exists "${EMU_CONTAINER}"; then
    die "${EMU_CONTAINER} already exists; run emulator-down first"
  fi
  mkdir -p "${WORK}"
  podman run -d \
    --name "${EMU_CONTAINER}" \
    --shm-size=2g \
    --device /dev/kvm \
    --network host \
    -e ANDROID_ADB_SERVER_PORT="${ADB_PORT}" \
    -v "${SDK_VOLUME}:/opt/android-sdk" \
    -v "${WORK}:/work:z" \
    "${IMAGE}" bash -c "
      set -euo pipefail
      if [ ! -d \"\$ANDROID_AVD_HOME/${avd}.avd\" ]; then
        mkdir -p \"\$ANDROID_AVD_HOME\"
        echo no | avdmanager create avd -n ${avd} -k 'system-images;android-${api};google_apis;x86_64' \\
          -d pixel_7 -p \"\$ANDROID_AVD_HOME/${avd}.avd\" --force
        # avdmanager takes its SDK root from its own install dir (/opt), not
        # ANDROID_HOME, so it writes android-sdk/system-images/...: make the
        # system image path relative to ANDROID_HOME.
        sed -i 's|^image.sysdir.1=.*system-images/|image.sysdir.1=system-images/|' \"\$ANDROID_AVD_HOME/${avd}.avd/config.ini\"
        printf 'hw.keyboard=yes\\nhw.gpu.enabled=yes\\n' >> \"\$ANDROID_AVD_HOME/${avd}.avd/config.ini\"
      fi
      # A crashed run leaves its locks behind and blocks the next boot.
      find \"\$ANDROID_AVD_HOME/${avd}.avd\" -name '*.lock' -prune -exec rm -rf {} +
      exec emulator -avd ${avd} -port ${EMU_PORT} -no-window -no-audio -no-boot-anim \
        -gpu ${EMU_GPU} -no-snapshot -memory 4096 -cores 4 -no-metrics
    " >/dev/null
  echo "rig: ${EMU_CONTAINER} starting (${avd}); waiting for boot"
  local serial="emulator-${EMU_PORT}"
  for _ in $(seq 1 180); do
    if podman exec "${EMU_CONTAINER}" adb -s "${serial}" shell getprop sys.boot_completed 2>/dev/null | grep -q 1; then
      echo "rig: ${serial} booted (api ${api})"
      return 0
    fi
    podman container exists "${EMU_CONTAINER}" || die "emulator container exited; see podman logs ${EMU_CONTAINER}"
    sleep 2
  done
  die "emulator did not boot in 6 min; podman logs ${EMU_CONTAINER}"
}

cmd_emulator_down() {
  require_rig
  if podman container exists "${EMU_CONTAINER}"; then
    podman rm -f "${EMU_CONTAINER}" >/dev/null
    echo "rig: removed ${EMU_CONTAINER}"
  else
    echo "rig: ${EMU_CONTAINER} not running"
  fi
}

cmd_adb() {
  require_rig
  podman container exists "${EMU_CONTAINER}" || die "no emulator; run emulator-up first"
  podman exec -i "${EMU_CONTAINER}" adb -s "emulator-${EMU_PORT}" "$@"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "${sub}" in
  push) cmd_push ;;
  build-image) cmd_build_image ;;
  gradle) cmd_gradle "$@" ;;
  emulator-up) cmd_emulator_up "$@" ;;
  emulator-down) cmd_emulator_down ;;
  adb) cmd_adb "$@" ;;
  bundletool) cmd_bundletool "$@" ;;
  *) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
