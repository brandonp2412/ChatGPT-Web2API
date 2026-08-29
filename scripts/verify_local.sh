#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
client_dir="${project_dir}/client"
cd "$project_dir"

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
  if [[ -n "${ANDROID_HOME:-}" && -d "${ANDROID_HOME}" ]]; then
    return 0
  fi
  for candidate in "${ANDROID_SDK_ROOT:-}" \
      "$HOME/.local/share/android-sdk" "$HOME/.local/android-sdk"; do
    if [[ -n "$candidate" && -d "$candidate" ]]; then
      export ANDROID_HOME="$candidate"
      export ANDROID_SDK_ROOT="$candidate"
      export PATH="$candidate/platform-tools:$PATH"
      return 0
    fi
  done
  return 1
}

flutter_bin="$(find_flutter)" || {
  printf 'flutter is required; set FLUTTER_BIN or install Flutter under ~/.local/flutter\n' >&2
  exit 1
}
dart_bin="$(dirname "$flutter_bin")/dart"
if [[ ! -x "$dart_bin" ]]; then
  printf 'dart executable was not found next to %s\n' "$flutter_bin" >&2
  exit 1
fi

printf '%s\n' '== Backend tests =='
./.venv/bin/pytest -q

printf '%s\n' '== Backend lint =='
./.venv/bin/ruff check src tests scripts

printf '%s\n' '== Shell syntax =='
bash -n scripts/*.sh

printf '%s\n' '== Flutter dependencies =='
(cd "$client_dir" && "$flutter_bin" pub get)

printf '%s\n' '== Dart format =='
(cd "$client_dir" && "$dart_bin" format --output=none --set-exit-if-changed lib test)

printf '%s\n' '== Flutter tests =='
(cd "$client_dir" && "$flutter_bin" test --no-pub)

printf '%s\n' '== Flutter analysis =='
(cd "$client_dir" && "$flutter_bin" analyze --no-pub)

printf '%s\n' '== Linux debug build =='
(cd "$client_dir" && "$flutter_bin" build linux --debug --no-pub)

printf '%s\n' '== Android debug build =='
if ! configure_android_sdk; then
  printf 'Android SDK not found; set ANDROID_HOME or ANDROID_SDK_ROOT\n' >&2
  exit 1
fi
android_build_args=()
if command -v waydroid >/dev/null 2>&1 && waydroid status | grep -Eq 'Session:[[:space:]]+RUNNING'; then
  bridge_host="${SLOPPA_HOST:-192.168.240.1}"
  bridge_url="${BRIDGE_URL:-http://${bridge_host}:8080}"
  bridge_url="${bridge_url%/}"
  android_build_args+=("--dart-define=SLOPPA_BRIDGE_URL=${bridge_url}")
fi
(cd "$client_dir" && "$flutter_bin" build apk --debug --no-pub "${android_build_args[@]}")

if command -v waydroid >/dev/null 2>&1; then
  if waydroid status | grep -Eq 'Session:[[:space:]]+RUNNING'; then
    printf '%s\n' '== Waydroid session =='
    waydroid status
    if ! command -v curl >/dev/null 2>&1; then
      printf 'curl is required to verify the Waydroid bridge\n' >&2
      exit 1
    fi
    bridge_host="${SLOPPA_HOST:-192.168.240.1}"
    bridge_url="${BRIDGE_URL:-http://${bridge_host}:8080}"
    bridge_url="${bridge_url%/}"
    curl --silent --show-error --fail --max-time 3 "$bridge_url/health" >/dev/null
    printf 'Waydroid bridge reachable at %s\n' "$bridge_url"
  else
    printf '%s\n' 'Waydroid installed but session is not running; device checks skipped.'
  fi
fi

printf '%s\n' 'Local verification completed successfully.'
