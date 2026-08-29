#!/usr/bin/env bash
set -euo pipefail

# Launch the bridge-backed Flutter client on a running Waydroid device.
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
client_dir="${project_dir}/client"
bridge_host="${SLOPPA_HOST:-192.168.240.1}"
bridge_url="${BRIDGE_URL:-http://${bridge_host}:8080}"
bridge_url="${bridge_url%/}"
device="${WAYDROID_DEVICE:-}"

find_flutter() {
  if [[ -n "${FLUTTER_BIN:-}" && -x "${FLUTTER_BIN}" ]]; then
    printf '%s\n' "${FLUTTER_BIN}"
    return 0
  fi
  if command -v flutter >/dev/null 2>&1; then
    command -v flutter
    return 0
  fi
  for candidate in "$HOME/.local/flutter/bin/flutter" "$HOME/.local/opt/flutter/bin/flutter"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

configure_android_sdk() {
  if command -v adb >/dev/null 2>&1; then
    return 0
  fi
  for candidate in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
      "$HOME/.local/share/android-sdk" "$HOME/.local/android-sdk"; do
    if [[ -n "$candidate" && -x "$candidate/platform-tools/adb" ]]; then
      export ANDROID_HOME="$candidate"
      export ANDROID_SDK_ROOT="$candidate"
      export PATH="$candidate/platform-tools:$PATH"
      return 0
    fi
  done
  return 1
}

connect_device() {
  local target="$1"
  [[ "$target" == *:* ]] || return 0
  if command -v timeout >/dev/null 2>&1; then
    timeout 8s adb connect "$target" >/dev/null
  else
    adb connect "$target" >/dev/null
  fi
}

if ! command -v waydroid >/dev/null 2>&1; then
  printf 'waydroid is required; install/start the container first\n' >&2
  exit 1
fi
if ! waydroid status | grep -Eq 'Session:[[:space:]]+RUNNING'; then
  printf 'Waydroid session is not running; start it with: waydroid session start\n' >&2
  exit 1
fi
if ! configure_android_sdk; then
  printf 'adb is required; set ANDROID_HOME or install Android platform-tools\n' >&2
  exit 1
fi
flutter_bin="$(find_flutter)" || {
  printf 'flutter is required; set FLUTTER_BIN or install Flutter under ~/.local/flutter\n' >&2
  exit 1
}

if [[ -n "$device" ]]; then
  if ! connect_device "$device"; then
    printf 'could not connect to ADB device %s\n' "$device" >&2
    exit 1
  fi
else
  device="$(adb devices | awk '$2 == "device" {print $1; exit}')"
fi
if [[ -z "$device" ]]; then
  printf 'no connected ADB device; connect Waydroid or set WAYDROID_DEVICE\n' >&2
  exit 1
fi
if [[ "$(adb -s "$device" get-state 2>/dev/null || true)" != "device" ]]; then
  printf 'ADB target %s is not ready\n' "$device" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  printf 'curl is required to verify the local bridge before launch\n' >&2
  exit 1
fi
if ! curl --silent --show-error --fail --max-time 3 "$bridge_url/health" >/dev/null; then
  printf 'bridge is not reachable at %s; start the backend first\n' "$bridge_url" >&2
  exit 1
fi

cd "$client_dir"
export SLOPPA_HOST="$bridge_host"
export SLOPPA_ALLOW_UNAUTH_REMOTE="${SLOPPA_ALLOW_UNAUTH_REMOTE:-1}"
exec "$flutter_bin" run -d "$device" \
  --dart-define="SLOPPA_BRIDGE_URL=${bridge_url}" "$@"
